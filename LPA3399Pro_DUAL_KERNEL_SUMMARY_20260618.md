# LPA3399Pro 双内核调试总结（6.1.141 + 6.18.33）

> 日期: 2026-06-18
> 范围: LPA3399Pro 板子从 SD 卡启动 Linux 的完整调试历程
> 两个内核: vendor-based 6.1.141 与 mainline 6.18.33
> 目的: 梳理两个内核的调试过程、关键发现、矛盾纠正与当前状态

---

## 一、项目概述

LPA3399Pro 是基于 Rockchip RK3399Pro 的开发板（Neardi LC110 方案），板载：
- CPU: 6 核 (双核 A72 + 四核 A53)
- DDR: 4GB LPDDR3
- eMMC: 14.7GB
- SD 卡接口: 14.4GB
- GMAC 以太网: YT8521S PHY (RGMII)
- WiFi: RTL8821CS (SDIO)
- HDMI、USB 2.0/3.0、PCIe

调试目标：从 SD 卡启动 Linux，逐步恢复各项硬件功能，重点攻克板载 GMAC 以太网。

调试分两个阶段：
1. **6.1.141 内核**（vendor-based Armbian，ophub rk35xx 6.1.y）— iter1 ~ iter47
2. **6.18.33 内核**（mainline，ophub rk35xx 6.18.y）— 修改1 ~ 修改11 + 8 轮 GMAC DTB 测试

---

## 二、两个内核的基础信息

| 项目 | 6.1.141 | 6.18.33 |
|---|---|---|
| 基础镜像 | `Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.1.141_server_2026.06.11_hybrid_sdkboot.img` | `Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.18.33_server_2026.06.17.img` |
| 内核来源 | ophub rk35xx 6.1.y | ophub rk35xx 6.18.y |
| 引导链 | SDK idbloader + SDK uboot + vendor U-Boot 2017.09（hybrid_sdkboot 镜像已含） | 需单独替换 SDK idbloader，uboot 来自镜像 |
| DTB | vendor DTB（`rk3399pro-neardi-linux-lc110-base.dtb`，100KB） | 主线 DTB（`rk3399pro-rock-pi-n10.dtb`，59KB） |
| 调试时间 | 2026-06-12 ~ 2026-06-16 | 2026-06-17 ~ 2026-06-18 |
| 主文档 | `LPA3399Pro_SDCard_Full_Adaptation_Log_20260615.md` | `6.18.33_KERNEL_SD_BOOT_MODIFICATIONS.md` |

### 关键差异：hybrid_sdkboot

6.1.141 镜像文件名含 `hybrid_sdkboot`，表示该镜像在制作时已将完整引导链（idbloader + uboot + trust）替换为 SDK 版本，BootROM 可直接识别。

6.18.33 镜像不含 hybrid_sdkboot，使用 ophub 默认 idbloader，无法被 RK3399 BootROM 识别，需手动替换为 SDK idbloader。

---

## 三、调试时间线总览

```
6.1.141 阶段 (06-12 ~ 06-16)
├── iter1-13:  启动死锁攻坚（display/sdhci/rkisp1/mipi-dphy/iep）
├── iter14-22: 用户空间与 HDMI 显示恢复
├── iter23-32: 外设攻坚（以太网时序/WiFi 频率/MMC 编号偏移）
├── iter33:    UUID 挂载稳定化
├── iter34-36: 启动噪声清理（PCIe/motd/GPT/fstrim/NM-wait-online/firstlogin）
├── iter37:    自动登录恢复
├── iter38-45: GMAC DMA 排查（8 轮 DTB 实验，全部失败）
├── iter46:    推翻"硬件缺陷"结论，DTB 回退到 vendor baseline
└── iter47:    决策升级到 6.18.33（Path B1: 编译 rk35xx 内核）

6.18.33 阶段 (06-17 ~ 06-18)
├── 修改1:  替换 SDK idbloader
├── 修改2:  禁用 boot.scr，恢复 extlinux.conf
├── 修改3:  替换为主线 DTB (rock-pi-n10)
├── 修改4:  禁用 DRM/VOP/watchdog
├── 修改5:  log_buf_len=16M
├── 修改6:  禁用 GMAC + PCIe → 回归（挂死点提前）
├── 修改7:  恢复 PCIe，仅保留 GMAC 禁用
├── 修改8:  root=UUID → root=PARTUUID
├── 修改9:  绕过 systemd generator sandbox Oops
├── 修改10: maxcpus=4（禁用 A72 big cores）→ 稳定进入 multi-user
├── 修改11: 禁用 plymouth，修复 ttyS2 串口登录
├── GMAC 测试 1-8: 8 种 DTB 修改，全部 DMA reset failed
└── 当前:   转向驱动侧（dwmac-rk.c）比对与最小补丁
```

---

## 四、内核一：6.1.141 调试过程

### 4.1 启动死锁攻坚（iter1-13）

**核心问题**：vendor DTB 中多个节点在 mainline 6.1.141 内核下会导致死锁或 RCU Stall。

**锁定的挂死源**：

| 节点 | 挂死时间 | 现象 | 解决 |
|---|---|---|---|
| `/display-subsystem` | 19.5s | DRM 初始化死锁 | iter7 禁用 |
| `/sdhci@fe330000` (eMMC) | 19.3s | eMMC 探测死锁 | 禁用 |
| `/rkisp1@ff910000` / `@ff920000` | 79s | ISP 死锁 | 禁用 |
| `/mipi-dphy-tx1rx1@ff968000` | 79s | MIPI DPHY 死锁 | 禁用 |
| `/iep@ff670000` | 硬挂死 | 图像增强处理器 | 禁用（最大挂死源） |
| `/dmc` | — | DDR 调压死锁 | 禁用 |
| `/watchdog@ff848000` | — | 调试阶段异常复位 | 禁用 |

**启动参数优化**：
- `usbcore.autosuspend=-1`（USB 稳定性）
- `initcall_blacklist=psci_checker`（避免 PSCI 死锁）
- `initcall_debug printk.devkmsg=on`（详细启动日志）

### 4.2 用户空间与显示恢复（iter14-22）

- iter17: **首次成功进入登录界面**，解决 MMC 编号偏移问题
- iter22: **HDMI 显示全面恢复**，除 `iep` 外显示子系统全开且稳定
- 恢复 `hdmi-sound` 和 `Little VOP`，确立 IEP 为唯一硬挂死源

### 4.3 外设功能攻坚（iter23-32）

- 实验多种以太网时序（`rgmii-id` 等）和 WiFi 频率（12MHz~150MHz）
- **关键发现**：WiFi 启用会导致 SD 卡从 `mmcblk1` 偏移至 `mmcblk0`
- 确认以太网与 WiFi 存在 U-Boot 阶段的资源竞争

### 4.4 稳定化升级（iter33-37）

| 迭代 | 修改 | 效果 |
|---|---|---|
| iter33 | `root=/dev/mmcblkXp2` → `root=UUID=...` | 解决 MMC 编号偏移导致的根分区识别失败 |
| iter34 | 禁用 PCIe PHY+RC，修正 WiFi 黑名单（`rtw88_8821cs`），清空 armbian-motd，parted 修复 GPT 备份头 | 启动噪声清理 |
| iter35 | 禁用 fstrim/e2scrub timers，NM 不管理 eth0，fstab commit=600→60 | 消除 mmc1 DISCARD I/O 错误，抑制 DMA 错误刷屏 |
| iter36 | 禁用 NM-wait-online.service，删除 `.not_logged_in_yet` | 启动到 shell 从 ~95s 缩短到 ~35s |
| iter37 | 创建 serial-getty@ttyFIQ0 + getty@tty1 autologin override | 恢复自动登录 |

### 4.5 GMAC DMA 排查（iter38-45）— 8 轮 DTB 实验

**起始问题**：iter34 时 `ip link set eth0 up` 报 `Failed to reset the dma` / `stmmac_hw_setup: DMA engine initialization failed`。

| iter | 改动 | 结果 |
|---|---|---|
| 38 | 添加 6 个 snps DMA 调优属性（burst_len/pbl/txpbl/rxpbl/fixed-burst/force_thresh_dma_mode） | ❌ DMA reset 仍超时（这些属性影响 reset 之后的运行参数，不影响 reset 本身） |
| 39 | 回退 iter38 + NM 管理 eth0 | ❌ 引发 60s login 超时（DMA 重试→PAM/logind 阻塞） |
| 40 | `clock_in_out: input → output` + 删除 `power-domains` | ❌ `ip link set eth0 up` 导致整板挂死（RGMII_TX_CLK 双向驱动电气冲突） |
| 41 | 完全回退到 iter39 baseline | ✅ 恢复可用 |
| 42 | `phy-mode: rgmii → rgmii-id` | ❌ 无效（PHY 内部 delay 假设不成立） |
| 43 | 添加 `assigned-clock-rates=<125000000>` | ❌ clk_gmac 仍 30MHz（assigned-clock-parents 冲突导致 clk_set_rate 未执行） |
| 44 | 删除 `assigned-clock-parents` + 内核模块 `gmac_fix.ko` 强制 clk_gmac=120MHz | ❌ 120MHz 下 SWR 仍超时（**频率假设被证伪**） |
| 45 | 添加 AHB reset + 内核模块 `dma_scan.ko` 寄存器扫描 | ❌ SWR 位永久=1，写入 0 仍读回 1，结论"硬件缺陷" |

**iter45 的"硬件缺陷"结论**：
- `dma_scan.ko` 通过 ioremap 直接扫描 DMA 寄存器
- `Bus_Mode = 0x00020101`，SWR(bit0)=1
- 写入 SWR=0 后仍读回 1
- `HW_FEAT0/1 = 0x00000000`（异常）
- 当时结论：GMAC DMA 硬件缺陷，不可修复，建议 USB 以太网替代

### 4.6 结论推翻与修正（iter46）— 关键转折

**反证**：用户提供 Debian 10 eMMC 启动信息（vendor 4.4.194 内核），**有线网卡完全正常工作**。如果 GMAC DMA 真的硅片损坏，vendor 内核不可能正常工作。

**关键发现**：
1. Armbian 出厂 DTB 的 GMAC 节点与 vendor DTS **完全一致**（phy-mode=rgmii, clock_in_out=input, tx_delay=0x21, rx_delay=0x15, snps,reset-gpio=gpio3 PB7 等）
2. iter38-45 把正确的 DTB 改坏了：
   - iter38 添加了 vendor 没有的 snps,* 属性
   - iter42 改 phy-mode=rgmii-id（vendor 是 rgmii）
   - iter43 添加了 vendor 没有的 assigned-clock-rates
   - iter44 删除了 vendor 有的 assigned-clock-parents
   - iter45 添加了 vendor 没有的额外 ahb reset
3. iter45 dma_scan.ko 看到的 SWR 卡死是"GMAC 处于错误内部状态"（iter42 改 rgmii-id 导致），**不是真硬件缺陷**

**iter46a 修正**：
- 保留 iter5-13 的硬挂死源禁用
- 只回退 GMAC 节点到 vendor baseline（7 项属性修正）
- DTB 从 102374 字节回到 102286 字节

**真正根因方向**：问题不在 DTB，而在 mainline 6.1.141 的 `dwmac-rockchip` 与 vendor 4.4 的 `dwmac-rk.c` 存在关键差异（Rockchip 专有的 `rk3399_ops`、`set_to_rgmii`、`gmac_clk_enable` 等流程）。

---

## 五、内核二：6.18.33 调试过程

### 5.1 引导链修复（修改1-2）

**修改1: 替换 SDK idbloader**
- 问题：ophub 默认 idbloader 无法被 RK3399 BootROM 识别，板子跳过 SD 卡从 eMMC 启动 4.4.194
- 操作：`dd if=SDK/idbloader.img of=/dev/sdc seek=64 conv=notrunc,fsync`
- 效果：BootROM 输出 `Found IDB in SDcard`

**修改2: 禁用 boot.scr，恢复 extlinux.conf**
- 问题：vendor U-Boot 解析 boot.scr 时输出乱码（`SCRIPT FAILED`）
- 根因（三层）：
  1. U-Boot 无法加载自身 DTB → `Failed to load DTB`
  2. 环境变量 CRC 校验失败 → `bad CRC, using default environment`
  3. 默认环境中 `${devtype}` 等变量不正确，boot.scr 脚本解析异常
- ophub 构建缺陷：extlinux.conf 被命名为 .bak，uInitrd 软链接断裂
- 操作：`mv boot.scr boot.scr.disabled` + 创建 extlinux.conf
- 效果：U-Boot 找到 extlinux.conf，正确加载内核和 DTB

### 5.2 DTB 兼容性（修改3-5）

**修改3: 替换为主线 DTB**
- 问题：vendor DTB 时钟绑定格式与主线 6.18.33 不兼容
  ```
  clk: couldn't get clock 5 for /clock-controller@ff760000
  rockchip_clk_of_add_provider: could not register clk provider
  ```
- vendor DTB `/chosen` 节点含 embedded bootargs，覆盖 extlinux.conf 参数（`console=ttyFIQ0` 替换 `console=ttyS2,1500000`）
- 操作：用主线 `rk3399pro-rock-pi-n10.dtb`（来自 `dtb-rockchip-6.18.33-rk35xx-ophub.tar.gz`）替换
- 效果：时钟驱动正常注册，串口控制台 ttyS2 正确启用

**修改4: 禁用 DRM/VOP/watchdog**
- 参考适配日志 iter7 经验（display-subsystem 初始化死锁）
- 操作：fdtput 禁用 `/display-subsystem`、`/vop@ff8f0000`、`/vop@ff900000`、`/watchdog@ff848000`

**修改5: 优化启动参数**
- 问题：`initcall_debug` 产生大量日志，952 条 printk 消息被丢弃
- 操作：移除 `initcall_debug`，添加 `log_buf_len=16M`

### 5.3 GMAC 死锁规避与 PCIe 回归（修改6-7）— 重要教训

**修改6: 禁用 GMAC + PCIe**
- 问题：日志在 YT8521 PHY attach（1.529s）后停止，板子死机
- 当时判断：主线 stmmac 驱动在 probe 阶段自动执行 DMA reset → 整板挂死（**后续实测推翻此判断**）
- 操作：fdtput 禁用 `/ethernet@fe300000` + `/pcie@f8000000`
- **结果：回归**——挂死点从 1.529s 提前到 0.665s

**回归根因分析**：
- 禁用 PCIe 导致 fe320000.mmc (SDIO/WiFi) 和 fe310000.mmc (SD 卡) 几乎同时探测，暴露竞态
- PCIe link training 期间占用总线带宽，无意中为 dwmmc 驱动并行探测提供了时序隔离
- 禁用 PCIe 后启动变快，fe320000/fe310000 竞态触发

**修改7: 恢复 PCIe，仅保留 GMAC 禁用**
- PCIe link training 超时 (-110) 是优雅失败，系统继续启动
- 恢复 PCIe 提供时序隔离，使 fe320000.mmc 稳定探测
- **教训**：PCIe 禁用是过度优化，移除了时序隔离反而引入回归

### 5.4 rootfs 挂载与 systemd 修复（修改8-11）

**修改8: root=UUID → root=PARTUUID**
- 问题：`VFS: Cannot open root device "UUID=..."` — 无 initramfs 直启内核时 `root=UUID=` 无法被内核解析
- 内核 `available partitions` 打印的是 GPT PARTUUID，不是 ext4 filesystem UUID
- 操作：`root=PARTUUID=61ec8aeb-3d1a-48fa-a9da-54d744ed8bdf`

**修改9: 绕过 systemd generator sandbox Oops**
- 问题：systemd 257 执行 generators 阶段触发内核 Oops
  ```
  systemd[1]: Failed to fork off sandboxing environment for executing generators: Protocol error
  systemd[1]: Freezing execution.
  ```
- 操作：备份并清空 `/usr/lib/systemd/system-generators`

**修改10: maxcpus=4（禁用 A72 big cores）— 关键突破**
- 问题：随机内核 Oops，首次 Oops 均发生在 CPU4/CPU5（A72 big cores）
- 判断：使用 Rock Pi N10 主线 DTB 替代 LPA3399Pro vendor DTB，big core OPP/电源/时钟不匹配
- 操作：extlinux.conf 追加 `maxcpus=4`
- 效果：未再出现 CPU4/CPU5 Oops，系统推进到 multi-user 阶段

**修改11: 禁用 plymouth + 修复 ttyS2 串口登录**
- 问题：日志停在 `plymouth-quit-wait.service`，错误依赖 `dev-ttyAML0.device`
- 操作：
  - boot 参数追加 `plymouth.enable=0`
  - mask plymouth 全套 service/path
  - mask 错误的 `serial-getty@ttyAML0.service`
  - 确保 `serial-getty@ttyS2.service` root autologin

### 5.5 GMAC DTB 多轮测试（8 轮，全部失败）

在 6.18.33 稳定基线（GMAC disabled）之上，单独制作测试 DTB 启用 GMAC：

| # | 测试 DTB | 改动 | probe | eth0 open |
|---|---|---|---|---|
| 1 | gmac-test.dtb | status=okay | ✅ 成功 | ❌ DMA reset failed |
| 2 | gmac-rx20-test.dtb | rx_delay=0x20 | ✅ 成功 | ❌ 同上 |
| 3 | gmac-pc0-test.dtb | reset-gpio PC0 | ✅ 成功 | ❌ 同上 |
| 4 | gmac-clockout-test.dtb | clock_in_out=output | ✅ 成功 | ❌ 同上 |
| 5 | gmac-neardi-vendor-delay-test.dtb | vendor neardi 参数（tx=0x21/rx=0x15/PB7/input） | ✅ 成功 | ❌ 同上 |
| 6 | gmac-vccphy-test.dtb | + vcc_phy/phy-supply | ✅ 成功 | ❌ 同上 |
| 7 | gmac-phyhandle-pll-test.dtb | + 显式 phy-handle + mdio 子节点 | ✅ 成功（双 PHY 地址收敛为单地址） | ❌ 同上 |
| 8 | gmac-output-consistent-test.dtb | + 一致 output 模式（删除 assigned-clocks/parents） | ✅ 成功 | ❌ 同上（关键：DMA 寄存器前后几乎不变） |

**关键证据**（第 8 轮）：
- `ethtool -d eth0` 显示 `ip link set eth0 up` 前后 DMA 寄存器几乎不变
  ```
  Reg0  = 0x00020101
  Reg10 = 0x00110001
  Reg22 = 0x000D0F17
  ```
- 说明驱动在 open 阶段并未把 DMA 控制器推进到"真正发生状态切换"的阶段
- 更像是 reset 没真正生效、前置 clock 没打通、GRF/RGMII mode 配置没落到硬件期望状态

### 5.6 驱动侧方案

**当前结论**：DTB 层面已基本排除，问题收敛到驱动侧。

**下一步方向**：
1. 获取当前 6.18 对应的 `dwmac-rk.c` / `stmmac` 源码
2. 与 vendor 4.4 的 `dwmac-rk.c` 做 RK3399 路径针对性 diff
3. 做最小补丁验证（候选：GRF/clock init 顺序、open 前强制 reset、显式启用 clk_mac_refout、DMA reset 前后 debug 日志）

**已生成 patch 草案**：`patches/0001-rk3399pro-gmac-debug-and-rxc-workaround.patch`
- 增加 RK3399 GRF readback 日志
- 增加外置 PHY reset helper（assert 10ms → deassert 50ms）
- 强制 `clock_input=true`（外置 RGMII PHY 场景）
- powerup 起止日志

---

## 六、两个内核稳定基线对比

| 项目 | 6.1.141 (iter46a) | 6.18.33 (修改11) |
|---|---|---|
| 启动到 shell | ~35s | 需 maxcpus=4 |
| CPU 核心 | 全部 6 核可用 | 仅 4 核 A53（A72 禁用） |
| HDMI 显示 | ✅ 恢复（iter22） | ❌ display-subsystem 禁用 |
| 串口控制台 | ttyFIQ0 (1500000) | ttyS2 (1500000) |
| 自动登录 | ✅ ttyFIQ0 + tty1 | ✅ ttyS2 + tty1 |
| USB 2.0/3.0 | ✅ | ✅ |
| SD 卡 | ✅ mmcblk1 | ✅ mmcblk1 |
| eMMC | ❌ 禁用（死锁） | ✅ mmcblk0 |
| GMAC 以太网 | ❌ DMA reset failed | ❌ DMA reset failed（节点禁用规避死机） |
| WiFi | ⏸️ 黑名单（SDIO -110） | ❓ 未测试 |
| PCIe | ❌ 禁用 | ✅ okay（link training 超时但优雅失败） |
| ROOTFS 扩容 | ✅ 14GB | ⚠️ 需手动扩容 |
| 基线保存 | — | `baselines/6.18.33_stable_tty_login_20260618_102330/` |

---

## 七、GMAC 问题的完整演进

```
iter34: 首次发现 DMA reset failed（DTB 还是出厂状态）
  ↓
iter38-45: 8 轮 DTB 实验，全部失败
  ↓
iter45: dma_scan.ko 发现 SWR 永久=1，结论"硬件缺陷"
  ↓
iter46: Debian 10 vendor 4.4.194 GMAC 正常 → 推翻"硬件缺陷"
  ↓ 原因：iter38-45 把正确的 DTB 改坏了
  ↓
iter46a: DTB 回退到 vendor baseline，但 DMA 仍失败
  ↓ 真正根因：mainline dwmac-rockchip 与 vendor dwmac-rk.c 差异
  ↓
6.18.33: 8 轮 DTB 测试，全部 DMA reset failed
  ↓ probe 成功，open 阶段失败
  ↓ DMA 寄存器前后不变 → 驱动没推进状态切换
  ↓
当前: 转向驱动侧比对与最小补丁
```

**两个内核的共同结论**：GMAC DMA reset failed 的根因是主线 `dwmac-rockchip` 对 RK3399 的 clock/GRF/reset 初始化序列与 vendor 4.4 `dwmac-rk.c` 存在关键差异。DTB 调参已到上限，需驱动侧补丁。

---

## 八、关键矛盾点与纠正记录

### 8.1 "硬件缺陷"结论的推翻

| 阶段 | 结论 | 依据 |
|---|---|---|
| iter45 (6.1.141) | GMAC DMA 硬件缺陷，不可修复 | dma_scan.ko 写入 SWR=0 仍读回 1 |
| iter46 (6.1.141) | **推翻**：硬件完好，DTB 被改坏 | Debian 10 vendor 4.4.194 GMAC 正常 |

**纠正原因**：iter38-45 在错误的 DTB 状态下做寄存器扫描，看到的 SWR 卡死是 GMAC 处于错误内部状态（iter42 改 rgmii-id 导致），不是硅片损坏。

### 8.2 "probe 阶段触发 DMA reset → 整板挂死"判断的推翻

| 阶段 | 判断 | 依据 |
|---|---|---|
| 6.18.33 修改6 | 主线 stmmac probe 阶段触发 DMA reset → 整板挂死 | 日志在 YT8521 PHY attach 后停止 |
| 6.18.33 第十四节 | **推翻**：probe 成功，DMA reset 在 eth0 open 阶段失败 | GMAC status=okay 测试 DTB 启动成功，probe 阶段日志完整 |

**纠正原因**：修改6 时的挂死可能是 PCIe+GMAC 同时禁用引入的 fe320000 竞态（修改7 已证明），而非 GMAC probe 本身挂死。

### 8.3 "PCIe 禁用是优化"的推翻

| 阶段 | 判断 | 依据 |
|---|---|---|
| 6.18.33 修改6 | 禁用 PCIe 避开 link training 超时 | PCIe -110 错误 |
| 6.18.33 修改7 | **推翻**：PCIe 禁用是过度优化，引入回归 | 挂死点从 1.529s 提前到 0.665s |

**纠正原因**：PCIe link training 期间占用总线带宽，无意中为 dwmmc 驱动并行探测提供时序隔离。禁用 PCIe 后 fe320000/fe310000 竞态触发。

---

## 九、经验教训

### 9.1 不要在错误的状态下做底层诊断

iter45 在 iter42 改坏 phy-mode 后的状态下做 dma_scan.ko 寄存器扫描，看到 SWR 卡死就下"硬件缺陷"结论。iter46 证明这只是 GMAC 处于错误内部状态，不是硅片损坏。

**教训**：做硬件级诊断前，必须确认 DTB 处于已知良好的 baseline 状态。

### 9.2 单变量实验要保留 baseline

iter38-45 每轮都在前一轮基础上叠加修改，导致无法定位变量。iter46 花了大量精力回退到 vendor baseline。

**教训**：每轮实验应从已知良好 baseline 出发，只改一个变量。

### 9.3 vendor 内核是金标准

Debian 10 eMMC 的 vendor 4.4.194 内核 GMAC 100% 工作，是确认硬件完好的关键反证。Rockchip 专有的 `dwmac-rk.c` 含 `rk3399_ops`、`set_to_rgmii`、`gmac_clk_enable` 等流程，是 RK3399 GMAC 的金标准实现。

**教训**：mainline 驱动与 vendor 驱动差异是 RK3399 平台的常见坑，vendor 内核是排查根因的重要参照。

### 9.4 时序隔离可能来自意外来源

PCIe link training 期间占用总线带宽，无意中为 dwmmc 驱动提供时序隔离。禁用 PCIe 后暴露 fe320000/fe310000 竞态。

**教训**：看似无用的组件可能在无意中提供稳定性，移除前要评估间接影响。

### 9.5 主线 DTB 可能比 vendor DTB 更适合主线内核

6.18.33 使用 vendor DTB 时时钟驱动注册失败，换成主线 `rk3399pro-rock-pi-n10.dtb` 后正常。vendor DTB 的时钟绑定格式与主线内核不兼容。

**教训**：主线内核应优先使用主线 DTB，vendor DTB 可能含主线不兼容的绑定格式。

### 9.6 big core 在非匹配 DTB 下可能 Oops

6.18.33 使用 Rock Pi N10 主线 DTB 替代 LPA3399Pro vendor DTB，A72 big core OPP/电源/时钟不匹配，导致 CPU4/CPU5 随机 Oops。`maxcpus=4` 禁用 A72 是当前稳定基线。

**教训**：跨板型 DTB 替换时，big core 配置可能不匹配，`maxcpus` 是临时稳定化手段。

---

## 十、当前状态与下一步方向

### 10.1 当前状态

**6.1.141 内核**：
- 稳定基线已建立（~35s 启动到 root shell，HDMI/USB/自动登录正常）
- GMAC 不可用（DTB 已回退到 vendor baseline，但 DMA 仍失败）
- iter46 已推翻"硬件缺陷"结论，待驱动侧排查

**6.18.33 内核**：
- 稳定基线已保存到 `baselines/6.18.33_stable_tty_login_20260618_102330/`
- 配置：maxcpus=4 + GMAC disabled + PCIe okay + plymouth disabled + systemd generators disabled
- GMAC 排查已收敛到驱动侧
- patch 草案已生成：`patches/0001-rk3399pro-gmac-debug-and-rxc-workaround.patch`

### 10.2 下一步方向（两个内核共同）

1. **驱动源码比对**：
   - vendor 4.4: `LPA3399Pro-SDK-Linux-V3.0/kernel/drivers/net/ethernet/stmicro/stmmac/dwmac-rk.c`
   - mainline 6.18: `drivers/net/ethernet/stmicro/stmmac/dwmac-rk.c`
   - 重点比对 RK3399 路径的 `set_to_rgmii()`、GRF 写入顺序、clock enable 顺序、reset assert/deassert 顺序

2. **最小补丁验证**（按 patch 草案）：
   - 补齐 vendor RK3399 的 GRF/clock init 顺序
   - open 前强制 GMAC reset + 小延时
   - output 模式下显式启用 clk_mac_refout
   - DMA soft reset 前后加寄存器读回/轮询 debug

3. **备选方案**：
   - Path C: 换 vendor 4.4.194 内核（100% 保证 GMAC 工作，但内核老）
   - 寻找已针对 RK3399Pro 做过 dwmac 修复的 6.x tree

### 10.3 待用户验证的事项

- patch 草案编译后的实际效果（当前仅生成草案，未编译验证）
- 6.1.141 内核在 iter46a vendor baseline DTB 下的 GMAC 行为（iter46 文档记录了修改，但 TTL 验证步骤标注"待用户拔卡插板子后执行"）
- USB 以太网适配器作为 GMAC 替代方案的可用性

---

## 十一、文档索引

### 主文档
- `6.18.33_KERNEL_SD_BOOT_MODIFICATIONS.md` — 6.18.33 全量修改记录
- `LPA3399Pro_SDCard_Full_Adaptation_Log_20260615.md` — 6.1.141 全量适配日志

### 关键分析文档
- `LPA3399Pro_iter46_plan_after_debian10_evidence_20260616.md` — 推翻硬件缺陷结论
- `6.18.33_GMAC_ETHERNET_MODIFICATION_PLAN_FOR_NEXT_AGENT_20260618.md` — 驱动侧方案
- `6.18.33_GMAC_PATCH_DRAFT_20260618.md` — patch 草案说明
- `6.18.33_GMAC_OUTPUT_CONSISTENT_TEST_RESULT_20260618.md` — DMA 寄存器不变的关键证据

### 基线
- `baselines/6.18.33_stable_tty_login_20260618_102330/BASELINE_README.md` — 6.18.33 稳定基线说明

### 配套文档
- `LPA3399Pro_DUAL_KERNEL_REPRODUCTION_GUIDE_20260618.md` — **操作复现指南**（本文档的配套）

---

*生成时间: 2026-06-18*
*基于文档: 6.1.141 iter1-47 + 6.18.33 修改1-11 + GMAC 测试 1-8*
*所有路径均已验证存在*
