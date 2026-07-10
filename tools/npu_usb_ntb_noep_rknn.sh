#!/usr/bin/env bash
set -euo pipefail

# Formal default NPU validation path:
# clean golden129 timing -> noep+usb_ntb firmware -> USB_DEVICE proxy -> RKNN.
# PCIe endpoint/link-training is intentionally bypassed; keep it as a separate
# investigation path.

export USB_FW_DIR=${USB_FW_DIR:-/usr/share/npu_fw_usb_ntb_noep}
export USB_FW_PROFILE=${USB_FW_PROFILE:-normal}
export BOOT_SCRIPT=${BOOT_SCRIPT:-/usr/local/bin/npu_mainline_usb_ntb_boot.sh}
export UBOOT_ADDR=${UBOOT_ADDR:-0x20000}
export TRUST_ADDR=${TRUST_ADDR:-0x20800}
export BOOT_ADDR=${BOOT_ADDR:-0x21000}
export WRITE_IMAGES_BEFORE_RS=${WRITE_IMAGES_BEFORE_RS:-1}
export DB_POLICY=${DB_POLICY:-require-maskrom}
export POWER_INIT_FIRST=${POWER_INIT_FIRST:-1}
export POWER_FORCE_OFF_FIRST=${POWER_FORCE_OFF_FIRST:-1}
export POWER_OFF_SETTLE_SEC=${POWER_OFF_SETTLE_SEC:-4}
export POWER_ON_SETTLE_SEC=${POWER_ON_SETTLE_SEC:-8}
export NPU_PRECISE_POWERUP_PROFILE=${NPU_PRECISE_POWERUP_PROFILE:-golden129}
export START_PROXY=${START_PROXY:-1}
export RS_STRICT=${RS_STRICT:-0}
export RS_TIMEOUT=${RS_TIMEOUT:-180}
export POST_RS_WAIT_SEC=${POST_RS_WAIT_SEC:-20}
export EXPECT_USB_IDS=${EXPECT_USB_IDS:-"2207:0019"}
export EXPECT_PROXY_DEVICE=${EXPECT_PROXY_DEVICE:-USB_DEVICE}
export WAIT_USB3_TIMEOUT_SEC=${WAIT_USB3_TIMEOUT_SEC:-60}
export WAIT_PROXY_TIMEOUT_SEC=${WAIT_PROXY_TIMEOUT_SEC:-30}
export RESTART_PROXY=${RESTART_PROXY:-1}
export FORCE_USB_DEVICE=${FORCE_USB_DEVICE:-1}
export SET_PCIE_DMA_SAFE=${SET_PCIE_DMA_SAFE:-1}
export RUN_RKNN=${RUN_RKNN:-1}
export RKNN_TIMEOUT_SEC=${RKNN_TIMEOUT_SEC:-60}
export RKNN_CMD=${RKNN_CMD:-"/opt/rknn_py39/bin/python /root/npu_deep_test/resnet18_zeros_test.py /root/npu_deep_test/resnet_18.rknn"}

exec /usr/local/bin/npu_usb_loader_rs_rknn_pipeline.sh "$@"
