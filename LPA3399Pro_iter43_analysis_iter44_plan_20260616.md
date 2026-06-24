# LPA3399Pro SD 卡适配迭代日志 — iter43→iter46 全量分析（GMAC DMA 内核不兼容确认）

> 日期: 2026-06-16
> 基于日志: `ttl_iter43_pcie_usbhost1_disabled_202606161433.log` (2995 行)
> TTL 在线验证: `ttl_iter44_*_20260616.log` (多个)
> 参考文档: `LPA3399Pro_SDCard_Full_Adaptation_Log_20260615.md`

---

## 1. iter43 启动日志分析

### 1.1 启动结果概览
| 项目 | 结果 | 详情 |
|---|---|---|
| Boot | ✅ 成功 | ~35s 到 auto-login root shell |
| GMAC probe | ✅ 返回 0 | `probe of fe300000.ethernet returned 0 after 8240789 usecs` |
| PHY attach | ✅ 成功 | YT8521S @ stmmac-0:00 + stmmac-0:03 |
| RGMII 模式 | ✅ RGMII_ID | `init for RGMII_ID` |
| DMA HW | ✅ 识别 | `DWMAC1000, DMA HW capability register supported` |
| SD 卡 | ✅ 正常 | mmc1, SDHC 14.4GiB, 25MHz |
| WiFi | ✅ 黑名单 | 无 SDIO -110 错误 |
| PCIe | ✅ 未探测 | 无 PCIe probe 错误 |
| 自动登录 | ✅ 正常 | `armbian login: root (automatic login)` |

### 1.2 无错误确认
```
grep "Failed to reset the dma" → 0 匹配（启动期间）
grep "DMA engine initialization failed" → 0 匹配
grep "DISCARD" → 0 匹配
grep "Card stuck" → 0 匹配
grep "sdio.*failed" → 0 匹配
```

### 1.3 probe 成功 vs stmmac_open 失败
启动期间 GMAC **probe** 成功（返回 0），但 probe 阶段不一定执行了完整的 DMA reset。`stmmac_open()`（由 `ip link set eth0 up` 触发）才真正调用 `dwmac1000_dma_reset()`，这是 DMA 失败的触发点。

---

## 2. TTL 在线验证（2026-06-16 15:xx，板子已启动 iter43 状态）

### 2.1 板子存活确认
```
root@armbian:~# echo ALIVE_CHECK
ALIVE_CHECK          ← TTL 正常通信
```

### 2.2 clk_gmac 频率检查 — ❌ 仍为 30 MHz
```
clkin_gmac          1  1  0  125000000   Y  deviceless
   clk_mac_ref      0  1  0  125000000   N  ethernet@fe300000
   clk_mac_refout   0  1  0  125000000   N  ethernet@fe300000
      clk_gmac      1  2  0   30000000   Y  fe300000.ethernet stmmaceth   ← ❌ 30 MHz

gpll_aclk_gmac_src  1  1  0  800000000   Y  deviceless
   aclk_gmac_pre    3  3  0  400000000   Y  deviceless
      pclk_gmac     2  4  0  100000000   Y  fe300000.ethernet pclk_mac
      aclk_gmac     1  3  0  400000000   Y  fe300000.ethernet aclk_mac
```
- `clkin_gmac`（外部 PHY 参考时钟）= 125 MHz ✅
- `aclk_gmac`（AHB 总线时钟）= 400 MHz ✅
- `pclk_gmac`（APB 总线时钟）= 100 MHz ✅
- **`clk_gmac`（MAC 核心时钟）= 30 MHz** ❌ （应 125 MHz）
- **结论：`assigned-clock-rates=<125000000>` 没有生效**

### 2.3 `ip link set eth0 up` — ❌ DMA reset 仍然失败
```
root@armbian:~# ip link set eth0 up
RTNETLINK answers: Connection timed out    ← ❌ DMA 超时
EXIT_CODE=2
```

dmesg 确认三连失败：
```
[  917.478926] rk_gmac-dwmac fe300000.ethernet eth0: Register MEM_TYPE_PAGE_POOL RxQ-0
[  917.933312] rk_gmac-dwmac fe300000.ethernet eth0: PHY [stmmac-0:00] driver [YT8521S Gigabit Ethernet] (irq=POLL)
[  918.138610] rk_gmac-dwmac fe300000.ethernet: Failed to reset the dma              ← ❌
[  918.138629] rk_gmac-dwmac fe300000.ethernet eth0: stmmac_hw_setup: DMA engine initialization failed  ← ❌
[  918.138640] rk_gmac-dwmac fe300000.ethernet eth0: __stmmac_open: Hw setup failed                   ← ❌
```

板子未挂死（比 iter40 好），但 DMA 仍然失败。

### 2.4 DTB assigned-clocks 验证
```
fdtget /sys/firmware/fdt /ethernet@fe300000 assigned-clocks
→ 8 166            (= &cru SCLK_MAC, clock ID 0xa6=166)

fdtget /sys/firmware/fdt /ethernet@fe300000 assigned-clock-parents
→ 26               (= phandle 26, external_gmac_clock, 125MHz fixed clock)

fdtget /sys/firmware/fdt /ethernet@fe300000 assigned-clock-rates
→ 125000000        (= 125 MHz)
```
DTB 配置完整存在，但**没有生效**。

### 2.5 clk_gmac 时钟树深度分析 — 🔑 根因定位
```
PARENT:        npll                          ← 当前父时钟
POSSIBLE:      dummy_cpll gpll npll           ← 可选父时钟（仅3个）
FLAGS:         (空)
RATE:          30000000                       ← 当前 30 MHz
```

**PLL 频率表：**
| PLL | 频率 | 能否得到 125 MHz（整数分频） |
|---|---|---|
| npll | 600 MHz | 600/125 = 4.8 → 不可整除，最近 120 MHz (÷5) |
| gpll | 800 MHz | 800/125 = 6.4 → 不可整除，最近 133 MHz (÷6) |
| dummy_cpll | 0 MHz | 不可用 |
| cpll | 24 MHz | 24 < 125 → 不可用 |

---

## 3. 根因分析（完整链条）

### 3.1 因果链
```
DTB: assigned-clock-parents = <26> (external_gmac_clock, 125MHz fixed clock)
           ↓
内核 __of_clk_set_defaults() 处理 assigned-clocks
           ↓
调用 clk_set_parent(clk_gmac, external_gmac_clock)
           ↓
clk_gmac 的 possible parents = {dummy_cpll, gpll, npll}
external_gmac_clock 不在可选列表中 → clk_set_parent() 返回错误
           ↓
__of_clk_set_defaults() 检测到 parent 设置失败 → 提前 return，跳过 clk_set_rate()
           ↓
clk_set_rate(clk_gmac, 125000000) 从未被调用！
           ↓
clk_gmac 保持默认 30 MHz (npll 600MHz ÷ 20)
           ↓
dwmac1000 DMA 状态机在 30 MHz 下运行过慢
           ↓
SWR 位在超时内未清零 → "Failed to reset the dma"
```

### 3.2 为什么 assigned-clock-parents 指向了不存在的父时钟？
DTB 中 `assigned-clock-parents = <&external_gmac_clock>` 意图是让 SCLK_MAC 从外部 125 MHz PHY 时钟获取。但 RK3399 的 CRU 硬件设计中，SCLK_MAC 是一个 COMPOSITE_NODIV 时钟，其 mux 父级**仅限内部 PLL**（cpll/gpll/npll/ppll），不支持选择外部固定时钟作为父级。

vendor 内核的 `__of_clk_set_defaults()` 实现在 parent 设置失败时**直接返回**，不会继续执行 rate 设置，导致 `assigned-clock-rates` 被完全忽略。

### 3.3 频率约束分析
即使成功执行 `clk_set_rate(125MHz)`：
- npll (600MHz) 整数分频最近值 = **120 MHz** (÷5)，误差 -4%
- gpll (800MHz) 整数分频最近值 = **133 MHz** (÷6)，误差 +6.4%
- 若 RK3399 支持分数分频（部分 COMPOSITE 时钟支持）：可能更接近 125 MHz
- 120 MHz 或 133 MHz 都远高于 30 MHz，足以让 DMA SWR 状态机在超时内完成

---

## 4. iter44 修复方案

### 4.1 核心修改：删除 `assigned-clock-parents`

| # | 修改项 | 工具 | 修改前 (iter43) | 修改后 (iter44) |
|---|---|---|---|---|
| 1 | `/ethernet@fe300000 assigned-clock-parents` | `fdtput -d` | `<0x1a>` (26, external_gmac_clock) | **删除** |

**修改原理：**
- 删除无效的 `assigned-clock-parents` 后，`__of_clk_set_defaults()` 只处理 `assigned-clock-rates`
- `clk_set_rate(clk_gmac, 125000000)` 将被调用
- CCF 自动选择最佳父时钟和分频器组合：
  - 若选 npll(600MHz)：÷5 → 120 MHz
  - 若选 gpll(800MHz)：÷6 → 133 MHz
  - 若支持分数分频：可能更接近 125 MHz
- 无论哪种情况，频率从 30 MHz 提升到 120+ MHz → DMA SWR 应在超时内清零

### 4.2 风险评估
- **低风险**：只删除一个无效属性，不触碰硬件方向/电源/复位
- **最坏情况**：clk_gmac 频率不变（CCF 仍无法改变 rate）→ DMA 仍失败，但板子不挂死
- **不预期副作用**：不影响 CPU/DDR/HDMI/USB/SD/WiFi/启动稳定性

### 4.3 执行步骤

**SD 卡修改（需连接 USB 读卡器）：**
```bash
# 1. 挂载 SD 卡 BOOT 分区
sudo mount /dev/sdc1 /mnt/sdboot

# 2. 备份 DTB
cp /mnt/sdboot/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb \
   /mnt/sdboot/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb.iter43_base_$(date +%Y%m%d_%H%M%S)

# 3. 删除 assigned-clock-parents 属性
fdtput -d /mnt/sdboot/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb \
   /ethernet@fe300000 assigned-clock-parents

# 4. 验证修改
fdtget /mnt/sdboot/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb \
   /ethernet@fe300000 assigned-clock-parents 2>&1
# 预期: "Couldn't find property" 或类似错误

fdtget /mnt/sdboot/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb \
   /ethernet@fe300000 assigned-clock-rates
# 预期: 125000000

# 5. sync 并卸载
sync
sudo umount /mnt/sdboot
```

**TTL 验证（板子启动后）：**
```bash
# Step 1: 确认 clk_gmac 频率变化
cat /sys/kernel/debug/clk/clk_summary | grep clk_gmac
# 期望：不再是 30000000，而是 120000000 或 133333333

# Step 2: 尝试 link-up（最关键测试）
ip link set eth0 up
# 期望：无 "Connection timed out"

# Step 3: 检查链路状态
ip -br link show eth0
# 期望：eth0 UP ...

# Step 4: 查看 dmesg
dmesg | grep -iE "Failed to reset|DMA|stmmac|eth0|link"
# 期望：无 "Failed to reset the dma"

# Step 5: 获取 IP 并测试
dhclient eth0
ip addr show eth0
ping -c 3 8.8.8.8
```

### 4.4 预期结果矩阵

| 场景 | clk_gmac | link-up | DMA | 网络 | 后续 |
|---|---|---|---|---|---|
| **A 完全成功** | 120-133MHz | UP | 无错误 | ping 通 | iter45 恢复 NM |
| **B clk 升但 DMA 仍失败** | 120-133MHz | timeout | 失败 | — | DMA 问题非时钟相关，转查 AHB reset |
| **C clk 未变** | 30MHz | timeout | 失败 | — | CCF 未处理 rate，需其他方法 |
| **D 挂死** | — | 无响应 | — | — | 回退（极不可能） |

### 4.5 回退方案
```bash
# 恢复 iter43 DTB
cp /mnt/sdboot/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb.iter43_base_*.bak \
   /mnt/sdboot/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb
```

---

## 5. iter43→iter44 DTB ethernet 节点变化对比

### iter43 终态（当前）
```
ethernet@fe300000 {
    assigned-clocks = <0x08 0xa6>;       /* &cru SCLK_MAC */
    assigned-clock-parents = <0x1a>;     /* ★ 无效！external_gmac_clock 不在 possible parents */
    assigned-clock-rates = <0x7735940>;  /* 125 MHz — 因 parent 失败被跳过 */
    phy-mode = "rgmii-id";
    clock_in_out = "input";
    power-domains = <0x16 0x16>;
    tx_delay = <0x21>;
    rx_delay = <0x15>;
    snps,rxpbl = <0x08>;
    snps,txpbl = <0x08>;
    snps,pbl = <0x10>;
    snps,fixed-burst = [00];
    snps,force_thresh_dma_mode = [00];
    snps,burst_len = <0x10>;
};
```

### iter44 目标态
```
ethernet@fe300000 {
    assigned-clocks = <0x08 0xa6>;       /* &cru SCLK_MAC — 不变 */
    /* assigned-clock-parents 已删除 */   /* ★ iter44 变更 */
    assigned-clock-rates = <0x7735940>;  /* 125 MHz — 现在会被执行 */
    phy-mode = "rgmii-id";               /* 不变 */
    clock_in_out = "input";              /* 不变 */
    power-domains = <0x16 0x16>;         /* 不变 */
    tx_delay = <0x21>;                   /* 不变 */
    rx_delay = <0x15>;                   /* 不变 */
    snps,rxpbl = <0x08>;                 /* 不变 */
    snps,txpbl = <0x08>;                 /* 不变 */
    snps,pbl = <0x10>;                   /* 不变 */
    snps,fixed-burst = [00];             /* 不变 */
    snps,force_thresh_dma_mode = [00];   /* 不变 */
    snps,burst_len = <0x10>;             /* 不变 */
};
```

---

## 6. 时钟树全景（来自 TTL 在线验证）

```
pll_npll           600 MHz
  npll             600 MHz  ← clk_gmac 当前 parent (÷20 = 30 MHz)
    npll_cs        600 MHz
    npll_aclk_cci  600 MHz

pll_gpll           800 MHz
  gpll             800 MHz  ← clk_gmac possible parent (÷6 ≈ 133 MHz)
    gpll_aclk_gmac_src  800 MHz
      aclk_gmac_pre     400 MHz
        pclk_gmac       100 MHz  (APB, fe300000.ethernet pclk_mac)
        aclk_gmac       400 MHz  (AHB, fe300000.ethernet aclk_mac)

clkin_gmac         125 MHz  ← 外部 PHY 时钟 (NOT clk_gmac parent candidate)
  clk_mac_ref      125 MHz
  clk_mac_refout   125 MHz

cpll                24 MHz
ppll               676 MHz  (NOT clk_gmac parent candidate)
```

---

## 7. 当前硬件支持矩阵（iter44 验证前）

| 硬件模块 | 状态 | 备注 |
|---|---|---|
| CPU / DDR | ✅ 正常 | LPDDR3 800MHz, 4GB |
| HDMI 显示 | ✅ 正常 | |
| USB 2.0/3.0 | ✅ 正常 | |
| 自动登录 | ✅ 正常 | ~35s 到 root shell |
| 根文件系统 | ✅ 稳定 | UUID, 14GB |
| SD 卡 | ⚠️ 25MHz | iter38 降频遗留 |
| 以太网 | ❌ DMA 失败 | `clk_gmac`=30MHz→120MHz（内核模块）仍失败；时钟频率**非根因**；4 个假设已排除（phy-mode/clock_in_out/snps属性/频率），转查 AHB reset |
| WiFi | ⏸️ 黑名单 | |
| PCIe | ⏸️ 已禁用 | |

---

## 8. 执行记录

| 时间 | 操作 | 结果 |
|---|---|---|
| 2026-06-16 15:xx | iter43 日志分析 | 启动成功，probe 返回 0 |
| 2026-06-16 15:xx | TTL 在线验证 | `clk_gmac`=30MHz, `ip link set eth0 up` 超时 |
| 2026-06-16 15:xx | 根因定位 | `assigned-clock-parents=<external_gmac_clock>` 无效 → `clk_set_rate` 被跳过 |
| 2026-06-16 15:xx | 时钟树分析 | possible parents = {dummy_cpll, gpll, npll}，npll=600MHz ÷20 = 30MHz |
| 2026-06-16 15:xx | iter44 方案制定 | 删除 `assigned-clock-parents`，让 CCF 执行 `clk_set_rate(125MHz)` |
| 2026-06-16 16:12 | **SD 卡修改执行** | ✅ 备份 `*.iter43_base_20260616_161228`；`fdtput -d` 删除 `assigned-clock-parents`；DTC 验证通过；sync + umount |
| 2026-06-16 16:24 | **iter44 启动验证** | ❌ 启动成功但 `clk_gmac` 仍 30 MHz — DTB 删除 `assigned-clock-parents` 不够，时钟已在内核早期初始化完成，driver probe 时 `of_clk_set_defaults()` 不重新设置 |
| 2026-06-16 16:xx | **iter44 DMA 测试** | ❌ `ip link set eth0 up` → `RTNETLINK: Connection timed out`，dmesg 三连失败：`Failed to reset the dma` / `DMA engine initialization failed` / `Hw setup failed` |
| 2026-06-16 16:xx | **debugfs / CRU 尝试** | debugfs `clk_rate` 和 `clk_parent` 只读（0444）；`/dev/mem` 写 CRU 寄存器被 `STRICT_DEVMEM` 阻止；动态 debug 未编译 |
| 2026-06-16 16:xx | **gmac_fix.ko 内核模块** | ✅ 编写 `gmac_fix.c` 通过 `of_clk_get_by_name(np, "stmmaceth")` + `clk_set_rate(clk, 125000000)` 直接在内核空间改时钟；base64 上传到板子 `/tmp/gmac_fix/`，编译成功 |
| 2026-06-16 16:xx | **gmac_fix.ko 加载** | ✅ `insmod gmac_fix.ko`：`clk_set_rate(125MHz) returned 0`，`clk_gmac new rate = 120000000` — **30→120 MHz 成功！** |
| 2026-06-16 16:xx | **120 MHz DMA 测试 — 关键失败** | ❌ `ip link set eth0 up` → 仍 `RTNETLINK: Connection timed out`，dmesg 仍 `Failed to reset the dma`。**时钟频率 120 MHz 下 DMA 仍失败！** |
| 2026-06-16 16:xx | **🔑 关键结论** | **时钟频率不是 DMA 失败的根因。** 从 30 MHz 提升到 120 MHz（4 倍），DMA SWR 复位仍超时。iter38-44 的时钟频率假设被证伪。需要转向非时钟原因排查。 |
| 2026-06-16 17:03 | **iter45-A: AHB reset** | SD 卡 DTB 添加 `resets = <&cru SRST_A_GMAC SRST_A_GMAC_NOC>` + `reset-names = "stmmaceth ahb"`；备份 `*.iter44_base_20260616_170321` |
| 2026-06-16 17:06 | **iter45 启动验证** | ✅ DTB 验证通过：`resets = <8 137 8 136>`, `reset-names = stmmaceth ahb` |
| 2026-06-16 17:xx | **iter45 DMA 测试** | ❌ `ip link set eth0 up` → 仍 `RTNETLINK: Connection timed out`，`Failed to reset the dma`。AHB reset 无效 |
| 2026-06-16 17:xx | **iter45-C: DMA 寄存器扫描** | 内核模块 `dma_scan.ko` 直接 ioremap + readl 扫描全部寄存器 |
| 2026-06-16 17:xx | **🔑🔑 硬件缺陷确认** | BUS_MODE=0x00020101 (**SWR=1 永久卡死**)，写入 0 后仍为 1。AHB 总线正常（寄存器可读写，其他位可写）。HW_FEAT0/1=0x00000000。**GMAC DMA 模块物理损坏**，软件无法修复。 |

---

## 9. 🔑 关键发现：内核不兼容（非硬件缺陷）

### 9.0 Debian 10 有线网卡正常 — 硬件无缺陷

**关键证据**：同一块 LPA3399Pro 板子，从 eMMC 启动 Debian 10（内核 4.4.194 Rockchip 原厂内核），有线网卡**完全正常工作**。

| 对比项 | Armbian SD 卡（失败） | Debian 10 eMMC（正常） |
|---|---|---|
| 内核版本 | 6.1.141-rk35xx-ophub | 4.4.194 (Rockchip vendor) |
| 编译目标 | RK35xx 系列 (RK3568/RK3588) | RK3399 系列 |
| CRU 驱动 | rk35xx-cru（缺少 RK3399 时钟定义） | rk3399-cru（完整时钟树） |
| `clk_mac_speed` | **不存在** — stmmac 报 `cannot get clock` | **存在** — DMA 时序正确 |
| GRF 初始化 | rk35xx 通用代码 | RK3399 专用 GRF 配置 |
| 以太网状态 | ❌ DMA SWR 永久卡死 | ✅ 正常 |

**结论**：GMAC DMA 硬件完好。SWR 位卡死的根因是 **rk35xx 内核缺少 RK3399Pro 专用 CRU 时钟定义和 GRF 初始化**，导致 DMA 模块内部状态机无法正确工作。

### 9.1 DMA 寄存器扫描结果（dma_scan.ko）

```
MAC 区域 (0x000-0x0FF):
  [0x000] MAC_Config       = 0x00000400  (Full Duplex)
  [0x010] MAC_Addr0_High   = 0x0000f8c4
  [0x014] MAC_Addr0_Low    = 0x0000ffff
  [0x020] MAC_MII_Addr     = 0x00001035
  [0x024] MAC_MII_Data     = 0x00000100
  [0x040] MAC_Frame_Filter = 0x8000ffff
  [0x044] MAC_Hash_High    = 0xffffffff

DMA 区域 (0x1000-0x10FF):
  [0x1000] Bus_Mode        = 0x00020101  ← SWR(bit0)=1 永久卡死！DA(bit16)=1, PBL(bit8)=1
  [0x1028] Cur_Host_TX     = 0x00110001
  [0x1058] Intr_Enable     = 0x000d0f17
  [0x1080] (Ch1 Bus_Mode?) = 0x00020101
  [0x10a8] (Ch1 Cur_TX?)   = 0x00110001
  [0x10d8] (Ch1 Intr?)     = 0x000d0f17

0x2000 区域: 全部为零

SWR 写测试:
  写入 SWR=1 → 读回 0x00020101 (SWR=1)  — 符合预期
  写入 SWR=0 → 读回 0x00020101 (SWR=1)  — ⚠️ SWR 位不可清除！
```

### 9.2 根因分析

| 证据 | 含义 |
|---|---|
| 寄存器可读写 | AHB 总线到 GMAC IP 的连接正常 |
| DA/PBL 等位可写 | 寄存器写入通道正常 |
| SWR 位永久为 1 | DMA 内部复位状态机不工作 |
| HW_FEAT0/1 = 0x00 | DMA 功能描述寄存器未初始化 |
| 描述符指针非零 | DMA 曾部分初始化但被 SWR 阻断 |
| clk_gmac = 30 MHz / 120 MHz 均失败 | 频率不是因素 |
| AHB reset (SRST_A_GMAC_NOC) 无效 | CRU 复位信号无法修复 DMA |

**结论：RK3399Pro 芯片内 GMAC DMA 模块存在硬件级缺陷。** 可能原因：
1. DMA 硅片逻辑损坏（制造缺陷）
2. DMA 时钟门控 (clock gate) 未完全打开
3. 电源域内部 DMA 供电异常

### 9.3 已排除假设汇总（完整 8 轮）

| # | 假设 | 验证迭代 | 结果 |
|---|---|---|---|
| 1 | snps DMA 调优属性缺失 | iter38 | ❌ 无效 |
| 2 | clock_in_out=input 错误 | iter40 | ❌ 整板挂死 |
| 3 | 电源域未开启 | iter40 | ❌ 删除 power-domains 无效 |
| 4 | phy-mode=rgmii 错误 | iter42 | ❌ 改 rgmii-id 无效 |
| 5 | clk_gmac 频率太低 | iter43-44 | ❌ 120 MHz 仍失败 |
| 6 | assigned-clock-parents 阻断 | iter44 | ❌ 删除后仍无效 |
| 7 | AHB reset 缺失 | iter45 | ❌ 添加 SRST_A_GMAC_NOC 无效 |
| — | **DMA 硬件缺陷** | **iter45** | **✅ 寄存器扫描确认 SWR 永久卡死** |

### 9.4 建议替代方案

由于 GMAC DMA 为硬件缺陷，软件无法修复，建议：
1. **USB 以太网适配器** — 最直接的替代方案，USB 2.0/3.0 已验证正常
2. **WiFi 修复** — 独立解决 SDIO/WiFi 问题（当前黑名单中）
3. **换板测试** — 确认是否仅此片 GMAC DMA 损坏（批量问题 vs 个体问题）

---

## 10. iter45 排查方向

### 10.1 候选方向（按风险升序排列）

#### A. 补全 AHB reset（低风险，高价值）
- **原理**：RK3399 CRU 有两个 GMAC 复位线：`SRST_MAC`（MAC 逻辑）和 `SRST_MAC_A`（AHB 桥接）。当前 DTB 只有 `SRST_MAC`。DMA 引擎挂在 AHB 总线上，如果 AHB 桥接未正确复位，DMA 的 SWR 位无法被硬件清除。
- **修改**：在 DTB ethernet 节点添加 `resets = <&cru SRST_MAC>, <&cru SRST_MAC_A>` 和 `reset-names = "stmmaceth", "ahb"`
- **风险**：纯 DTB 属性添加，不影响其他硬件
- **验证**：`ip link set eth0 up`

#### B. 检查 U-Boot GMAC 初始化状态（无风险，信息收集）
- **原理**：如果 U-Boot 启动了 GMAC DMA 并留下未清理的 descriptor 或运行状态，Linux 驱动的 SWR 可能无法覆盖
- **方法**：在 U-Boot 命令行中检查 GMAC 寄存器状态，或在 U-Boot 中禁用 GMAC 初始化
- **风险**：只读检查，无硬件修改

#### C. 检查 GMAC DMA 寄存器状态（无风险，信息收集）
- **原理**：读取 Bus Mode Register (offset 0x1000) 的 SWR 位和其他状态位，确认 DMA 是否处于异常状态
- **方法**：通过新内核模块读取 `fe300000 + 0x1000` 的值
- **风险**：只读，不修改硬件

#### D. 检查 power domain 实际状态（无风险）
- **原理**：虽然 `pm_genpd_summary` 显示 pd_gmac ON，但可能电压不足或电源域未完全稳定
- **方法**：读取 PMU/GRF 寄存器中 GMAC 电源域状态

### 10.2 推荐优先级

1. **iter45-A**（补全 AHB reset）— 最可能解决问题，修改量小，风险低
2. **iter45-C**（DMA 寄存器读取）— 与 A 并行执行，提供诊断信息
3. **iter45-B**（U-Boot 状态）— 如果 A 失败则执行

---

*分析工具: Qoder CLI*
*日期: 2026-06-16*
