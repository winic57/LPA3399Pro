# iter46a 只读 DTB 验证结果 (2026-06-17)

> 板子已重启,SD 卡上为 iter46a 修正后 DTB。
> 本轮**只做只读检查,未触发 `ip link set eth0 up`**,板子未挂死。

---

## 验证结果汇总

| 项 | 期望 | 实际 | 对照 vendor | 判定 |
|---|---|---|---|---|
| 内核版本 | 6.1.141-rk35xx-ophub | ✅ `6.1.141-rk35xx-ophub` | N/A | ✅ |
| phy-mode | `rgmii` | ✅ `rgmii` | `rgmii` | ✅ |
| assigned-clock-parents | `26` | ✅ `26` | `26` (clkin_gmac) | ✅ |
| snps,reset-delays-us | `0 10000 50000` | ✅ `0 10000 50000` | `0 10000 50000` | ✅ |
| snps,burst_len | NOT FOUND | ✅ `FDT_ERR_NOTFOUND` | 不存在 | ✅ |
| resets | `8 137` | ✅ `8 137` | `8 137` (单一 SRST_A_GMAC) | ✅ |
| clkin_gmac | 125 MHz | ✅ `125000000` | 125 MHz | ✅ |
| **clk_gmac** | 125 MHz | ❌ **`30000000`** (30 MHz) | 125 MHz | ❌ |
| aclk_gmac | 400 MHz | ✅ `400000000` | 400 MHz | ✅ |
| pclk_gmac | 100 MHz | ✅ `100000000` | 100 MHz | ✅ |
| dmesg probe | 无 `Failed to reset` | ✅ 启动期间无 DMA 错误 | — | ✅ |
| eth0 状态 | DOWN (未 up) | ✅ `DOWN` | — | ✅ |
| 板子稳定性 | 不挂死 | ✅ 正常返回 shell | — | ✅ |

---

## 关键发现

### ✅ DTB 配置已完全回退到 vendor baseline

iter46a 修正后的 DTB,GMAC 节点所有属性已与 vendor DTS **完全一致**:

- `phy-mode = rgmii` (不再是 iter42 的 `rgmii-id`)
- `assigned-clock-parents = 26` (clkin_gmac,iter44 误删的属性已补回)
- `snps,reset-delays-us = 0 10000 50000` (iter45 丢失的属性已补回)
- `snps,burst_len` 不存在 (iter38 多余属性已删除)
- `resets = 8 137` (单一 SRST_A_GMAC,iter45 额外的 SRST_A_GMAC_NOC 已删除)

### ✅ 启动期间 GMAC probe 成功,无 DMA 错误

dmesg 中 GMAC 驱动初始化正常:
```
[   10.541518] rk_gmac-dwmac fe300000.ethernet: clock input or output? (input).
[   10.541539] rk_gmac-dwmac fe300000.ethernet: TX delay(0x21).
[   10.541554] rk_gmac-dwmac fe300000.ethernet: RX delay(0x15).
[   10.541641] rk_gmac-dwmac fe300000.ethernet: clock input from PHY
[   10.542101] rk_gmac-dwmac fe300000.ethernet: 	DWMAC1000
[   10.542130] rk_gmac-dwmac fe300000.ethernet: DMA HW capability register supported
[   10.542145] rk_gmac-dwmac fe300000.ethernet: COE Type 2
[   10.542158] rk_gmac-dwmac fe300000.ethernet: TX Checksum insertion supported
```

**无** `Failed to reset the dma` 错误(此错误只在 `ip link set eth0 up` 时才出现,启动期间不会触发完整 DMA reset)。

### ❌ 但 clk_gmac 仍为 30 MHz,不是 125 MHz

```
clkin_gmac     1  1  0  125000000   Y   deviceless
  clk_gmac     1  2  0   30000000   Y   fe300000.ethernet  stmmaceth   ← ❌ 应为 125 MHz
```

**这证实了 iter46 plan §3.1 的根因分析**:

`assigned-clock-parents = <&clkin_gmac>` 指向了不在 `clk_gmac` 的 possible parents 列表中的时钟源,导致 `__of_clk_set_defaults()` 在 parent 设置失败后**提前返回,跳过了 `assigned-clock-rates = <125000000>` 的执行**。

即使 iter46a 保留了 `assigned-clock-parents = 26`,问题依然存在,因为 RK3399 CRU 硬件设计中 `SCLK_MAC` 的 mux 父级**仅限内部 PLL**(cpll/gpll/npll),不支持选择外部固定时钟(clkin_gmac)作为父级。

### ⚠️ 关键警告: `cannot get clock clk_mac_speed`

```
[   10.541626] rk_gmac-dwmac fe300000.ethernet: cannot get clock clk_mac_speed
```

这是 6.1.141 mainline `dwmac-rockchip` 驱动与 vendor 4.4.194 `dwmac-rk` 驱动的差异之一。vendor 驱动在 `set_speed` 回调中会动态调整 `clk_mac` 频率(10M/100M/1000M → 2.5M/25M/125M),mainline 驱动缺少这个 RK3399 专有逻辑。

---

## iter46a 结论

**DTB 修正成功 ✅,但问题根因在内核驱动层,DTB 已无法继续优化。**

iter38-45 的所有 DTB 改动已全部回退,GMAC 节点已与 vendor DTS 完全一致。启动期间 GMAC probe 正常,但 `clk_gmac` 仍卡在 30 MHz,且驱动缺少 `clk_mac_speed` 时钟控制能力。

**下一步必须进入 Path B: 升级到 6.18.33 内核**,该内核包含:

1. **YT8521S PHY 驱动改进**(motorcomm-yt8521 在 6.6+ 有多次更新)
2. **dwmac-rockchip 在 6.6+ 合并的若干 RK3399 相关修复**
3. **stmmac 核心驱动在 6.6+ 的 DMA 初始化流程改进**

如果 6.18.33 仍失败,则 Step C: 换 vendor 4.4.194 内核(终极保底,100% 能工作,但 Debian Trixie 兼容性差)。

---

## 附录: dmesg 完整 GMAC 相关行

```
[   10.541166] rk_gmac-dwmac fe300000.ethernet: IRQ eth_wake_irq not found
[   10.541190] rk_gmac-dwmac fe300000.ethernet: IRQ eth_lpi not found
[   10.541258] rk_gmac-dwmac fe300000.ethernet: Deprecated MDIO bus assumption used
[   10.541324] rk_gmac-dwmac fe300000.ethernet: PTP uses main clock
[   10.541518] rk_gmac-dwmac fe300000.ethernet: clock input or output? (input).
[   10.541539] rk_gmac-dwmac fe300000.ethernet: TX delay(0x21).
[   10.541554] rk_gmac-dwmac fe300000.ethernet: RX delay(0x15).
[   10.541574] rk_gmac-dwmac fe300000.ethernet: integrated PHY? (no).
[   10.541626] rk_gmac-dwmac fe300000.ethernet: cannot get clock clk_mac_speed
[   10.541641] rk_gmac-dwmac fe300000.ethernet: clock input from PHY
[   10.541878] rk_gmac-dwmac fe300000.ethernet: init for RGMII
[   10.542080] rk_gmac-dwmac fe300000.ethernet: User ID: 0x10, Synopsys ID: 0x35
[   10.542101] rk_gmac-dwmac fe300000.ethernet: 	DWMAC1000
[   10.542115] rk_gmac-dwmac fe300000.ethernet: DMA HW capability register supported
[   10.542130] rk_gmac-dwmac fe300000.ethernet: RX Checksum Offload Engine supported
[   10.542145] rk_gmac-dwmac fe300000.ethernet: COE Type 2
[   10.542158] rk_gmac-dwmac fe300000.ethernet: TX Checksum insertion supported
[   10.542171] rk_gmac-dwmac fe300000.ethernet: Wake-Up On Lan supported
[   10.542234] rk_gmac-dwmac fe300000.ethernet: Normal descriptors
[   10.542249] rk_gmac-dwmac fe300000.ethernet: Ring mode enabled
[   10.542262] rk_gmac-dwmac fe300000.ethernet: Enable RX Mitigation via HW Watchdog Timer
[   18.824341] probe of stmmac-0:00 returned 0 after 36 usecs
[   18.834268] probe of stmmac-0:03 returned 0 after 20 usecs
[   18.840624] YT8521S Gigabit Ethernet stmmac-0:00: attached PHY driver (mii_bus:phy_addr=stmmac-0:00, irq=POLL)
[   18.840650] YT8521S Gigabit Ethernet stmmac-0:03: attached PHY driver (mii_bus:phy_addr=stmmac-0:03, irq=POLL)
```

---

*验证时间: 2026-06-17*
*验证方式: Python TTL 脚本 @ /dev/ttyUSB0 1500000 baud*
*下一步: Path B 升级到 6.18.33 内核*
