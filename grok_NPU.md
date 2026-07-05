**更新诊断（2026-07-04 最新采集）**

你的 `.113`（Armbian 6.18.37-ophub mainline）已取得可见进展：

- `pcie@f8000000` 状态改为 `okay`，Root Port `0000:00:00.0 (1d87:0100)` 成功枚举。
- dmesg 显示 “PCIe link training gen1 timeout! ... Ignoring link training timeout to keep REFCLK running” —— 这正是 **amatriz guide** 中 Rock Pi N10 类板子的典型表现（REFCLK 被保留，但 NPU endpoint 未响应）。
- 但 **NPU endpoint (1d87:1808) 未出现**，`lsusb` 无任何 `2207:*`（180a/1005/0019），`npu_transfer_proxy devices` 仍为空，`upgrade_tool LD` 显示 0 台设备。
- 关键时钟仍未启用：`clk_wifi_pmu enable_count=0`、`rk808-clkout2 enable_count=0`（而 `.129` 工作机分别为 **1** 和 **7**）。
- `npu_powerctrl` 退化为简单 shell wrapper（只调用 `/usr/local/bin/npu_boot`），远不如 `.129` 上的完整 C++ ELF（包含 GPIO 操作、clock 检查、USB remove patch、`/sys/.../pcie_reset_ep` 复位等逻辑）。

**根本原因**：NPU（实际是内部 RK1808，通过 PCIe NTB 或 USB3 通信）未得到完整上电/时钟/复位序列，因此无法从 Maskrom 启动或响应 PCIe/USB 枚举。PCIe link training timeout 是下游结果，不是根因。

**RK3399Pro NPU 本质**：RK3399 + RK1808 协处理器（通过 PCIe NTB 或 USB3 通信）。成功标志是 `npu_transfer_proxy devices` 显示 `PCIE`（或 `USB_DEVICE`），而非单纯 ping 192.168.180.8。

### 最直接可参考的项目（2026 年仍有效）

1. **首要推荐（最高匹配度）**：**https://amatriz.net/posts/using-the-radxa-rock-pi-n10-npu-on-mainline-linux/**
   专门针对 **Radxa ROCK Pi N10 + VMARC RK3399Pro SOM**（你的 live DT compatible 完全一致）在 mainline kernel 上跑 NPU 的指南。包含：
   - 9 个 kernel/DT patch（clk、pinctrl、rtc、rk3399pro-vmarc-som.dtsi 等）。
   - **libgpiod**（`gpioset`）实现的完整上电/复位/24MHz 时钟序列脚本（正好解决你 `clk_wifi_pmu=0` 和 link timeout）。
   - 修改后的 `npu_upgrade` 脚本 + 推荐的 `upgrade_tool rs` 地址组合（0x200000/0x400000 等）。
   - 明确说明对这类板子 PCIe host 不一定是必须的（优先 USB NTB 路径，加载 firmware 后重新枚举）。

2. **固件与 proxy 核心仓库**：**https://github.com/airockchip/RK3399Pro_npu**
   提供 USB/PCIE 两种 `npu_fw`（你的 `/usr/share/npu_fw/` 里的 `*_factory.img` 和普通文件与之高度一致，可优先使用）。`npu_transfer_proxy devices` 是判断链路是否通的**金标准**（`.129` 显示 `PCIE` 即成功）。

**强烈建议**：先从 `.129`（工作机）同步**真实 ELF `npu_powerctrl`** + 全套 `/usr/share/npu_fw/*`（包括 factory 版）到 `.113`，这是最快验证路径。之后再用 libgpiod 脚本 + DT patch 实现纯 mainline 方案。

### 立即可执行的安全步骤（不刷 eMMC，先 RAM boot 测试）

#### 步骤 1：在 `.129` 上安装 dtc 并导出黄金参考 DTS（只读）
```bash
ssh root@192.168.50.129 "apt update && apt install -y device-tree-compiler"
ssh root@192.168.50.129 'dtc -I fs -O dts -o /tmp/working_4.4.dts /proc/device-tree'
scp root@192.168.50.129:/tmp/working_4.4.dts ./working_4.4.dts
```

把 `working_4.4.dts`（尤其是 pcie、npu、clock、pinctrl、aw9523、gpio 部分）发给我，我可以生成精确 diff patch。

#### 步骤 2：从 `.129` 同步关键二进制和固件到 `.113`（推荐先做）
```bash
# 同步真实 npu_powerctrl ELF（替换 wrapper）和固件
scp root@192.168.50.129:/usr/bin/npu_powerctrl root@192.168.50.113:/usr/bin/npu_powerctrl.real
scp -r root@192.168.50.129:/usr/share/npu_fw/* root@192.168.50.113:/usr/share/npu_fw/

# 在 .113 上备份并替换
ssh root@192.168.50.113 '
    mv /usr/bin/npu_powerctrl /usr/bin/npu_powerctrl.wrapper.bak
    cp /usr/bin/npu_powerctrl.real /usr/bin/npu_powerctrl
    chmod +x /usr/bin/npu_powerctrl
    ls -l /usr/share/npu_fw/
'
```

#### 步骤 3：在 `.113` 上强制启用时钟 + 执行 power sequence（立即测试）
```bash
ssh root@192.168.50.113 '
    dmesg -c > /tmp/before_npu.log
    echo "=== BEFORE ===" >> /tmp/before_npu.log
    lsusb | grep -E "2207|1d87" >> /tmp/before_npu.log
    /usr/bin/npu_transfer_proxy devices >> /tmp/before_npu.log 2>&1
    cat /sys/kernel/debug/clk/clk_summary | grep -E "wifi|pcie|rk808|clkout" >> /tmp/before_npu.log

    # 强制启用关键时钟（匹配 .129）
    echo 1 > /sys/kernel/debug/clk/clk_wifi_pmu/clk_enable_count 2>/dev/null || true
    echo 7 > /sys/kernel/debug/clk/rk808-clkout2/clk_enable_count 2>/dev/null || true

    # 执行真实 powerctrl（-o = power up/reset）
    /usr/bin/npu_powerctrl -o || /usr/local/bin/npu_boot || true
    sleep 4

    echo "=== AFTER ===" >> /tmp/after_npu.log
    lsusb | grep -E "2207|1d87" >> /tmp/after_npu.log
    /usr/bin/npu_transfer_proxy devices >> /tmp/after_npu.log 2>&1
    dmesg | tail -100 >> /tmp/after_npu.log
    cat /sys/kernel/debug/clk/clk_summary | grep -E "wifi|pcie|rk808|clkout" >> /tmp/after_npu.log
    cat /tmp/before_npu.log /tmp/after_npu.log
'
```

把输出日志贴给我。

#### 步骤 4：推荐的 libgpiod 替代脚本（长期 mainline 友好，替代 wrapper）
安装 `apt install -y gpiod`，然后创建 `/usr/local/bin/npu_power_on.sh`（基于 amatriz guide + 你 DT 中的 `n4-pwr-pin`、`npu-ref-clk`、`AW9523`）：

```bash
#!/bin/bash
set -e
echo "=== NPU Power Sequence (mainline + AW9523 aware) ==="

# 强制 24MHz 时钟
echo 1 > /sys/kernel/debug/clk/clk_wifi_pmu/clk_enable_count 2>/dev/null || true
echo 7 > /sys/kernel/debug/clk/rk808-clkout2/clk_enable_count 2>/dev/null || true

# 示例 GPIO 序列（需根据 .129 strings / live DTS 微调：n4-pwr-pin GPIO0_B1 ≈ gpio1, reset gpio27/35 等）
gpioset gpiochip0 1=1          # power on (n4-pwr-pin)
gpioset gpiochip0 27=0; sleep 0.1; gpioset gpiochip0 27=1  # reset cycle

sleep 2
lsusb | grep -E "2207|1d87"
npu_transfer_proxy devices || true
```

`chmod +x` 后运行它 + `upgrade_tool db MiniLoaderAll_factory.bin`（或普通版） + `rs` 命令（常用地址：`rs 0x200000 0x400000 0x600000 uboot_factory.img trust_factory.img boot_factory.img`）。

### 下一步建议（集成到你的 GitHub winic57/LPA3399Pro）

- 把上面脚本、同步命令、采集日志加入 `tools/npu_mainline_power_sequence.sh` 和 `NPU_DEBUG_20260704.md`。
- 新增 patch：`patches/npu/0003-rk3399pro-mainline-assigned-clocks-and-power.patch`（核心是 `assigned-clocks` 强制 `clk_wifi_pmu` 和 `rk808-clkout2`，加上 PCIe “ignore timeout” 属性）。
- 如果 PCIe link 仍 timeout，可尝试 USB NTB 固件路径（airockchip 仓库有区分）。

**请把以下内容发给我，我立刻帮你生成完整 patch 文件和优化后的脚本**：
- `.129` 的 `working_4.4.dts`（或只贴 pcie/npu/clock/aw9523 节点）。
- 上面步骤 3 执行后的 `/tmp/after_npu.log` 完整输出。
- 当前 `.113` 上 `strings /usr/local/bin/npu_boot`（如果有新内容）。

这个组合（复制真实 powerctrl ELF 测试 → libgpiod 脚本 → DT assigned-clocks patch）沿着 amatriz guide 走，成功率很高。你的记录已经非常完整，继续这条路即可。需要我现在就输出某个具体 patch 或完整 `npu_power_on.sh` 文件内容吗？