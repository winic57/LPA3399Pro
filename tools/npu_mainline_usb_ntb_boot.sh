#!/usr/bin/env bash
set -euo pipefail

FW_DIR=${FW_DIR:-/usr/share/npu_fw}
UPGRADE_TOOL=${UPGRADE_TOOL:-/usr/bin/upgrade_tool}
TRANSFER_PROXY=${TRANSFER_PROXY:-/usr/bin/npu_transfer_proxy}
TRANSFER_PROXY_LAUNCHER=${TRANSFER_PROXY_LAUNCHER:-/usr/local/bin/npu_transfer_proxy_launcher.sh}
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
WRITE_IMAGES_BEFORE_RS=${WRITE_IMAGES_BEFORE_RS:-0}
POST_RS_WAIT_SEC=${POST_RS_WAIT_SEC:-8}
POST_RS_PCIE_RESCAN=${POST_RS_PCIE_RESCAN:-0}
POST_RS_PCIE_RESCAN_DELAY_SEC=${POST_RS_PCIE_RESCAN_DELAY_SEC:-0}
RS_STRICT=${RS_STRICT:-0}
# DB_POLICY=auto: run `db` only from Maskrom; skip it when already Loader.
# Other values: always, skip, require-maskrom.
DB_POLICY=${DB_POLICY:-auto}
ROCKUSB_WAIT_SEC=${ROCKUSB_WAIT_SEC:-8}
POWER_OFF_SETTLE_SEC=${POWER_OFF_SETTLE_SEC:-2}
POWER_ON_SETTLE_SEC=${POWER_ON_SETTLE_SEC:-3}
PCIE_RESCAN_AFTER_POWER=${PCIE_RESCAN_AFTER_POWER:-0}
PCIE_HOST_REBIND_AFTER_POWER=${PCIE_HOST_REBIND_AFTER_POWER:-0}
PCIE_HOST_PLATFORM_DEV=${PCIE_HOST_PLATFORM_DEV:-f8000000.pcie}
PCIE_HOST_REBIND_WAIT_SEC=${PCIE_HOST_REBIND_WAIT_SEC:-4}

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

rockusb_ld() {
  "$UPGRADE_TOOL" ld 2>/dev/null || true
}

rockusb_mode() {
  rockusb_ld | awk -F'Mode=' '/Mode=/{split($2,a,/[^A-Za-z0-9_-]/); print a[1]; exit}'
}

wait_rockusb_mode() {
  local timeout_s="${1:-$ROCKUSB_WAIT_SEC}" mode i
  for i in $(seq 1 "$timeout_s"); do
    mode=$(rockusb_mode || true)
    if [ -n "$mode" ]; then
      echo "$mode"
      return 0
    fi
    sleep 1
  done
  return 1
}

run_loader_db_if_needed() {
  local mode="${1:-}"
  if [ -z "$mode" ]; then
    mode=$(rockusb_mode || true)
  fi

  echo "== rockusb mode before db: ${mode:-none} =="
  case "$DB_POLICY" in
    skip)
      echo "== DB_POLICY=skip: skip upgrade_tool db =="
      return 0
      ;;
    always)
      echo "== DB_POLICY=always: force upgrade_tool db MiniLoaderAll.bin =="
      "$UPGRADE_TOOL" db "$LOADER"
      sleep 1
      return 0
      ;;
    require-maskrom)
      if [ "$mode" != "Maskrom" ]; then
        echo "ERROR: DB_POLICY=require-maskrom but mode is ${mode:-none}; refusing db" >&2
        return 3
      fi
      ;;
    auto)
      if [ "$mode" = "Loader" ]; then
        echo "== already Loader: skip upgrade_tool db to avoid unsupported duplicate db =="
        return 0
      fi
      if [ "$mode" != "Maskrom" ]; then
        echo "ERROR: expected Maskrom for db, got ${mode:-none}; refusing db" >&2
        return 3
      fi
      ;;
    *)
      echo "ERROR: unknown DB_POLICY=$DB_POLICY" >&2
      return 2
      ;;
  esac

  echo "== upgrade_tool db MiniLoaderAll.bin =="
  "$UPGRADE_TOOL" db "$LOADER"
  sleep 1
}

proxy_running() {
  local bin base
  bin="$TRANSFER_PROXY"
  base="$(basename "$TRANSFER_PROXY")"

  # Do not use broad `pgrep -f npu_transfer_proxy`: it can match the
  # current shell/ssh command line when that line contains
  # "npu_transfer_proxy devices", creating a false "already running".
  ps -eo args= | awk -v bin="$bin" -v base="$base" '
    $1 == bin || $1 == base || $1 ~ ("/" base "$") { found = 1 }
    END { exit found ? 0 : 1 }
  '
}

start_transfer_proxy() {
  if proxy_running; then
    echo "== npu_transfer_proxy already running =="
    return 0
  fi

  if [ -x "$TRANSFER_PROXY_LAUNCHER" ]; then
    echo "== start npu_transfer_proxy via launcher =="
    echo "TRANSFER_PROXY_LAUNCHER=$TRANSFER_PROXY_LAUNCHER"
    "$TRANSFER_PROXY_LAUNCHER" || true
    sleep 1
    return 0
  fi

  echo "== start npu_transfer_proxy =="
  nohup "$TRANSFER_PROXY" >/tmp/npu_transfer_proxy.log 2>&1 &
  sleep 1
}

pcie_host_ab_after_power() {
  if [ "$PCIE_RESCAN_AFTER_POWER" = 1 ] && [ -w /sys/bus/pci/rescan ]; then
    echo "== host PCIe rescan after power =="
    echo 1 > /sys/bus/pci/rescan || true
    sleep 2
  fi

  if [ "$PCIE_HOST_REBIND_AFTER_POWER" = 1 ] && \
     [ -w /sys/bus/platform/drivers/rockchip-pcie/unbind ] && \
     [ -w /sys/bus/platform/drivers/rockchip-pcie/bind ] && \
     [ -e "/sys/bus/platform/drivers/rockchip-pcie/${PCIE_HOST_PLATFORM_DEV}" ]; then
    echo "== host PCIe rebind after power (${PCIE_HOST_PLATFORM_DEV}) =="
    echo "$PCIE_HOST_PLATFORM_DEV" > /sys/bus/platform/drivers/rockchip-pcie/unbind || true
    sleep 1
    echo "$PCIE_HOST_PLATFORM_DEV" > /sys/bus/platform/drivers/rockchip-pcie/bind || true
    sleep "$PCIE_HOST_REBIND_WAIT_SEC"
  fi
}

pcie_host_ab_after_rs() {
  if [ "$POST_RS_PCIE_RESCAN" = 1 ] && [ -w /sys/bus/pci/rescan ]; then
    echo "== host PCIe rescan after rs =="
    echo "POST_RS_PCIE_RESCAN_DELAY_SEC=$POST_RS_PCIE_RESCAN_DELAY_SEC"
    sleep "$POST_RS_PCIE_RESCAN_DELAY_SEC"
    echo 1 > /sys/bus/pci/rescan || true
    sleep 3
  fi
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
    sleep "$POWER_OFF_SETTLE_SEC"
  fi
  run_power_action on
  sleep "$POWER_ON_SETTLE_SEC"
  pcie_host_ab_after_power
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
echo "WRITE_IMAGES_BEFORE_RS=$WRITE_IMAGES_BEFORE_RS"
echo "POST_RS_WAIT_SEC=$POST_RS_WAIT_SEC"
echo "POST_RS_PCIE_RESCAN=$POST_RS_PCIE_RESCAN"
echo "POST_RS_PCIE_RESCAN_DELAY_SEC=$POST_RS_PCIE_RESCAN_DELAY_SEC"
echo "RS_STRICT=$RS_STRICT"
echo "DB_POLICY=$DB_POLICY"
echo "ROCKUSB_WAIT_SEC=$ROCKUSB_WAIT_SEC"
echo "POWER_OFF_SETTLE_SEC=$POWER_OFF_SETTLE_SEC"
echo "POWER_ON_SETTLE_SEC=$POWER_ON_SETTLE_SEC"
echo "PCIE_RESCAN_AFTER_POWER=$PCIE_RESCAN_AFTER_POWER"
echo "PCIE_HOST_REBIND_AFTER_POWER=$PCIE_HOST_REBIND_AFTER_POWER"
echo "PCIE_HOST_PLATFORM_DEV=$PCIE_HOST_PLATFORM_DEV"
echo "PCIE_HOST_REBIND_WAIT_SEC=$PCIE_HOST_REBIND_WAIT_SEC"

echo "== before firmware download =="
lsusb | grep -Ei '2207:|rockchip|rk3xxx' || true

MODE_BEFORE_DB=$(wait_rockusb_mode "$ROCKUSB_WAIT_SEC" || true)
run_loader_db_if_needed "$MODE_BEFORE_DB"

if [ "$LOADER_WAIT" = 1 ]; then
  MODE_AFTER_DB=$(wait_rockusb_mode "$ROCKUSB_WAIT_SEC" || true)
  if [ "$MODE_AFTER_DB" = "Loader" ]; then
    echo "== already Loader after db/skip; skip upgrade_tool td =="
  else
    echo "== upgrade_tool td (wait loader) =="
    "$UPGRADE_TOOL" td || true
  fi
fi

if [ "$WRITE_IMAGES_BEFORE_RS" = 1 ]; then
  echo "== vendor-style preload with upgrade_tool wl (PERSISTENT WRITE RISK) =="
  "$UPGRADE_TOOL" wl "$UBOOT_ADDR" "$UBOOT"
  "$UPGRADE_TOOL" wl "$TRUST_ADDR" "$TRUST"
  "$UPGRADE_TOOL" wl "$BOOT_ADDR" "$BOOT"
fi

echo "== upgrade_tool rs uboot/trust/boot =="
set +e
if command -v timeout >/dev/null 2>&1; then
  timeout "${RS_TIMEOUT}s" "$UPGRADE_TOOL" rs "$UBOOT_ADDR" "$TRUST_ADDR" "$BOOT_ADDR" \
    "$UBOOT" "$TRUST" "$BOOT"
  RS_RC=$?
else
  "$UPGRADE_TOOL" rs "$UBOOT_ADDR" "$TRUST_ADDR" "$BOOT_ADDR" \
    "$UBOOT" "$TRUST" "$BOOT"
  RS_RC=$?
fi
set -e
echo "RS_RC=$RS_RC"

echo "== wait for USB2 Loader disconnect and USB3 NTB gadget re-enumeration =="
sleep "$POST_RS_WAIT_SEC"
pcie_host_ab_after_rs

if [ "$START_PROXY" = 1 ] && [ -x "$TRANSFER_PROXY" ]; then
  start_transfer_proxy
fi

run_check

if [ "$RS_STRICT" = 1 ] && [ "$RS_RC" -ne 0 ]; then
  exit "$RS_RC"
fi
