import os
import termios
import fcntl
import struct
import sys
import time
import select

TCGETS2 = 0x802C542A
TCSETS2 = 0x402C542B
CBAUD = 0x100F
BOTHER = 0x1000
CSIZE = 0x0030

def configure_termios2(fd, baud):
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

def main():
    port = "/dev/ttyUSB0"
    baud = 1500000
    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        configure_termios2(fd, baud)
        print("Sending newlines to wake up console...")
        os.write(fd, b"\n\n\n")
        time.sleep(1)
        print("Reading response (10 seconds)...")
        start = time.time()
        while time.time() - start < 10:
            r, _, _ = select.select([fd], [], [], 0.5)
            if r:
                data = os.read(fd, 4096)
                if data:
                    sys.stdout.buffer.write(data)
                    sys.stdout.buffer.flush()
    finally:
        os.close(fd)

if __name__ == "__main__":
    main()
