#!/usr/bin/env bash
set -euo pipefail

FW_DIR=${FW_DIR:-/usr/share/npu_fw}
UPGRADE_TOOL=${UPGRADE_TOOL:-/usr/bin/upgrade_tool}
TRANSFER_PROXY=${TRANSFER_PROXY:-/usr/bin/npu_transfer_proxy}
NPU_POWERCTRL=${NPU_POWERCTRL:-/usr/bin/npu_powerctrl}
UBOOT_ADDR=${UBOOT_ADDR:-0x00200000}
TRUST_ADDR=${TRUST_ADDR:-0x08400000}
BOOT_ADDR=${BOOT_ADDR:-0x02000000}
SKIP_POWER=${SKIP_POWER:-0}
START_PROXY=${START_PROXY:-1}
CHECK_ONLY=${CHECK_ONLY:-0}

need_file() {
  if [ ! -e "$1" ]; then
    echo "ERROR: missing $1" >&2
    exit 2
  fi
}

run_check() {
  if command -v npu_mainline_usb_ntb_check.sh >/dev/null 2>&1; then
    npu_mainline_usb_ntb_check.sh
  elif [ -x "$(dirname "$0")/npu_mainline_usb_ntb_check.sh" ]; then
    "$(dirname "$0")/npu_mainline_usb_ntb_check.sh"
  else
    echo "== fallback check =="
    lsusb | grep -Ei '2207:|rockchip|rk3xxx' || true
    dmesg | grep -Ei 'usb 3-1|usb 4-1|2207|180a|1808|0019|firmware changed|SuperSpeed|ntb|rknn|npu|error -71|disconnect' | tail -120 || true
    [ -x "$TRANSFER_PROXY" ] && "$TRANSFER_PROXY" devices || true
  fi
}

if [ "$CHECK_ONLY" = 1 ]; then
  run_check
  exit 0
fi

need_file "$FW_DIR/MiniLoaderAll.bin"
need_file "$FW_DIR/uboot.img"
need_file "$FW_DIR/trust.img"
need_file "$FW_DIR/boot.img"
need_file "$UPGRADE_TOOL"

if [ "$SKIP_POWER" != 1 ] && [ -x "$NPU_POWERCTRL" ]; then
  echo "== reset/power NPU through $NPU_POWERCTRL =="
  "$NPU_POWERCTRL" off || true
  sleep 1
  "$NPU_POWERCTRL" on || true
  sleep 2
else
  echo "== skip npu_powerctrl =="
fi

echo "== before firmware download =="
lsusb | grep -Ei '2207:|rockchip|rk3xxx' || true

echo "== upgrade_tool db MiniLoaderAll.bin =="
"$UPGRADE_TOOL" db "$FW_DIR/MiniLoaderAll.bin"
sleep 1

echo "== upgrade_tool rs uboot/trust/boot =="
"$UPGRADE_TOOL" rs "$UBOOT_ADDR" "$TRUST_ADDR" "$BOOT_ADDR" \
  "$FW_DIR/uboot.img" "$FW_DIR/trust.img" "$FW_DIR/boot.img"

echo "== wait for USB2 Loader disconnect and USB3 NTB gadget re-enumeration =="
sleep 8

if [ "$START_PROXY" = 1 ] && [ -x "$TRANSFER_PROXY" ]; then
  if ! pgrep -x npu_transfer_proxy >/dev/null 2>&1; then
    echo "== start npu_transfer_proxy =="
    nohup "$TRANSFER_PROXY" >/tmp/npu_transfer_proxy.log 2>&1 &
    sleep 1
  fi
fi

run_check
