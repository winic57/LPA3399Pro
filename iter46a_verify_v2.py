#!/usr/bin/env python3
"""iter46a 验证 v2 — 慢节奏,每条命令等 3s,避免输出交错"""
import os, sys, time, select, fcntl, struct, termios

PORT = "/dev/ttyUSB0"
BAUD = 1500000
TCGETS2 = 0x802C542A; TCSETS2 = 0x402C542B
CBAUD = 0x100F; BOTHER = 0x1000; CSIZE = 0x0030

def set_baud(fd, baud):
    buf = bytearray(44)
    fcntl.ioctl(fd, TCGETS2, buf, True)
    f = list(struct.unpack("IIII20BII", buf))
    f[0]=0; f[1]=0
    f[2] &= ~(CBAUD|CSIZE); f[2] |= BOTHER|termios.CS8|termios.CLOCAL|termios.CREAD
    f[3]=0; f[-2]=baud; f[-1]=baud
    fcntl.ioctl(fd, TCSETS2, struct.pack("IIII20BII", *f))

def drain(fd, t=1.0):
    end = time.time()+t; out=b""
    while time.time()<end:
        r,_,_ = select.select([fd],[],[],0.1)
        if r:
            c = os.read(fd, 4096)
            if not c: break
            out += c
    return out

def send_and_wait(fd, cmd, settle=3.0, total_timeout=30.0):
    """Send cmd, wait settle seconds, then drain everything."""
    os.write(fd, f"{cmd}\n".encode())
    time.sleep(0.3)  # let the command echo appear
    # Read until we see a fresh prompt after the output
    end = time.time() + total_timeout
    buf = b""
    last_data = time.time()
    while time.time() < end:
        r,_,_ = select.select([fd],[],[],0.5)
        if r:
            c = os.read(fd, 4096)
            if c:
                buf += c
                last_data = time.time()
        # Stop after `settle` seconds of silence following last data
        if time.time() - last_data > settle and buf:
            break
    return buf

def main():
    out_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/iter46a_v2.log"
    fd = os.open(PORT, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    set_baud(fd, BAUD)
    log = []
    def p(s):
        print(s); log.append(s)

    p(f"=== iter46a GMAC v2 verify — {time.ctime()} ===\n")
    os.write(fd, b"\n")
    time.sleep(0.5)
    drain(fd, 1.0)

    cmds = [
        "uname -r",
        "echo '--- DTB properties ---'",
        "cat /sys/firmware/devicetree/base/ethernet@fe300000/phy-mode && echo",
        "fdtget /sys/firmware/fdt /ethernet@fe300000 assigned-clock-parents",
        "fdtget /sys/firmware/fdt /ethernet@fe300000 snps,reset-delays-us",
        "fdtget /sys/firmware/fdt /ethernet@fe300000 resets",
        "fdtget /sys/firmware/fdt /ethernet@fe300000 snps,burst_len 2>&1 || echo 'snps,burst_len NOT FOUND (good)'",
        "echo '--- eth0 state BEFORE up ---'",
        "ip -br link show eth0",
        "echo '--- clk_summary BEFORE up ---'",
        "cat /sys/kernel/debug/clk/clk_summary 2>/dev/null | grep -E 'clk_gmac|clkin_gmac' | head -5",
        "echo '--- NOW: ip link set eth0 up ---'",
        "ip link set eth0 up 2>&1; echo \"EXIT_CODE=\$?\"",
        "echo '--- waiting 3s ---'",
        "sleep 3",
        "echo '--- eth0 state AFTER up ---'",
        "ip -br link show eth0",
        "echo '--- clk_summary AFTER up ---'",
        "cat /sys/kernel/debug/clk/clk_summary 2>/dev/null | grep -E 'clk_gmac|clkin_gmac' | head -5",
        "echo '--- dmesg GMAC-related ---'",
        "dmesg | grep -iE 'gmac|eth0|stmmac|dwmac|phy|Failed to reset|DMA' | tail -40",
        "echo '--- ethtool eth0 ---'",
        "ethtool eth0 2>&1 | head -30",
        "echo ITER46A_V2_DONE",
    ]

    for cmd in cmds:
        p(f"\n>>> {cmd}")
        o = send_and_wait(fd, cmd, settle=2.5, total_timeout=45.0)
        p(o.decode(errors="replace"))

    os.close(fd)
    with open(out_path, "w") as f: f.write("\n".join(log))
    print(f"\n=== Saved to {out_path} ({os.path.getsize(out_path)} bytes) ===")

if __name__ == "__main__":
    main()
