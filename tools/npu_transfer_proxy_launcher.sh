#!/usr/bin/env bash
set -euo pipefail

TRANSFER_PROXY_BIN=${TRANSFER_PROXY_BIN:-${TRANSFER_PROXY:-/usr/bin/npu_transfer_proxy}}
TRANSFER_PROXY_LOG=${TRANSFER_PROXY_LOG:-/tmp/npu_transfer_proxy.log}
PROXY_CPUINFO_SERIAL_INJECT=${PROXY_CPUINFO_SERIAL_INJECT:-auto}
PROXY_SERIAL_VALUE=${PROXY_SERIAL_VALUE:-}
PROXY_STARTUP_WAIT_SEC=${PROXY_STARTUP_WAIT_SEC:-1}
PROXY_EFUSE_PATH=${PROXY_EFUSE_PATH:-/sys/devices/platform/ff690000.efuse/rockchip-efuse0/nvmem}

log() {
  echo "[npu_proxy_launcher] $*"
}

proxy_running() {
  local bin base
  bin="$TRANSFER_PROXY_BIN"
  base="$(basename "$TRANSFER_PROXY_BIN")"

  # Avoid broad `pgrep -f npu_transfer_proxy`: it can match the caller's
  # ssh/shell command line when that line contains "npu_transfer_proxy devices",
  # causing a false "proxy already running" and preventing listener startup.
  ps -eo args= | awk -v bin="$bin" -v base="$base" '
    $1 == bin || $1 == base || $1 ~ ("/" base "$") { found = 1 }
    END { exit found ? 0 : 1 }
  '
}

has_cpuinfo_serial() {
  grep -q '^Serial' /proc/cpuinfo 2>/dev/null
}

sanitize_serial() {
  tr -cd '0-9a-fA-F' | tr 'A-F' 'a-f' | head -c 16
}

serial_from_dt() {
  local f
  for f in /proc/device-tree/serial-number /sys/firmware/devicetree/base/serial-number; do
    if [ -r "$f" ]; then
      tr -d '\0' <"$f" | sanitize_serial
      return 0
    fi
  done
  return 1
}

serial_from_efuse() {
  [ -r "$PROXY_EFUSE_PATH" ] || return 1
  sha256sum "$PROXY_EFUSE_PATH" | awk '{print substr($1, 1, 16)}'
}

serial_from_machine_id() {
  [ -r /etc/machine-id ] || return 1
  sanitize_serial </etc/machine-id
}

derive_serial() {
  local serial=""

  if [ -n "$PROXY_SERIAL_VALUE" ]; then
    serial="$(printf '%s' "$PROXY_SERIAL_VALUE" | sanitize_serial)"
  fi

  if [ -z "$serial" ]; then
    serial="$(serial_from_dt 2>/dev/null || true)"
  fi
  if [ -z "$serial" ]; then
    serial="$(serial_from_efuse 2>/dev/null || true)"
  fi
  if [ -z "$serial" ]; then
    serial="$(serial_from_machine_id 2>/dev/null || true)"
  fi

  if [ -z "$serial" ]; then
    serial="0123456789abcdef"
  fi

  printf '%s\n' "$serial"
}

start_raw_proxy() {
  nohup "$TRANSFER_PROXY_BIN" >>"$TRANSFER_PROXY_LOG" 2>&1 &
  echo $!
}

start_proxy_in_private_mount_ns() {
  local tmp_cpuinfo="$1"

  nohup unshare -m sh -c "mount --bind '$tmp_cpuinfo' /proc/cpuinfo && exec '$TRANSFER_PROXY_BIN'" \
    >>"$TRANSFER_PROXY_LOG" 2>&1 &
  sleep "$PROXY_STARTUP_WAIT_SEC"

  if proxy_running; then
    log "proxy resident in private mount namespace"
    return 0
  fi

  return 1
}

start_proxy_with_injected_serial() {
  local serial="$1"
  local tmp_cpuinfo proxy_pid

  tmp_cpuinfo="$(mktemp /tmp/npu_proxy_cpuinfo.XXXXXX)"
  cp /proc/cpuinfo "$tmp_cpuinfo"
  printf '\nSerial\t\t: %s\n' "$serial" >>"$tmp_cpuinfo"

  if command -v unshare >/dev/null 2>&1; then
    if start_proxy_in_private_mount_ns "$tmp_cpuinfo"; then
      rm -f "$tmp_cpuinfo"
      return 0
    fi
    log "private mount namespace startup failed; fallback to temporary global bind"
  fi

  if ! mount --bind "$tmp_cpuinfo" /proc/cpuinfo; then
    rm -f "$tmp_cpuinfo"
    return 1
  fi
  nohup "$TRANSFER_PROXY_BIN" >>"$TRANSFER_PROXY_LOG" 2>&1 &
  proxy_pid=$!
  sleep "$PROXY_STARTUP_WAIT_SEC"

  umount /proc/cpuinfo 2>/dev/null || true
  rm -f "$tmp_cpuinfo"

  if ps -p "$proxy_pid" >/dev/null 2>&1; then
    log "proxy resident after injected Serial=$serial pid=$proxy_pid"
    return 0
  fi

  log "proxy exited during injected-serial startup"
  return 1
}

main() {
  local inject serial proxy_pid

  if [ ! -x "$TRANSFER_PROXY_BIN" ]; then
    log "missing proxy binary: $TRANSFER_PROXY_BIN"
    exit 2
  fi

  if proxy_running; then
    log "proxy already running"
    exit 0
  fi

  inject="$PROXY_CPUINFO_SERIAL_INJECT"
  case "$inject" in
    auto)
      if has_cpuinfo_serial; then
        inject=0
      else
        inject=1
      fi
      ;;
    0|1)
      ;;
    *)
      log "unknown PROXY_CPUINFO_SERIAL_INJECT=$inject, fallback to auto"
      if has_cpuinfo_serial; then
        inject=0
      else
        inject=1
      fi
      ;;
  esac

  if [ "$inject" = 1 ]; then
    serial="$(derive_serial)"
    log "cpuinfo Serial missing; inject synthetic Serial=$serial"
    if start_proxy_with_injected_serial "$serial"; then
      exit 0
    fi
    log "injected startup failed; fallback to raw start"
  fi

  proxy_pid="$(start_raw_proxy)"
  sleep "$PROXY_STARTUP_WAIT_SEC"
  if ps -p "$proxy_pid" >/dev/null 2>&1; then
    log "proxy resident after raw start pid=$proxy_pid"
  else
    log "proxy exited after raw start"
  fi
}

main "$@"
