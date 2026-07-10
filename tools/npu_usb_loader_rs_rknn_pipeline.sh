#!/usr/bin/env bash
set -euo pipefail

# RK3399Pro NPU mainline USB bring-up pipeline:
# clean power/maskrom -> db -> optional wl -> rs -> wait USB3 -> proxy USB_DEVICE -> optional RKNN.
# All knobs are env-overridable so A/B timing and firmware tests can be run without editing this file.

ENV_FILE=${ENV_FILE:-/etc/default/npu-usb-workflow}
# Preserve explicit command-line environment overrides before sourcing ENV_FILE.
# /etc/default/npu-usb-workflow contains service defaults; interactive A/B runs
# must be able to override them with `VAR=value npu_usb_loader_rs_rknn_pipeline.sh`.
NPU_ENV_OVERRIDE_VARS="BOOT_SCRIPT CHECK_SCRIPT NPU_POWERCTRL TRANSFER_PROXY TRANSFER_PROXY_LAUNCHER UPGRADE_TOOL LOG_DIR RUN_ID LOG_FILE SNAP_DMESG_LINES USB_FW_DIR USB_FW_PROFILE DB_POLICY POWER_INIT_FIRST POWER_FORCE_OFF_FIRST POWER_OFF_SETTLE_SEC POWER_ON_SETTLE_SEC WRITE_IMAGES_BEFORE_RS START_PROXY RS_STRICT POST_RS_WAIT_SEC RS_TIMEOUT POST_RS_USB_REBIND POST_RS_USB_REBIND_DELAY_SEC POST_RS_USB_REBIND_DRIVER POST_RS_USB_REBIND_DEVICES POST_RS_DWC3_REBIND POST_RS_DWC3_REBIND_DRIVER POST_RS_DWC3_REBIND_DEVICES POST_RS_USBDEV_RESCAN POST_RS_USBDEV_RESCAN_DELAY_SEC UBOOT_ADDR TRUST_ADDR BOOT_ADDR WAIT_USB3_TIMEOUT_SEC WAIT_USB3_POLL_SEC EXPECT_USB_ID EXPECT_USB_IDS EXPECT_PROXY_DEVICE WAIT_PROXY_TIMEOUT_SEC WAIT_PROXY_POLL_SEC RESTART_PROXY RUN_RKNN RKNN_TIMEOUT_SEC RKNN_CMD RKNN_PYTHONPATH RKNN_LD_LIBRARY_PATH FAIL_ON_NO_USB3 FAIL_ON_NO_USB_DEVICE DUMP_PCIE_DEBUGFS SET_PCIE_DMA_SAFE FORCE_USB_DEVICE PCIE_DEV_PATH PCIE_DEV_HIDDEN_PATH"
declare -A _npu_pre_set _npu_pre_val
for _npu_var in $NPU_ENV_OVERRIDE_VARS; do
  if [ "${!_npu_var+x}" = x ]; then
    _npu_pre_set[$_npu_var]=1
    _npu_pre_val[$_npu_var]="${!_npu_var}"
  fi
done
if [ -r "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE"; set +a
fi
for _npu_var in $NPU_ENV_OVERRIDE_VARS; do
  if [ "${_npu_pre_set[$_npu_var]:-0}" = 1 ]; then
    export "$_npu_var=${_npu_pre_val[$_npu_var]}"
  fi
done
unset _npu_var

BOOT_SCRIPT=${BOOT_SCRIPT:-/usr/local/bin/npu_mainline_usb_ntb_boot.sh}
CHECK_SCRIPT=${CHECK_SCRIPT:-/usr/local/bin/npu_mainline_usb_ntb_check.sh}
POWERCTRL=${NPU_POWERCTRL:-/usr/local/bin/npu_powerctrl-gpiod}
TRANSFER_PROXY=${TRANSFER_PROXY:-/usr/bin/npu_transfer_proxy}
TRANSFER_PROXY_LAUNCHER=${TRANSFER_PROXY_LAUNCHER:-/usr/local/bin/npu_transfer_proxy_launcher.sh}
UPGRADE_TOOL=${UPGRADE_TOOL:-/usr/bin/upgrade_tool}

LOG_DIR=${LOG_DIR:-/var/log/npu-usb-pipeline}
RUN_ID=${RUN_ID:-$(date +%Y%m%d_%H%M%S)}
LOG_FILE=${LOG_FILE:-${LOG_DIR}/usb_loader_rs_rknn_${RUN_ID}.log}
SNAP_DMESG_LINES=${SNAP_DMESG_LINES:-160}

# Mainline USB defaults. Override for A/B.
# Use USB_* aliases so legacy service defaults such as FW_PROFILE=factory do not
# accidentally steer this pipeline away from the official USB npu_fw path.
export FW_DIR=${USB_FW_DIR:-/usr/share/npu_fw_usb_ntb_noep}
export FW_PROFILE=${USB_FW_PROFILE:-normal}
export DB_POLICY=${DB_POLICY:-require-maskrom}
export POWER_INIT_FIRST=${POWER_INIT_FIRST:-1}
export POWER_FORCE_OFF_FIRST=${POWER_FORCE_OFF_FIRST:-1}
export POWER_OFF_SETTLE_SEC=${POWER_OFF_SETTLE_SEC:-2}
export POWER_ON_SETTLE_SEC=${POWER_ON_SETTLE_SEC:-4}
export WRITE_IMAGES_BEFORE_RS=${WRITE_IMAGES_BEFORE_RS:-1}
export START_PROXY=${START_PROXY:-0}
export RS_STRICT=${RS_STRICT:-0}
export POST_RS_WAIT_SEC=${POST_RS_WAIT_SEC:-20}
export POST_RS_USB_REBIND=${POST_RS_USB_REBIND:-0}
export POST_RS_USB_REBIND_DELAY_SEC=${POST_RS_USB_REBIND_DELAY_SEC:-0}
export POST_RS_USB_REBIND_DRIVER=${POST_RS_USB_REBIND_DRIVER:-xhci-hcd}
export POST_RS_USB_REBIND_DEVICES="${POST_RS_USB_REBIND_DEVICES:-xhci-hcd.0.auto xhci-hcd.8.auto}"
export POST_RS_DWC3_REBIND=${POST_RS_DWC3_REBIND:-0}
export POST_RS_DWC3_REBIND_DRIVER=${POST_RS_DWC3_REBIND_DRIVER:-dwc3}
export POST_RS_DWC3_REBIND_DEVICES="${POST_RS_DWC3_REBIND_DEVICES:-fe800000.usb fe900000.usb}"
export POST_RS_USBDEV_RESCAN=${POST_RS_USBDEV_RESCAN:-0}
export POST_RS_USBDEV_RESCAN_DELAY_SEC=${POST_RS_USBDEV_RESCAN_DELAY_SEC:-0}
export RS_TIMEOUT=${RS_TIMEOUT:-90}
export UBOOT_ADDR=${UBOOT_ADDR:-0x20000}
export TRUST_ADDR=${TRUST_ADDR:-0x20800}
export BOOT_ADDR=${BOOT_ADDR:-0x21000}

WAIT_USB3_TIMEOUT_SEC=${WAIT_USB3_TIMEOUT_SEC:-45}
WAIT_USB3_POLL_SEC=${WAIT_USB3_POLL_SEC:-1}
EXPECT_USB_ID=${EXPECT_USB_ID:-2207:0019}
# Accept multiple VID:PID values for A/B: older notes expected 2207:0019,
# while .129 vendor golden currently exposes 2207:1005 (rk3xxx/acm).
EXPECT_USB_IDS=${EXPECT_USB_IDS:-$EXPECT_USB_ID}
EXPECT_PROXY_DEVICE=${EXPECT_PROXY_DEVICE:-USB_DEVICE}
WAIT_PROXY_TIMEOUT_SEC=${WAIT_PROXY_TIMEOUT_SEC:-20}
WAIT_PROXY_POLL_SEC=${WAIT_PROXY_POLL_SEC:-1}
RESTART_PROXY=${RESTART_PROXY:-1}
RUN_RKNN=${RUN_RKNN:-0}
RKNN_TIMEOUT_SEC=${RKNN_TIMEOUT_SEC:-60}
RKNN_CMD=${RKNN_CMD:-}
RKNN_PYTHONPATH=${RKNN_PYTHONPATH:-/root/npu_deep_manual:/root/npu_deep_test}
RKNN_LD_LIBRARY_PATH=${RKNN_LD_LIBRARY_PATH:-/root/npu_deep_manual:/usr/lib:/usr/local/lib}
FAIL_ON_NO_USB3=${FAIL_ON_NO_USB3:-1}
FAIL_ON_NO_USB_DEVICE=${FAIL_ON_NO_USB_DEVICE:-1}
DUMP_PCIE_DEBUGFS=${DUMP_PCIE_DEBUGFS:-1}
SET_PCIE_DMA_SAFE=${SET_PCIE_DMA_SAFE:-1}
FORCE_USB_DEVICE=${FORCE_USB_DEVICE:-0}
PCIE_DEV_PATH=${PCIE_DEV_PATH:-/dev/pcie-dev}
PCIE_DEV_HIDDEN_PATH=${PCIE_DEV_HIDDEN_PATH:-/dev/pcie-dev.hidden_usbtest}
PCIE_DEV_WAS_HIDDEN=0

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

log() { printf '\n[%s] %s\n' "$(date -Is)" "$*"; }
run() { log "+ $*"; "$@"; }

have() { command -v "$1" >/dev/null 2>&1; }

rockusb_ld() {
  if [ -x "$UPGRADE_TOOL" ]; then
    "$UPGRADE_TOOL" ld 2>&1 || true
  else
    echo "WARN: missing $UPGRADE_TOOL"
  fi
}

proxy_devices() {
  if [ -x "$TRANSFER_PROXY" ]; then
    "$TRANSFER_PROXY" devices 2>&1 || true
  else
    echo "WARN: missing $TRANSFER_PROXY"
  fi
}

pcie_safe_controls() {
  [ "$SET_PCIE_DMA_SAFE" = 1 ] || return 0
  mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true
  [ -d /sys/kernel/debug/pcie ] || return 0
  echo 1 > /sys/kernel/debug/pcie/dma_disabled 2>/dev/null || true
  echo 1000 > /sys/kernel/debug/pcie/dma_timeout_ms 2>/dev/null || true
  echo 0 > /sys/kernel/debug/pcie/dma_failfast_mode 2>/dev/null || true
  [ -e /sys/kernel/debug/pcie/dma_fake_poll_mask ] && echo 0 > /sys/kernel/debug/pcie/dma_fake_poll_mask || true
  [ -e /sys/kernel/debug/pcie/dma_fake_rx_mask ] && echo 0 > /sys/kernel/debug/pcie/dma_fake_rx_mask || true
}

snapshot() {
  local stage="$1"
  log "SNAPSHOT: $stage"
  echo "RUN_ID=$RUN_ID"
  echo "LOG_FILE=$LOG_FILE"
  echo "uname=$(uname -a)"
  echo "cmdline=$(cat /proc/cmdline 2>/dev/null || true)"
  echo "-- params --"
  env | sort | grep -E '^(USB_FW_DIR|USB_FW_PROFILE|FW_DIR|FW_PROFILE|DB_POLICY|POWER_|WRITE_IMAGES_BEFORE_RS|START_PROXY|POST_RS|RS_|UBOOT_ADDR|TRUST_ADDR|BOOT_ADDR|WAIT_USB3|EXPECT_|WAIT_PROXY|RESTART_PROXY|RUN_RKNN|RKNN_|FAIL_ON_|SET_PCIE|NPU_PRECISE|GPIO_HOLD|NPU_POWERCTRL)=' || true
  echo "-- clocks --"
  for p in \
    /sys/kernel/debug/clk/clk_wifi_pmu/clk_rate \
    /sys/kernel/debug/clk/clk_wifi_pmu/clk_enable_count \
    /sys/kernel/debug/clk/clk_wifi_pmu/clk_prepare_count \
    /sys/kernel/debug/clk/rk808-clkout2/clk_enable_count \
    /sys/kernel/debug/clk/rk808-clkout2/clk_prepare_count; do
    [ -r "$p" ] && printf '%s=' "$p" && cat "$p" || true
  done
  echo "-- rockusb ld --"
  rockusb_ld
  echo "-- lsusb rockchip --"
  if have lsusb; then lsusb | grep -Ei '2207:|rockchip|rk3xxx' || true; else echo "WARN: no lsusb"; fi
  echo "-- proxy process --"
  ps -ef | grep -E 'npu_transfer_proxy|rknn' | grep -v grep || true
  echo "-- proxy devices --"
  proxy_devices
  if [ "$DUMP_PCIE_DEBUGFS" = 1 ]; then
    echo "-- pcie_trx --"
    mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true
    [ -r /sys/kernel/debug/pcie/pcie_trx ] && sed -n '1,120p' /sys/kernel/debug/pcie/pcie_trx || true
  fi
  echo "-- dmesg usb/npu tail --"
  dmesg | grep -Ei 'usb|2207|180a|0019|1005|firmware changed|SuperSpeed|ntb|rknn|npu|pcie|dma|error -71|disconnect' | tail -n "$SNAP_DMESG_LINES" || true
}

post_rs_usb_recover() {
  local dev driver

  if [ "$POST_RS_USBDEV_RESCAN" = 1 ]; then
    log "post-rs USB authorized toggle delay=${POST_RS_USBDEV_RESCAN_DELAY_SEC}s"
    sleep "$POST_RS_USBDEV_RESCAN_DELAY_SEC"
    for dev in /sys/bus/usb/devices/*/authorized; do
      [ -w "$dev" ] || continue
      echo 0 > "$dev" 2>/dev/null || true
      sleep 0.1
      echo 1 > "$dev" 2>/dev/null || true
    done
    sleep 2
    snapshot "after_post_rs_usbdev_rescan"
  fi

  if [ "$POST_RS_USB_REBIND" = 1 ]; then
    log "post-rs xHCI rebind delay=${POST_RS_USB_REBIND_DELAY_SEC}s driver=${POST_RS_USB_REBIND_DRIVER} devices=${POST_RS_USB_REBIND_DEVICES}"
    sleep "$POST_RS_USB_REBIND_DELAY_SEC"
    driver="/sys/bus/platform/drivers/${POST_RS_USB_REBIND_DRIVER}"
    if [ -w "$driver/unbind" ] && [ -w "$driver/bind" ]; then
      for dev in $POST_RS_USB_REBIND_DEVICES; do
        [ -e "$driver/$dev" ] || { echo "WARN: missing $driver/$dev"; continue; }
        echo "$dev" > "$driver/unbind" 2>/dev/null || true
        sleep 1
        echo "$dev" > "$driver/bind" 2>/dev/null || true
        sleep 3
      done
    else
      echo "WARN: missing bind/unbind for $driver"
    fi
    snapshot "after_post_rs_xhci_rebind"
  fi

  if [ "$POST_RS_DWC3_REBIND" = 1 ]; then
    log "post-rs DWC3 rebind driver=${POST_RS_DWC3_REBIND_DRIVER} devices=${POST_RS_DWC3_REBIND_DEVICES}"
    driver="/sys/bus/platform/drivers/${POST_RS_DWC3_REBIND_DRIVER}"
    if [ -w "$driver/unbind" ] && [ -w "$driver/bind" ]; then
      for dev in $POST_RS_DWC3_REBIND_DEVICES; do
        [ -e "$driver/$dev" ] || { echo "WARN: missing $driver/$dev"; continue; }
        echo "$dev" > "$driver/unbind" 2>/dev/null || true
        sleep 1
        echo "$dev" > "$driver/bind" 2>/dev/null || true
        sleep 4
      done
    else
      echo "WARN: missing bind/unbind for $driver"
    fi
    snapshot "after_post_rs_dwc3_rebind"
  fi
}

wait_for_usb3() {
  local i out id
  log "WAIT USB ids [${EXPECT_USB_IDS}] timeout=${WAIT_USB3_TIMEOUT_SEC}s"
  for i in $(seq 0 "$WAIT_USB3_TIMEOUT_SEC"); do
    out="$(lsusb 2>/dev/null || true)"
    for id in $EXPECT_USB_IDS; do
      if printf '%s\n' "$out" | grep -qi "$id"; then
        echo "$out" | grep -Ei '2207:|rockchip|rk3xxx' || true
        log "USB criterion met: $id"
        return 0
      fi
    done
    sleep "$WAIT_USB3_POLL_SEC"
  done
  log "USB criterion NOT met: ${EXPECT_USB_IDS}"
  return 1
}


force_usb_device_begin() {
  [ "$FORCE_USB_DEVICE" = 1 ] || return 0
  log "FORCE_USB_DEVICE=1: hide ${PCIE_DEV_PATH} before proxy/RKNN"
  if [ -e "$PCIE_DEV_HIDDEN_PATH" ] && [ ! -e "$PCIE_DEV_PATH" ]; then
    echo "WARN: existing hidden PCIe dev at $PCIE_DEV_HIDDEN_PATH; assuming previous USB-only test left it hidden"
    PCIE_DEV_WAS_HIDDEN=1
    return 0
  fi
  if [ -e "$PCIE_DEV_PATH" ]; then
    mv "$PCIE_DEV_PATH" "$PCIE_DEV_HIDDEN_PATH"
    PCIE_DEV_WAS_HIDDEN=1
  else
    echo "INFO: $PCIE_DEV_PATH not present; proxy will naturally use USB_DEVICE only"
  fi
}

force_usb_device_restore() {
  [ "$FORCE_USB_DEVICE" = 1 ] || return 0
  if [ "$PCIE_DEV_WAS_HIDDEN" = 1 ] && [ -e "$PCIE_DEV_HIDDEN_PATH" ] && [ ! -e "$PCIE_DEV_PATH" ]; then
    log "restore hidden PCIe dev ${PCIE_DEV_HIDDEN_PATH} -> ${PCIE_DEV_PATH}"
    mv "$PCIE_DEV_HIDDEN_PATH" "$PCIE_DEV_PATH" || true
  fi
}

restart_proxy() {
  [ "$RESTART_PROXY" = 1 ] || return 0
  log "restart npu_transfer_proxy"
  systemctl stop npu_transfer_proxy 2>/dev/null || true
  killall -q npu_transfer_proxy 2>/dev/null || true
  sleep 1
  if [ -x "$TRANSFER_PROXY_LAUNCHER" ]; then
    TRANSFER_PROXY="$TRANSFER_PROXY" "$TRANSFER_PROXY_LAUNCHER" || true
  elif [ -x "$TRANSFER_PROXY" ]; then
    nohup "$TRANSFER_PROXY" >/tmp/npu_transfer_proxy_pipeline.log 2>&1 &
  fi
  sleep 2
}

wait_for_proxy_device() {
  local i out
  log "WAIT proxy device ${EXPECT_PROXY_DEVICE} timeout=${WAIT_PROXY_TIMEOUT_SEC}s"
  for i in $(seq 0 "$WAIT_PROXY_TIMEOUT_SEC"); do
    out="$(proxy_devices)"
    printf '%s\n' "$out"
    if printf '%s\n' "$out" | grep -q "$EXPECT_PROXY_DEVICE"; then
      log "proxy criterion met: $EXPECT_PROXY_DEVICE"
      return 0
    fi
    sleep "$WAIT_PROXY_POLL_SEC"
  done
  log "proxy criterion NOT met: $EXPECT_PROXY_DEVICE"
  return 1
}

run_rknn() {
  [ "$RUN_RKNN" = 1 ] || { log "RUN_RKNN=0: skip RKNN"; return 0; }
  if [ -z "$RKNN_CMD" ]; then
    if [ -f /root/npu_deep_test/resnet18_zeros_test.py ]; then
      RKNN_CMD="python3 /root/npu_deep_test/resnet18_zeros_test.py"
    elif [ -f /root/npu_deep_manual/resnet18_zeros_test.py ]; then
      RKNN_CMD="python3 /root/npu_deep_manual/resnet18_zeros_test.py"
    else
      log "RUN_RKNN=1 but RKNN_CMD is empty and no default test found"
      return 127
    fi
  fi
  log "RUN RKNN timeout=${RKNN_TIMEOUT_SEC}s cmd=${RKNN_CMD}"
  export PYTHONPATH="${RKNN_PYTHONPATH}:${PYTHONPATH:-}"
  export LD_LIBRARY_PATH="${RKNN_LD_LIBRARY_PATH}:${LD_LIBRARY_PATH:-}"
  set +e
  timeout "${RKNN_TIMEOUT_SEC}s" bash -lc "$RKNN_CMD"
  local rc=$?
  set -e
  echo "RKNN_RC=$rc"
  return "$rc"
}

main() {
  local usb_rc=0 proxy_rc=0 rknn_rc=0
  log "START USB loader -> rs -> USB_DEVICE -> proxy -> RKNN pipeline"
  trap force_usb_device_restore EXIT
  pcie_safe_controls
  snapshot "initial"

  if [ ! -x "$BOOT_SCRIPT" ]; then
    echo "ERROR: missing BOOT_SCRIPT=$BOOT_SCRIPT" >&2
    exit 2
  fi

  log "BOOT SCRIPT: $BOOT_SCRIPT"
  "$BOOT_SCRIPT"
  local boot_rc=$?
  echo "BOOT_SCRIPT_RC=$boot_rc"
  snapshot "after_boot_script_rs"
  post_rs_usb_recover

  wait_for_usb3 || usb_rc=$?
  snapshot "after_usb3_wait"
  if [ "$FAIL_ON_NO_USB3" = 1 ] && [ "$usb_rc" -ne 0 ]; then
    exit "$usb_rc"
  fi

  force_usb_device_begin
  restart_proxy
  wait_for_proxy_device || proxy_rc=$?
  snapshot "after_proxy_wait"
  if [ "$FAIL_ON_NO_USB_DEVICE" = 1 ] && [ "$proxy_rc" -ne 0 ]; then
    exit "$proxy_rc"
  fi

  run_rknn || rknn_rc=$?
  snapshot "after_rknn"
  log "SUMMARY boot_rc=$boot_rc usb_rc=$usb_rc proxy_rc=$proxy_rc rknn_rc=$rknn_rc log=$LOG_FILE"
  return "$rknn_rc"
}

main "$@"
