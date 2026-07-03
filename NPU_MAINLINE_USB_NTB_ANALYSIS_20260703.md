# RK3399Pro / Rock Pi N10 NPU 主线 Linux 调试思路复盘与转换建议（2026-07-03）

## 1. 参考资料

本次分析参考：

- Rockchip 官方 RK3399Pro NPU 仓库：`https://github.com/airockchip/RK3399Pro_npu`
- A Matriz 文章：`https://amatriz.net/posts/using-the-radxa-rock-pi-n10-npu-on-mainline-linux/`
- 本地官方 NPU SDK：`/mnt/sdb3/LPA3399Pro/LPA3399Pro-SDK-Linux-V3.0/npu/`

遇到网络访问问题时使用代理：

```bash
export http_proxy=http://192.168.50.62:7890
export https_proxy=http://192.168.50.62:7890
export HTTP_PROXY=http://192.168.50.62:7890
export HTTPS_PROXY=http://192.168.50.62:7890
```

## 2. 核心结论

当前 NPU 调试需要转换思路：**不要继续优先把 NPU 当作 RNDIS 网络设备调试，也不要优先追 `192.168.180.8`。**

更符合 Rock Pi N10 / RK3399Pro 主线 Linux 路线的是：

1. 主控侧保证 NPU 相关 USB3 Host、24MHz NPU reference clock、GPIO 上电/复位时序正确；
2. NPU 初始通过 USB2 以 Maskrom/Loader 形式出现，常见为 `2207:180a`；
3. 主控通过 `upgrade_tool db/rs` 或 vendor `npu_boot`/`npu_powerctrl` 封装脚本将 NPU firmware 推入 NPU；
4. NPU 跳转后从 USB2 断开并重新枚举到 USB3；
5. NPU 侧暴露的是 FunctionFS / NTB 通道，而不是 RNDIS 网卡；
6. 主控侧通过 `npu_transfer_proxy devices` 验证是否出现 `USB_DEVICE`；
7. 之后再运行 RKNN C API demo。

因此，当前成功标准应从：

```text
ping 192.168.180.8 成功
```

改为：

```bash
npu_transfer_proxy devices
```

输出中出现：

```text
USB_DEVICE
```

## 3. 官方 RK3399Pro_npu 仓库关键点

官方仓库 README 明确说明：

- RK3399Pro NPU 驱动封装在 NPU 的 `boot.img` 中；
- 不同 RK3399Pro 开发板可能通过 **PCIE** 或 **USB 3.0** 与 NPU 通信；
- USB 固件目录：

  ```text
  drivers/npu_firmware/npu_fw/
  ```

- PCIe 固件目录：

  ```text
  drivers/npu_firmware/npu_pcie_fw/
  ```

- AI 应用和 NPU 通信需要主控侧 `npu_transfer_proxy` 服务；
- 可以通过如下命令确认通信方式：

  ```bash
  npu_transfer_proxy devices
  ```

USB 成功时类似：

```text
List of ntb devices attached
2010fcfcde48fafd    80f3eb90    USB_DEVICE
```

PCIe 成功时类似：

```text
List of ntb devices attached
0123456789ABCDEF    cfbc0c55    PCIE
```

官方仓库还提供主控侧需要的二进制：

```text
drivers/npu_transfer_proxy/linux-aarch64/npu_transfer_proxy
rknn-api/librknn_api/Linux/lib64/librknn_api.so
rknn-api/librknn_api/include/rknn_api.h
rknn-api/examples/c_demos/
```

## 4. A Matriz 主线 Linux 文章关键点

文章说明 Rock Pi N10 / RK3399Pro NPU 在主线 Linux 下的关键路径：

- Rock Pi N10 的 RK3399Pro NPU 与主控通信走 USB；
- Maskrom 阶段是 USB2；
- 推送 firmware 后，NPU 会重新枚举为 USB3；
- PCIe 相关内容不是该板 NPU 主通信路径的关键；
- 必须确保 NPU 需要的 24MHz clock 正确输出；
- 文章中提到默认 WiFi 26MHz clock 不适合 NPU，需要切到 24MHz；
- 文章用 debugfs clock + libgpiod 脚本复刻 `npu_powerctrl` 上电/复位时序。

文章给出的关键 clock 操作包括：

```bash
echo "1" > /sys/kernel/debug/clk/rk808-clkout2/clk_prepare_enable
echo "24000000" > /sys/kernel/debug/clk/clk_wifi_pmu/clk_rate
echo "1" > /sys/kernel/debug/clk/clk_wifi_pmu/clk_prepare_enable
```

文章中成功现象不是 RNDIS，而是 USB 设备重新枚举，例如：

```text
usb 3-1: New USB device found, idVendor=2207, idProduct=180a
usb 3-1: USB disconnect
usb 4-1: new SuperSpeed USB device
usb 4-1: New USB device found, idVendor=2207, idProduct=0019
```

之后应通过 `npu_transfer_proxy devices` 看到 USB NPU。

## 5. 本地 SDK 关键发现

本地 SDK 路径：

```text
/mnt/sdb3/LPA3399Pro/LPA3399Pro-SDK-Linux-V3.0/npu/
```

### 5.1 NPU 构建配置

当前 SDK BoardConfig：

```text
/mnt/sdb3/LPA3399Pro/LPA3399Pro-SDK-Linux-V3.0/npu/device/rockchip/.BoardConfig.mk
```

关键项：

```bash
export RK_ARCH=arm64
export RK_UBOOT_DEFCONFIG=rknpu-lion
export RK_KERNEL_DEFCONFIG=rk3399pro_npu_defconfig
export RK_KERNEL_DTS=rk3399pro-npu-evb-v10
export RK_PARAMETER=parameter-npu.txt
export RK_CFG_RAMBOOT=rockchip_rk3399pro-npu
export RK_TARGET_PRODUCT=rk3399pro
```

生成的 parameter：

```text
/mnt/sdb3/LPA3399Pro/LPA3399Pro-SDK-Linux-V3.0/npu/rockdev/parameter.txt
```

内容显示分区布局为：

```text
CMDLINE:mtdparts=rk29xxnand:0x00002000@0x00004000(uboot),0x00002000@0x00006000(trust),0x00002000@0x00008000(misc),0x00008000@0x0000a000(resource),0x00010000@0x00012000(kernel),0x00010000@0x00022000(boot)
```

### 5.2 NPU 侧 gadget 不是 RNDIS，而是 FunctionFS NTB

本地 SDK 已生成的 NPU rootfs 中存在：

```text
/mnt/sdb3/LPA3399Pro/LPA3399Pro-SDK-Linux-V3.0/npu/buildroot/output/rockchip_rk3399pro-npu/target/usr/bin/start_usb.sh
```

其中 `ntb` 分支关键逻辑：

```sh
configfs_init 0x1808 ntb
function_init ntb
mkdir -p /dev/usb-ffs/ntb
mount -o uid=2000,gid=2000 -t functionfs ntb /dev/usb-ffs/ntb
start_rknn.sh &
```

它创建的是：

```text
/sys/kernel/config/usb_gadget/rockchip/functions/ffs.ntb
/dev/usb-ffs/ntb
```

而不是：

```text
rndis.usb0
usb0/rndis0 网络口
```

因此此前新增的 RNDIS 固定 IP 脚本：

```text
LPA3399Pro-SDK-Linux-V3.0/npu/buildroot/board/rockchip/rk3399pro_npu/fs-overlay-64/etc/init.d/S51usb-rndis-ip
```

可能不是当前主线目标的正确修复点。该脚本等待 `usb0` / `rndis0` / `eth0`，但 NPU 默认通信模式是 `ffs.ntb`。所以 `192.168.180.8` 不通不等价于 NPU 不可用。

## 6. 对此前判断的修正

此前判断：

> `upgrade_tool db/rs` 是临时 Loader/RAM 调试路径，不应作为最终 NPU 正常启动判断。

现在需要修正为：

- 如果目标是 vendor 产品形态、NPU 独立 eMMC 自启动，则 `db/rs` 确实不是最终判断；
- 但如果目标是 **mainline Linux 上使用 Rock Pi N10 NPU**，那么 `db/rs` / `npu_boot` 将 NPU 从 Maskrom 拉起是文章验证过的可行路径；
- 所以当前不应一味绕开 `upgrade_tool db/rs`，而应确认它是否能把 NPU 从 `2207:180a` 推到 USB3 NTB 工作状态。

## 7. 推荐的新验证路线

### 7.1 阶段一：确认主控 USB3 Host、clock、GPIO

重点确认主控 DTB / kernel：

- `usbdrd3_1` 是否 `okay`；
- `usbdrd_dwc3_1` 是否 `okay`；
- `tcphy1` 是否 `okay`；
- `u2phy1` / `u2phy1_otg` 是否 `okay`；
- `usbdrd_dwc3_1` 是否为 `dr_mode = "host"`；
- GPIO0_A2 / `npu-ref-clk` 是否正确 pinmux；
- 24MHz reference clock 是否可启用；
- NPU reset / power GPIO 时序是否正确。

可以参考 A Matriz 脚本，先通过 debugfs + libgpiod 做运行时验证，成功后再固化到 DTS 或驱动。

### 7.2 阶段二：使用 USB firmware 拉起 NPU

优先使用 USB 版 firmware：

```text
RK3399Pro_npu/drivers/npu_firmware/npu_fw/MiniLoaderAll.bin
RK3399Pro_npu/drivers/npu_firmware/npu_fw/uboot.img
RK3399Pro_npu/drivers/npu_firmware/npu_fw/trust.img
RK3399Pro_npu/drivers/npu_firmware/npu_fw/boot.img
RK3399Pro_npu/drivers/npu_firmware/npu_fw/parameter.txt
```

不要优先使用：

```text
npu_pcie_fw/
```

除非后续确认板端实际通信是 PCIe。

### 7.3 阶段三：验证 USB 重新枚举

监控：

```bash
dmesg -w | grep -Ei 'usb 3-1|usb 4-1|2207|180a|1808|0019|firmware changed|error -71|disconnect|SuperSpeed'
```

成功方向：

1. 初始可见 `2207:180a`；
2. 推送 firmware 后 USB disconnect；
3. 重新枚举为 USB3 设备，可能为 `2207:0019` 或本地 SDK `start_usb.sh ntb` 设置的 `2207:1808`；
4. 后续由 `npu_transfer_proxy` 发现设备。

### 7.4 阶段四：验证 npu_transfer_proxy

主控侧部署：

```text
npu_transfer_proxy
librknn_api.so
RKNN C demos
```

运行：

```bash
/usr/bin/npu_transfer_proxy &
sleep 1
/usr/bin/npu_transfer_proxy devices
```

成功标准：

```text
USB_DEVICE
```

而不是 `ping 192.168.180.8`。

## 8. 本地 SDK 优化建议

### 8.1 暂停把 RNDIS 固定 IP 作为主线修复

当前 SDK 默认 NPU 通信是 NTB/FunctionFS，不是 RNDIS。因此：

- `S51usb-rndis-ip` 可以保留为实验分支；
- 但不要把它作为主要成功标准；
- 不要继续围绕 `192.168.180.8` 做主线判断。

### 8.2 新增主控侧 mainline NPU 拉起脚本

建议新增 host 侧脚本，例如：

```bash
#!/bin/bash
set -euo pipefail
FW=/usr/share/npu_fw
UPGRADE=/usr/bin/upgrade_tool

$UPGRADE db "$FW/MiniLoaderAll.bin"
sleep 1
$UPGRADE rs 0x00200000 0x08400000 0x02000000 \
  "$FW/uboot.img" "$FW/trust.img" "$FW/boot.img"

sleep 8
/usr/bin/npu_transfer_proxy devices
```

注意：`rs` 地址必须以板端原始 `/usr/local/bin/npu_boot` 或已有工作脚本为准，不应盲写。

### 8.3 审计现有 `/usr/local/bin/npu_boot`

当前更合理的假设是：`npu_boot` 可能正是 vendor 对 `upgrade_tool db/rs`、power GPIO、clock 的封装，而不一定是错误路径。

建议在板端执行：

```bash
strings /usr/local/bin/npu_boot | grep -Ei 'db|rs|uboot|trust|boot|0x|upgrade|180a|2207'
cat /usr/bin/npu_powerctrl
```

如果 `npu_boot` 内置了正确地址和步骤，应复用或复刻它，而不是绕开。

### 8.4 后续如需 RNDIS，应做成 composite gadget，而不是只加 ifconfig

如果确实需要 NPU 内部 Linux 可通过 IP 访问，需要改 NPU 侧 `start_usb.sh`，让 gadget 同时包含：

```text
ffs.ntb + rndis.usb0
```

但这可能影响 `npu_transfer_proxy`，不建议作为第一阶段目标。

## 9. 当前一句话结论

当前最值得优化/转换的方向是：**停止把 NPU 当成 RNDIS 网络设备调试，改为按官方 RK3399Pro_npu + A Matriz 的 mainline USB NTB 路线处理：保证 USB3_1 host、24MHz NPU ref clock 和 GPIO 上电时序，使用 USB 版 `npu_fw` 通过 `upgrade_tool db/rs` 或 `npu_boot` 拉起 NPU，然后用 `npu_transfer_proxy devices` 验证 `USB_DEVICE`。**

---

## 10. 已落地的下一步改动（2026-07-03 18:20）

根据上述分析，仓库新增了主控侧 mainline USB NTB 验证工具，并准备将 NPU SDK overlay 从 RNDIS 实验路径切回默认 NTB/RKNN 路径。

新增文件：

```text
tools/npu_mainline_usb_ntb_boot.sh
tools/npu_mainline_usb_ntb_check.sh
patches/npu/0002-rk3399pro-npu-mainline-usb-ntb-default.patch
```

`tools/npu_mainline_usb_ntb_boot.sh` 用于主控侧执行：

1. 可选调用 `npu_powerctrl off/on`；
2. 调用 `upgrade_tool db MiniLoaderAll.bin`；
3. 调用 `upgrade_tool rs uboot/trust/boot`；
4. 等待 USB2 Loader 断开并重新枚举为 USB3 NTB gadget；
5. 启动或检查 `npu_transfer_proxy devices`。

`tools/npu_mainline_usb_ntb_check.sh` 用于统一收集：

```bash
lsusb
dmesg USB/NPU 关键日志
npu_transfer_proxy devices
```

新的 SDK patch 会：

- 删除此前 RNDIS 固定 IP 实验脚本 `S51usb-rndis-ip`；
- 在 NPU rootfs overlay 中写入 `.usb_config`：

  ```text
  usb_ntb_en
  ```

- 增加 `S51npu-ntb-rknn`，确保 NPU ramboot 内部启动后暴露 `ffs.ntb` 并启动 `start_rknn.sh` / `rknn_server`。

同时 `kdevbuild/npu_kernel.sh` 已调整为构建前自动按顺序应用 `patches/npu/*.patch`。因此历史 `0001` 可作为记录保留，`0002` 会在其后覆盖 RNDIS 实验路径，最终产物默认回到官方 mainline USB NTB + `npu_transfer_proxy` 路线。

---

## 11. 同型号 4.4 官方系统机器对照检查（192.168.50.129）

2026-07-03 通过 SSH 检查另一台同型号 LPA3399Pro，结果如下：

```text
Linux LPA3399Pro 4.4.194 #1 SMP Thu Jun 12 08:43:20 UTC 2025 aarch64 GNU/Linux
lsusb: 2207:1005 Fuzhou Rockchip Electronics Company
npu_transfer_proxy devices:
  0123456789ABCDEF    cfbc0c55    PCIE
/usr/bin/npu_transfer_proxy 正在后台运行
/usr/share/npu_fw/ 存在 MiniLoaderAll.bin / uboot.img / trust.img / boot.img / parameter.txt
clk_wifi_pmu: 24000000
rk808-clkout2: 32768
```

这个对照样本说明：

1. 官方 4.4 系统上 NPU 最终可由 `npu_transfer_proxy devices` 识别；
2. 该样本报告的链路类型是 `PCIE`，而不是 `USB_DEVICE`；
3. `2207:1005` 和 `usb0` 可以存在，但并不能替代 `npu_transfer_proxy devices` 的判断；
4. `npu_powerctrl` 是 ELF 二进制，字符串中可见 24MHz `clk_wifi_pmu`、`rk808-clkout2`、GPIO 以及 `f8000000.pcie/pcie_reset_ep` 等控制路径。

因此当前策略需要保留两个分支：

- 对主线 Linux / Rock Pi N10 参考路径，继续验证 USB NTB：成功标准是 `USB_DEVICE`；
- 对官方 4.4 / LPA3399Pro vendor 路径，需要同时验证 PCIe NPU：成功标准可以是 `PCIE`。

两条路径的共同点是：第一成功标准都应是 `npu_transfer_proxy devices`，而不是单独依赖 `ping 192.168.180.8`。
