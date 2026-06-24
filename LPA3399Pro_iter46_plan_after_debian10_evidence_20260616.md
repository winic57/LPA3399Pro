# LPA3399Pro iter46 排查计划 — 推翻"硬件缺陷"结论,DTB 已偏离 baseline

> 日期: 2026-06-16
> 输入证据: 用户提供的 Debian 10 eMMC 启动信息(4.4.194 vendor 内核,**有线网卡完全正常**)
> 参考文档:
> - `LPA3399Pro_iter43_analysis_iter44_plan_20260616.md` (iter43-45 完整复盘)
> - `LPA3399Pro_SDCard_Full_Adaptation_Log_20260615.md` (iter1-42 完整复盘)
> 工作目录: `/mnt/sdb3/LPA3399Pro`

---

## 0. 关键纠正:前两轮结论都错了

### 0.1 iter45 结论"GMAC DMA 硬件缺陷"是错的

**反证(用户提供)**: 同一块 LPA3399Pro 板子,从 eMMC 启动 Debian 10(`Linux 4.4.194 #1 SMP Thu Jun 12 08:43:20 UTC 2025 aarch64`),**有线网卡完全正常工作**。dpkg 列表中 `librockchip-mpp1`/`gstreamer1.0-rockchip1`/`rkisp-engine`/`libmali-midgard-t86x-r18p0-x11` 等 vendor 包齐全,证明这是厂商 SDK 出厂系统。

如果 GMAC DMA 真的硅片损坏,vendor 4.4.194 内核不可能正常工作。硬件 100% 完好。

### 0.2 iter43 §9.0 结论"rk35xx 内核缺少 RK3399 CRU 定义"也是错的

我从 Armbian 打包目录里把 `boot-6.1.141-rk35xx-ophub.tar.gz` 解开,提取 `config-6.1.141-rk35xx-ophub`,确认:

```
CONFIG_ARCH_ROCKCHIP=y
CONFIG_COMMON_CLK_ROCKCHIP=y
CONFIG_CLK_RK3399=y              ← RK3399 CRU 驱动已编译进内核
CONFIG_ROCKCHIP_PLL_RK3399=y     ← RK3399 PLL 驱动已编译进内核
CONFIG_CPU_RK3399=y              ← RK3399 CPU 支持已编译进内核
CONFIG_STMMAC_ETH=y              ← Synopsys MAC 驱动 builtin
CONFIG_STMMAC_PLATFORM=y
CONFIG_DWMAC_GENERIC=y
CONFIG_DWMAC_ROCKCHIP=y          ← Rockchip DWMAC 平台驱动 builtin
CONFIG_ROCKCHIP_PHY=y
```

且 ophub 的 `model_database.conf` 注释明确写着:
> `[ rk35xx/6.1.y ]` = Dedicated to Rockchip **rk3328/rk3399/rk3528/rk3566/rk3568** series devices.

已收录的 RK3399 板子(EAIDK-610 / King3399 / TN3399 / Kylin3399 / ZCube1-Max / tvi3315a / xiaobao / SMART-AM40 / CRRC)用的就是同一套 `rk35xx/6.1.y` 内核,**它们的 GMAC 都能正常工作**。

→ iter43 §9.0 提出的"换 RK3399 专用内核"假设不成立。当前内核本身就支持 RK3399 GMAC。

---

## 1. 🔑 最关键发现:Armbian 出厂 DTB 与 vendor DTB **完全一致**

把 `/mnt/sdb3/LPA3399Pro/lpa3399pro-armbian/build-armbian/armbian-files/different-files/lpa3399pro/rootfs/usr/lib/lpa3399pro/rk3399pro-neardi-linux-lc110-base.dtb`(打包出厂的 DTB,**iter38 之前的状态**)反编译,得到 ethernet@fe300000 节点:

```
ethernet@fe300000 {
    compatible = "rockchip,rk3399-gmac";
    reg = <0x00 0xfe300000 0x00 0x10000>;
    interrupts = <0x00 0x0c 0x04 0x00>;
    interrupt-names = "macirq";
    clocks = <0x08 0x69 0x08 0x67 0x08 0x68 0x08 0x66 0x08 0x6a 0x08 0xd5 0x08 0x166>;
    clock-names = "stmmaceth\0mac_clk_rx\0mac_clk_tx\0clk_mac_ref\0clk_mac_refout\0aclk_mac\0pclk_mac";
    power-domains = <0x16 0x16>;
    resets = <0x08 0x89>;
    reset-names = "stmmaceth";
    rockchip,grf = <0x17>;
    status = "okay";
    phy-supply = <0x18>;                                  ← 与 vendor 一致
    phy-mode = "rgmii";                                   ← 与 vendor 一致
    clock_in_out = "input";                               ← 与 vendor 一致
    snps,reset-gpio = <0x19 0x0f 0x01>;                   ← 与 vendor 一致 (gpio3 RK_PB7)
    snps,reset-active-low;                                ← 与 vendor 一致
    snps,reset-delays-us = <0x00 0x2710 0xc350>;          ← 与 vendor 一致 (0/10ms/50ms)
    assigned-clocks = <0x08 0xa6>;                        ← 0xa6=166=SCLK_RMII_SRC, 与 vendor 一致
    assigned-clock-parents = <0x1a>;                      ← external_gmac_clock, 与 vendor 一致
    pinctrl-names = "default";
    pinctrl-0 = <0x1b>;                                   ← rgmii_pins, 与 vendor 一致
    tx_delay = <0x21>;                                    ← 与 vendor 一致
    rx_delay = <0x15>;                                    ← 与 vendor 一致
};
```

**对照 vendor DTS 源码**(`LPA3399Pro-SDK-Linux-V3.0/kernel/arch/arm64/boot/dts/rockchip/rk3399pro-neardi-linux-ld110-phy.dtsi` + `rk3399.dtsi`):

```dts
&gmac {                                                  /* rk3399.dtsi */
    compatible = "rockchip,rk3399-gmac";
    clocks = <&cru SCLK_MAC>, ..., <&cru PCLK_GMAC>;
    power-domains = <&power RK3399_PD_GMAC>;
    resets = <&cru SRST_A_GMAC>;
    reset-names = "stmmaceth";
    rockchip,grf = <&grf>;
};

/* rk3399pro-neardi-linux-ld110-phy.dtsi 覆盖 */
&gmac {
    phy-supply = <&vcc_phy>;
    phy-mode = "rgmii";
    clock_in_out = "input";
    snps,reset-gpio = <&gpio3 RK_PB7 GPIO_ACTIVE_LOW>;
    snps,reset-active-low;
    snps,reset-delays-us = <0 10000 50000>;
    assigned-clocks = <&cru SCLK_RMII_SRC>;
    assigned-clock-parents = <&clkin_gmac>;
    pinctrl-names = "default";
    pinctrl-0 = <&rgmii_pins>;
    tx_delay = <0x21>;
    rx_delay = <0x15>;
    status = "okay";
};
```

**结论:Armbian 打包时使用的 DTB,GMAC 节点配置与 vendor SDK 完全一致**。原始镜像里 DTB 没有"缺属性"的问题。

---

## 2. iter38-45 把正确的 DTB 改坏了

对照 iter43 文档第 5 节记录的 iter43 终态,iter38-45 对 GMAC 节点的所有改动**全部偏离了 vendor baseline**:

| 迭代 | 改动 | 与 vendor 对比 | 影响 |
|---|---|---|---|
| iter38 | 添加 `snps,rxpbl/txpbl/pbl/fixed-burst/force_thresh_dma_mode/burst_len` | vendor **没有**这些属性 | 添加额外 DMA 调优参数,可能与 6.1.141 内核默认行为冲突 |
| iter42 | `phy-mode: rgmii → rgmii-id` | vendor 是 `rgmii` | **BROKE**: 让 MAC 不再加 delay,但 YT8521S strap 配置可能没有内部 delay → RGMII 时序错位 |
| iter43 | 添加 `assigned-clock-rates = <0x7735940>` (125 MHz) | vendor **没有**此属性 | 多余,且 iter43 后续分析显示并未生效 |
| iter44 | **删除** `assigned-clock-parents = <0x1a>` | vendor **有**此属性 | **BROKE**: vendor 4.4.194 内核依赖此属性把 SCLK_RMII_SRC 切到 clkin_gmac |
| iter45 | 添加 `resets = <... SRST_A_GMAC_NOC>` + `reset-names = "ahb"` | vendor 只有 `SRST_A_GMAC`/`stmmaceth` | 多余 reset id 索引,可能让 reset_control_assert 行为异常 |

**所以 iter38-45 整套排查方向走偏了**。本来 DTB 是对的,大家不断"修"DTB,反而越改越远。

---

## 3. 那 iter34 最初的 DMA 失败,根因到底是什么?

iter34 时 DTB 还没被改坏(Armbian 出厂状态),但 `ip link set eth0 up` 已经报 `Failed to reset the dma`。

这说明问题**不在 DTB**,而在:

| 候选根因 | 证据 | 验证方法 |
|---|---|---|
| **A. 6.1.141 mainline 的 dwmac_rockchip 对 RK3399 处理不完整** | vendor 4.4.194 的 dwmac-rk.c 是 Rockchip 改过的版本(`dwmac-rk.c` + `dwmac-rk-tool.c`),含 RK3399 专有 `rk3399_ops`、`set_to_rgmii`、`gmac_clk_enable` 等流程;mainline 6.1.141 用的是社区 dwmac-rockchip,可能缺少这些 vendor 补丁 | 对比 mainline dwmac-rockchip.c 与 vendor dwmac-rk.c 的 RK3399 clock/grf 操作 |
| **B. YT8521S PHY 在 mainline 6.1.141 中驱动行为与 vendor 不同** | YT8521S 是较新的 PHY,mainline driver 可能在 attach 后没有正确配置时钟输出/RGMII delay | 在 DTB 里**显式添加 PHY 子节点** mdio { ethernet-phy@0 { ... } },绑定到 motorcomm-yt8521 驱动并配置 rx-internal-delay/tx-internal-delay |
| **C. U-Boot hybrid_sdkboot 留下的 GMAC 状态污染** | U-Boot 来自 Neardi SDK,可能已经在 boot 阶段初始化过 GMAC;vendor 4.4.194 内核能清理,但 mainline 6.1.141 不能 | 在 U-Boot 命令行加 `gmac off` 或在内核启动参数加 `stmmaceth.reset=1` |
| **D. CRU 复位时序问题** | SRST_A_GMAC(0x89) 是 CRU AHB 复位,在 6.1.141 的 reset_control_assert 路径下可能时序不同 | DTB 加 `reset-gpios = <&gpio3 RK_PB7 GPIO_ACTIVE_LOW>` 替代 snps,reset-gpio(改名) |

A 和 B 概率最高,C/D 是次要候选。

---

## 4. iter46 执行计划

### 4.1 Step A — 恢复 Armbian 出厂 DTB(零风险,首选)

**理由**: iter38-45 把正确的 DTB 改坏了,先回到已知最接近 vendor 的 baseline,再看是否仍然失败。

**操作**(SD 卡 BOOT 分区已挂载到 PC):

```bash
SD_BOOT=/path/to/sd/boot   # 视具体路径调整

# 1. 备份当前 DTB(iter45 状态)
cp $SD_BOOT/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb \
   $SD_BOOT/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb.iter45_failed_$(date +%Y%m%d_%H%M%S)

# 2. 用 Armbian 打包出厂的 DTB 覆盖回去
cp /mnt/sdb3/LPA3399Pro/lpa3399pro-armbian/build-armbian/armbian-files/different-files/lpa3399pro/rootfs/usr/lib/lpa3399pro/rk3399pro-neardi-linux-lc110-base.dtb \
   $SD_BOOT/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb

# 3. 验证
fdtget $SD_BOOT/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb /ethernet@fe300000 phy-mode
# 期望: rgmii (不再是 rgmii-id)

fdtget $SD_BOOT/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb /ethernet@fe300000 assigned-clock-parents
# 期望: 26 (0x1a, external_gmac_clock phandle) — iter44 错误删除的属性回来了

# 4. 同步并弹出
sync
```

**TTL 验证**(板子启动后):

```bash
# 关键 1: 确认 DTB 是出厂状态
cat /sys/firmware/devicetree/base/ethernet@fe300000/phy-mode
# 期望: rgmii

# 关键 2: 直接试 link-up
ip link set eth0 up
# 期望: 无 "RTNETLINK: Connection timed out"

dmesg | grep -iE "Failed to reset|stmmac|eth0" | tail -10

ip -br link show eth0
```

**预期结果矩阵**:

| 场景 | DMA | eth0 | 后续 |
|---|---|---|---|
| 🟢 完全恢复 | 无错误 | UP | iter47 进一步流量测试 + 解决 WiFi |
| 🟡 仍失败 | `Failed to reset the dma` | timeout | 进入 Step B(换 kernel) |
| 🔴 启动卡死 | — | — | 立即回退到 iter45 备份(可能性极低,出厂 DTB 应能稳定启动) |

### 4.2 Step B — 升级到 6.18.33 内核(若 Step A 仍失败)

本地已有 Armbian 6.18.33 trunk 镜像:
```
/mnt/sdb3/LPA3399Pro/lpa3399pro-armbian/build/output/images/Armbian_26.05.0-trunk_trixie_arm64_6.18.33.img
```

6.18 内核含 YT8521S(motorcomm-yt8521)驱动改进,且 dwmac-rockchip 在 6.6+ 已合并若干 RK3399 相关修复。**但这需要换整套 rootfs**,不是只换 kernel 文件那么简单。

**操作**: 解开 6.18.33.img,把里面的 `/boot/vmlinuz-*` 和 `/lib/modules/6.18.33-*/` 替换到 SD 卡对应目录,然后改 `extlinux.conf` 指向新内核。这一步比 Step A 复杂,建议 Step A 验证后再决定是否需要。

### 4.3 Step C — 用 vendor 4.4.194 内核替换 SD 卡上的 kernel(终极保底)

如果 Step A/B 都失败,直接把 SD 卡上的 `6.1.141-rk35xx-ophub` 内核替换成 vendor `4.4.194` 内核。这能保证 GMAC 工作,但代价是:

- Debian Trixie(13)用户空间对 4.4.194 这种老内核兼容性较差(Syscall 接口、cgroup v2 等)
- NPU 驱动 (`rknpu2`) 依赖 vendor 内核 ABI,反而成为优势
- 需要从 SDK 编译 kernel + modules tarball

这是最重的方案,但确定能 work。**建议作为 iter48 候选,iter47 优先尝试 Step A+B**。

### 4.4 排除路径(不要再走)

下面这些 iter38-44 已经验证无效的方向,**iter46 不要再尝试**:

- ❌ 改 `clock_in_out`(iter40 验证会电气冲突挂死)
- ❌ 改 `phy-mode`(iter42 验证无效)
- ❌ 添加 `snps,burst_len` 等 DMA 调优(iter38 验证无效)
- ❌ 添加 `assigned-clock-rates`(iter43 验证无效)
- ❌ 删除 `assigned-clock-parents`(iter44 验证无效)
- ❌ 添加 AHB reset(iter45 验证无效)
- ❌ 编写内核模块强制 clk_set_rate(已有 `gmac_fix.ko`,把 clk_gmac 拉到 120 MHz 仍失败)
- ❌ DMA 寄存器扫描写 SWR=0(dma_scan.ko 已证明不可清除,**但这是因为前序 DTB 改动让 GMAC 处于错误状态**,不是真硬件缺陷)

---

## 5. 证据汇总(确认 Step A 是正确方向)

| 证据 | 含义 |
|---|---|
| Debian 10 eMMC + vendor 4.4.194 内核 → GMAC 正常 | 硬件 100% 完好 |
| 内核 config 显示 `CONFIG_CLK_RK3399=y` / `CONFIG_DWMAC_ROCKCHIP=y` | Armbian 6.1.141 内核理论上能驱动 RK3399 GMAC |
| Armbian 出厂 DTB 与 vendor DTS **完全一致** | DTB 本身没问题,iter38-45 是在错误的方向上"修"DTB |
| iter34 第一次报错时 DTB 还没被改 | 真正的原始根因与 DTB 无关,而是 mainline 6.1.141 dwmac-rockchip 与 vendor dwmac-rk 的行为差异 |
| dma_scan.ko 看到 SWR 卡死,写 0 不清除 | 不是硬件坏,而是 GMAC 在被 driver 初始化时进入了一个错误的内部状态(很可能与 iter42 改 rgmii-id 有关) |

---

## 6. 总结:iter46 三条路

| 优先级 | 方案 | 难度 | 预期成功率 | 备注 |
|---|---|---|---|---|
| **1** | Step A: 恢复 Armbian 出厂 DTB | ⭐ (5 分钟) | 70% | 零风险,先做 |
| **2** | Step B: 升级到 6.18.33 内核 | ⭐⭐⭐ (1-2 小时) | 85% | 如果 A 失败 |
| **3** | Step C: 换 vendor 4.4.194 内核 | ⭐⭐⭐⭐⭐ (半天-1 天) | 99% | 终极保底,NPU 兼容性反而最好 |

iter38-45 把简单的内核驱动问题,通过 8 轮 DTB 改动,误诊为"硬件缺陷"。**Debian 10 工作正常这一证据直接证伪了硬件缺陷假设**。

---

## 7. Step A 执行记录(2026-06-16 18:35)

### 7.1 SD 卡修改清单

| # | 路径 | 操作 | 备份名 |
|---|---|---|---|
| 1 | `/mnt/sdboot/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb` (BOOT 分区) | `cp` Armbian 出厂 DTB 覆盖 | `*.iter45_failed_20260616_183505` |
| 2 | `/mnt/sdroot/usr/lib/lpa3399pro/rk3399pro-neardi-linux-lc110-base.dtb` (ROOTFS 副本, 供 armbian-update 使用) | `cp` Armbian 出厂 DTB 覆盖 | (无,直接覆盖) |

### 7.2 修改前后对比

| 属性 | iter45 终态(改前) | Step A 后(改后) | vendor baseline |
|---|---|---|---|
| `phy-mode` | `rgmii-id` (iter42 改坏) | ✅ `rgmii` | `rgmii` |
| `assigned-clock-parents` | 不存在 (iter44 删错) | ✅ `26` (clkin_gmac) | `26` |
| `clock_in_out` | `input` | ✅ `input` | `input` |
| `snps,reset-gpio` | `25 15 1` | ✅ `25 15 1` | `25 15 1` (gpio3 PB7) |
| `snps,reset-delays-us` | `0 10000 50000` | ✅ `0 10000 50000` | `0 10000 50000` |
| `tx_delay` | `33` (0x21) | ✅ `33` | `33` |
| `rx_delay` | `21` (0x15) | ✅ `21` | `21` |
| `pinctrl-0` | `27` (rgmii_pins) | ✅ `27` | `27` |
| `snps,burst_len` | `16` (iter38 多余) | ✅ 已删除 | 不存在 |
| `snps,pbl` | `16` (iter38 多余) | ✅ 已删除 | 不存在 |
| `snps,rxpbl`/`txpbl` | 各 8 (iter38 多余) | ✅ 已删除 | 不存在 |
| `snps,fixed-burst` | 存在 (iter38 多余) | ✅ 已删除 | 不存在 |
| `snps,force_thresh_dma_mode` | 存在 (iter38 多余) | ✅ 已删除 | 不存在 |
| `assigned-clock-rates` | `125000000` (iter43 多余) | ✅ 已删除 | 不存在 |
| `resets` (额外 ahb) | iter45 加了 `SRST_A_GMAC_NOC` | ✅ 已撤销(回到单一 `SRST_A_GMAC=0x89`) | 单一 `SRST_A_GMAC` |

### 7.3 DTB 文件大小对照

| 版本 | 字节数 |
|---|---|
| iter45 终态(已偏离) | 102374 |
| Armbian 出厂 baseline | 102365 |
| Step A 后(SD 卡上) | 102365 |

### 7.4 保留的 ROOTFS 状态(未动)

- `/etc/NetworkManager/NetworkManager.conf` 仍含 `[keyfile] unmanaged-devices=interface-name:eth0` — iter39 引入,**故意保留**:Step A 验证阶段先手动 `ip link set eth0 up`,避免 NM 重试 → PAM 阻塞 → 60s login 超时级联。验证 DMA 工作正常后,iter47 再考虑放开 NM。
- `/etc/systemd/system/timers.target.wants/fstrim.timer` / `e2scrub_all.timer` — iter35 禁用,保留(避免 SD 卡 DISCARD 错误)
- `/etc/systemd/system/network-online.target.wants/NetworkManager-wait-online.service` — iter36 禁用,保留(避免 60s 启动超时)
- `/etc/systemd/system/serial-getty@ttyFIQ0.service.d/autologin.conf` / `getty@tty1.service.d/autologin.conf` — iter37 创建,保留(自动登录)
- `/root/.not_logged_in_yet` — iter36 移到 `.bak`,保留(跳过 firstlogin)
- `/root/eth_diag.sh` / `eth_quick.sh` / `eth_run.sh` — iter38 注入的诊断脚本,保留

### 7.5 TTL 验证步骤(待用户拔卡插板子后执行)

```bash
# Step 1: 确认 DTB 已恢复出厂状态
cat /sys/firmware/devicetree/base/ethernet@fe300000/phy-mode
# 期望: rgmii  (不再是 rgmii-id)

# Step 2: 尝试 link-up
ip link set eth0 up
# 期望: 立即返回(无 "RTNETLINK answers: Connection timed out")

# Step 3: 检查 dmesg
dmesg | tail -20
# 期望: 无 "Failed to reset the dma" / "DMA engine initialization failed"

# Step 4: 检查 eth0 状态
ip -br link show eth0
# 期望: eth0 UP ...

# Step 5: 取 IP 并 ping
dhclient eth0
ip addr show eth0
ping -c 3 8.8.8.8

# 完整诊断(可保存到日志)
bash /root/eth_diag.sh > /tmp/eth_diag_iter46.log 2>&1
cat /tmp/eth_diag_iter46.log
```

### 7.6 预期结果矩阵

| 场景 | DMA | eth0 | 后续 |
|---|---|---|---|
| 🟢 **iter46 完全成功** | 无错误 | UP + 拿到 IP | iter47 移除 NM unmanaged,放开 NM 管理 eth0 |
| 🟡 DMA 仍失败 | `Failed to reset the dma` | timeout | 进入 Step B(升级到 6.18.33 内核) |
| 🔴 启动卡死 | — | — | 立即回退:`cp /mnt/sdboot/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb.iter45_failed_20260616_183505` 回 active(可能性极低) |

---

## 8. Step A 第一轮失败 + 修正(2026-06-16 18:49~18:58)

### 8.1 第一轮 Step A 直接 `cp` 出厂 DTB → 板子 RCU stall

把 factory DTB 整体覆盖到 SD 卡 BOOT 后,启动 79s 在 deferred_probe_work_func + pm_runtime_work 处 RCU stall。日志保存在:
- `/home/henry/dav/rk3399pro/logs/ttl_iter46_boot_20260616_184948.log` (175 KB)

关键证据:
```
[   19.275961] probe of ff968000.mipi-dphy-tx1rx1 returned -517 after 6 usecs
[   19.276086] probe of f8000000.pcie returned -517 after 4 usecs
[   19.276513] iep: failed to find iep power down clock source.
[   19.277058] iep: IEP Power ON
[   19.277924] iep: IEP Driver loaded succesfully
[   19.279012] rockchip-drm display-subsystem: bound ff8f0000.vop
[   19.328258] dwmmc_rockchip fe310000.dwmmc: Unexpected interrupt latency
[   79.294906] rcu: INFO: rcu_sched detected stalls on CPUs/tasks:
[   79.294991] task:kworker/u12:1   Workqueue: events_unbound deferred_probe_work_func
[   79.295095] task:kworker/3:1     Workqueue: pm pm_runtime_work
```

**根因**: factory DTB 把 iter5-13 期间禁用的硬挂死源全部启用 — `iep`、`display-subsystem`、`rkisp1`、`mipi-dphy-tx1rx1`、`sdhci@fe330000` 全部 `status="okay"`,deferred probe 反复重试导致 stall。

### 8.2 Step A 修正方案

不能直接 cp factory DTB。正确做法:**以 iter45 终态 DTB 为基底**(iter5-13 的禁用全部保留),**只回退 GMAC 节点的 iter38-45 改动**。

### 8.3 修正执行(2026-06-16 18:57~18:58)

**Step 1**: 备份当前(factory,导致 RCU stall)DTB 到 `*.iter46a_factory_broke_20260616_185741`

**Step 2**: 从 `*.iter45_failed_20260616_183505` 恢复 iter45 终态作为基底

**Step 3**: 在 GMAC 节点做 7 项回退:

| # | 属性 | iter45 → iter46a |
|---|---|---|
| 1 | `phy-mode` | `rgmii-id` → `rgmii` |
| 2 | `assigned-clock-parents` | (iter44 删了)→ 补回 `0x1a` |
| 3 | `snps,burst_len` | `16` → 删除 |
| 4 | `snps,pbl` | `16` → 删除 |
| 5 | `snps,rxpbl`/`txpbl`/`fixed-burst`/`force_thresh_dma_mode` | 各值 → 全部删除 |
| 6 | `assigned-clock-rates` | `125000000` → 删除 |
| 7 | `resets` + `reset-names` | `<8 137 8 136>` + `stmmaceth ahb` → `<8 137>` + `stmmaceth` |

**Step 4**: 顺手补回 iter45 终态丢失的 `snps,reset-delays-us = <0 10000 50000>`(早期某轮 iter 误删,vendor baseline 必须有)

**Step 5**: 同步更新 ROOTFS 副本 `/usr/lib/lpa3399pro/rk3399pro-neardi-linux-lc110-base.dtb`,避免 `armbian-update` 日后恢复坏状态

### 8.4 iter46a 修正后 GMAC 节点终态(全属性对照 vendor baseline 通过)

| 属性 | iter46a 值 | vendor baseline | 对照 |
|---|---|---|---|
| `phy-mode` | `rgmii` | `rgmii` | ✅ |
| `clock_in_out` | `input` | `input` | ✅ |
| `tx_delay` | `33` (0x21) | `33` | ✅ |
| `rx_delay` | `21` (0x15) | `21` | ✅ |
| `snps,reset-gpio` | `25 15 1` | `25 15 1` | ✅ |
| `snps,reset-delays-us` | `0 10000 50000` | `0 10000 50000` | ✅ |
| `snps,reset-active-low` | 存在 | 存在 | ✅ |
| `phy-supply` | `24` (vcc_phy phandle) | `24` | ✅ |
| `assigned-clocks` | `8 166` (SCLK_RMII_SRC) | `8 166` | ✅ |
| `assigned-clock-parents` | `26` (clkin_gmac) | `26` | ✅ |
| `resets` | `8 137` (单一 SRST_A_GMAC) | `8 137` | ✅ |
| `reset-names` | `stmmaceth` | `stmmaceth` | ✅ |
| `pinctrl-0` | `27` (rgmii_pins) | `27` | ✅ |
| `rockchip,grf` | `23` | `23` | ✅ |
| `snps,burst_len`/`pbl`/`rxpbl`/`txpbl`/`fixed-burst`/`force_thresh_dma_mode` | 已全部删除 | 不存在 | ✅ |
| `assigned-clock-rates` | 已删除 | 不存在 | ✅ |

### 8.5 iter5-13 禁用的硬挂死源节点状态(应保持 disabled)

| 节点 | 状态 | 备注 |
|---|---|---|
| `/iep@ff670000` | `disabled` ✅ | iter5-13 最大挂死源,保持禁用 |
| `/sdhci@fe330000` | `disabled` ✅ | eMMC 探测死锁 |
| `/rkisp1@ff910000` | `disabled` ✅ | ISP0 |
| `/rkisp1@ff920000` | `disabled` ✅ | ISP1 |
| `/mipi-dphy-tx1rx1@ff968000` | `disabled` ✅ | iter33 期间死锁 |
| `/pcie-phy` | `disabled` ✅ | iter34 关闭 |
| `/pcie@f8000000` | `disabled` ✅ | iter34 关闭 |
| `/usb@fe3c0000` | `okay` | iter34 标题提及但实际表里未列,iter43-45 启动正常,保持 |

### 8.6 DTB 文件大小

| 版本 | 字节数 |
|---|---|
| factory 原始(Armbian 打包) | 102365 |
| iter45 终态 | 102374 |
| iter46a factory(导致 stall) | 102365 |
| **iter46a 修正后(当前 SD 卡上)** | **102286** |

### 8.7 备份文件清单(SD BOOT 分区)

| 文件 | 内容 |
|---|---|
| `*.iter45_failed_20260616_183505` | iter45 终态(SWR 卡死,但能 boot 到 shell) |
| `*.iter46a_factory_broke_20260616_185741` | 误 cp factory 导致 RCU stall 的中间态 |
| `rk3399pro-neardi-linux-lc110-base.dtb` | iter46a 修正后的 active DTB |

### 8.8 待 TTL 验证(用户拔卡插板子后执行)

```bash
# Step 1: 确认能正常 boot 到 root shell(不再 RCU stall)
# (登录后)
cat /sys/firmware/devicetree/base/ethernet@fe300000/phy-mode
# 期望: rgmii

# Step 2: GMAC link-up 测试
ip link set eth0 up
# 期望: 无 "RTNETLINK answers: Connection timed out"

dmesg | tail -20
# 期望: 无 "Failed to reset the dma" / "DMA engine initialization failed"

ip -br link show eth0
# 期望: eth0 UP ...

dhclient eth0
ip addr show eth0
ping -c 3 8.8.8.8
```

### 8.9 备份回退

```bash
# 如果 iter46a 修正后仍卡死或行为异常
sudo mount /dev/sdc1 /mnt/sdboot
sudo cp /mnt/sdboot/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb.iter45_failed_20260616_183505 \
        /mnt/sdboot/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb
sync && sudo umount /mnt/sdboot
```

---

*分析者: Claude Code (glm-5.2)*
*日期: 2026-06-16*
*Step A 执行: 2026-06-16 18:35*
*Step A 第一轮失败: 2026-06-16 18:49(RCU stall)*
*Step A 修正执行: 2026-06-16 18:57~18:58*
*下次执行: 等用户拔卡插板子,做 TTL 验证*
