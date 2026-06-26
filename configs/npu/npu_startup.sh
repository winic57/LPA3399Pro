#!/bin/bash
echo '=== Starting NPU Power-up and Reset ==='
/usr/local/bin/npu_boot
sleep 3

echo '=== Triggering PCIe Driver Bind ==='
if [ ! -d '/sys/bus/platform/drivers/rockchip-pcie/f8000000.pcie' ]; then
    echo 'f8000000.pcie' > /sys/bus/platform/drivers/rockchip-pcie/bind 2>/dev/null
    sleep 2
fi

if [ -d '/sys/bus/platform/drivers/rockchip-pcie/f8000000.pcie' ]; then
    echo 'PCIe NPU device bound successfully'
else
    echo 'Warning: PCIe NPU device failed to bind, proxy may fail to start'
fi

echo '=== Starting NPU Transfer Proxy ==='
exec /usr/bin/npu_transfer_proxy
