#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-status}"

case "$ACTION" in
  -i) ACTION="init" ;;
  -o) ACTION="on" ;;
  -r) ACTION="resume" ;;
  -s) ACTION="suspend" ;;
  -d) ACTION="off" ;;
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
NPU_INIT_GLOBAL_LINES=${NPU_INIT_GLOBAL_LINES:-}
NPU_SUSPEND_TRIGGER_GLOBAL_LINE=${NPU_SUSPEND_TRIGGER_GLOBAL_LINE:-}
NPU_SUSPEND_ACK_GLOBAL_LINE=${NPU_SUSPEND_ACK_GLOBAL_LINE:-}
NPU_SUSPEND_TRIGGER_ACTIVE=${NPU_SUSPEND_TRIGGER_ACTIVE:-1}
NPU_SUSPEND_TRIGGER_INACTIVE=${NPU_SUSPEND_TRIGGER_INACTIVE:-0}
NPU_SUSPEND_ACK_SLEEP_VALUE=${NPU_SUSPEND_ACK_SLEEP_VALUE:-1}
NPU_SUSPEND_ACK_AWAKE_VALUE=${NPU_SUSPEND_ACK_AWAKE_VALUE:-0}
NPU_SUSPEND_TIMEOUT_MS=${NPU_SUSPEND_TIMEOUT_MS:-1000}
GPIO_HOLD_DIR=${GPIO_HOLD_DIR:-/run/npu_powerctrl_gpiod}
GPIO_HOLD_SETTLE_MS=${GPIO_HOLD_SETTLE_MS:-50}
GPIO_HOLD_RELEASE_SETTLE_MS=${GPIO_HOLD_RELEASE_SETTLE_MS:-50}
NPU_PRECISE_POWERUP_PROFILE=${NPU_PRECISE_POWERUP_PROFILE:-}
NPU_PRECISE_STEP_DELAY_MS=${NPU_PRECISE_STEP_DELAY_MS:-2}
NPU_PRECISE_FINAL_DELAY_MS=${NPU_PRECISE_FINAL_DELAY_MS:-25}
NPU_PRECISE_POST_POWER_DELAY_MS=${NPU_PRECISE_POST_POWER_DELAY_MS:-1500}
NPU_PRECISE_PRE_CLK_WIFI_PMU_TARGET=${NPU_PRECISE_PRE_CLK_WIFI_PMU_TARGET:-0}
NPU_PRECISE_PRE_RK808_CLKOUT2_TARGET=${NPU_PRECISE_PRE_RK808_CLKOUT2_TARGET:-1}
NPU_PRECISE_STAGE1_CLK_WIFI_PMU_TARGET=${NPU_PRECISE_STAGE1_CLK_WIFI_PMU_TARGET:-1}
NPU_PRECISE_STAGE1_RK808_CLKOUT2_TARGET=${NPU_PRECISE_STAGE1_RK808_CLKOUT2_TARGET:-}
NPU_PRECISE_LOW_GLOBALS=${NPU_PRECISE_LOW_GLOBALS:-56,55,54,11,4,10,36,32}
NPU_PRECISE_RISE_STAGE1_GLOBALS=${NPU_PRECISE_RISE_STAGE1_GLOBALS:-4,10,11}
NPU_PRECISE_RISE_STAGE2_GLOBALS=${NPU_PRECISE_RISE_STAGE2_GLOBALS:-54,55,56}
NPU_PRECISE_FINAL_GLOBAL=${NPU_PRECISE_FINAL_GLOBAL:-32}
NPU_PRECISE_INPUT_GLOBALS=${NPU_PRECISE_INPUT_GLOBALS:-35}
NPU_PRECISE_HELPER_CMD=${NPU_PRECISE_HELPER_CMD:-}
NPU_PRECISE_HELPER_STAGE=${NPU_PRECISE_HELPER_STAGE:-after_stage1}
NPU_PRECISE_POWER_GPIO_STAGE=${NPU_PRECISE_POWER_GPIO_STAGE:-before_low}
NPU_PRECISE_KEEP_RESET_GPIO=${NPU_PRECISE_KEEP_RESET_GPIO:-0}
NPU_PRECISE_KEEP_PCIE_RESET_EP=${NPU_PRECISE_KEEP_PCIE_RESET_EP:-0}

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
  [ -n "$value" ] || return 0
  [ -e "$path" ] || return 0
  ( printf '%s\n' "$value" > "$path" ) 2>/dev/null || true
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
  if gpioset --help 2>&1 | grep -q -- '--chip'; then
    mkdir -p "$GPIO_HOLD_DIR"
    local pidfile="${GPIO_HOLD_DIR}/${chip}_${line}.pid"
    if [ -f "$pidfile" ]; then
      local oldpid
      oldpid="$(cat "$pidfile" 2>/dev/null || true)"
      [ -n "$oldpid" ] && kill "$oldpid" 2>/dev/null || true
      rm -f "$pidfile"
      if [ "${GPIO_HOLD_RELEASE_SETTLE_MS}" -gt 0 ]; then
        sleep_ms "${GPIO_HOLD_RELEASE_SETTLE_MS}"
      fi
    fi
    nohup gpioset -c "$chip" "$line=$value" >/dev/null 2>&1 &
    echo $! > "$pidfile"
    if [ "${GPIO_HOLD_SETTLE_MS}" -gt 0 ]; then
      sleep_ms "${GPIO_HOLD_SETTLE_MS}"
    fi
  elif gpioset --help 2>&1 | grep -q -- '--mode'; then
    gpioset --mode=exit "$chip" "$line=$value"
  else
    gpioset "$chip" "$line=$value"
  fi
}

release_gpio_hold() {
  local chip="$1" line="$2"
  local pidfile="${GPIO_HOLD_DIR}/${chip}_${line}.pid"
  if [ -f "$pidfile" ]; then
    local oldpid
    oldpid="$(cat "$pidfile" 2>/dev/null || true)"
    [ -n "$oldpid" ] && kill "$oldpid" 2>/dev/null || true
    rm -f "$pidfile"
    if [ "${GPIO_HOLD_RELEASE_SETTLE_MS}" -gt 0 ]; then
      sleep_ms "${GPIO_HOLD_RELEASE_SETTLE_MS}"
    fi
  fi
}

gpioget_read() {
  local chip="$1" line="$2"
  if command -v gpioget >/dev/null 2>&1; then
    if gpioget --help 2>&1 | grep -q -- '--chip'; then
      gpioget -c "$chip" "$line"
    else
      gpioget "$chip" "$line"
    fi
  else
    return 1
  fi
}

set_global_gpio() {
  local global_line="$1" value="$2"
  local chip_index=$((global_line / 32))
  local chip_line=$((global_line % 32))
  gpioset_write "gpiochip${chip_index}" "${chip_line}" "${value}"
}

set_global_gpio_input() {
  local global_line="$1"
  local chip_index=$((global_line / 32))
  local chip_line=$((global_line % 32))
  release_gpio_hold "gpiochip${chip_index}" "${chip_line}"
  if [ -w "/sys/class/gpio/export" ]; then
    printf '%s\n' "$global_line" > /sys/class/gpio/export 2>/dev/null || true
    if [ -w "/sys/class/gpio/gpio${global_line}/direction" ]; then
      printf 'in\n' > "/sys/class/gpio/gpio${global_line}/direction" || true
      return 0
    fi
  fi
  gpioget_read "gpiochip${chip_index}" "${chip_line}" >/dev/null || true
}

read_global_gpio() {
  local global_line="$1"
  local chip_index=$((global_line / 32))
  local chip_line=$((global_line % 32))
  if [ -r "/sys/class/gpio/gpio${global_line}/value" ]; then
    cat "/sys/class/gpio/gpio${global_line}/value"
  else
    gpioget_read "gpiochip${chip_index}" "${chip_line}"
  fi
}

apply_global_spec() {
  local spec="$1"
  local global="${spec%%=*}"
  local mode="${spec#*=}"
  mode="${mode//[[:space:]]/}"
  case "$mode" in
    in|input)
      set_global_gpio_input "$global"
      ;;
    out:0|o0|low|0)
      set_global_gpio "$global" 0
      ;;
    out:1|o1|high|1)
      set_global_gpio "$global" 1
      ;;
    *)
      log "unsupported gpio spec: ${spec}"
      return 1
      ;;
  esac
}

init_global_lines() {
  [ -n "$NPU_INIT_GLOBAL_LINES" ] || return 0
  local spec
  IFS=',' read -r -a _specs <<< "$NPU_INIT_GLOBAL_LINES"
  for spec in "${_specs[@]}"; do
    [ -n "$spec" ] || continue
    apply_global_spec "$spec"
  done
}

set_globals_csv() {
  local csv="$1" value="$2"
  [ -n "$csv" ] || return 0
  local global
  IFS=',' read -r -a _globals <<< "$csv"
  for global in "${_globals[@]}"; do
    global="${global//[[:space:]]/}"
    [ -n "$global" ] || continue
    set_global_gpio "$global" "$value"
  done
}

set_globals_csv_input() {
  local csv="$1"
  [ -n "$csv" ] || return 0
  local global
  IFS=',' read -r -a _globals <<< "$csv"
  for global in "${_globals[@]}"; do
    global="${global//[[:space:]]/}"
    [ -n "$global" ] || continue
    set_global_gpio_input "$global"
  done
}

run_precise_helper() {
  local stage="$1"
  [ -n "$NPU_PRECISE_HELPER_CMD" ] || return 0
  [ "$NPU_PRECISE_HELPER_STAGE" = "$stage" ] || return 0
  if [ -x "$NPU_PRECISE_HELPER_CMD" ]; then
    log "run precise helper at stage=${stage}: ${NPU_PRECISE_HELPER_CMD}"
    "$NPU_PRECISE_HELPER_CMD" || true
  else
    log "precise helper missing or not executable: ${NPU_PRECISE_HELPER_CMD}"
  fi
}

run_precise_power_gpio_stage() {
  local stage="$1"
  [ "$NPU_PWR_GPIO_ENABLED" = "1" ] || return 0
  [ "$NPU_PRECISE_POWER_GPIO_STAGE" = "$stage" ] || return 0
  log "precise power gpio stage=${stage}: ${NPU_PWR_CHIP}:${NPU_PWR_LINE} -> ${NPU_PWR_ACTIVE}"
  set_power_gpio "$NPU_PWR_ACTIVE" || true
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
  echo "npu_init_global_lines=${NPU_INIT_GLOBAL_LINES:-unset}"
  echo "npu_suspend_trigger_global_line=${NPU_SUSPEND_TRIGGER_GLOBAL_LINE:-unset}"
  echo "npu_suspend_ack_global_line=${NPU_SUSPEND_ACK_GLOBAL_LINE:-unset}"
  echo "gpio_hold_settle_ms=${GPIO_HOLD_SETTLE_MS}"
  echo "gpio_hold_release_settle_ms=${GPIO_HOLD_RELEASE_SETTLE_MS}"
  echo "npu_precise_powerup_profile=${NPU_PRECISE_POWERUP_PROFILE:-unset}"
  echo "npu_precise_power_gpio_stage=${NPU_PRECISE_POWER_GPIO_STAGE:-unset}"
  echo "npu_precise_pre_clk_wifi_pmu_target=${NPU_PRECISE_PRE_CLK_WIFI_PMU_TARGET}"
  echo "npu_precise_pre_rk808_clkout2_target=${NPU_PRECISE_PRE_RK808_CLKOUT2_TARGET}"
  echo "npu_precise_stage1_clk_wifi_pmu_target=${NPU_PRECISE_STAGE1_CLK_WIFI_PMU_TARGET}"
  echo "npu_precise_stage1_rk808_clkout2_target=${NPU_PRECISE_STAGE1_RK808_CLKOUT2_TARGET:-unset}"
  echo "npu_precise_low_globals=${NPU_PRECISE_LOW_GLOBALS:-unset}"
  echo "npu_precise_rise_stage1_globals=${NPU_PRECISE_RISE_STAGE1_GLOBALS:-unset}"
  echo "npu_precise_rise_stage2_globals=${NPU_PRECISE_RISE_STAGE2_GLOBALS:-unset}"
  echo "npu_precise_final_global=${NPU_PRECISE_FINAL_GLOBAL:-unset}"
  echo "npu_precise_input_globals=${NPU_PRECISE_INPUT_GLOBALS:-unset}"
  echo "npu_precise_helper_cmd=${NPU_PRECISE_HELPER_CMD:-unset}"
  echo "npu_precise_helper_stage=${NPU_PRECISE_HELPER_STAGE:-unset}"
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

init_only() {
  log "apply optional vendor-style init lines"
  init_global_lines || true
}

power_on_precise_golden129() {
  log "run precise holder profile=golden129"
  mount_debugfs
  write_clk_target "$RK808_CLKOUT2_ENABLE" "$NPU_PRECISE_PRE_RK808_CLKOUT2_TARGET"
  write_clk_target "$CLK_WIFI_PMU_ENABLE" "$NPU_PRECISE_PRE_CLK_WIFI_PMU_TARGET"
  run_precise_power_gpio_stage before_low
  set_globals_csv_input "$NPU_PRECISE_INPUT_GLOBALS"
  set_globals_csv "$NPU_PRECISE_LOW_GLOBALS" 0
  run_precise_helper before_stage1
  sleep_ms "$NPU_PRECISE_STEP_DELAY_MS"

  local global
  IFS=',' read -r -a _stage1 <<< "$NPU_PRECISE_RISE_STAGE1_GLOBALS"
  for global in "${_stage1[@]}"; do
    global="${global//[[:space:]]/}"
    [ -n "$global" ] || continue
    set_global_gpio "$global" 1
    sleep_ms "$NPU_PRECISE_STEP_DELAY_MS"
  done

  run_precise_power_gpio_stage after_stage1
  write_clk_target "$RK808_CLKOUT2_ENABLE" "$NPU_PRECISE_STAGE1_RK808_CLKOUT2_TARGET"
  write_clk_target "$CLK_WIFI_PMU_ENABLE" "$NPU_PRECISE_STAGE1_CLK_WIFI_PMU_TARGET"
  run_precise_helper after_stage1

  IFS=',' read -r -a _stage2 <<< "$NPU_PRECISE_RISE_STAGE2_GLOBALS"
  for global in "${_stage2[@]}"; do
    global="${global//[[:space:]]/}"
    [ -n "$global" ] || continue
    set_global_gpio "$global" 1
    sleep_ms "$NPU_PRECISE_STEP_DELAY_MS"
  done

  run_precise_power_gpio_stage after_stage2
  run_precise_helper after_stage2
  sleep_ms "$NPU_PRECISE_FINAL_DELAY_MS"
  [ -n "$NPU_PRECISE_FINAL_GLOBAL" ] && set_global_gpio "$NPU_PRECISE_FINAL_GLOBAL" 1
  run_precise_power_gpio_stage after_final
  run_precise_helper after_final

  if [ "$NPU_PRECISE_KEEP_PCIE_RESET_EP" = "1" ]; then
    pulse_pcie_reset_ep || true
  fi
  if [ "$NPU_PRECISE_KEEP_RESET_GPIO" = "1" ]; then
    pulse_reset_gpio || true
  fi
  sleep_ms "$NPU_PRECISE_POST_POWER_DELAY_MS"
}

power_on() {
  if [ "$NPU_PRECISE_POWERUP_PROFILE" = "golden129" ]; then
    power_on_precise_golden129
    return 0
  fi
  log "enable clocks"
  enable_clocks
  init_only
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

suspend_npu() {
  [ -n "$NPU_SUSPEND_TRIGGER_GLOBAL_LINE" ] || {
    log "suspend trigger line not configured"
    return 0
  }
  if [ -n "$NPU_SUSPEND_ACK_GLOBAL_LINE" ]; then
    local ack
    ack="$(read_global_gpio "$NPU_SUSPEND_ACK_GLOBAL_LINE" 2>/dev/null || echo unknown)"
    if [ "$ack" = "$NPU_SUSPEND_ACK_SLEEP_VALUE" ]; then
      log "NPU already suspended"
      return 0
    fi
  fi
  log "pulse suspend trigger line"
  set_global_gpio "$NPU_SUSPEND_TRIGGER_GLOBAL_LINE" "$NPU_SUSPEND_TRIGGER_ACTIVE" || true
  sleep_ms "$RESET_HOLD_MS"
  set_global_gpio "$NPU_SUSPEND_TRIGGER_GLOBAL_LINE" "$NPU_SUSPEND_TRIGGER_INACTIVE" || true
  [ -n "$NPU_SUSPEND_ACK_GLOBAL_LINE" ] || return 0
  local loops=$(( (NPU_SUSPEND_TIMEOUT_MS + 99) / 100 )) ack=""
  while [ "$loops" -gt 0 ]; do
    ack="$(read_global_gpio "$NPU_SUSPEND_ACK_GLOBAL_LINE" 2>/dev/null || echo unknown)"
    [ "$ack" = "$NPU_SUSPEND_ACK_SLEEP_VALUE" ] && return 0
    sleep_ms 100
    loops=$((loops - 1))
  done
  log "suspend timed out waiting for ack=${NPU_SUSPEND_ACK_SLEEP_VALUE}"
  return 1
}

resume_npu() {
  if [ -n "$NPU_SUSPEND_ACK_GLOBAL_LINE" ]; then
    local ack
    ack="$(read_global_gpio "$NPU_SUSPEND_ACK_GLOBAL_LINE" 2>/dev/null || echo unknown)"
    if [ "$ack" = "$NPU_SUSPEND_ACK_AWAKE_VALUE" ]; then
      log "NPU already awake"
      return 0
    fi
  fi
  log "resume fallback uses power-on sequence"
  power_on
}

case "$ACTION" in
  init)
    init_only
    status_report
    ;;
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
  suspend)
    suspend_npu
    status_report
    ;;
  resume)
    resume_npu
    status_report
    ;;
  status)
    status_report
    ;;
  *)
    echo "Usage: $0 {init|on|off|cycle|suspend|resume|status|-i|-o|-r|-s|-d}" >&2
    exit 1
    ;;
esac
