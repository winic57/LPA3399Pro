#!/usr/bin/env bash
set -euo pipefail

FW_DIR=${FW_DIR:-/usr/share/npu_fw}
UPGRADE_TOOL=${UPGRADE_TOOL:-/usr/bin/upgrade_tool}
TRANSFER_PROXY=${TRANSFER_PROXY:-/usr/bin/npu_transfer_proxy}
NPU_POWERCTRL=${NPU_POWERCTRL:-/usr/bin/npu_powerctrl}
FW_PROFILE=${FW_PROFILE:-factory}
LOADER_WAIT=${LOADER_WAIT:-1}
RS_TIMEOUT=${RS_TIMEOUT:-90}
UBOOT_ADDR=${UBOOT_ADDR:-0x20000}
TRUST_ADDR=${TRUST_ADDR:-0x20800}
BOOT_ADDR=${BOOT_ADDR:-0x21000}
SKIP_POWER=${SKIP_POWER:-0}
START_PROXY=${START_PROXY:-1}
CHECK_ONLY=${CHECK_ONLY:-0}
POWER_INIT_FIRST=${POWER_INIT_FIRST:-1}
POWER_FORCE_OFF_FIRST=${POWER_FORCE_OFF_FIRST:-0}

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

select_fw() {
  local normal="$1" factory="$2"
  case "$FW_PROFILE" in
    factory)
      if [ -e "$FW_DIR/$factory" ]; then
        echo "$FW_DIR/$factory"
      else
        echo "$FW_DIR/$normal"
      fi
      ;;
    normal|usb|default)
      echo "$FW_DIR/$normal"
      ;;
    *)
      echo "$FW_DIR/$normal"
      ;;
  esac
}

run_power_action() {
  local action="$1"
  [ -x "$NPU_POWERCTRL" ] || return 0
  case "$action" in
    init)
      "$NPU_POWERCTRL" init 2>/dev/null || "$NPU_POWERCTRL" -i || true
      ;;
    off)
      "$NPU_POWERCTRL" off 2>/dev/null || "$NPU_POWERCTRL" -d || true
      ;;
    on)
      "$NPU_POWERCTRL" on 2>/dev/null || "$NPU_POWERCTRL" -o || true
      ;;
  esac
}

if [ "$CHECK_ONLY" = 1 ]; then
  run_check
  exit 0
fi

need_file "$UPGRADE_TOOL"

LOADER=$(select_fw MiniLoaderAll.bin MiniLoaderAll_factory.bin)
UBOOT=$(select_fw uboot.img uboot_factory.img)
TRUST=$(select_fw trust.img trust_factory.img)
BOOT=$(select_fw boot.img boot_factory.img)

need_file "$LOADER"
need_file "$UBOOT"
need_file "$TRUST"
need_file "$BOOT"

if [ "$SKIP_POWER" != 1 ] && [ -x "$NPU_POWERCTRL" ]; then
  echo "== reset/power NPU through $NPU_POWERCTRL =="
  if [ "$POWER_INIT_FIRST" = 1 ]; then
    echo "== vendor-compatible gpio init =="
    run_power_action init
    sleep 1
  fi
  if [ "$POWER_FORCE_OFF_FIRST" = 1 ]; then
    echo "== forced power down before power up =="
    run_power_action off
    sleep 1
  fi
  run_power_action on
  sleep 2
else
  echo "== skip npu_powerctrl =="
fi

echo "== firmware profile =="
echo "FW_PROFILE=$FW_PROFILE"
echo "LOADER=$LOADER"
echo "UBOOT=$UBOOT"
echo "TRUST=$TRUST"
echo "BOOT=$BOOT"
echo "ADDRS: uboot=$UBOOT_ADDR trust=$TRUST_ADDR boot=$BOOT_ADDR"

echo "== before firmware download =="
lsusb | grep -Ei '2207:|rockchip|rk3xxx' || true

echo "== upgrade_tool db MiniLoaderAll.bin =="
"$UPGRADE_TOOL" db "$LOADER"
sleep 1

if [ "$LOADER_WAIT" = 1 ]; then
  echo "== upgrade_tool td (wait loader) =="
  "$UPGRADE_TOOL" td || true
fi

echo "== upgrade_tool rs uboot/trust/boot =="
if command -v timeout >/dev/null 2>&1; then
  timeout "${RS_TIMEOUT}s" "$UPGRADE_TOOL" rs "$UBOOT_ADDR" "$TRUST_ADDR" "$BOOT_ADDR" \
    "$UBOOT" "$TRUST" "$BOOT"
else
  "$UPGRADE_TOOL" rs "$UBOOT_ADDR" "$TRUST_ADDR" "$BOOT_ADDR" \
    "$UBOOT" "$TRUST" "$BOOT"
fi

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
