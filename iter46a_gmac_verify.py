#!/usr/bin/env python3
"""iter46a GMAC 验证脚本 — 向 /dev/ttyUSB0 @1500000 发命令并捕获输出"""
import os, sys, time, select, fcntl, struct, termios

PORT = "/dev/ttyUSB0"
BAUD = 1500000
TCGETS2 = 0x802C542A
TCSETS2 = 0x402C542B
CBAUD = 0x100F
BOTHER = 0x1000
CSIZE = 0x0030

def set_baud(fd, baud):
    buf = bytearray(44)
    fcntl.ioctl(fd, TCGETS2, buf, True)
    f = list(struct.unpack("IIII20BII", buf))
    f[0]=0; f[1]=0
    f[2] &= ~(CBAUD|CSIZE); f[2] |= BOTHER|termios.CS8|termios.CLOCAL|termios.CREAD
    f[3]=0; f[-2]=baud; f[-1]=baud
    fcntl.ioctl(fd, TCSETS2, struct.pack("IIII20BII", *f))

def drain(fd, timeout=0.5):
    end = time.time() + timeout
    out = b""
    while time.time() < end:
        r,_,_ = select.select([fd],[],[],0.1)
        if r:
            c = os.read(fd, 4096)
            if not c: break
            out += c
    return out

def send(fd, cmd, sentinel, timeout=30.0):
    os.write(fd, f"{cmd}\n".encode())
    sb = sentinel.encode()
    end = time.time() + timeout
    buf = b""
    while time.time() < end:
        r,_,_ = select.select([fd],[],[],0.5)
        if r:
            c = os.read(fd, 4096)
            if not c: break
            buf += c
            if sb in buf: break
    return buf

def main():
    out_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/iter46a_verify.log"
    fd = os.open(PORT, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    set_baud(fd, BAUD)
    log = []
    def p(s):
        print(s); log.append(s)

    p(f"=== iter46a GMAC verification — {time.ctime()} ===\n")
    # Wake
    os.write(fd, b"\n\n")
    time.sleep(0.5)
    wake = drain(fd, 1.0)
    p("--- wake ---")
    p(wake.decode(errors="replace"))

    # Verify alive
    t = f"__ITER46A_ALIVE_{int(time.time()*1000)}__"
    o = send(fd, f"echo ITER46A_ALIVE; echo {t}:$?", t, 10)
    p("--- alive ---")
    p(o.decode(errors="replace"))
    if t.encode() not in o:
        p("\n!!! Board not responding, abort. !!!")
        os.close(fd)
        with open(out_path,"w") as f: f.write("\n".join(log))
        return

    p("\n--- Board alive, running GMAC diagnostics ---\n")

    cmds = [
        ("uname -a", "__A1__"),
        ("cat /sys/firmware/devicetree/base/ethernet@fe300000/phy-mode", "__A2__"),
        ("fdtget /sys/firmware/fdt /ethernet@fe300000 assigned-clock-parents 2>&1", "__A3__"),
        ("fdtget /sys/firmware/fdt /ethernet@fe300000 snps,reset-delays-us 2>&1", "__A4__"),
        ("fdtget /sys/firmware/fdt /ethernet@fe300000 snps,burst_len 2>&1", "__A5__"),
        ("fdtget /sys/firmware/fdt /ethernet@fe300000 resets 2>&1", "__A6__"),
        ("ip -br link show", "__A7__"),
        ("dmesg | tail -30", "__A8__"),
        ("cat /sys/kernel/debug/clk/clk_summary 2>/dev/null | grep -iE 'clk_gmac|aclk_gmac|pclk_gmac|clkin_gmac' | head -10", "__A9__"),
        ("echo '--- NOW: ip link set eth0 up ---'", "__A10__"),
        ("ip link set eth0 up 2>&1; echo EXIT_CODE=$?", "__A11__"),
        ("sleep 2", "__A12__"),
        ("dmesg | tail -30", "__A13__"),
        ("ip -br link show eth0", "__A14__"),
        ("ethtool eth0 2>&1 | head -25", "__A15__"),
        ("cat /sys/kernel/debug/clk/clk_summary 2>/dev/null | grep -iE 'clk_gmac|aclk_gmac|pclk_gmac|clkin_gmac' | head -10", "__A16__"),
        ("echo '--- dhclient eth0 ---'", "__A17__"),
        ("timeout 15 dhclient eth0 2>&1; echo DHCP_EXIT=$?", "__A18__"),
        ("ip addr show eth0", "__A19__"),
        ("ip route 2>&1 | head -5", "__A20__"),
        ("echo '--- ping test ---'", "__A21__"),
        ("ping -c 3 -W 2 192.168.1.1 2>&1 || ping -c 3 -W 2 8.8.8.8 2>&1", "__A22__"),
        ("echo ITER46A_ALL_DONE", "__A23__"),
    ]

    for cmd, token in cmds:
        p(f"\n========== CMD: {cmd} ==========")
        o = send(fd, f"{cmd}; echo {token}:$?", token, 60.0)
        p(o.decode(errors="replace"))

    os.close(fd)
    with open(out_path,"w") as f: f.write("\n".join(log))
    print(f"\n=== Saved to {out_path} ({os.path.getsize(out_path)} bytes) ===")

if __name__ == "__main__":
    main()
