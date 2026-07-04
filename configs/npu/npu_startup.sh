#!/usr/bin/env bash
set -euo pipefail

export FW_PROFILE="${FW_PROFILE:-factory}"
export NPU_POWERCTRL="${NPU_POWERCTRL:-/usr/local/bin/npu_powerctrl-gpiod}"
export START_PROXY="${START_PROXY:-1}"
export RS_TIMEOUT="${RS_TIMEOUT:-90}"

BOOT_SCRIPT="${NPU_BOOT_SCRIPT:-/usr/local/bin/npu_mainline_usb_ntb_boot.sh}"

echo '=== RK3399Pro NPU USB ramboot startup ==='
echo "FW_PROFILE=${FW_PROFILE}"
echo "NPU_POWERCTRL=${NPU_POWERCTRL}"
echo "BOOT_SCRIPT=${BOOT_SCRIPT}"

exec "${BOOT_SCRIPT}"
