#!/usr/bin/env bash
# LPA3399Pro WiFi/BT bring-up helper (idempotent)
set -euo pipefail
log() { echo "[lpa-wifi-bt] $*"; }

# 1) modules path: uname -r may be 6.18.33 while tree is 6.18.33-rk35xx-ophub
UREL="$(uname -r)"
if [[ ! -d "/lib/modules/${UREL}" ]]; then
  if [[ -d /lib/modules/6.18.33-rk35xx-ophub ]]; then
    ln -sfn 6.18.33-rk35xx-ophub "/lib/modules/${UREL}"
    log "symlink /lib/modules/${UREL} -> 6.18.33-rk35xx-ophub"
  fi
fi
if [[ -d "/lib/modules/${UREL}" && ! -f "/lib/modules/${UREL}/modules.dep" ]]; then
  depmod -a "${UREL}" || true
fi

# 2) load reset_gpio then wifi/bt stack
for m in reset_gpio rfkill cfg80211 mac80211 rtw88_core rtw88_sdio rtw88_8821c rtw88_8821cs bluetooth btrtl hci_uart; do
  modprobe "$m" 2>/dev/null || true
done

# 3) kick deferred probes (sdio-pwrseq / fe310000.mmc)
if [[ -w /sys/bus/platform/drivers_probe ]]; then
  echo sdio-pwrseq > /sys/bus/platform/drivers_probe 2>/dev/null || true
  echo fe310000.mmc > /sys/bus/platform/drivers_probe 2>/dev/null || true
fi
# bind if still unbound
if [[ -e /sys/devices/platform/sdio-pwrseq && ! -e /sys/devices/platform/sdio-pwrseq/driver ]]; then
  echo sdio-pwrseq > /sys/bus/platform/drivers/pwrseq_simple/bind 2>/dev/null || true
fi
if [[ -e /sys/devices/platform/fe310000.mmc && ! -e /sys/devices/platform/fe310000.mmc/driver ]]; then
  echo fe310000.mmc > /sys/bus/platform/drivers/dwmmc_rockchip/bind 2>/dev/null || true
fi

sleep 1
if ip link show wlan0 >/dev/null 2>&1; then
  ip link set wlan0 up 2>/dev/null || true
  log "wlan0 present"
else
  log "wlan0 missing (check dmesg for sdio-pwrseq/rtw88)"
fi

# 4) Bluetooth: hold enable/device-wake if gpioset available; try hciattach
# GPIO: chip2 line28 enable, line26 device-wake (from DT serial@ff180000/bluetooth)
if command -v gpioset >/dev/null 2>&1; then
  if ! pgrep -f 'gpioset -c 2 .*28=1' >/dev/null 2>&1; then
    # keep lines driven
    nohup gpioset -c 2 28=1 26=1 >/run/lpa-bt-gpioset.log 2>&1 &
    log "BT GPIO enable held via gpioset"
  fi
fi

# Prefer kernel serdev if DT bluetooth status=okay and CONFIG_BT_HCIUART_RTL=y
# Current 6.18.33 package has CONFIG_BT_HCIUART_RTL not set; userspace attach is best-effort.
if [[ ! -e /sys/class/bluetooth/hci0 ]]; then
  systemctl stop serial-getty@ttyS0.service 2>/dev/null || true
  fuser -k /dev/ttyS0 2>/dev/null || true
  if command -v hciattach >/dev/null 2>&1; then
    # rtk_h5 may be unavailable depending on bluez build; try any as fallback
    hciattach /dev/ttyS0 rtk_h5 115200 noflow 2>/run/lpa-hciattach.log || \
      hciattach /dev/ttyS0 any 115200 noflow 2>>/run/lpa-hciattach.log || true
  fi
fi

if [[ -e /sys/class/bluetooth/hci0 ]]; then
  log "hci0 present"
  command -v hciconfig >/dev/null && hciconfig hci0 up 2>/dev/null || true
else
  log "hci0 missing (need CONFIG_BT_HCIUART_RTL=y or working rtk_hciattach + BT power)"
fi

exit 0
