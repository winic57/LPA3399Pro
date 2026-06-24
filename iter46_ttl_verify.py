#!/usr/bin/env python3
"""TTL automation for iter46 verification.

Sends commands to /dev/ttyUSB0 at 1500000 baud (BOTHER) and captures output.
Each command is followed by a unique sentinel: `echo <TOKEN>:$?` to delimit.
"""
import os
import sys
import time
import select
import fcntl
import struct
import termios

PORT = "/dev/ttyUSB0"
BAUD = 1500000

TCGETS2 = 0x802C542A
TCSETS2 = 0x402C542B
CBAUD = 0x100F
BOTHER = 0x1000
CSIZE = 0x0030


def configure(fd, baud):
    buf = bytearray(44)
    fcntl.ioctl(fd, TCGETS2, buf, True)
    fields = list(struct.unpack("IIII20BII", buf))
    fields[0] = 0
    fields[1] = 0
    fields[2] &= ~(CBAUD | CSIZE)
    fields[2] |= BOTHER | termios.CS8 | termios.CLOCAL | termios.CREAD
    fields[3] = 0
    fields[-2] = baud
    fields[-1] = baud
    fcntl.ioctl(fd, TCSETS2, struct.pack("IIII20BII", *fields))


def drain(fd, timeout=0.5):
    end = time.time() + timeout
    out = b""
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            chunk = os.read(fd, 4096)
            if not chunk:
                break
            out += chunk
    return out


def send_cmd(fd, cmd, sentinel, timeout=30.0):
    """Write `cmd\n` to fd; read until sentinel bytes appear or timeout."""
    payload = f"{cmd}\n".encode()
    os.write(fd, payload)
    sentinel_b = sentinel.encode()
    deadline = time.time() + timeout
    buf = b""
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.5)
        if r:
            chunk = os.read(fd, 4096)
            if not chunk:
                break
            buf += chunk
            if sentinel_b in buf:
                break
    return buf


def main():
    out_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/iter46_run.log"
    fd = os.open(PORT, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    configure(fd, BAUD)

    log_lines = []

    def log(s):
        print(s)
        log_lines.append(s)

    log("=== iter46 TTL verification — /dev/ttyUSB0 @ 1500000 ===")
    log(f"=== log file: {out_path} ===\n")

    # Wake console
    os.write(fd, b"\n\n\n")
    time.sleep(0.5)
    wake = drain(fd, 1.0)
    log("--- wake ---")
    log(wake.decode(errors="replace"))

    # Quick alive check
    alive_token = f"__ITER46_ALIVE_{int(time.time()*1000)}__"
    alive_out = send_cmd(fd, f"echo ALIVE_ITER46; echo {alive_token}:$?", alive_token, 10.0)
    log("\n--- alive ---")
    log(alive_out.decode(errors="replace"))

    if alive_token.encode() not in alive_out:
        log("\n!!! Board not responding. !!!")
        os.close(fd)
        with open(out_path, "w") as f:
            f.write("\n".join(log_lines))
        return

    log("\n--- Board alive, proceeding with diagnostics ---\n")

    cmds = [
        ("uname -a", "__ITER46_UNAME__"),
        ("cat /proc/cmdline", "__ITER46_CMDLINE__"),
        ("cat /sys/firmware/devicetree/base/ethernet@fe300000/phy-mode", "__ITER46_PHYMODE__"),
        ("cat /sys/firmware/devicetree/base/ethernet@fe300000/clock-in-out 2>/dev/null || cat /sys/firmware/devicetree/base/ethernet@fe300000/clock_in_out 2>/dev/null", "__ITER46_CLKINOUT__"),
        ("fdtget /sys/firmware/fdt /ethernet@fe300000 assigned-clock-parents 2>&1", "__ITER46_ASP__"),
        ("fdtget /sys/firmware/fdt /ethernet@fe300000 snps,burst_len 2>&1", "__ITER46_BURST__"),
        ("fdtget /sys/firmware/fdt /ethernet@fe300000 snps,reset-gpio 2>&1", "__ITER46_RESETGPIO__"),
        ("dmesg | tail -60", "__ITER46_DMESG_PRE__"),
        ("ip -br link show", "__ITER46_LINK_PRE__"),
        ("cat /sys/kernel/debug/clk/clk_summary 2>/dev/null | grep -iE 'clk_gmac|aclk_gmac|pclk_gmac|clkin_gmac' | head -20", "__ITER46_CLK_PRE__"),
        ("echo '--- NOW: ip link set eth0 up ---'", "__ITER46_MARKER_UP__"),
        ("ip link set eth0 up 2>&1; echo EXIT_CODE=$?", "__ITER46_UP__"),
        ("sleep 2", "__ITER46_SLEEP__"),
        ("dmesg | tail -30", "__ITER46_DMESG_POST__"),
        ("ip -br link show eth0", "__ITER46_LINK_POST__"),
        ("ethtool eth0 2>&1 | head -25", "__ITER46_ETHTOOL__"),
        ("cat /sys/kernel/debug/clk/clk_summary 2>/dev/null | grep -iE 'clk_gmac|aclk_gmac|pclk_gmac|clkin_gmac' | head -20", "__ITER46_CLK_POST__"),
        ("echo ITER46_ALL_DONE", "__ITER46_DONE__"),
    ]

    for cmd, token in cmds:
        log(f"\n========== CMD: {cmd} ==========")
        out = send_cmd(fd, f"{cmd}; echo {token}:$?", token, 60.0)
        log(out.decode(errors="replace"))

    os.close(fd)

    with open(out_path, "w") as f:
        f.write("\n".join(log_lines))
    print(f"\n=== Saved log to {out_path} ({os.path.getsize(out_path)} bytes) ===")


if __name__ == "__main__":
    main()
