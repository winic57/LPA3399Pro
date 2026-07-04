#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-status}"

case "$ACTION" in
  -i) ACTION="off" ;;
  -o) ACTION="on" ;;
  -r) ACTION="cycle" ;;
  -s|-d) ACTION="status" ;;
esac

CLK_WIFI_PMU_ENABLE=${CLK_WIFI_PMU_ENABLE:-/sys/kernel/debug/clk/clk_wifi_pmu/clk_enable_count}
RK808_CLKOUT2_ENABLE=${RK808_CLKOUT2_ENABLE:-/sys/kernel/debug/clk/rk808-clkout2/clk_enable_count}
PCIE_RESET_EP_PATH=${PCIE_RESET_EP_PATH:-/sys/devices/platform/f8000000.pcie/pcie_reset_ep}

CLK_WIFI_PMU_TARGET=${CLK_WIFI_PMU_TARGET:-1}
RK808_CLKOUT2_TARGET=${RK808_CLKOUT2_TARGET:-7}

NPU_PWR_GPIO_ENABLED=${NPU_PWR_GPIO_ENABLED:-1}
NPU_PWR_CHIP=${NPU_PWR_CHIP:-gpiochip0}
NPU_PWR_LINE=${NPU_PWR_LINE:-9}
NPU_PWR_ACTIVE=${NPU_PWR_ACTIVE:-1}
NPU_PWR_INACTIVE=${NPU_PWR_INACTIVE:-0}

NPU_RST_GPIO_ENABLED=${NPU_RST_GPIO_ENABLED:-0}
NPU_RST_CHIP=${NPU_RST_CHIP:-}
NPU_RST_LINE=${NPU_RST_LINE:-}
NPU_RST_ACTIVE=${NPU_RST_ACTIVE:-0}
NPU_RST_INACTIVE=${NPU_RST_INACTIVE:-1}

PCIE_RESET_EP_ENABLED=${PCIE_RESET_EP_ENABLED:-1}
PCIE_RESET_EP_ASSERT_VALUE=${PCIE_RESET_EP_ASSERT_VALUE:-1}
PCIE_RESET_EP_DEASSERT_VALUE=${PCIE_RESET_EP_DEASSERT_VALUE:-0}
PCIE_RESET_EP_PULSE=${PCIE_RESET_EP_PULSE:-0}

RESET_HOLD_MS=${RESET_HOLD_MS:-100}
POST_POWER_DELAY_MS=${POST_POWER_DELAY_MS:-1500}

TRANSFER_PROXY=${TRANSFER_PROXY:-/usr/bin/npu_transfer_proxy}
UPGRADE_TOOL=${UPGRADE_TOOL:-/usr/bin/upgrade_tool}

log() {
  echo "[npu_powerctrl_gpiod] $*"
}

sleep_ms() {
  python3 - "$1" <<'PY'
import sys, time
time.sleep(float(sys.argv[1]) / 1000.0)
PY
}

mount_debugfs() {
  mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true
}

write_clk_target() {
  local path="$1"
  local value="$2"
  if [ -w "$path" ]; then
    printf '%s\n' "$value" > "$path" || true
  fi
}

read_clk_value() {
  local path="$1"
  if [ -r "$path" ]; then
    cat "$path"
  else
    echo "missing"
  fi
}

gpioset_write() {
  local chip="$1" line="$2" value="$3"
  if ! command -v gpioset >/dev/null 2>&1; then
    log "gpioset not found; install gpiod/libgpiod-tools first"
    return 1
  fi
  if gpioset --help 2>&1 | grep -q -- '--mode'; then
    gpioset --mode=exit "$chip" "$line=$value"
  else
    gpioset "$chip" "$line=$value"
  fi
}

set_power_gpio() {
  [ "$NPU_PWR_GPIO_ENABLED" = "1" ] || return 0
  gpioset_write "$NPU_PWR_CHIP" "$NPU_PWR_LINE" "$1"
}

set_reset_gpio() {
  [ "$NPU_RST_GPIO_ENABLED" = "1" ] || return 0
  [ -n "$NPU_RST_CHIP" ] && [ -n "$NPU_RST_LINE" ] || return 0
  gpioset_write "$NPU_RST_CHIP" "$NPU_RST_LINE" "$1"
}

pulse_reset_gpio() {
  set_reset_gpio "$NPU_RST_ACTIVE" || true
  sleep_ms "$RESET_HOLD_MS"
  set_reset_gpio "$NPU_RST_INACTIVE" || true
}

pulse_pcie_reset_ep() {
  [ "$PCIE_RESET_EP_ENABLED" = "1" ] || return 0
  [ -w "$PCIE_RESET_EP_PATH" ] || return 0
  printf '%s\n' "$PCIE_RESET_EP_ASSERT_VALUE" > "$PCIE_RESET_EP_PATH" || true
  if [ "$PCIE_RESET_EP_PULSE" = "1" ]; then
    sleep_ms "$RESET_HOLD_MS"
    printf '%s\n' "$PCIE_RESET_EP_DEASSERT_VALUE" > "$PCIE_RESET_EP_PATH" || true
  fi
}

enable_clocks() {
  mount_debugfs
  write_clk_target "$CLK_WIFI_PMU_ENABLE" "$CLK_WIFI_PMU_TARGET"
  write_clk_target "$RK808_CLKOUT2_ENABLE" "$RK808_CLKOUT2_TARGET"
}

status_report() {
  mount_debugfs
  echo "action=status"
  echo "clk_wifi_pmu_enable_count=$(read_clk_value "$CLK_WIFI_PMU_ENABLE")"
  echo "rk808_clkout2_enable_count=$(read_clk_value "$RK808_CLKOUT2_ENABLE")"
  echo "npu_power_gpio=${NPU_PWR_GPIO_ENABLED}:${NPU_PWR_CHIP}:${NPU_PWR_LINE}"
  echo "npu_reset_gpio=${NPU_RST_GPIO_ENABLED}:${NPU_RST_CHIP:-unset}:${NPU_RST_LINE:-unset}"
  echo "pcie_reset_ep_path=${PCIE_RESET_EP_PATH}"
  if command -v lsusb >/dev/null 2>&1; then
    lsusb | grep -Ei '2207:|1d87:' || true
  fi
  if [ -x "$UPGRADE_TOOL" ]; then
    "$UPGRADE_TOOL" LD || true
  fi
  if [ -x "$TRANSFER_PROXY" ]; then
    "$TRANSFER_PROXY" devices || true
  fi
}

power_on() {
  log "enable clocks"
  enable_clocks
  log "assert power gpio"
  set_power_gpio "$NPU_PWR_ACTIVE" || true
  sleep_ms "$RESET_HOLD_MS"
  log "pulse endpoint reset"
  pulse_pcie_reset_ep || true
  log "pulse optional reset gpio"
  pulse_reset_gpio || true
  sleep_ms "$POST_POWER_DELAY_MS"
}

power_off() {
  log "assert optional reset gpio"
  set_reset_gpio "$NPU_RST_ACTIVE" || true
  sleep_ms "$RESET_HOLD_MS"
  log "deassert power gpio"
  set_power_gpio "$NPU_PWR_INACTIVE" || true
}

case "$ACTION" in
  on)
    power_on
    status_report
    ;;
  off)
    power_off
    status_report
    ;;
  cycle)
    power_off || true
    sleep_ms "$RESET_HOLD_MS"
    power_on
    status_report
    ;;
  status)
    status_report
    ;;
  *)
    echo "Usage: $0 {on|off|cycle|status|-i|-o|-r|-s|-d}" >&2
    exit 1
    ;;
esac
