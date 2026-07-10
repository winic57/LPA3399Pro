#!/usr/bin/env bash
# Golden129 USB workflow wrapper.
# Source /etc/default/npu-usb-workflow for board defaults, but let caller-provided
# environment variables win.  This matters for A/B tests such as POST_RS_WAIT_SEC=20.
set -euo pipefail

VARS_TO_PRESERVE=(
  FW_DIR FW_DIR_OVERRIDE FW_PROFILE FW_PROFILE_OVERRIDE
  UBOOT_ADDR UBOOT_ADDR_OVERRIDE TRUST_ADDR TRUST_ADDR_OVERRIDE BOOT_ADDR BOOT_ADDR_OVERRIDE
  WRITE_IMAGES_BEFORE_RS WRITE_IMAGES_BEFORE_RS_OVERRIDE
  START_PROXY CHECK_ONLY RS_TIMEOUT RS_STRICT DB_POLICY ROCKUSB_WAIT_SEC
  POST_RS_WAIT_SEC POST_RS_PCIE_RESCAN POST_RS_PCIE_RESCAN_DELAY_SEC
  POWER_INIT_FIRST POWER_FORCE_OFF_FIRST POWER_OFF_SETTLE_SEC POWER_ON_SETTLE_SEC SKIP_POWER
  PCIE_RESCAN_AFTER_POWER PCIE_HOST_REBIND_AFTER_POWER PCIE_HOST_PLATFORM_DEV PCIE_HOST_REBIND_WAIT_SEC
  NPU_POWERCTRL NPU_PRECISE_POWERUP_PROFILE NPU_PRECISE_POWER_GPIO_STAGE
  NPU_PRECISE_HELPER_CMD NPU_PRECISE_HELPER_STAGE
  GPIO_HOLD_SETTLE_MS GPIO_HOLD_RELEASE_SETTLE_MS
)

save_var() {
  local n="$1"
  eval "__had_${n}=\${${n}+x}"
  eval "__val_${n}=\${${n}-}"
}

restore_var_if_caller_set() {
  local n="$1" had
  eval "had=\${__had_${n}-}"
  if [ "$had" = x ]; then
    eval "export ${n}=\"\${__val_${n}}\""
  fi
}

for v in "${VARS_TO_PRESERVE[@]}"; do
  save_var "$v"
done

set -a
[ -f /etc/default/npu-usb-workflow ] && . /etc/default/npu-usb-workflow
set +a

for v in "${VARS_TO_PRESERVE[@]}"; do
  restore_var_if_caller_set "$v"
done

export FW_DIR="${FW_DIR_OVERRIDE:-${FW_DIR:-/opt/npu_fw_profiles/golden129_usb_current}}"
export FW_PROFILE="${FW_PROFILE_OVERRIDE:-${FW_PROFILE:-normal}}"
export UBOOT_ADDR="${UBOOT_ADDR_OVERRIDE:-${UBOOT_ADDR:-0x20000}}"
export TRUST_ADDR="${TRUST_ADDR_OVERRIDE:-${TRUST_ADDR:-0x20800}}"
export BOOT_ADDR="${BOOT_ADDR_OVERRIDE:-${BOOT_ADDR:-0x21000}}"
export WRITE_IMAGES_BEFORE_RS="${WRITE_IMAGES_BEFORE_RS_OVERRIDE:-${WRITE_IMAGES_BEFORE_RS:-0}}"

exec /usr/local/bin/npu_mainline_usb_ntb_boot.sh "$@"
