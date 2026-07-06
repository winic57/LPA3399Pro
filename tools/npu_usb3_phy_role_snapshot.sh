#!/usr/bin/env bash
set -euo pipefail

# Non-destructive RK3399Pro NPU USB3/PHY/role snapshot.
# Intended to compare .129 golden vs .113 mainline before/after USB loader rs.

SNAP_ID=${SNAP_ID:-$(hostname)_$(date +%Y%m%d_%H%M%S)}
DMESG_LINES=${DMESG_LINES:-260}
LSUSB_VERBOSE=${LSUSB_VERBOSE:-0}
MAX_FIND_LINES=${MAX_FIND_LINES:-200}

section() { printf '\n===== %s =====\n' "$*"; }
kv() { printf '%s=%s\n' "$1" "$2"; }
run() { echo "+ $*"; "$@" 2>&1 || true; }
cat_if() { for f in "$@"; do [ -e "$f" ] && { printf '%s=' "$f"; cat "$f" 2>&1 || true; }; done; }

section "snapshot_meta"
kv SNAP_ID "$SNAP_ID"
kv TS_ISO "$(date -Is)"
kv HOSTNAME "$(hostname 2>/dev/null || true)"
kv UNAME "$(uname -a)"
kv CMDLINE "$(cat /proc/cmdline 2>/dev/null || true)"
kv UPTIME "$(cat /proc/uptime 2>/dev/null || true)"

mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true

section "network"
run ip -br addr
run ip route

section "npu_fw_hashes"
for d in /usr/share/npu_fw /usr/share/npu_fw_pcie /vendor/usr/share/npu_fw /root/npu_fw; do
  [ -d "$d" ] || continue
  echo "-- $d --"
  find "$d" -maxdepth 2 -type f \( -name '*.bin' -o -name '*.img' -o -name 'parameter.txt' -o -name '*.sh' -o -name 'npu*' \) -print0 2>/dev/null \
    | sort -z \
    | xargs -0r sha256sum 2>/dev/null || true
  find "$d" -maxdepth 2 -type f -printf '%TY-%Tm-%Td %TH:%TM:%TS %s %p\n' 2>/dev/null | sort | head -n "$MAX_FIND_LINES" || true
done

section "npu_scripts_and_binaries"
for p in /usr/bin/upgrade_tool /usr/bin/npu_transfer_proxy /usr/bin/npu_upgrade_pcie /usr/bin/npu-image.sh /usr/local/bin/npu-image.sh /usr/local/bin/npu_upgrade_pcie /usr/local/bin/npu_boot /usr/local/bin/npu_powerctrl-gpiod /usr/local/bin/npu_usb_loader_rs_rknn_pipeline.sh; do
  if [ -e "$p" ]; then
    ls -l "$p" || true
    sha256sum "$p" 2>/dev/null || true
    case "$p" in *.sh|*/npu-image.sh|*/npu_usb_loader_rs_rknn_pipeline.sh) sed -n '1,120p' "$p" 2>/dev/null || true;; esac
  fi
done

section "rockusb_and_proxy"
run upgrade_tool ld
run pgrep -af 'npu_transfer_proxy|npu_usb_loader|upgrade_tool'
run npu_transfer_proxy devices
run systemctl status npu_transfer_proxy --no-pager -l

section "lsusb"
run lsusb
run lsusb -t
if [ "$LSUSB_VERBOSE" = 1 ]; then
  run lsusb -v
fi

section "usb_device_tree_key_attrs"
for dev in /sys/bus/usb/devices/*; do
  [ -d "$dev" ] || continue
  base=$(basename "$dev")
  printf '\n-- usbdev %s --\n' "$base"
  for a in idVendor idProduct product manufacturer serial speed busnum devnum devpath bDeviceClass bDeviceSubClass bDeviceProtocol configuration authorized maxchild removable rx_lanes tx_lanes version; do
    [ -e "$dev/$a" ] && printf '%s=%s\n' "$a" "$(cat "$dev/$a" 2>/dev/null || true)"
  done
  [ -L "$dev/driver" ] && readlink -f "$dev/driver" || true
done

section "platform_usb_drivers"
for drv in /sys/bus/platform/drivers/xhci-hcd /sys/bus/platform/drivers/dwc3 /sys/bus/platform/drivers/ehci-platform /sys/bus/platform/drivers/ohci-platform /sys/bus/platform/drivers/rockchip-usb2phy /sys/bus/platform/drivers/phy-rockchip-inno-usb2 /sys/bus/platform/drivers/rockchip-typec-phy /sys/bus/platform/drivers/rockchip-dwc3; do
  [ -d "$drv" ] || continue
  echo "-- $drv --"
  ls -l "$drv" 2>/dev/null | sed -n '1,120p' || true
done

section "usb_platform_device_attrs"
for dev in /sys/bus/platform/devices/*usb* /sys/bus/platform/devices/*dwc3* /sys/bus/platform/devices/*phy* /sys/bus/platform/devices/*typec*; do
  [ -e "$dev" ] || continue
  [ -d "$dev" ] || continue
  echo "-- $dev --"
  [ -L "$dev/driver" ] && echo "driver=$(readlink -f "$dev/driver")"
  cat_if "$dev/modalias" "$dev/status" "$dev/dr_mode" "$dev/maximum_speed" "$dev/current_dr_role" "$dev/role" "$dev/of_node/status" "$dev/of_node/dr_mode" "$dev/of_node/maximum-speed" "$dev/power/runtime_status" "$dev/power/control" "$dev/power/runtime_usage" "$dev/power/autosuspend_delay_ms"
done

section "phy_class_attrs"
for phy in /sys/class/phy/* /sys/bus/platform/devices/*/phy*/; do
  [ -e "$phy" ] || continue
  [ -d "$phy" ] || continue
  echo "-- $phy --"
  [ -L "$phy/device" ] && echo "device=$(readlink -f "$phy/device")"
  cat_if "$phy/power/runtime_status" "$phy/power/control" "$phy/power/runtime_usage" "$phy/power/autosuspend_delay_ms" "$phy/uevent"
done

section "role_switch_and_typec"
for d in /sys/class/usb_role/* /sys/class/typec/* /sys/class/extcon/*; do
  [ -e "$d" ] || continue
  echo "-- $d --"
  find "$d" -maxdepth 2 -type f -printf '%p=' -exec cat {} \; 2>/dev/null | head -n "$MAX_FIND_LINES" || true
done

section "clocks_key"
if [ -r /sys/kernel/debug/clk/clk_summary ]; then
  grep -Ei 'wifi_pmu|rk808|clkout|usb|utmi|phy|pcie|npu|24m|xin24|gmac' /sys/kernel/debug/clk/clk_summary | sed -n '1,240p' || true
fi
cat_if /sys/kernel/debug/clk/clk_wifi_pmu/clk_rate /sys/kernel/debug/clk/clk_wifi_pmu/clk_enable_count /sys/kernel/debug/clk/clk_wifi_pmu/clk_prepare_count /sys/kernel/debug/clk/rk808-clkout2/clk_enable_count /sys/kernel/debug/clk/rk808-clkout2/clk_prepare_count

section "reset_and_regulator_key"
for d in /sys/kernel/debug/regulator/* /sys/class/regulator/*; do
  [ -d "$d" ] || continue
  name=$(basename "$d")
  if echo "$name $(cat "$d/name" 2>/dev/null || true)" | grep -Eiq 'usb|phy|pcie|npu|wifi|vcc|3v3|1v8|rk808'; then
    echo "-- $d --"
    cat_if "$d/name" "$d/state" "$d/status" "$d/microvolts" "$d/min_microvolts" "$d/max_microvolts" "$d/num_users" "$d/use_count"
  fi
done

section "gpio_pinctrl_key"
for g in /sys/kernel/debug/gpio /sys/kernel/debug/pinctrl/*/pinmux-pins /sys/kernel/debug/pinctrl/*/pinconf-pins; do
  [ -r "$g" ] || continue
  echo "-- $g --"
  grep -Ei 'npu|pcie|usb|wifi|pmu|reset|gpio0|gpio1|gpio32|gpio35|gpio36|gpio54|gpio55|gpio56|GPIO0_A2' "$g" 2>/dev/null | sed -n '1,220p' || true
done

section "pcie_debugfs"
if [ -d /sys/kernel/debug/pcie ]; then
  ls -l /sys/kernel/debug/pcie || true
  for f in dma_disabled dma_timeout_ms dma_failfast_mode dma_read_dump_enable dma_read_dump_len pcie_trx; do
    [ -e "/sys/kernel/debug/pcie/$f" ] && { echo "-- $f --"; cat "/sys/kernel/debug/pcie/$f" 2>&1 || true; }
  done
fi
[ -e /dev/pcie-dev ] && ls -l /dev/pcie-dev || true

section "dmesg_usb_npu_tail"
dmesg | grep -Ei 'usb|dwc3|xhci|ehci|ohci|2207|180a|0019|firmware changed|SuperSpeed|high-speed|typec|role|phy|utmi|npu|ntb|pcie|dma|error -71|disconnect|reset' | tail -n "$DMESG_LINES" || true

section "end"
kv TS_ISO_END "$(date -Is)"
