#!/usr/bin/env bash
set -euo pipefail

TRANSFER_PROXY=${TRANSFER_PROXY:-/usr/bin/npu_transfer_proxy}
DMESG_LINES=${DMESG_LINES:-160}

echo "== RK3399Pro NPU USB/NTB quick check =="

printf '\n[1/5] Rockchip USB devices\n'
if command -v lsusb >/dev/null 2>&1; then
  lsusb | grep -Ei '2207:|rockchip|rk3xxx' || true
else
  echo "WARN: lsusb not found"
fi

printf '\n[2/5] Recent USB/NPU dmesg\n'
dmesg | grep -Ei 'usb 3-1|usb 4-1|2207|180a|1808|0019|1005|firmware changed|SuperSpeed|ntb|rknn|npu|error -71|disconnect' | tail -n "$DMESG_LINES" || true

printf '\n[3/5] Host USB/network interfaces (informational only)\n'
ip -brief link 2>/dev/null | grep -Ei 'usb|rndis|enx|eth' || true

printf '\n[4/5] npu_transfer_proxy process\n'
pgrep -af npu_transfer_proxy || true

printf '\n[5/5] npu_transfer_proxy devices\n'
if [ -x "$TRANSFER_PROXY" ]; then
  "$TRANSFER_PROXY" devices || true
else
  echo "WARN: $TRANSFER_PROXY is missing or not executable"
  echo "      Install drivers/npu_transfer_proxy/linux-aarch64/npu_transfer_proxy from https://github.com/airockchip/RK3399Pro_npu"
fi

printf '\nExpected mainline success criterion: npu_transfer_proxy devices shows USB_DEVICE.\n'
echo "Do not use ping 192.168.180.8 as the primary criterion for the default RK3399Pro NPU NTB firmware."
