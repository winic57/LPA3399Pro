# LPA3399Pro SD 卡适配下一步建议（基于 iter39）

> 参考文件：`LPA3399Pro_SDCard_Full_Adaptation_Log_20260615.md`  
> 当前基线：iter39  
> 生成日期：2026-06-16  

---

## 1. 当前结论摘要

截至 iter39，系统启动稳定性已经基本达标：

- ✅ SD 卡启动稳定，ROOTFS 已改为 UUID 挂载并扩容到约 14GB
- ✅ HDMI Console、HDMI 音频、USB、自动登录可用
- ✅ 已消除 PCIe、WiFi、DISCARD、NM-wait-online、firstlogin、motd、GPT 等启动噪声
- ✅ 启动到 root shell 约 35s
- ⏸️ Ethernet 仍不可用，`stmmac` DMA reset 超时
- ⏸️ WiFi 仍不可用，`rtw88_8821cs` 加载时 SDIO `-110` 超时
- ⏸️ PCIe 当前已禁用，暂不建议恢复

当前最重要原则：

> **保持 iter39 作为稳定基线，不要同时打开 Ethernet / WiFi / PCIe 多个不稳定模块。后续每次只改一个变量，并保留完整启动日志。**

---

## 2. 优先级建议

| 优先级 | 目标 | 建议状态 |
|---|---|---|
| P0 | 固化 iter39 稳定启动基线 | 立即执行 |
| P1 | Ethernet GMAC DMA 根因排查 | 下一轮 iter40 主线 |
| P2 | WiFi SDIO `-110` 排查 | Ethernet 稳定后再做，或单独分支做 |
| P3 | 清理无效 DTB 实验参数 | 在诊断完成后执行 |
| P4 | PCIe 恢复 | 暂缓，不建议近期处理 |

---

## 3. iter40 建议：先做 Ethernet 诊断，不急于改 DTB

iter38 已证明以下方向无效：

- `snps,burst_len`
- `snps,pbl`
- `snps,txpbl`
- `snps,rxpbl`
- `snps,fixed-burst`
- `snps,force_thresh_dma_mode`

原因是这些参数影响 DMA reset 之后的数据传输策略，而当前失败点是：

```text
rk_gmac-dwmac fe300000.ethernet: Failed to reset the dma
stmmac_hw_setup: DMA engine initialization failed
__stmmac_open: Hw setup failed
```

这说明 `dwmac1000_dma_reset()` 的 SWR 位无法自动清零，更像是：

1. GMAC DMA/AHB 时钟没开或频率异常
2. GMAC power domain 实际未上电
3. reset line 不完整或顺序错误
4. PHY/MAC 时钟方向不匹配
5. GMAC bus/NOC 侧未释放

### 3.1 建议先执行现有诊断脚本

在 iter39 启动成功并进入 root shell 后，通过 TTL 执行：

```bash
bash /root/eth_run.sh
cat /tmp/eth_diag.log
```

同时保留完整 TTL 日志，建议命名：

```text
ttl_iter40_eth_diag_YYYYMMDDHHMM.log
```

重点关注以下内容：

```bash
dmesg | grep -Ei 'gmac|stmmac|ethernet|phy|yt8521|dma|clk|power'
cat /sys/kernel/debug/clk/clk_summary | grep -Ei 'gmac|mac|stmmac|ethernet'
cat /sys/kernel/debug/pm_genpd/pm_genpd_summary 2>/dev/null
cat /sys/kernel/debug/rk_pd/* 2>/dev/null
ethtool eth0
ethtool -i eth0
ip link set eth0 up
```

### 3.2 根据诊断结果再选修复方向

#### 情况 A：`aclk_mac` / `pclk_mac` / `stmmaceth` 时钟未启用或频率为 0

优先尝试 DTB 增加 `assigned-clocks` / `assigned-clock-rates`，不要先改 PHY delay。

建议方向：

```dts
&gmac {
    assigned-clocks = <&cru SCLK_RMII_SRC>, <&cru ACLK_GMAC>, <&cru PCLK_GMAC>;
    assigned-clock-rates = <125000000>, <100000000>, <50000000>;
};
```

实际 clock ID 需要以当前 DTB 反编译结果和 RK3399 CRU binding 为准，不能直接盲写。

#### 情况 B：power domain 未启用

当前日志认为 `power-domains = <0x16 0x16>` 形式上正确，但仍建议用运行时 debugfs 验证。

如果 `PD_GMAC` 未 active：

- 检查 `/ethernet@fe300000` 的 `power-domains` phandle 是否指向真正的 power controller
- 检查 power controller 节点是否被错误裁剪或 status 异常
- 检查 kernel 是否启用了对应 rockchip power-domain driver

#### 情况 C：reset 只有 `stmmaceth`，缺少 AHB/NOC reset

当前 DTB 只有：

```dts
resets = <&cru 0x89>;
reset-names = "stmmaceth";
```

如果诊断显示 clock/power 均正常，下一步可尝试补充 AHB reset。方向如下：

```dts
resets = <&cru SRST_GMAC>, <&cru SRST_A_GMAC>;
reset-names = "stmmaceth", "ahb";
```

注意：

- 具体 reset ID 必须从 RK3399 CRU binding 或当前 DTS 源确认
- 不建议直接猜 `<0x89>, <0x??>` 写入生产 SD 卡
- 建议先备份 DTB，并只在测试分支中验证

#### 情况 D：PHY 可读但 link 不起

这类问题已经晚于 DMA reset，目前不是主问题。只有在 DMA reset 成功之后，才需要继续调：

- `phy-mode = "rgmii" / "rgmii-id" / "rgmii-rxid" / "rgmii-txid"`
- `tx_delay`
- `rx_delay`
- YT8521S strap

当前不建议继续消耗时间在 delay 上。

---

## 4. iter40 不建议做的事情

### 4.1 不建议让 NetworkManager 重新管理 eth0

iter38 已证明：

- NM 管理 eth0 会自动 ifup
- ifup 触发 DMA reset 超时
- DMA 失败后引发 PAM/logind/login 阻塞
- 最终导致 autologin 60s 超时

因此在 GMAC 修好前，保持：

```ini
[keyfile]
unmanaged-devices=interface-name:eth0
```

只通过手动命令触发：

```bash
ip link set eth0 up
```

### 4.2 不建议继续增加 `snps,*` DMA 运行参数

DMA reset 还没过，这类参数价值有限。建议诊断后清理掉 iter38 保留的 6 个无效参数，避免后续误判。

### 4.3 不建议同时解锁 WiFi

WiFi probe 会带来大量 SDIO `-110` 错误，干扰 Ethernet 日志阅读。iter40 应保持：

```text
modprobe.blacklist=...,rtw88_8821cs,...
```

---

## 5. WiFi 后续建议

WiFi 当前结论：

- 50MHz 失败
- 25MHz 仍失败
- 表现一致，说明频率大概率不是根因
- `rtw88_8821cs` 目前应继续黑名单

后续建议单独开 iter 分支处理，不要和 Ethernet 混测。

排查顺序：

1. 确认 `wifi_enable_H` / `wifi_disable_H` GPIO 是否正确
2. 确认 3.3V / 1.8V / WL_REG_ON / WL_WAKE 等电源时序
3. 确认 SDIO bus-width、non-removable、keep-power-in-suspend 配置
4. 再尝试 12MHz 低频验证
5. 如仍 `-110`，优先怀疑电源/GPIO/复位时序，而非 SDIO clock

建议 WiFi 测试时单独保存日志：

```text
ttl_iterXX_wifi_gpio_power_test_YYYYMMDDHHMM.log
```

---

## 6. 建议的下一轮执行清单

### 6.1 启动前

1. 确认 SD 卡处于 iter39 稳定状态
2. 确认 WiFi 仍黑名单
3. 确认 NM 不管理 eth0
4. 准备 TTL 日志采集，波特率 1500000

### 6.2 启动后

执行：

```bash
bash /root/eth_run.sh
cat /tmp/eth_diag.log
```

然后额外执行：

```bash
cat /sys/kernel/debug/clk/clk_summary | grep -Ei 'gmac|mac|stmmac|ethernet'
cat /sys/kernel/debug/pm_genpd/pm_genpd_summary 2>/dev/null
find /sys/kernel/debug -maxdepth 3 -iname '*pd*' -o -iname '*power*' 2>/dev/null
```

### 6.3 日志分析重点

优先判断：

```text
DMA reset 超时前，GMAC 的 clock 是否已 enable？
GMAC power domain 是否 active？
reset line 是否只有 stmmaceth？
PHY 是否能被 MDIO 正常读取？
```

### 6.4 iter41 修改方向

根据 iter40 诊断结果再决定：

| 诊断结果 | iter41 建议 |
|---|---|
| clock 未启用 / 频率异常 | 添加或修正 assigned-clocks / assigned-clock-rates |
| power domain inactive | 修正 power-domains / power-controller 节点 |
| clock/power 正常但 DMA reset 仍失败 | 尝试补充 AHB/NOC reset |
| DMA reset 成功但 link 不起 | 再调 phy-mode / tx_delay / rx_delay |
| PHY 不可读 | 查 YT8521S 电源、复位、strap、MDIO 引脚 |

---

## 7. 建议保留的稳定基线

建议将当前 iter39 SD 卡状态做一次镜像备份，作为可回滚基线：

```bash
sudo dd if=/dev/sdX of=LPA3399Pro_iter39_stable_20260616.img bs=4M status=progress conv=fsync
```

或至少备份以下文件：

```text
/boot/extlinux/extlinux.conf
/boot/armbianEnv.txt
/boot/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb
/etc/NetworkManager/NetworkManager.conf
/etc/systemd/system/serial-getty@ttyFIQ0.service.d/autologin.conf
/etc/systemd/system/getty@tty1.service.d/autologin.conf
```

---

## 8. 最推荐的下一步一句话版

> **下一步不要再盲改 DTB，先在 iter39 稳定基线上运行 `/root/eth_run.sh`，抓取 GMAC clock / power-domain / reset / PHY 证据；确认 DMA reset 超时到底是 clock、power 还是 reset 问题后，再进入 iter41 做单点 DTB 修改。**
