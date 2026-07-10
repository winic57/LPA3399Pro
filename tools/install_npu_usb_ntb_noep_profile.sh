#!/usr/bin/env bash
set -euo pipefail

# Install a formal RK3399Pro NPU-side USB-NTB/no-EP firmware profile.
# Preferred input is a known-good noep+usb_ntb boot.img.  If unavailable and
# npu_make_noep_ntb_boot.py + dtc/cpio/gzip are installed, the boot image can be
# generated from the source PCIe firmware boot.img.

SRC_FW_DIR=${SRC_FW_DIR:-/usr/share/npu_fw_pcie}
PROFILE_DIR=${PROFILE_DIR:-/usr/share/npu_fw_usb_ntb_noep}
BOOT_BUILDER=${BOOT_BUILDER:-/usr/local/bin/npu_make_noep_ntb_boot.py}
NOEP_BOOT_IMG=${NOEP_BOOT_IMG:-}
FALLBACK_NOEP_BOOT_IMG=${FALLBACK_NOEP_BOOT_IMG:-/root/npu_fw_pcie_noep_ntb_debug/boot.img}
FORCE_REBUILD=${FORCE_REBUILD:-0}

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1" >&2; exit 2; }; }
need_file() { [ -e "$1" ] || { echo "ERROR: missing $1" >&2; exit 2; }; }

need_file "$SRC_FW_DIR/MiniLoaderAll.bin"
need_file "$SRC_FW_DIR/uboot.img"
need_file "$SRC_FW_DIR/trust.img"
need_file "$SRC_FW_DIR/boot.img"

install -d -m 0755 "$PROFILE_DIR"
install -m 0644 "$SRC_FW_DIR/MiniLoaderAll.bin" "$PROFILE_DIR/MiniLoaderAll.bin"
install -m 0644 "$SRC_FW_DIR/uboot.img" "$PROFILE_DIR/uboot.img"
install -m 0644 "$SRC_FW_DIR/trust.img" "$PROFILE_DIR/trust.img"
[ -e "$SRC_FW_DIR/parameter.txt" ] && install -m 0644 "$SRC_FW_DIR/parameter.txt" "$PROFILE_DIR/parameter.txt"
for f in MiniLoaderAll_factory.bin uboot_factory.img trust_factory.img boot_factory.img; do
  [ -e "$SRC_FW_DIR/$f" ] && install -m 0644 "$SRC_FW_DIR/$f" "$PROFILE_DIR/$f"
done

if [ -n "$NOEP_BOOT_IMG" ]; then
  need_file "$NOEP_BOOT_IMG"
  install -m 0644 "$NOEP_BOOT_IMG" "$PROFILE_DIR/boot.img"
elif [ "$FORCE_REBUILD" != 1 ] && [ -e "$FALLBACK_NOEP_BOOT_IMG" ]; then
  install -m 0644 "$FALLBACK_NOEP_BOOT_IMG" "$PROFILE_DIR/boot.img"
else
  need python3
  need dtc
  need cpio
  need gzip
  need_file "$BOOT_BUILDER"
  tmp="$(mktemp -d /tmp/npu_noep_profile.XXXXXX)"
  trap 'rm -rf "$tmp"' EXIT
  python3 "$BOOT_BUILDER" --input "$SRC_FW_DIR/boot.img" --output "$tmp/boot.img" --workdir "$tmp"
  install -m 0644 "$tmp/boot.img" "$PROFILE_DIR/boot.img"
fi

cat > "$PROFILE_DIR/README.noep-usb-ntb" <<README
RK3399Pro NPU USB-NTB/no-EP profile
Created: $(date -Is)
Source firmware: $SRC_FW_DIR
Profile dir: $PROFILE_DIR

Differences from source boot.img:
- NPU-side DT pcie@fc400000 status is disabled.
- ramdisk /etc/init.d/.usb_config is usb_ntb_en.
- ttyFIQ0/rknn_server console debug may be enabled, depending on builder/input.

Use with:
  FW_DIR=$PROFILE_DIR FW_PROFILE=normal WRITE_IMAGES_BEFORE_RS=1 \\
  UBOOT_ADDR=0x20000 TRUST_ADDR=0x20800 BOOT_ADDR=0x21000 \\
  POST_RS_WAIT_SEC=20 /usr/local/bin/npu_mainline_usb_ntb_boot.sh
README

(
  cd "$PROFILE_DIR"
  sha256sum MiniLoaderAll.bin uboot.img trust.img boot.img parameter.txt 2>/dev/null || true
) > "$PROFILE_DIR/SHA256SUMS"

printf 'Installed NPU USB-NTB/no-EP profile: %s\n' "$PROFILE_DIR"
cat "$PROFILE_DIR/SHA256SUMS"
