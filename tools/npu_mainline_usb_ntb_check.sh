#!/usr/bin/env bash
set -euo pipefail

TRANSFER_PROXY=${TRANSFER_PROXY:-/usr/bin/npu_transfer_proxy}
DMESG_LINES=${DMESG_LINES:-160}
EXPECT_USB_ID=${EXPECT_USB_ID:-2207:0019}
EXPECT_PROXY_DEVICE=${EXPECT_PROXY_DEVICE:-USB_DEVICE}
CHECK_STRICT=${CHECK_STRICT:-0}

echo "== RK3399Pro NPU USB/NTB quick check =="

printf '\n[1/5] Rockchip USB devices\n'
USB_MATCH=0
if command -v lsusb >/dev/null 2>&1; then
  lsusb | grep -Ei '2207:|rockchip|rk3xxx' || true
  if lsusb | grep -qi "$EXPECT_USB_ID"; then USB_MATCH=1; fi
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
PROXY_MATCH=0
if [ -x "$TRANSFER_PROXY" ]; then
  PROXY_OUT=$("$TRANSFER_PROXY" devices 2>&1 || true)
  printf '%s\n' "$PROXY_OUT"
  if printf '%s\n' "$PROXY_OUT" | grep -q "$EXPECT_PROXY_DEVICE"; then PROXY_MATCH=1; fi
else
  echo "WARN: $TRANSFER_PROXY is missing or not executable"
  echo "      Install drivers/npu_transfer_proxy/linux-aarch64/npu_transfer_proxy from https://github.com/airockchip/RK3399Pro_npu"
fi

printf '\nExpected mainline success criterion: lsusb has %s and npu_transfer_proxy devices shows %s.\n' "$EXPECT_USB_ID" "$EXPECT_PROXY_DEVICE"
echo "USB_MATCH=$USB_MATCH PROXY_MATCH=$PROXY_MATCH"
echo "Do not use ping 192.168.180.8 as the primary criterion for the default RK3399Pro NPU NTB firmware."
if [ "$CHECK_STRICT" = 1 ] && { [ "$USB_MATCH" != 1 ] || [ "$PROXY_MATCH" != 1 ]; }; then
  exit 1
fi
