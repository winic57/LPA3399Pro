#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#ifndef SYS_gettid
#define SYS_gettid __NR_gettid
#endif

typedef uint32_t u32;

union pcie_dma_ioctl_param_u {
    struct { u32 idx, l_widx, r_widx, size, type; } in;
    struct { u32 lwa, rwa; } out;
    u32 lra;
    u32 count;
    unsigned char raw[20];
};

#define PCIE_BASE 'P'
#define PCIE_DMA_START _IOW(PCIE_BASE, 0, union pcie_dma_ioctl_param_u)
#define PCIE_DMA_GET_LOCAL_READ_BUFFER_INDEX _IOR(PCIE_BASE, 1, union pcie_dma_ioctl_param_u)
#define PCIE_DMA_GET_LOCAL_REMOTE_WRITE_BUFFER_INDEX _IOR(PCIE_BASE, 2, union pcie_dma_ioctl_param_u)
#define PCIE_DMA_SET_LOCAL_READ_BUFFER_INDEX _IOW(PCIE_BASE, 3, union pcie_dma_ioctl_param_u)
#define PCIE_DMA_SYNC_BUFFER_FOR_CPU _IOW(PCIE_BASE, 4, union pcie_dma_ioctl_param_u)
#define PCIE_DMA_SYNC_BUFFER_TO_DEVICE _IOW(PCIE_BASE, 5, union pcie_dma_ioctl_param_u)
#define PCIE_DMA_WAIT_TRANSFER_COMPLETE _IO(PCIE_BASE, 6)
#define PCIE_DMA_SET_LOOP_COUNT _IOW(PCIE_BASE, 7, union pcie_dma_ioctl_param_u)

#define MAX_FD 4096
#define MAX_MAPS 32
#define SZ_1M (1024U * 1024U)
#define PCIE_DMA_BUF_SIZE SZ_1M
#define PCIE_DMA_RD_BUF_SIZE (8U * SZ_1M)
#define PCIE_DMA_WR_BUF_SIZE (8U * SZ_1M)
#define PCIE_DMA_SET_DATA_CHECK_POS (SZ_1M - 0x4)
#define PCIE_DMA_SET_LOCAL_IDX_POS  (SZ_1M - 0x8)
#define PCIE_DMA_SET_BUF_SIZE_POS   (SZ_1M - 0xc)

static int log_fd = -1;
static bool fd_is_pcie[MAX_FD];
static __thread int in_hook;
struct map_ent { void *addr; size_t len; off_t off; int fd; };
static struct map_ent maps[MAX_MAPS];

static long tid(void) { return syscall(SYS_gettid); }


static void open_log(void) {
    if (log_fd >= 0) return;
    const char *p = getenv("PCIE_SNIFFER_LOG");
    char def[128];
    if (!p || !*p) {
        snprintf(def, sizeof(def), "/tmp/pcie_sniffer.%ld.log", (long)getpid());
        p = def;
    }
    log_fd = syscall(SYS_openat, AT_FDCWD, p, O_WRONLY|O_CREAT|O_APPEND|O_CLOEXEC, 0644);
}

static void log_line(const char *fmt, ...) {
    if (in_hook) return;
    in_hook = 1;
    open_log();
    if (log_fd >= 0) {
        struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts);
        char prefix[96];
        int n = snprintf(prefix, sizeof(prefix), "%lld.%09ld pid=%ld tid=%ld ",
                         (long long)ts.tv_sec, ts.tv_nsec, (long)getpid(), tid());
        if (n > 0) syscall(SYS_write, log_fd, prefix, (size_t)n);
        char buf[4096];
        va_list ap; va_start(ap, fmt);
        n = vsnprintf(buf, sizeof(buf), fmt, ap);
        va_end(ap);
        if (n > 0) syscall(SYS_write, log_fd, buf, (size_t)((n < (int)sizeof(buf)) ? n : (int)sizeof(buf)-1));
        syscall(SYS_write, log_fd, "\n", 1);
    }
    in_hook = 0;
}

static bool is_pcie_path(const char *path) {
    return path && strcmp(path, "/dev/pcie-dev") == 0;
}

static const char *cmd_name(unsigned long cmd) {
    switch (cmd) {
    case PCIE_DMA_START: return "START";
    case PCIE_DMA_GET_LOCAL_READ_BUFFER_INDEX: return "GET_LREAD_IDX";
    case PCIE_DMA_GET_LOCAL_REMOTE_WRITE_BUFFER_INDEX: return "GET_LRWRITE_IDX";
    case PCIE_DMA_SET_LOCAL_READ_BUFFER_INDEX: return "SET_LREAD_IDX";
    case PCIE_DMA_SYNC_BUFFER_FOR_CPU: return "SYNC_FOR_CPU";
    case PCIE_DMA_SYNC_BUFFER_TO_DEVICE: return "SYNC_TO_DEV";
    case PCIE_DMA_WAIT_TRANSFER_COMPLETE: return "WAIT_COMPLETE";
    case PCIE_DMA_SET_LOOP_COUNT: return "SET_LOOP_COUNT";
    default: return "UNKNOWN";
    }
}

static const char *type_name(u32 type) {
    switch (type) {
    case 0: return "DATA_SND";
    case 1: return "DATA_RCV_ACK";
    case 2: return "DATA_FREE_ACK";
    default: return "TYPE?";
    }
}

static void raw_hex(char *dst, size_t dsz, const unsigned char *p, size_t n) {
    size_t o = 0;
    for (size_t i = 0; i < n && o + 3 < dsz; i++)
        o += snprintf(dst + o, dsz - o, "%02x", p[i]);
}

static struct map_ent *first_map(void) {
    for (int i = 0; i < MAX_MAPS; i++) if (maps[i].addr && maps[i].len) return &maps[i];
    return NULL;
}

static void dump_mem_at(const char *tag, size_t off, size_t len) {
    struct map_ent *m = first_map();
    if (!m || off >= m->len) return;
    if (len > 64) len = 64;
    if (off + len > m->len) len = m->len - off;
    char hx[200]; raw_hex(hx, sizeof(hx), (unsigned char*)m->addr + off, len);
    log_line("MEM %s off=0x%zx len=%zu hex=%s", tag, off, len, hx);
}

static void dump_pcie_summary(const char *why, const union pcie_dma_ioctl_param_u *p) {
    struct map_ent *m = first_map();
    if (!m) return;
    log_line("MAP_SUMMARY why=%s base=%p len=0x%zx", why, m->addr, m->len);
    dump_mem_at("base0", 0, 64);
    dump_mem_at("base0_markers", PCIE_DMA_SET_BUF_SIZE_POS, 12);
    dump_mem_at("base8M", PCIE_DMA_WR_BUF_SIZE, 64);
    dump_mem_at("base8M_markers", PCIE_DMA_WR_BUF_SIZE + PCIE_DMA_SET_BUF_SIZE_POS, 12);
    if (p) {
        size_t idx = p->in.idx & 7U;
        size_t lw = p->in.l_widx & 7U;
        size_t rw = p->in.r_widx & 7U;
        dump_mem_at("idx_buf", idx * PCIE_DMA_BUF_SIZE, 64);
        dump_mem_at("l_widx_buf", lw * PCIE_DMA_BUF_SIZE, 64);
        dump_mem_at("r_widx_buf", rw * PCIE_DMA_BUF_SIZE, 64);
        dump_mem_at("idx_buf_8M", PCIE_DMA_WR_BUF_SIZE + idx * PCIE_DMA_BUF_SIZE, 64);
    }
}

__attribute__((constructor)) static void ctor(void) {
    log_line("pcie_dev_sniffer loaded version=20260707c-ioctl-only");
}

int open(const char *path, int flags, ...) {
    mode_t mode = 0; if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap); }
    int fd = (int)syscall(SYS_openat, AT_FDCWD, path, flags, mode);
    if (fd >= 0 && fd < MAX_FD && is_pcie_path(path)) { fd_is_pcie[fd] = true; log_line("OPEN fd=%d path=%s flags=0x%x", fd, path, flags); }
    return fd;
}

int open64(const char *path, int flags, ...) {
    mode_t mode = 0; if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap); }
    int fd = (int)syscall(SYS_openat, AT_FDCWD, path, flags, mode);
    if (fd >= 0 && fd < MAX_FD && is_pcie_path(path)) { fd_is_pcie[fd] = true; log_line("OPEN64 fd=%d path=%s flags=0x%x", fd, path, flags); }
    return fd;
}

int openat(int dirfd, const char *path, int flags, ...) {
    mode_t mode = 0; if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap); }
    int fd = (int)syscall(SYS_openat, dirfd, path, flags, mode);
    if (fd >= 0 && fd < MAX_FD && is_pcie_path(path)) { fd_is_pcie[fd] = true; log_line("OPENAT fd=%d path=%s flags=0x%x", fd, path, flags); }
    return fd;
}

int close(int fd) {
    if (fd >= 0 && fd < MAX_FD && fd_is_pcie[fd]) { log_line("CLOSE fd=%d", fd); fd_is_pcie[fd] = false; }
    return (int)syscall(SYS_close, fd);
}

void *mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset) {
    void *ret = (void *)syscall(SYS_mmap, addr, length, prot, flags, fd, offset);
    if (fd >= 0 && fd < MAX_FD && fd_is_pcie[fd] && ret != MAP_FAILED) {
        for (int i = 0; i < MAX_MAPS; i++) if (!maps[i].addr) { maps[i] = (struct map_ent){ret, length, offset, fd}; break; }
        log_line("MMAP fd=%d ret=%p len=0x%zx prot=0x%x flags=0x%x off=0x%llx", fd, ret, length, prot, flags, (long long)offset);
        dump_pcie_summary("after_mmap", NULL);
    }
    return ret;
}

int munmap(void *addr, size_t length) {
    for (int i = 0; i < MAX_MAPS; i++) if (maps[i].addr == addr) { log_line("MUNMAP addr=%p len=0x%zx", addr, length); memset(&maps[i], 0, sizeof(maps[i])); break; }
    return (int)syscall(SYS_munmap, addr, length);
}

int ioctl(int fd, unsigned long request, ...) {
    void *arg = NULL; va_list ap; va_start(ap, request); arg = va_arg(ap, void*); va_end(ap);
    bool watch = (fd >= 0 && fd < MAX_FD && fd_is_pcie[fd]) || (_IOC_TYPE(request) == PCIE_BASE);
    union pcie_dma_ioctl_param_u before; memset(&before, 0, sizeof(before));
    if (watch && arg && _IOC_SIZE(request) <= sizeof(before)) memcpy(&before, arg, _IOC_SIZE(request));
    char hx_before[64] = {0}; raw_hex(hx_before, sizeof(hx_before), before.raw, sizeof(before.raw));
    if (watch) {
        log_line("IOCTL_BEFORE fd=%d cmd=0x%lx name=%s dir=%u nr=%u size=%u idx=%u l_widx=%u r_widx=%u size_in=%u type=%u/%s count=%u raw=%s",
                 fd, request, cmd_name(request), _IOC_DIR(request), _IOC_NR(request), _IOC_SIZE(request),
                 before.in.idx, before.in.l_widx, before.in.r_widx, before.in.size, before.in.type, type_name(before.in.type), before.count, hx_before);
        if (request == PCIE_DMA_START || request == PCIE_DMA_SYNC_BUFFER_TO_DEVICE) dump_pcie_summary("before_start_or_sync", &before);
    }
    errno = 0;
    int ret = (int)syscall(SYS_ioctl, fd, request, arg);
    int saved = errno;
    if (watch) {
        union pcie_dma_ioctl_param_u after; memset(&after, 0, sizeof(after));
        if (arg && _IOC_SIZE(request) <= sizeof(after)) memcpy(&after, arg, _IOC_SIZE(request));
        char hx_after[64] = {0}; raw_hex(hx_after, sizeof(hx_after), after.raw, sizeof(after.raw));
        log_line("IOCTL_AFTER fd=%d cmd=0x%lx name=%s ret=%d errno=%d idx=%u l_widx=%u r_widx=%u size_in=%u type=%u/%s out_lwa=0x%x out_rwa=0x%x lra=0x%x count=%u raw=%s",
                 fd, request, cmd_name(request), ret, saved,
                 after.in.idx, after.in.l_widx, after.in.r_widx, after.in.size, after.in.type, type_name(after.in.type),
                 after.out.lwa, after.out.rwa, after.lra, after.count, hx_after);
        if (request == PCIE_DMA_GET_LOCAL_READ_BUFFER_INDEX || request == PCIE_DMA_GET_LOCAL_REMOTE_WRITE_BUFFER_INDEX || request == PCIE_DMA_START)
            dump_pcie_summary("after_key_ioctl", &after);
    }
    errno = saved;
    return ret;
}
