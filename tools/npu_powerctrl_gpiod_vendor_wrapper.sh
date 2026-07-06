#!/bin/bash
# Mainline wrapper for vendor npu_upgrade_pcie/npu-image.sh.
# It preserves the vendor CLI (-i/-o/-s/-d) but routes GPIO/refclk work to
# /usr/local/bin/npu_powerctrl-gpiod so kernels without /sys/class/gpio still
# get the .129-like golden holder timing.

set -euo pipefail

export NPU_PRECISE_POWERUP_PROFILE=${NPU_PRECISE_POWERUP_PROFILE:-golden129}
export GPIO_HOLD_SETTLE_MS=${GPIO_HOLD_SETTLE_MS:-0}
export GPIO_HOLD_RELEASE_SETTLE_MS=${GPIO_HOLD_RELEASE_SETTLE_MS:-0}
export NPU_PRECISE_POWER_GPIO_STAGE=${NPU_PRECISE_POWER_GPIO_STAGE:-before_low}
export NPU_PWR_GPIO_ENABLED=${NPU_PWR_GPIO_ENABLED:-1}
export NPU_PWR_CHIP=${NPU_PWR_CHIP:-gpiochip0}
export NPU_PWR_LINE=${NPU_PWR_LINE:-9}
export NPU_PRECISE_HELPER_CMD=${NPU_PRECISE_HELPER_CMD:-/usr/local/bin/npu_boot}
export NPU_PRECISE_HELPER_STAGE=${NPU_PRECISE_HELPER_STAGE:-after_stage1}
export NPU_PRECISE_LOW_GLOBALS=${NPU_PRECISE_LOW_GLOBALS:-56,55,54,11,4,10,36,32}
export NPU_PRECISE_RISE_STAGE1_GLOBALS=${NPU_PRECISE_RISE_STAGE1_GLOBALS:-4,10,11}
export NPU_PRECISE_RISE_STAGE2_GLOBALS=${NPU_PRECISE_RISE_STAGE2_GLOBALS:-54,55,56}
export NPU_PRECISE_FINAL_GLOBAL=${NPU_PRECISE_FINAL_GLOBAL:-32}
export NPU_PRECISE_INPUT_GLOBALS=${NPU_PRECISE_INPUT_GLOBALS:-35}

exec /usr/local/bin/npu_powerctrl-gpiod "$@"
