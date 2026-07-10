#!/usr/bin/env python3
"""Build an experimental RK3399Pro NPU boot.img for USB-NTB validation.

Input: vendor NPU Android boot.img (RK1808/RK3399Pro-NPU side).
Output: boot.img with:
  - DT pcie@fc400000 configurable mode:
      * noep: status = "disabled" to avoid endpoint link-loop blocking init.
      * deferred: keep status = "okay" and add opt-in properties for the
        companion vendor EP-driver patch to bound the link wait at init.
  - ramdisk /etc/init.d/.usb_config = usb_ntb_en to enumerate 2207:0019.
  - ttyFIQ0 getty enabled and start_rknn.sh logging to console.

The repacker preserves the original Android boot v0 second-stage length/alignment;
Rockchip U-Boot may reject truncated second-stage images.
"""
from __future__ import annotations
import argparse, gzip, hashlib, os, shutil, struct, subprocess, tempfile
from pathlib import Path

PAGE_DEFAULT = 2048
MAGIC = b"ANDROID!"
FDT_MAGIC = b"\xd0\x0d\xfe\xed"


def run(cmd, cwd=None, stdout=None, input=None, stderr=None):
    return subprocess.run(cmd, cwd=cwd, check=True, stdout=stdout, input=input, stderr=stderr)


def cpio_needs_fakeroot() -> bool:
    """Non-root cannot create/preserve dev nodes from the vendor ramdisk."""
    return os.geteuid() != 0 and shutil.which("fakeroot") is not None


def run_cpio_extract(raw_cpio: bytes, rd: Path, fakeroot_state: Path):
    cmd = ["cpio", "-id", "--no-absolute-filenames", "--quiet"]
    if cpio_needs_fakeroot():
        return run(["fakeroot", "-s", str(fakeroot_state), "--", *cmd], cwd=rd,
                   input=raw_cpio, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    proc = subprocess.run(cmd, cwd=rd, input=raw_cpio, stdout=subprocess.DEVNULL,
                          stderr=subprocess.PIPE)
    if proc.returncode != 0:
        err = proc.stderr.decode(errors="replace")
        # Fallback for restricted filesystems: keep going only for device-node mknod denial.
        if "Cannot mknod" not in err:
            raise subprocess.CalledProcessError(proc.returncode, cmd, stderr=proc.stderr)
        print("WARN: cpio could not create some device nodes; install/use fakeroot to preserve them", flush=True)
    return proc


def run_cpio_pack(rd: Path, payload: bytes, fakeroot_state: Path):
    cmd = ["cpio", "-o", "-H", "newc", "--quiet"]
    if fakeroot_state.exists() and shutil.which("fakeroot") is not None:
        cmd = ["fakeroot", "-i", str(fakeroot_state), "--", *cmd]
    return subprocess.run(cmd, cwd=rd, input=payload, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=True)


def align(data: bytes, page: int) -> bytes:
    return data + b"\0" * ((page - (len(data) % page)) % page)


def unpack_boot(img: Path, out: Path):
    data = img.read_bytes()
    if data[:8] != MAGIC:
        raise SystemExit(f"{img}: not Android boot image")
    ks, kaddr, rs, raddr, ss, saddr, tags, page, dt_size, unused = struct.unpack_from("<10I", data, 8)
    off = page
    kernel = data[off:off+ks]; off += ((ks + page - 1)//page)*page
    ramdisk = data[off:off+rs]; off += ((rs + page - 1)//page)*page
    second = data[off:off+ss]
    (out/"kernel.bin").write_bytes(kernel)
    (out/"ramdisk.bin").write_bytes(ramdisk)
    (out/"second.bin").write_bytes(second)
    return bytearray(data[:page]), page, kernel, ramdisk, second


def extract_second_dtb(second: bytes, out_dtb: Path):
    off = second.find(FDT_MAGIC)
    if off < 0:
        raise SystemExit("no FDT magic in second stage")
    size = struct.unpack(">I", second[off+4:off+8])[0]
    out_dtb.write_bytes(second[off:off+size])
    return off, size


def patch_dtb(dtb: Path, out_dtb: Path, work: Path, pcie_mode: str):
    dts = work/"npu.dts"
    run(["dtc", "-I", "dtb", "-O", "dts", "-o", str(dts), str(dtb)])
    text = dts.read_text()
    node = "pcie@fc400000 {"
    i = text.find(node)
    if i < 0:
        raise SystemExit("pcie@fc400000 not found in NPU DT")
    end = text.find("\n\t};", i)
    if pcie_mode == "noep":
        j = text.find('status = "okay";', i, end)
        if j < 0:
            raise SystemExit("pcie status=okay not found in pcie@fc400000")
        text = text[:j] + 'status = "disabled"; /* noep USB-NTB test */' + text[j+len('status = "okay";'):]
    elif pcie_mode == "deferred":
        j = text.find('status = "okay";', i, end)
        if j < 0:
            raise SystemExit("pcie status=okay not found in pcie@fc400000")
        props = []
        if 'rockchip,ep-nonblocking-probe;' not in text[i:end]:
            props.append('\t\trockchip,ep-nonblocking-probe; /* requires vendor EP-driver patch */')
        if 'rockchip,ep-link-wait-ms' not in text[i:end]:
            props.append('\t\trockchip,ep-link-wait-ms = <0x32>; /* 50 ms bounded init wait */')
        if props:
            text = text[:j] + '\n'.join(props) + '\n' + text[j:]
    else:
        raise SystemExit(f"unknown pcie mode: {pcie_mode}")
    dts.write_text(text)
    run(["dtc", "-I", "dts", "-O", "dtb", "-o", str(out_dtb), str(dts)])


def patch_ramdisk(ramdisk_gz: bytes, out_gz: Path, work: Path, pcie_mode: str):
    rd = work/"ramdisk"
    rd.mkdir()
    raw_cpio = gzip.decompress(ramdisk_gz)
    fakeroot_state = work/"fakeroot.state"
    run_cpio_extract(raw_cpio, rd, fakeroot_state)
    cfg = rd/"etc/init.d/.usb_config"
    cfg.parent.mkdir(parents=True, exist_ok=True)
    cfg.write_text("usb_ntb_en\n")
    inittab = rd/"etc/inittab"
    if inittab.exists():
        text = inittab.read_text()
        text = text.replace("#ttyFIQ0::respawn:/sbin/getty -L  ttyFIQ0 0 vt100 # GENERIC_SERIAL",
                            "ttyFIQ0::respawn:/sbin/getty -L ttyFIQ0 0 vt100 # GENERIC_SERIAL")
        inittab.write_text(text)
    sr = rd/"usr/bin/start_rknn.sh"
    if sr.exists():
        text = sr.read_text()
        text = text.replace("  rknn_server #>/dev/null 2>&1",
                            '  echo "NPU_DEBUG start rknn_server $(date)" >/dev/console\n  RKNN_SERVER_LOGLEVEL=5 TRANSFER_LOG_LEVEL=5 rknn_server')
        sr.write_text(text)
    if pcie_mode == "deferred":
        helper = rd/"usr/bin/npu_pcie_deferred_trigger.sh"
        helper.write_text("""#!/bin/sh
set -eu
PCIE_SYSFS=${PCIE_SYSFS:-/sys/devices/platform/fc000000.pcie/pcie_deferred}
DELAY=${NPU_PCIE_DEFERRED_DELAY_SEC:-0}
echo "NPU_PCIE_DEFERRED_TRIGGER delay=${DELAY} path=${PCIE_SYSFS}" >/dev/console
sleep "${DELAY}"
if [ -e "${PCIE_SYSFS}" ]; then
  echo 1 > "${PCIE_SYSFS}"
  echo "NPU_PCIE_DEFERRED_TRIGGER done" >/dev/console
else
  echo "NPU_PCIE_DEFERRED_TRIGGER missing ${PCIE_SYSFS}" >/dev/console
  exit 1
fi
""")
        helper.chmod(0o755)
    # Stable order; cpio wants relative paths on stdin and emits archive on stdout.
    names = ["."] + [str(p.relative_to(rd)) for p in sorted(rd.rglob("*"))]
    payload = ("\n".join(names) + "\n").encode()
    proc = run_cpio_pack(rd, payload, fakeroot_state)
    out_gz.write_bytes(gzip.compress(proc.stdout, compresslevel=9, mtime=0))


def repack(orig_header: bytearray, page: int, kernel: bytes, ramdisk: bytes, orig_second: bytes, new_dtb: bytes, out: Path):
    second = bytearray(orig_second)
    off = second.find(FDT_MAGIC)
    old_size = struct.unpack(">I", second[off+4:off+8])[0]
    if len(new_dtb) > len(second) - off:
        raise SystemExit("new dtb too large for preserved second stage")
    second[off:off+old_size] = b"\0" * old_size
    second[off:off+len(new_dtb)] = new_dtb
    second = bytes(second)
    struct.pack_into("<I", orig_header, 8, len(kernel))
    struct.pack_into("<I", orig_header, 16, len(ramdisk))
    struct.pack_into("<I", orig_header, 24, len(second))
    h = hashlib.sha1()
    for blob in (kernel, ramdisk, second):
        h.update(blob); h.update(struct.pack("<I", len(blob)))
    orig_header[576:596] = h.digest(); orig_header[596:608] = b"\0" * 12
    out.write_bytes(bytes(orig_header[:page]) + align(kernel, page) + align(ramdisk, page) + align(second, page))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True, type=Path)
    ap.add_argument("--output", required=True, type=Path)
    ap.add_argument("--workdir", type=Path)
    ap.add_argument("--pcie-mode", choices=["noep", "deferred"], default="noep",
                    help="NPU PCIe DT handling: noep disables EP; deferred adds EP nonblocking DT properties")
    args = ap.parse_args()
    with tempfile.TemporaryDirectory(prefix="npu_noep_ntb_", dir=str(args.workdir) if args.workdir else None) as td:
        work = Path(td)
        header, page, kernel, ramdisk, second = unpack_boot(args.input, work)
        dtb = work/"orig.dtb"; extract_second_dtb(second, dtb)
        new_dtb = work/(args.pcie_mode + ".dtb"); patch_dtb(dtb, new_dtb, work, args.pcie_mode)
        new_ramdisk = work/("ramdisk_" + args.pcie_mode + "_ntb.cpio.gz"); patch_ramdisk(ramdisk, new_ramdisk, work, args.pcie_mode)
        repack(header, page, kernel, new_ramdisk.read_bytes(), second, new_dtb.read_bytes(), args.output)
    print(f"WROTE {args.output}")
    print(hashlib.sha256(args.output.read_bytes()).hexdigest(), args.output)

if __name__ == "__main__":
    main()
