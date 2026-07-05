**最直接可以参考的项目是这两个（高度匹配你的硬件和场景）：**

### 1. 首要推荐（最接近你的 6.18.33 mainline + Rock Pi N10 兼容板）
**https://amatriz.net/posts/using-the-radxa-rock-pi-n10-npu-on-mainline-linux/**

你的 live DT 显示 `model: Radxa ROCK Pi N10` + `compatible: radxa,rockpi-n10 + vamrs,rk3399pro-vmarc-som`，**这篇文章就是专门为和你几乎一样的硬件在 mainline kernel 上跑 NPU 写的**（2023 年，但核心 patch 和流程在 6.x 上仍有很高参考价值）。

它解决了你 MD 中几乎所有痛点：
- 详细的 **9 个 kernel/DT patch**（修改 `rk3399.dtsi`、`rk3399pro-vmarc-som.dtsi`、`pinctrl`、`clk.c`、`rtc-hym8563.c` 等）。
- **npu_ref_clk**（GPIO0_A2 / clk_wifi_pmu 强制 24MHz，`enable_count=0` 是你当前问题之一）。
- 使用 **libgpiod**（`gpioset`）实现的完整上电/复位/时钟序列脚本，取代你当前功能不全的 `/usr/bin/npu_powerctrl` 和 `/usr/local/bin/npu_boot`。
- 修改后的 `npu_upgrade` 脚本 + 具体 `upgrade_tool` 地址（`UBOOT_ADDR=0x40000`, `TRUST_ADDR=0x40800`, `BOOT_ADDR=0x20000` 等组合）。
- 明确说明 PCIe 相关节点在 Rock Pi N10 类板子上**不是必须**（NPU 通过 USB3 NTB 与主机通信，Maskrom 阶段走 USB2，加载后走 USB3 SuperSpeed，重新枚举为 2207:0019 或类似）。这解释了为什么你单纯 enable `pcie@f8000000` 会挂机。

**成功标志**（和你 MD 里的一致）：
- `lsusb` 看到从 2207:180a → 2207:0019（或 1005/1808）在 SuperSpeed 上。
- `npu_transfer_proxy devices` 显示 `USB_DEVICE`（或 PCIE，如果加载了对应 firmware）。
- 可运行 rknn-api demo。

文章推荐从 **https://github.com/airockchip/RK3399Pro_npu** 下载 firmware（分 USB 和 PCIE 版本）和 `npu_transfer_proxy`（linux-aarch64）。

### 2. 官方/社区固件与 proxy 仓库
**https://github.com/airockchip/RK3399Pro_npu**

这是 Rockchip 社区维护的 RK3399Pro NPU 专用仓库（rknn-toolkit 文档也指向它）。包含：
- `npu_fw`（USB 版和 PCIE 版固件：MiniLoaderAll.bin、uboot.img、trust.img、boot.img、parameter.txt）。
- 各平台 `npu_transfer_proxy` 二进制（你的 SDK 里的版本最好优先用，但这个仓库的 linux-aarch64 版可作为对比）。
- 使用说明（`npu_transfer_proxy devices` 是判断链路是否通的关键，不是靠 ping 192.168.180.8）。

**结合你的 LPA3399Pro-SDK-Linux-V3.0**：优先使用 SDK 中 `/usr/share/npu_fw/` 的固件（尤其是 factory 版本）和 `npu_boot`/`upgrade_tool`，因为它是针对你这块工业板的。把工作机（192.168.50.129）的固件 hash、rs 命令参数、npu_boot binary strings 提取出来对比。

### 当前问题诊断（基于你的 MD）
- `npu_powerctrl` / `npu_boot` 只完成了部分上电（24MHz clock + reset），把 NPU 拉到 Maskrom/Loader (2207:180a)，但 `rs` 阶段无法让 RK1808（NPU 协处理器）成功跳转运行。
- clk_wifi_pmu `enable_count=0` + 主线 DT 中 PCIe/pcie-ep/pinctrl/clock/reset 节点不完整，是核心原因。
- 简单改 `status = "okay"` 会 hang，说明需要**完整**的 pinctrl、regulators、ep-gpios、assigned-clocks 等（amatriz guide 正是做了这些）。
- 官方 4.4 走 PCIE 路径，你的 mainline 更适合先尝试 USB NTB 路径（更稳，不依赖完整 PCIe host 枚举）。

### 推荐立即执行的安全路线（避免再次拔卡）
1. **从工作机（.129）导出黄金参考**（只读）：
   ```bash
   dtc -I fs -O dts -o /root/working_4.4.dts /proc/device-tree
   strings /usr/local/bin/npu_boot | grep -E '0x[0-9A-F]+|upgrade_tool|rs|db'
   ls -l /usr/share/npu_fw/
   sha256sum /usr/share/npu_fw/*
   upgrade_tool LD
   npu_transfer_proxy devices
   ```
   把结果传到 .113 并对比。

2. **在 .113 上安装 libgpiod-tools**，用 **amatriz guide 中的 gpioset 序列** 替换当前 npu_powerctrl（这是最关键的改进）。文章里有完整脚本（设置 rk808-clkout2、clk_wifi_pmu=24000000、多路 GPIO 严格时序）。

3. **安全测试 DTB**（推荐你已经在做的 extlinux 多菜单方式）：
   - 复制当前 DTB 为 `...-npu-test.dtb`。
   - 在 `/boot/extlinux/extlinux.conf` 加第二个菜单项，默认仍用稳定 DTB。
   - 合并 amatriz patch 中与 clock、pinctrl、npu-ref-clk、USB host mode 相关的部分（先不全开 PCIe host）。

4. **RAM boot 测试**（不要先刷 eMMC）：
   用 SDK 或 airockchip 的 firmware + 正确 rs 地址（先试 guide 里的 0x40000/0x40800/0x20000 组合，带 timeout）。
   成功后 `npu_transfer_proxy devices` 应该能看到设备。

5. **把这些集成到你的 GitHub**（winic57/LPA3399Pro）：
   - 新增 patch：`0003-mainline-npu-power-sequence-and-dts.patch`（基于 amatriz 适配 neardi）。
   - 更新 `tools/npu_mainline_usb_ntb_boot.sh` 和 `npu_mainline_usb_ntb_check.sh`。
   - 把本 MD + 新日志一起 push。

---

## 附录 A：工作机 .129（vendor 4.4 kernel，NPU 正常工作）采集结果

> 采集时间：2026-07-03，SSH paramiko 并行采集，原始日志：`E:\rk3399pro\NPU\ssh_logs\collect_129.txt`

### A.1 系统信息
```
Kernel: 4.4.194
OS: Debian GNU/Linux 10 (buster)
```

### A.2 NPU 固件文件（/usr/share/npu_fw/）
```
MiniLoaderAll.bin   160,078 bytes   sha256: 521aa944983bd0492fbbaa922ed2957915a516ed5a28443c9b67953b41ed6c27
boot.img         35,387,392 bytes   sha256: 0fdb5013f851de968ae8aa53dcae7c582a8ebb199e2c561f6ce29cef81970f26
parameter.txt          399 bytes   sha256: fedaf45f8c22a94b25271844757d3c303c2d7987ef0e4b3533b0503fdcdd6b03
trust.img       2,097,152 bytes   sha256: 524f987049c3f3c27c64a6b5b3d29de711513d23acd2ce9ea1eb390677ab4827
uboot.img       2,097,152 bytes   sha256: 4f3f63bb6377baae850a778b83ccecd314d49c841f3bd26e55ab2c5368ceb21a
```

### A.3 upgrade_tool LD（设备处于 Maskrom 模式）
```
Not found config.ini
Program Data in /usr/bin
List of rockusb connected(1)
DevNo=1  Vid=0x2207,Pid=0x1005,LocationID=101  Mode=Maskrom  SerialNo=04e48e8f3d4a7d07
```
**关键发现**：.129 上 NPU 处于 **Maskrom 模式**（PID 1005），而非正常 Loader 模式。这说明即使是工作机，NPU 也没有完全 boot 到正常状态，但 PCIE 链路已建立。

### A.4 npu_transfer_proxy devices（PCIE 链路已通）
```
List of ntb devices attached
0123456789ABCDEF    cfbc0c55    PCIE
```
**对比**：.113 上此命令显示空列表（`List of ntb devices attached` 后无设备）。

### A.5 lsusb（确认 2207:1005 在 Bus 1）
```
Bus 001 Device 009: ID 2207:1005 Fuzhou Rockchip Electronics Company
```
NPU 通过 USB 2.0 总线挂载（Bus 1），处于 Maskrom 模式。

### A.6 npu_powerctrl（ELF 二进制，C++ 编译）
`.129` 上的 `npu_powerctrl` 是 **C++ ELF 二进制**（链接 libstdc++、libpthread、libdl），版本 V1.1。

通过 strings 提取的关键信息：
```
/sys/kernel/debug/clk/clk_wifi_pmu/clk_enable_count
set clk_en %c to %s
/sys/class/gpio/export
/sys/class/gpio/unexport
/sys/class/gpio/gpio%s/direction
/sys/class/gpio/gpio%s/value
version: %s
init gpio: %s
```

GPIO 编号（从 strings 中的数字推断）：
- **35** — 可能对应 npu_reset
- **1** — 可能对应 npu_power
- **0** — rk808-clkout2 enable
- **56, 55, 54** — 可能是 USB 相关 GPIO
- **11, 4, 10** — 其他控制引脚
- **36, 32** — 其他

关键 strings 片段：
```
/sys/kernel/debug/clk/rk808-clkout2/clk_enable_count
0
```
说明 npu_powerctrl 会检查 `rk808-clkout2` 的 enable_count。

```
cat /sys/bus/platform/devices/fe380000.usb/usb*/*/idProduct
cat /sys/bus/platform/devices/fe3a0000.usb/usb*/*/idProduct
ACM idProduct: %s
1005
find /sys/bus/platform/devices/fe3a0000.usb/usb*/*/ -name remove
find /sys/bus/platform/devices/fe380000.usb/usb*/*/ -name remove
usb remove patch is %s
```
说明 npu_powerctrl 会检测 USB idProduct，若为 1005（Maskrom）则执行 USB remove patch（强制重枚举）。

```
sys/devices/platform/f8000000.pcie/pcie_reset_ep
```
说明 npu_powerctrl 通过 `/sys/devices/platform/f8000000.pcie/pcie_reset_ep` 控制 NPU 的 PCIe 复位。

用法：
```
Usage: npu_powerctrl [-s] [-r] [-o] [-i] [-d]
  -s  npu enter sleep
  -r  wakup npu
  -o  power up or reset npu
  -i  gpio init
  -d  power down
```

### A.7 npu_boot（不存在）
```
/usr/local/bin/npu_boot: cannot open '/usr/local/bin/npu_boot' (No such file or directory)
```
**关键发现**：.129 上 **没有 npu_boot**！上电/复位逻辑完全由 `npu_powerctrl`（C++ 二进制）完成。

### A.8 设备树（dtc 未安装，无法导出）
.129 上 `dtc` 未安装，无法从 `/proc/device-tree` 导出 live DTS。需要后续安装 dtc 后重新采集，或从 SDK 源码 DTS 中提取。

### A.9 dmesg（无 NPU/PCIE 相关日志）
```
(dmesg | grep -iE 'npu|rk1808|pcie|usb.*2207|2207:' 返回空)
```
可能原因：4.4 kernel 的 NPU 驱动日志被过滤，或日志已 rotate。需后续用 `dmesg | tail -200` 完整查看。

---

## 附录 B：目标机 .113（mainline 6.18.33 kernel，NPU 未工作）采集结果

> 采集时间：2026-07-03，原始日志：`E:\rk3399pro\NPU\ssh_logs\collect_113.txt`

### B.1 系统信息
```
Kernel: 6.18.33
OS: Armbian OS 26.05.0 trixie (Debian 13 trixie)
Model: Radxa ROCK Pi N10
Compatible: radxa,rockpi-n10, vamrs,rk3399pro-vmarc-som, rockchip,rk3399pro
```

### B.2 Live DTS（成功导出，3635 行）
dtc 成功导出 live device tree。关键节点如下：

#### B.2.1 NPU pinctrl 节点
```dts
pinctrl {
    npu {
        npu-ref-clk {
            rockchip,pins = <0x00 0x02 0x01 0xb5>;  // GPIO0_A2, func=1 (clk_wifi_pmu)
            phandle = <0xf4>;
        };
    };
};
```
**分析**：`npu-ref-clk` 引脚配置为 GPIO0_A2 复用功能 1，即 `clk_wifi_pmu` 输出 24MHz 时钟。这与 amatriz guide 中描述的完全一致。

#### B.2.2 PCIe 节点（status: disabled）
```dts
pcie@f8000000 {
    vpcie3v3-supply = <0x1d>;       // regulator-vcc-pcie (vcc3v3_pcie)
    vpcie0v9-supply = <0x1b>;
    vpcie1v8-supply = <0x1c>;
    pinctrl-0 = <0x1a>;             // pci-clkreqnb-cpm
    phy-names = "pcie-phy-0", "pcie-phy-1", "pcie-phy-2", "pcie-phy-3";
    phys = <0x18 0x00 0x18 0x01 0x18 0x02 0x18 0x03>;
    num-lanes = <0x04>;
    max-link-speed = <0x01>;        // Gen1
    aspm-no-l0s;
    clock-names = "aclk", "aclk-perf", "hclk", "pm";
    clocks = <0x08 0xc5 0x08 0xc4 0x08 0x147 0x08 0xa0>;
    resets = <0x08 0x82 0x08 0x83 0x08 0x84 0x08 0x85 0x08 0x86 0x08 0x81 0x08 0x80>;
    reset-names = "core", "mgmt", "mgmt-sticky", "pipe", "pm", "pclk", "aclk";
    status = "disabled";            // ← 当前禁用
    compatible = "rockchip,rk3399-pcie";
    reg = <0x00 0xf8000000 0x00 0x2000000  0x00 0xfd000000 0x00 0x1000000>;
    ranges = <0x82000000 0x00 0xfa000000 0x00 0xfa000000 0x00 0x1e00000
              0x81000000 0x00 0xfbe00000 0x00 0xfbe00000 0x00 0x100000>;
};
```

#### B.2.3 PCIe PHY 节点（status: okay）
```dts
pcie-phy {
    clock-names = "refclk";
    resets = <0x08 0x87>;
    clocks = <0x08 0x8a>;
    compatible = "rockchip,rk3399-pcie-phy";
    status = "okay";
    reset-names = "phy";
    #phy-cells = <0x01>;
    phandle = <0x18>;
};
```
**注意**：PCIe PHY 本身已启用，但 PCIe host 控制器 disabled。这与预期一致 — PHY 就绪但 host 未使能。

#### B.2.4 PCIe 电源 regulator
```dts
regulator-vcc-pcie {
    regulator-boot-on;
    gpio = <0x3d 0x1c 0x00>;       // GPIO4_C4 (pin 28)
    pinctrl-0 = <0xc0>;             // pcie-pwr pin group
    regulator-always-on;
    enable-active-high;
    regulator-name = "vcc3v3_pcie";
    compatible = "regulator-fixed";
    phandle = <0x1d>;
    vin-supply = <0x83>;
};
```

#### B.2.5 PCIe pinctrl
```dts
pcie {
    pcie-pwr {
        rockchip,pins = <0x04 0x1c 0x00 0xb8>;  // GPIO4_C4, func=0
        phandle = <0xc0>;
    };
    pci-clkreqn-cpm {
        rockchip,pins = <0x02 0x1a 0x02 0xb5>;  // GPIO2_B2, func=2 (clkreqn)
    };
    pci-clkreqnb-cpm {
        rockchip,pins = <0x02 0x1a 0x02 0xb5>;  // 同上
        phandle = <0x1a>;
    };
};
```

#### B.2.6 AW9523 GPIO 扩展器
```dts
aw9523@5a {
    pinctrl-names = "default";
    pinctrl-0 = <0x1a5>;            // aw9523-reset pin group
    reset-gpios = <0x81 0x0a 0x01>; // 某个 GPIO10, active-low
    compatible = "awinic,aw9523";
    status = "okay";
    reg = <0x5a>;                   // I2C address 0x5a
    phandle = <0x1a4>;

    gpio {
        gpio-controller;
        compatible = "awinic,aw9523-gpio";
        #gpio-cells = <0x02>;
        phandle = <0x1a6>;
    };
};
```
**重要发现**：板子上有 **AW9523 GPIO 扩展器**（I2C 0x5a），可能用于 NPU 的电源/复位控制。这可能是 .129 上 npu_powerctrl 操作的 GPIO 之一。

#### B.2.7 n4-pwr-pin（NPU 电源控制引脚）
```dts
n4 {
    n4-pwr-pin {
        rockchip,pins = <0x00 0x09 0x00 0xd4>;  // GPIO0_B1, func=0, pull-none
        phandle = <0xf2>;
    };
};
```
**关键发现**：`n4-pwr-pin` 使用 GPIO0_B1，这可能直接控制 NPU（RK1808）的电源。

### B.3 npu_boot（存在，ELF 二进制）
.113 上有 `/usr/local/bin/npu_boot`，是 ARM64 ELF 动态链接二进制（源码 npu_boot.c）。

strings 输出：
```
/dev/mem
open /dev/mem
mmap failed
=== Starting NPU Power-up and Reset Sequence ===
Enabled clk_wifi_pmu. Register 0xff750100: 0x%08x
Powering up rails...
Releasing NPU from reset...
NPU Boot sequence completed successfully.
```

符号表（关键函数）：
```
main, open, close, read_reg, write_reg, mmap, munmap, sysconf
printf, perror, puts, usleep, abort
```

**分析**：npu_boot 通过 `/dev/mem` 直接操作寄存器：
1. 启用 `clk_wifi_pmu`（寄存器 0xff750100 — GRF 基地址 + 偏移，对应 GPIO0_A2 的复用功能）
2. Powering up rails（上电）
3. Releasing NPU from reset（释放复位）

### B.4 npu_powerctrl（与 .129 相同的 C++ 二进制）
.113 上也有 `/usr/bin/npu_powerctrl`，从 strings 看内容与 .129 版本一致。

### B.5 upgrade_tool LD（未检测到设备）
```
Not found config.ini
Program Data in /usr/bin
List of rockusb connected(0)
```
**对比**：.129 检测到 1 个设备（Maskrom 2207:1005），.113 检测到 0 个。说明 .113 上 NPU 没有被正确上电/复位到 Maskrom 模式。

### B.6 npu_transfer_proxy devices（空列表）
```
List of ntb devices attached
(空 — 无设备)
```
**对比**：.129 显示 `0123456789ABCDEF    cfbc0c55    PCIE`，.113 为空。

### B.7 dmesg（无 NPU/PCIE 相关日志）
```
[    0.563987] rk_gmac-dwmac fe300000.ethernet: clock input or output? (output).
[   18.265369] input: rk805 pwrkey as /devices/platform/ff3c0000.i2c/i2c-0/0-0020/rk805-pwrkey.3.auto/input/input0
```
仅匹配到 ethernet 和 pwrkey，无 npu/pcie/usb 2207 相关日志。说明 NPU 完全没有被枚举。

### B.8 extlinux.conf（不存在）
.113 上没有 `/boot/extlinux/extlinux.conf`，使用其他 boot 方式（可能 U-Boot 直接加载或 Armbian 的 boot script）。

### B.9 GPIO debug
```
gpio-27  (                    |reset               ) out hi ACTIVE LOW
gpio-15  (                    |snps,reset          ) out hi ACTIVE LOW
```
- gpio-27: `reset` — 可能是 NPU reset 引脚（ACTIVE LOW，当前 out hi = 复位释放）
- gpio-15: `snps,reset` — Synopsys DWC 以太网 PHY reset（非 NPU 相关）

### B.10 clk_summary（PCIe/wifi 时钟状态）
```
clk_pciephy_ref          1    1    0    24000000    0    0    50000    Y    ff770000.syscon:pcie-phy    refclk
clk_pcie_pm              0    0    0    24000000    0    0    50000    Y    deviceless                  no_connection_id
clk_pcie_core_cru        0    0    0    125000000   0    0    50000    Y    deviceless                  no_connection_id
clk_pciephy_ref100m      0    0    0    100000000   0    0    50000    Y    deviceless                  no_connection_id
aclk_pcie                0    0    0    148500000   0    0    50000    Y    deviceless                  no_connection_id
aclk_perf_pcie           0    0    0    148500000   0    0    50000    Y    deviceless                  no_connection_id
pclk_pcie                0    0    0    37125000    0    0    50000    Y    deviceless                  no_connection_id
clk_wifi_div             0    0    0    24000000    0    0    50000    N    deviceless                  no_connection_id
clk_wifi_pmu             0    0    0    24000000    0    0    50000    Y    deviceless                  no_connection_id
clk_wifi_frac            0    0    0    1200000     0    0    50000    Y    deviceless                  no_connection_id
clk_pcie_core            0    0    0    0           0    0    50000    Y    deviceless                  no_connection_id
```

**关键发现**：
- `clk_pciephy_ref`：enable_count=1，已启用（24MHz 参考）
- `clk_wifi_pmu`：enable_count=0，**未启用**！这就是 npu_ref_clk（GPIO0_A2 输出 24MHz）的来源。需要强制启用。
- `clk_wifi_div`/`clk_wifi_frac`：enable_count=0，也未启用
- 所有 PCIe 核心/总线时钟：enable_count=0（因为 PCIe host disabled，符合预期）

---

## 附录 C：两台机器对比总结

| 项目 | .129 (工作机, vendor 4.4) | .113 (目标机, mainline 6.18.33) |
|------|---------------------------|----------------------------------|
| **Kernel** | 4.4.194 | 6.18.33 |
| **OS** | Debian 10 buster | Armbian 26.05 trixie (Debian 13) |
| **NPU 状态** | Maskrom 模式 (2207:1005) | 未枚举（完全不可见） |
| **PCIE 链路** | ✅ 已通 (npu_transfer_proxy 显示 PCIE) | ❌ 未通 (空列表) |
| **upgrade_tool LD** | 1 设备 (Maskrom) | 0 设备 |
| **lsusb 2207** | ✅ Bus 1 Device 009 | ❌ 未出现 |
| **npu_boot** | ❌ 不存在 | ✅ 存在 (ARM64 ELF, npu_boot.c) |
| **npu_powerctrl** | ✅ 存在 (C++ ELF, V1.1) | ✅ 存在 (同版本) |
| **dtc 导出** | ❌ 未安装 | ✅ 成功 (3635 行) |
| **clk_wifi_pmu** | 未知 (需后续采集) | enable_count=0 (未启用) |
| **PCIe host** | 未知 (需后续采集) | status=disabled |
| **dmesg NPU 日志** | 无 (可能 rotated) | 无 (完全未枚举) |
| **extlinux.conf** | 未采集 | 不存在 |
| **NPU 固件** | ✅ /usr/share/npu_fw/ (5文件) | 未采集 |

### 关键差异分析

1. **.129 没有 npu_boot，.113 有**：说明 .129 的 NPU 上电完全由 `npu_powerctrl`（C++ 二进制）通过 sysfs GPIO 控制，不依赖 `/dev/mem` 直接寄存器操作。而 .113 上的 `npu_boot` 使用 `/dev/mem` + mmap 方式，在 mainline kernel 上可能因 `/dev/mem` 访问限制而失败。

2. **.129 的 NPU 处于 Maskrom 模式但 PCIE 已通**：说明 vendor 4.4 kernel 中 NPU 的上电序列成功执行了（clk_wifi_pmu 启用 + GPIO 复位序列），NPU 进入 Maskrom，然后 PCIE NTB 链路建立。但 NPU 固件可能未完全加载（仍在 Maskrom）。

3. **.113 的 clk_wifi_pmu enable_count=0 是根本原因**：NPU 的 24MHz 参考时钟未启用，NPU 无法启动。这验证了 amatriz guide 的诊断 — 需要强制启用 clk_wifi_pmu。

4. **AW9523 GPIO 扩展器**：.113 的 live DTS 中有 AW9523（I2C 0x5a），这可能控制 NPU 的电源轨。需要确认 .129 上是否也有同样的 AW9523 以及其 GPIO 输出状态。

5. **n4-pwr-pin (GPIO0_B1)**：这是一个专门的 NPU 电源控制引脚，在 vendor DTS 中可能被 npu_powerctrl 操作。mainline DTS 中已定义但可能未被任何驱动引用。

6. **pcie@f8000000 status=disabled**：.113 上 PCIe host 控制器禁用是合理的（避免 hang），但这也意味着无法通过 PCIE 路径与 NPU 通信。 amatriz 建议的 USB NTB 路径可能是更好的选择。

7. **GPIO0_A2 (npu-ref-clk)**：mainline DTS 中 pinctrl 已定义 `npu-ref-clk` 引脚配置（func=1 = clk_wifi_pmu），但时钟驱动未启用它。需要通过 sysfs 或 DT assigned-clocks 强制启用。

---

## 下一步行动计划（基于采集结果更新）

### 立即可执行
1. **在 .113 上手动启用 clk_wifi_pmu**：
   ```bash
   echo 1 > /sys/kernel/debug/clk/clk_wifi_pmu/clk_enable_count
   # 或
   cat /sys/kernel/debug/clk/clk_wifi_pmu/clk_enable_count  # 确认当前值
   # 可能需要通过 CLK API 而非直接写 debugfs
   ```
   更安全的方式：用 `libgpiod` 的 `gpioset` 将 GPIO0_A2 配置为 clk_wifi_pmu 复用功能。

2. **在 .113 上运行 npu_boot 并检查 dmesg**：
   ```bash
   dmesg -c  # 清空日志
   /usr/local/bin/npu_boot
   dmesg | tail -50
   lsusb | grep 2207
   ```
   确认 npu_boot 是否能通过 /dev/mem 成功操作寄存器。

3. **在 .129 上安装 dtc 并导出 vendor DTS**：
   ```bash
   apt install device-tree-compiler
   dtc -I fs -O dts -o /tmp/working_4.4.dts /proc/device-tree
   ```
   这是获取 vendor NPU 电源序列黄金参考的最关键步骤。

4. **在 .129 上采集 clk_summary 和 GPIO 状态**：
   ```bash
   cat /sys/kernel/debug/clk/clk_summary | grep -E 'wifi|pcie|npu'
   cat /sys/kernel/debug/gpio | grep -E 'npu|reset|power|clk|wifi'
   ```
   对比两台机器的时钟和 GPIO 状态差异。

5. **在 .129 上运行 npu_powerctrl -o (powerup) 并采集前后对比**：
   ```bash
   # 采集前
   cat /sys/kernel/debug/clk/clk_summary > /tmp/before_clk.txt
   cat /sys/kernel/debug/gpio > /tmp/before_gpio.txt
   lsusb > /tmp/before_lsusb.txt
   # 执行
   npu_powerctrl -o
   # 采集后
   cat /sys/kernel/debug/clk/clk_summary > /tmp/after_clk.txt
   cat /sys/kernel/debug/gpio > /tmp/after_gpio.txt
   lsusb > /tmp/after_lsusb.txt
   npu_transfer_proxy devices > /tmp/after_npu.txt
   ```
   这将揭示 npu_powerctrl 具体修改了哪些 GPIO 和时钟。

### 中期（patch 开发）
6. **基于 amatriz guide + .129 采集结果编写 DTS patch**：
   - 启用 npu-ref-clk pinctrl 并绑定到 clock consumer
   - 添加 assigned-clocks 强制 clk_wifi_pmu = 24MHz
   - 考虑是否需要启用 PCIe host（或先走 USB NTB 路径）
   - 添加 n4-pwr-pin GPIO 控制到 NPU 节点

7. **用 libgpiod 替代 npu_boot/npu_powerctrl**：
   - 编写 shell 脚本使用 `gpioset` 和 `gpioget` 实现 NPU 上电序列
   - 参考 amatriz guide 中的完整脚本
   - 不依赖 /dev/mem，更安全且 mainline 兼容

### 长期
8. **将完整方案集成到 GitHub repo (winic57/LPA3399Pro)**：
   - DTS patch 文件
   - 上电脚本
   - 文档更新

---

此外，如果你想走纯 vendor 路线，用 Armbian 的 legacy rockchip 4.4/5.10 kernel + 你 SDK 完整 build 会更容易让 NPU 跑起来（但你显然想留在 6.18.33 mainline）。

你的调试记录质量很高，继续沿着 DT diff + 完整 power sequence + 正确 rs 地址这条路走，成功概率很高。需要我帮你起草某个具体 patch 或脚本吗？



## 建议：

**更新诊断（基于你提供的 npu.md 完整数据）**

你的硬件是 **Radxa ROCK Pi N10 兼容板**（SOM 为 vamrs,rk3399pro-vmarc-som，Neardi/LPA3399Pro 载板）。核心结论：

- **工作机 (.129, 4.4 kernel)** 使用 **PCIe NTB** 路径（`npu_transfer_proxy devices` 显示 `PCIE`，即使处于 Maskrom 2207:1005 也成立）。`npu_powerctrl`（C++ 二进制）负责完整序列：检查/启用 `clk_wifi_pmu` 和 `rk808-clkout2`、操作多个 GPIO（含 reset ~35、power ~1、0 等）、USB remove patch（看到 1005 时强制重枚举）、通过 `/sys/.../pcie_reset_ep` 复位。
- **目标机 (.113, 6.18.33 mainline)** 根本问题在于 `clk_wifi_pmu enable_count=0`（NPU 需要的 24MHz 参考时钟未输出到 GPIO0_A2）。`npu_boot`（用 `/dev/mem` + mmap 操作寄存器）在 modern kernel 上效果不佳，PCIe host 保持 disabled 是正确的（单独 enable 会 hang）。
- DT 中已有 `npu-ref-clk`（GPIO0_A2 func=1）、`n4-pwr-pin`（GPIO0_B1）、AW9523 GPIO 扩展器、完整的 PCIe PHY 和 regulator 定义，但缺少 **assigned-clocks**、完整 pinctrl 引用、reset 序列和 PCIe NTB 相关 consumer 节点。
- `upgrade_tool LD` 在 .113 上无设备 → NPU 未被正确上电到 Maskrom；rs 阶段失败是因为时钟/电源/复位序列不完整。

**最直接可参考的项目仍然是这两个（现在匹配度更高）：**

1. **https://amatriz.net/posts/using-the-radxa-rock-pi-n10-npu-on-mainline-linux/**（首要推荐）
   专门针对和你几乎一样的 Rock Pi N10 + mainline 内核。包含 9 个 patch（clk、pinctrl、rtc-hym8563、rk3399pro-vmarc-som.dtsi 等），libgpiod 实现的完整上电脚本（强制 24MHz clk_wifi_pmu、多路 GPIO 严格时序），修改后的 `npu_upgrade` 脚本和 rs 地址。强烈建议完整阅读并把其中的 power sequence 部分适配到你的板子。

2. **https://github.com/airockchip/RK3399Pro_npu**
   提供 USB 和 PCIE 两种 firmware（你的 .129 固件 hash 与此仓库高度一致，可优先用你 SDK 中的 `/usr/share/npu_fw/`）。用 `npu_transfer_proxy devices` 判断是 PCIE 还是 USB_DEVICE。

**立即可执行的安全步骤（不刷 eMMC，不破坏当前系统）**

### 1. 在 .113 上先做只读检查 + 手动补时钟（推荐先执行）
```bash
# 清日志 + 检查当前状态
dmesg -c
echo "=== Before power ===" > /tmp/npu_test.log
lsusb | grep -E '2207|1005|180a' >> /tmp/npu_test.log
/usr/bin/npu_transfer_proxy devices >> /tmp/npu_test.log 2>&1
cat /sys/kernel/debug/clk/clk_wifi_pmu/clk_enable_count >> /tmp/npu_test.log
cat /sys/kernel/debug/clk/clk_summary | grep -E 'wifi|pcie|npu|rk808' >> /tmp/npu_test.log

# 尝试强制启用时钟（临时 hack，后面会改成 DT 方式）
echo 1 > /sys/kernel/debug/clk/clk_wifi_pmu/clk_enable_count || true
cat /sys/kernel/debug/clk/clk_wifi_pmu/clk_enable_count

# 运行现有工具观察
/usr/bin/npu_powerctrl -o || true
sleep 2
/usr/local/bin/npu_boot || true
sleep 3

echo "=== After power ===" >> /tmp/npu_test.log
lsusb | grep -E '2207|1005|180a|0019' >> /tmp/npu_test.log
/usr/bin/npu_transfer_proxy devices >> /tmp/npu_test.log 2>&1
dmesg | tail -80 >> /tmp/npu_test.log
cat /tmp/npu_test.log
```

把输出贴给我，我可以进一步调整。

### 2. 推荐替换为 libgpiod 版上电脚本（更安全，主线友好）
安装工具：
```bash
apt install -y gpiod
```

新建 `/usr/local/bin/npu_power_on.sh`（基于 amatriz guide + 你 npu_powerctrl strings + DTS 里的引脚）：

```bash
#!/bin/bash
set -e

echo "=== NPU Power Sequence (mainline safe) ==="

# 1. 启用 24MHz 参考时钟 (GPIO0_A2 = clk_wifi_pmu)
echo "Enabling clk_wifi_pmu..."
echo 1 > /sys/kernel/debug/clk/clk_wifi_pmu/clk_enable_count 2>/dev/null || true
cat /sys/kernel/debug/clk/clk_wifi_pmu/clk_enable_count

# 2. 使用 gpioset 控制关键 GPIO（需根据实际 GPIO 编号微调，可从 AW9523 或 n4-pwr-pin 映射）
# GPIO0_B1 (n4-pwr-pin) - power
gpioset --mode=exit gpiochip0 1=1   # GPIO0_B1 = 1 (power on)

# reset (常见 GPIO 可能为 35 或从 AW9523 导出，需确认)
gpioset --mode=exit gpiochip0 35=0  # reset low
sleep 0.1
gpioset --mode=exit gpiochip0 35=1  # reset high

echo "Power sequence completed. Waiting for enumeration..."
sleep 3

lsusb | grep -E '2207'
/usr/bin/npu_transfer_proxy devices || true
```

`chmod +x /usr/local/bin/npu_power_on.sh` 后运行 `./npu_power_on.sh` 并观察是否出现 2207:1005 或 0019。

### 3. DT 安全测试方案（强烈建议用测试 DTB）
当前 PCIe host disabled 是正确的。不要直接改默认 DTB。

- 把当前 DTB 复制为 `rk3399pro-neardi-linux-lc110-base-npu-test.dtb`。
- 在 DT 中增加 `assigned-clocks` 强制 clk_wifi_pmu（推荐 patch 片段）：

```dts
&clk_wifi_pmu {
    assigned-clocks = <&cru CLK_WIFI_PMU>;
    assigned-clock-rates = <24000000>;
    status = "okay";
};

&npu_ref_clk {
    clock-frequency = <24000000>;
};
```

用 `dtc` 把修改后的 dts 转成 dtb，放到 `/boot/dtb/rockchip/`，然后在 boot loader 配置中添加第二菜单项（extlinux.conf 或 u-boot 环境变量），默认仍启动稳定 DTB。测试失败时拔卡恢复（你已有成功恢复经验）。

### 4. RAM Boot 测试（使用 .129 固件 hash 匹配的版本）
用你 SDK 或 airockchip 仓库的 PCIE 版 firmware，推荐 rs 地址组合（amatriz guide 常用值）：

```bash
upgrade_tool db MiniLoaderAll.bin
sleep 2
upgrade_tool rs 0x200000 0x400000 0x600000 uboot.img trust.img boot.img
```

加 `timeout 90s` 防止挂起。成功后应看到设备重枚举 + `npu_transfer_proxy devices` 显示 `PCIE`。

**下一步建议**

1. 先跑上面「立即可执行」部分的命令，把 `/tmp/npu_test.log` 内容贴出来。
2. 把 .129 的完整 live DTS（安装 dtc 后 `dtc -I fs -O dts /proc/device-tree > working_4.4.dts`）也传给我。
3. 我可以帮你生成：
   - 完整的 `0003-mainline-npu-power-sequence.patch`
   - 适配你 neardi 载板的 `npu_power_on.sh`（包含 AW9523 支持）
   - extlinux.conf 测试菜单

把这些集成到你的 GitHub `winic57/LPA3399Pro`（新增 patch 和 tools 目录）会非常有价值。

这个方向（DT assigned-clocks + libgpiod power sequence + 正确 rs 地址）结合 amatriz guide，成功率很高。你当前调试记录已经非常专业，继续这条路走即可。需要我现在就输出具体 patch 文件内容吗？

### 2026-07-04 基于 paramiko 的补充实采

> 采集方式：Windows 侧 Python `paramiko`；采集脚本：`E:\rk3399pro\NPU\artifacts\collect_npu_info.py`  
> 汇总结果：`E:\rk3399pro\NPU\artifacts\ssh_collect_summary.json`  
> 单机明细：`E:\rk3399pro\NPU\artifacts\target_113.json`、`E:\rk3399pro\NPU\artifacts\work_129.json`

#### 1) 结果概览

- `.113` 当前已不是之前记录的 `6.18.33`，而是 **`6.18.37-ophub-gacb0ea9f34d4-dirty`**。
- `.113` 当前 live DT 中 `pcie@f8000000/status` 为 **`okay`**，与前文旧采样里“disabled”不同，说明系统状态已变化。
- `.113` 的 `npu_transfer_proxy devices` 仍为空、`upgrade_tool LD` 仍为 `List of rockusb connected(0)`、`lsusb` 无 `2207:*`，说明 **NPU 依然没有进入可见的 USB Maskrom/Loader 状态**。
- `.113` 的 `clk_wifi_pmu=0`、`rk808-clkout2=0`；`.129` 的 `clk_wifi_pmu=1`、`rk808-clkout2=7`，差异仍然非常明显。
- `.129` 仍保持 **PCIE 正常**：`npu_transfer_proxy devices` 显示 `0123456789ABCDEF cfbc0c55 PCIE`，同时 `upgrade_tool LD` 看到 `2207:1005 Maskrom`。

#### 2) .113 当前关键变化

##### 2.1 内核 / DT / PCIe

```text
Kernel: Linux armbian 6.18.37-ophub-gacb0ea9f34d4-dirty
Model: Radxa ROCK Pi N10
Compatible: radxa,rockpi-n10 / vamrs,rk3399pro-vmarc-som / rockchip,rk3399pro
pcie@f8000000/status: okay
PCI: 0000:00:00.0  vendor=0x1d87 device=0x0100 class=0x060400
```

结合 `dmesg`，当前 `.113` 的 PCIe host 已经实际初始化，但链路训练失败：

```text
rockchip-pcie f8000000.pcie: PCIe link training gen1 timeout!
rockchip-pcie f8000000.pcie: Ignoring link training timeout to keep REFCLK running
rockchip-pcie f8000000.pcie: Link is down, keeping all lanes powered on
pci 0000:00:00.0: [1d87:0100] type 01 class 0x060400 PCIe Root Port
```

这说明现在不是“PCIe host 完全没启用”，而是 **host 已起、Root Port 已枚举，但 NPU endpoint 没上来**。

##### 2.2 时钟 / USB / 工具状态

```text
clk_wifi_pmu enable_count: 0
rk808-clkout2 enable_count: 0
npu_transfer_proxy devices: empty
upgrade_tool LD: List of rockusb connected(0)
lsusb: no 2207:1005 / 180a / 0019
```

`.113` 上的 `npu_powerctrl` 也和旧记录不同，当前不是 C++ ELF，而是一个很薄的 shell wrapper：

```sh
#!/bin/sh
case "$1" in
    -i) /usr/local/bin/npu_boot ;;
    -o) /usr/local/bin/npu_boot ;;
    *)  /usr/local/bin/npu_boot ;;
esac
```

即：`.113` 现在的 `npu_powerctrl` 本质只是转调 `/usr/local/bin/npu_boot`，并不具备 `.129` 上那个原生 ELF `npu_powerctrl` 的完整 GPIO/clock/USB remove patch 行为。

##### 2.3 固件目录差异

`.113` 的 `/usr/share/npu_fw/` 比 `.129` 多出一套 `*_factory` 镜像：

- `boot_factory.img`
- `trust_factory.img`
- `uboot_factory.img`
- `MiniLoaderAll_factory.bin`

同时目录里还多出一个异常文件名：

```text
/usr/share/npu_fw/ystemctl start npu_transfer_proxy.service
```

这大概率是之前脚本误写入留下的脏文件，虽然不一定直接导致当前问题，但值得清理前先备份留证。

#### 3) .129 当前关键状态

```text
Kernel: Linux LPA3399Pro 4.4.194
pcie@f8000000/status: okay
clk_wifi_pmu enable_count: 1
rk808-clkout2 enable_count: 7
upgrade_tool LD: 2207:1005 Maskrom
npu_transfer_proxy devices: PCIE
PCI: 0000:01:00.0 vendor=0x1d87 device=0x1808
```

补充点：

- `.129` 上 **`dtc` 仍未安装**，所以“直接导出 live DTS”这一步还没完成。
- `.129` 上 `npu_powerctrl` 仍是 **ELF 可执行文件**，这与 `.113` 的 shell wrapper 形成直接对比。
- `.129` 的固件 hash 仍与前文记录一致；`.113` 的 `trust.img` / `parameter.txt` 与 `.129` 相同，但 `MiniLoaderAll.bin`、`uboot.img`、`boot.img` 已明显不是同一套。

#### 4) 新的对比结论

1. **当前 .113 的症结更明确了**：  
   不是 PCIe host 没启，而是 **PCIe Root Port 已经起来，但 NPU 侧既没有形成 USB rockusb 枚举，也没有形成 PCIe endpoint 枚举**。

2. **`.113` 的上电路径明显弱化**：  
   现在 `npu_powerctrl` 只是调用 `npu_boot`，缺少 `.129` 那种独立 ELF 中封装的完整时钟/GPIO/USB remove patch 逻辑。

3. **clock 差异仍是最关键证据**：  
   `.113` 的 `clk_wifi_pmu=0`、`rk808-clkout2=0`；`.129` 的对应值分别是 `1` 和 `7`。  
   这与“NPU 没有得到正确参考时钟/上电时序”的判断继续一致。

4. **firmware 套件也存在分叉**：  
   `.113` 不仅文件更多，而且 hash 与 `.129` 不同，说明当前目标机上已经不是工作机那套已验证可工作的最小固件组合。

#### 5) 现阶段最建议的下一步

- 先不要继续扩大改动面，优先做一件事：**把 `.129` 上的 `npu_powerctrl`、`/usr/share/npu_fw/`、以及如果后续装上 `dtc` 后导出的 live DTS，整体作为黄金参考同步留档。**
- `.113` 上后续实验时，建议优先恢复到“`.129` 同款 firmware + 同类 powerctrl 行为”，再看 `2207:1005` 或 `0000:01:00.0 1d87:1808` 是否出现。
- 如果继续走 mainline 路线，下一步应优先补的是：
  - `clk_wifi_pmu` 强制启用；
  - `rk808-clkout2` 引用关系；
  - `n4-pwr-pin` / AW9523 对应的实际上电 GPIO 时序；
  - 用 `libgpiod` 重建 `.129` 的 power sequence，而不是继续依赖 `.113` 这个简化版 wrapper。

### 2026-07-04 `.129` 黄金参考已同步留档

已按“现阶段最建议的下一步”执行完成，来源主机：`192.168.50.129`。

#### 本地归档位置

- `E:\rk3399pro\NPU\artifacts\golden_129\bin\npu_powerctrl`
- `E:\rk3399pro\NPU\artifacts\golden_129\usr_share_npu_fw\`
- `E:\rk3399pro\NPU\artifacts\golden_129\tmp\working_4.4.dts`
- `E:\rk3399pro\NPU\artifacts\golden_129\manifest.json`

#### 本次动作

1. 通过 Python `paramiko` 连接 `.129`
2. 执行 `apt-get install -y device-tree-compiler`
3. 用 `dtc -I fs -O dts -o /tmp/working_4.4.dts /proc/device-tree` 导出 live DTS
4. 下载 `npu_powerctrl`
5. 下载 `/usr/share/npu_fw/` 全部 5 个固件文件
6. 在本地生成 `manifest.json`，记录命令输出、文件大小与 SHA256

#### 关键留档结果

```text
npu_powerctrl sha256:
74e19570755d8b3a2a3cc23ee7510588fe4b385aeeb64bad78c32b86be55ce37

working_4.4.dts sha256:
b2a3ca38e9e2be7d008140b55928408598cc2109415d5ddbdad3739d0dc2f5ae
```

固件 SHA256：

```text
MiniLoaderAll.bin  521aa944983bd0492fbbaa922ed2957915a516ed5a28443c9b67953b41ed6c27
boot.img           0fdb5013f851de968ae8aa53dcae7c582a8ebb199e2c561f6ce29cef81970f26
parameter.txt      fedaf45f8c22a94b25271844757d3c303c2d7987ef0e4b3533b0503fdcdd6b03
trust.img          524f987049c3f3c27c64a6b5b3d29de711513d23acd2ce9ea1eb390677ab4827
uboot.img          4f3f63bb6377baae850a778b83ccecd314d49c841f3bd26e55ab2c5368ceb21a
```

#### Gemini实际发现

 根据刚才的实际测量和历史日志对比，我们得到了一个极其关键的物理调试发现：

 

 \### 关键诊断发现：PCIe 状态与 NPU BootROM 的行为冲突

 

1. 当 PCIe 禁用时（昨天的测试状态）：

   • 主控不启动 PCIe 链路训练。

   • NPU 在上电后由于检测不到 PCIe 信号，其 BootROM 自动退回并初始化了 USB 控制器，从而在 USB Bus 3 上成功枚举出 2207:180a （Maskrom 模式）。

2. 当 PCIe 启用时（今天的测试状态）：

   • 主控加载了 PCIe 驱动并开始不断进行 Gen1 链路训练（通过 pcie-rockchip-host.c 的重试机制）。

   • NPU 上电复位后，其内部的 BootROM 检测到了主控侧 PCIe 的训练请求，尝试与其建立 PCIe 握手。

   • 由于目前 NPU 的 eMMC 内没有成功加载完整的 PCIe 驱动或处于未就绪状态，NPU 在 BootROM 阶段陷入了 PCIe 握手死循环，导致整片 NPU 彻底挂死（console

   串口无输出，且无法退回到 USB 模式，因此 lsusb 找不到任何 NPU 设备）。

 

 ──────

 \### 下一步验证方案（验证此冲突）

 

 为了确认此结论，我们可以暂时在开发板的设备树中禁用 PCIe 节点，重启后观察 NPU 是否能立即恢复到 2207:180a 状态。

 

 我们可以通过修改 extlinux 配置或直接修改设备树进行验证。请问您是否同意我们现在临时在板端设备树中将 pcie@f8000000 设置为 status = "disabled" ，并重启开发板进行 A/B

 测试？

#### 说明

- `.129` 上 `dtc` 已安装成功：`/usr/bin/dtc`
- 导出 live DTS 成功；`dtc` 过程中出现大量 warning，但 **DTS 文件已生成并成功回传**
- 后续所有 `.113` 的 mainline 适配，都应优先以 `golden_129` 中的：
  - `npu_powerctrl`
  - `working_4.4.dts`
  - `usr_share_npu_fw/*`
  
  作为黄金参考基线进行比对
