#!/usr/bin/env bash
# Quectel EC200A/EC20 power-on sequence for LPA3399Pro (mainline 6.18.33)
# From 6.18.33_GMAC_PATCH_COMPILE_VERIFY_20260618.md (2026-06-24 verified path)
# PWREN  = GPIO4_D5 = gpiochip4 line 29  (1 = power on)
# RESET  = GPIO1_A2 = gpiochip1 line 2   (0 = release reset, 1 = hold reset)
# PWRKEY = GPIO4_D1 = gpiochip4 line 25  (active-low pulse ~1.5s then hold high)
set -euo pipefail
log(){ echo "[ec20-init] $*"; }

command -v gpioset >/dev/null || { log "gpioset missing"; exit 1; }

# Ensure modem USB drivers present
for m in usbserial usb_wwan option qmi_wwan cdc_mbim cdc_ether cdc_acm; do
  modprobe "$m" 2>/dev/null || true
done

# Kill previous holders of these lines if any (best-effort)
pkill -f 'gpioset -c 4 .*29=' 2>/dev/null || true
pkill -f 'gpioset -c 1 .*2=' 2>/dev/null || true
pkill -f 'gpioset -c 4 .*25=' 2>/dev/null || true
sleep 0.2

log "cold reset: PWREN=0 RESET=1 PWRKEY=1"
# hold reset state briefly
gpioset -c 4 29=0 25=1 &
PID_A=$!
gpioset -c 1 2=1 &
PID_B=$!
sleep 0.5
kill $PID_A $PID_B 2>/dev/null || true
wait $PID_A $PID_B 2>/dev/null || true

log "power on: PWREN=1 RESET=0, then PWRKEY low pulse 1.5s"
# Keep PWREN high and RESET low permanently in background
nohup gpioset -c 4 29=1 >/run/ec20-pwren.log 2>&1 &
echo $! >/run/ec20-pwren.pid
nohup gpioset -c 1 2=0 >/run/ec20-reset.log 2>&1 &
echo $! >/run/ec20-reset.pid
sleep 0.3

# PWRKEY active-low pulse 1.5s
gpioset -c 4 25=0 &
PID_K=$!
sleep 1.5
kill $PID_K 2>/dev/null || true
wait $PID_K 2>/dev/null || true
# hold PWRKEY high after pulse
nohup gpioset -c 4 25=1 >/run/ec20-pwrkey.log 2>&1 &
echo $! >/run/ec20-pwrkey.pid

log "wait USB enum..."
for i in $(seq 1 20); do
  if lsusb 2>/dev/null | grep -qiE '2c7c|2dee|quectel|meig'; then
    log "modem seen on USB at ${i}s"
    lsusb | grep -iE '2c7c|2dee|quectel|meig' || true
    ls -l /dev/ttyUSB* /dev/cdc-wdm* 2>/dev/null || true
    exit 0
  fi
  sleep 1
done

log "timeout: no Quectel/MeiG USB ID after 20s"
lsusb || true
dmesg | tail -30 || true
exit 1
