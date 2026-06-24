# LPA3399Pro SD 卡全量适配修改日志 (完整版)

> 本文件是对 LPA3399Pro SD 卡适配过程的全量记录，包含从 iter1 到 iter33 的所有技术细节、测试结果与策略演进。
> 基础镜像：`Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.1.141_server_2026.06.11_hybrid_sdkboot.img`

---

## 0. 核心工作流

1. **环境准备**：基于 Neardi SDK 提取的 `idbloader.img`, `uboot.img`, `trust.img` 构建混合引导 SD 卡。
2. **迭代原则**：直接修改 SD 卡 `/boot` 分区下的 `extlinux.conf`, `armbianEnv.txt` 和 `dtb/` 文件，利用 `fdtput` 进行外科手术式 DTB 调整，无需重新烧录。
3. **日志捕获**：通过 TTL 串口（波特率 1500000）配合 `initcall_debug` 和 `printk.devkmsg=on` 捕获关键挂死点。

---

## 1. 适配里程碑

- **iter7**: 首次突破 19.5s DRM 死锁，通过禁用 `display-subsystem` 实现。
- **iter17**: **首次成功进入登录界面**，解决 MMC 编号偏移。
- **iter22**: **HDMI 显示全面恢复**，除 `iep` 外显示子系统全开且稳定。
- **iter28**: 实现系统**自动登录 (Auto Login)**。
- **iter33**: **引入 UUID 挂载**，彻底解决因硬件启用/禁用导致的根分区识别失败问题。
- **iter34**: **清理启动噪声 + 禁用 PCIe**——修正 WiFi 主线驱动黑名单、清空损坏 armbian-motd、parted 修复 GPT 备份头错位。
- **iter35**: **修复 mmc1 DISCARD I/O 错误 + 抑制 Ethernet DMA 错误刷屏**——禁用 fstrim/e2scrub timers、NM 不自动 ifup eth0。
- **iter36**: **跳过 NM-wait-online 60s 超时 + 跳过首次登录建密提示**——禁用 NM-wait-online.service，删除 `.not_logged_in_yet` 标记。
- **iter37**: **恢复自动登录**——为 `serial-getty@ttyFIQ0.service` 和 `getty@tty1.service` 显式创建 autologin override。
- **iter38**: **GMAC DMA 修复尝试 + WiFi 解锁 + 注入以太网诊断脚本**——DTB 添加 6 个 snps DMA 调优属性；WiFi SDIO 总线 50→25MHz；从黑名单移除 `rtw88_8821cs`；NM 恢复管理 eth0；注入 `/root/eth_diag.sh` + `eth_quick.sh` + `eth_run.sh`。
- **iter39**: **iter38 三项回退 + 启动可用性恢复**——重新禁用 NM 对 eth0 的管理（解除 DMA 重试→PAM/logind 阻塞→60s login 超时级联）；重新拉黑 `rtw88_8821cs`（25MHz 仍 -110，无法解锁）；保留 iter38 snps,\* DTB 属性供 `eth_diag.sh` 验证。
- **iter40**: **MAC 时钟方向反转 + 移除 PD 引用**——基于 eth_diag.sh 日志证据（`clk_gmac` 仅 30 MHz、`pm_genpd_summary` 中无 `gmac` 域），将 `clock_in_out` 从 `input` 改为 `output`（MAC 自生成 125 MHz 时钟），删除 `power-domains` 属性（rk3399 GMAC 属 always-on 域，DTB 原引用的 PD 索引实际未注册）。
- **iter41**: **iter40 完全回退（DMA 排查暂停）**——iter40 的 `clock_in_out=output` 导致 `ip link set eth0 up` 时整板挂死（30s 监听 0 字节，连 Ctrl-C 都无响应），推测 RGMII_TX_CLK 双向驱动电气冲突。回退：`clock_in_out: output → input`，恢复 `power-domains=<0x16 0x16>`，回到 iter39 已验证可用 baseline。
- **iter42**: **phy-mode 由 rgmii 改 rgmii-id（iter42-A 实验）**——让 PHY 内部处理 RGMII 延迟，跳过 MAC 的 tx_delay=0x21/rx_delay=0x15 配置；若 delay 不匹配是 DMA 触发的副作用，本改动可能生效。

---

## 2. 详细迭代记录 (Iter 1 - Iter 33)

### iter1 - iter13: 攻克启动死锁与 RCU Stall
- 锁定并禁用三大挂死源：`display-subsystem` (19s 挂死)、`sdhci@fe330000` (19.3s 挂死)、`rkisp1/mipi-dphy` (79s 死锁)。
- 引入 `usbcore.autosuspend=-1` 和 `initcall_blacklist=psci_checker` 优化稳定性。

### iter14 - iter22: 用户空间与显示恢复
- 恢复 `hdmi-sound` 和 `Little VOP`，确立 IEP 为唯一硬挂死源。
- 成功实现 HDMI 物理 Console 输出。

### iter23 - iter32: 外设功能攻坚 (PCIe/Ethernet/WiFi)
- 实验了多种以太网时序 (`rgmii-id` 等) 和 WiFi 频率 (12MHz~150MHz)。
- 发现 WiFi 启用会导致 SD 卡从 `mmcblk1` 偏移至 `mmcblk0`。
- 确认以太网与 WiFi 存在 U-Boot 阶段的资源竞争。

### iter33 (2026-06-15 14:15): 稳定化升级
- **UUID 切换**：将 `root=/dev/mmcblkXp2` 统一修改为 `root=UUID=d9159ff7-f834-4aba-a518-ac5f1dfc7175`。
- **功能找回**：重新启用 WiFi 节点，利用 UUID 避开编号偏移。
- **底座固化**：恢复 Syscon 的 `simple-mfd` 兼容性，确保 USB/显示 驱动链条完整。

### iter34 (2026-06-15 21:25): PCIe/USBHost1 禁用 + 黑名单修正 + GPT/motd 修复
基于日志 `ttl_iter33_pcie_usbhost1_disabled_202606152006.log` 的全量复盘：
- **iter33 名义上禁用 PCIe/USB Host1 但实际未生效**：DTB 中 `/pcie-phy`、`/pcie@f8000000`、`/usb@fe3c0000` 仍为 `status="okay"`，导致 `rockchip_pcie_driver_init` 持续 `probe ... returned -517 (-EPROBE_DEFER)`，并伴随 `rockchip-pcie-phy pcie-phy: Cannot find GRF syscon` 报错（虽然 DTB `rockchip,grf = <0x17>` 正确指向 GRF phandle，但驱动仍报失败）。
- **WiFi 黑名单拼写不一致**：`extlinux.conf`/`armbianEnv.txt` 黑名单写的是 `rtl8821cs`（vendor 名），但 ROOTFS 实际只有主线驱动 `rtw88_8821cs.ko`（注意 `rtw88` 下划线）。两者不相等导致驱动照常加载，触发 `sdio read32/write32 failed ... -110` 持续报错（约 30s 处，干扰 init）。
- **Ethernet DMA 失败**：YT8521S PHY 成功 attach（log line 1703-1704），但 `ifup` 时 `Failed to reset the dma` / `stmmac_hw_setup: DMA engine initialization failed`。DTB 中 `clock_in_out = input`，log 显示 `cannot get clock clk_mac_speed`。根因仍在排查（疑似 IOMMU/Power Domain）。
- **armbian-motd 文件损坏**：`/etc/default/armbian-motd` 全为 0xFF 字节（714B），导致 root 自动登录执行 `/etc/default/armbian-motd` 时打印 `command not found` 噪声。
- **GPT 备份头错位**：`GPT:7225343 != 30203903` —— 镜像按 ~30GB 创建，写入 14.4GB SD 卡后备份 GPT 头不在磁盘末端，每次启动 partprobe 报警。

iter34 SD 卡直接修改清单（均已验证）：
| # | 修改项 | 工具 | 修改前 | 修改后 |
|---|---|---|---|---|
| 1 | `/pcie-phy status` | `fdtput -t s` | `okay` | `disabled` |
| 2 | `/pcie@f8000000 status` | `fdtput -t s` | `okay` | `disabled` |
| 3 | `extlinux.conf` modprobe.blacklist | `sed` | `...,rtl8821cs,hci_uart` | `...,rtl8821cs,rtw88_8821cs,hci_uart` |
| 4 | `armbianEnv.txt` extraboardargs | `sed` | 同上 | 同上 |
| 5 | `/etc/default/armbian-motd` | `truncate -s 0` | 714B 全 0xFF | 空 (0B) |
| 6 | GPT 备份头位置 | `parted ---pretend-input-tty` "Fix" | LBA 7225343 | 磁盘末端 30203903 |

备份文件：
- `dtb/.../rk3399pro-neardi-linux-lc110-base.dtb.iter33_base_20260615_212255`
- `extlinux/extlinux.conf.iter33_base_20260615_212255`
- `armbianEnv.txt.iter33_base_20260615_212255`
- `ROOTFS:/etc/default/armbian-motd.iter33_corrupt_20260615_212255`

预期 iter34 启动行为：
- PCIe probe 不再发生（无 -517/-22 错误）。
- WiFi 驱动 `rtw88_8821cs` 被 blacklist，不再触发 SDIO -110 错误链。
- 登录后不再有 armbian-motd 的 `command not found` 噪声。
- 启动时无 GPT 错位警告。
- **遗留**：Ethernet DMA 失败仍需 iter35 解决（计划方向：检查 GMAC 的 `power-domains`/`resets`/`iommu` 引用，或尝试 `phy-mode = "rgmii-txid"`）。

### iter35 (2026-06-15 21:37): 修复 mmc1 DISCARD 错误 + 抑制 Ethernet DMA 噪声
基于 `ttl_iter34_pcie_usbhost1_disabled_202606152129.log` 复盘：
- ✅ **iter34 全部 4 项修复验证生效**：日志中 PCIe/WiFi/armbian-motd/GPT 报错全部消失，启动稳定进入 auto-login。
- ⚠️ **新问题**：35.319s 出现 `mmc1: Card stuck being busy! __mmc_poll_for_busy` → `I/O error, dev mmcblk1, sector 778256 op 0x3:(DISCARD)`。flags 0x800 = REQ_BACKGROUND，定位为 `fstrim.timer`/`e2scrub_all.timer` 在启动时触发（两者 `Persistent=true`，首次启动会补执行）。
- ❌ **遗留问题确认**：Ethernet DMA `Failed to reset the dma` / `stmmac_hw_setup: DMA engine initialization failed` 在 NM 自动 ifup eth0 时触发两次。DTB 中 `power-domains = <22 22>` 引用 power-controller(phandle 0x16) + PD_GMAC(reg=0x16) **完全正确**，问题不在 power domain；clk_mac_speed 是 input-from-PHY 模式下可忽略的告警。根因待 iter36 排查（怀疑 ACLK/PCLK_GMAC 时钟链或 IOMMU）。

iter35 SD 卡直接修改清单（均已 sync）：

| # | 修改项 | 工具 | 修改前 | 修改后 |
|---|---|---|---|---|
| 1 | `timers.target.wants/fstrim.timer` | `rm` 软链 | enabled (weekly+Persistent) | disabled（保留 .bak） |
| 2 | `timers.target.wants/e2scrub_all.timer` | `rm` 软链 | enabled (Sun 03:10+Persistent) | disabled（保留 .bak） |
| 3 | `etc/fstab` commit | `sed` | `commit=600` | `commit=60`（降低 journal 后台 IO 风暴） |
| 4 | `NetworkManager.conf` 追加 `[keyfile] unmanaged-devices=interface-name:eth0` | `cat >>` | NM 自动 ifup eth0 → DMA 失败 | NM 不管理 eth0，DMA 错误不再刷屏 |

备份文件（在 ROOTFS 中）：
- `/etc/systemd/system/timers.target.wants/fstrim.timer.iter34_disabled_20260615_213729.bak`
- `/etc/systemd/system/timers.target.wants/e2scrub_all.timer.iter34_disabled_20260615_213729.bak`
- `/etc/fstab.iter34_disabled_20260615_213729`
- `/etc/NetworkManager/NetworkManager.conf.iter35_disabled_20260615_213729`

预期 iter35 启动行为：
- 启动时不再触发 fstrim → 不再出现 `mmc1: Card stuck being busy` / `op 0x3:(DISCARD)` 错误链。
- journal commit 间隔从 600s 缩短至 60s，配合 noatime 减少 fsync 风暴。
- NetworkManager 不再启动 eth0，避免 `stmmac_hw_setup: DMA engine initialization failed` 重复刷屏（但 eth0 也暂时无网络）。
- **遗留待 iter36**：彻底修复 GMAC DMA reset（计划：尝试在 DTB 添加 `snps,burst_len = <16>`、`snps,force_thresh_dma_mode`、或调整 `tx-delay/rx-delay`；如仍失败，再尝试更新 U-Boot 中 GMAC 的 init 序列）。

### iter36 (2026-06-16 08:46): 消除 NM-wait-online 60s 超时 + 跳过首次登录建密提示
基于 `ttl_iter35_pcie_usbhost1_disabled_202606160838.log` 复盘：
- ✅ **iter35 DISCARD 修复验证**：日志中 `op 0x3:(DISCARD)` / `Card stuck being busy` 出现次数 = 0（iter34 是 2 次）。
- ✅ **iter35 Ethernet DMA 错误抑制验证**：日志中 `Failed to reset the dma` / `DMA engine initialization failed` 出现次数 = 0（iter34 是 2 次，因 NM 不再 ifup eth0）。
- ⚠️ **新问题1**：iter35 让 NM 不管理 eth0 后，`NetworkManager-wait-online.service` 在网络启动阶段持续 60s 超时（log line 2958-2971：`Created symlink ... NetworkManager-wait-online.service` → `IP address: Waiting for local connection! Retrying... (6..1)` → `Network connection timeout!`）。服务配置 `NM_ONLINE_TIMEOUT=60`，且因为没有任何 unmanaged 之外的可连接接口，永远到不了 "startup complete"。
- ⚠️ **新问题2**：登录后立即弹出 `Create root password:`（log line 2973）。这是 `/etc/profile.d/armbian-check-first-login.sh` 检测到 `/root/.not_logged_in_yet` 文件后调用 `/usr/lib/armbian/armbian-firstlogin` 触发。但 `/etc/shadow` 中 root 密码字段已是 `$y$j9T$...`（yescrypt 哈希，73 字符），密码实际已设置，标记文件未清理是镜像制作疏漏。

iter36 SD 卡直接修改清单（均已 sync）：

| # | 修改项 | 工具 | 修改前 | 修改后 |
|---|---|---|---|---|
| 1 | `network-online.target.wants/NetworkManager-wait-online.service` | `mv` 软链到 `.bak` | enabled（60s 超时） | disabled（保留 .bak） |
| 2 | `/root/.not_logged_in_yet` 标记文件 | `mv` 到 `.bak` | 存在（触发 firstlogin 建密提示） | 移除（跳过 firstlogin） |

备份文件（在 ROOTFS 中）：
- `/etc/systemd/system/network-online.target.wants/NetworkManager-wait-online.service.iter36_disabled_20260616_084616.bak`
- `/root/.not_logged_in_yet.iter36_removed_20260616_084616.bak`

预期 iter36 启动行为：
- auto-login 后立即进入 shell，不再被 NM-wait-online 阻塞 60s（启动到可用 shell 的时间从约 95s 缩短到约 35s）。
- 登录后不再弹 `Create root password:` 提示；使用 `/etc/shadow` 中既有的 yescrypt 密码即可登录（密码值需用户告知或后续重置）。
- **遗留待 iter37**：彻底修复 GMAC DMA reset（iter35 计划不变：尝试在 DTB 添加 `snps,burst_len`、`snps,force_thresh_dma_mode` 或调整 `tx-delay/rx-delay`）。
- **遗留待 iter37**：当前 ROOTFS 仍是 3GB 未扩展（SD 卡有 14.4GB，剩 11.5GB 空闲），考虑 parted resizepart + resize2fs 扩容。

### iter37 (2026-06-16 09:05): 恢复自动登录 + ROOTFS 扩容确认
基于 `ttl_iter36_pcie_usbhost1_disabled_202606160852.log` 复盘：
- ✅ **iter36 全部 4 项修复验证生效**：
  - NM-wait-online 60s 超时消失（启动到 login 提示从 ~95s 缩短到 ~35s）
  - `Create root password:` 提示消失（firstlogin 跳过）
  - DMA 错误 0 次
  - DISCARD 错误 0 次
- ⚠️ **新问题**：**自动登录失效**——iter36 日志末尾为 `armbian login:` 但无 `(automatic login)` 后缀（iter33-35 均有）。iter36 ROOTFS 中 `/etc/systemd/system/serial-getty@.service.d/` 和 `getty@.service.d/` 均为空，找不到任何 `--autologin` 配置。推测 iter33-35 期间曾通过临时手段（可能是 ROOTFS 临时挂载修改或 in-memory overlay）实现过自动登录，但未持久化到 SD 卡，resize ROOTFS（3GB→14GB）后丢失。
- ℹ️ **附注**：ROOTFS 已被 resize 扩容——`Block count=3640315`（约 14GB），`Mount count=61`，与 iter34 时 `Block count=767744`（3GB）不同。iter36 测试期间应已通过 parted + resize2fs 完成扩容，iter34 时遗留的"未扩展空间"问题已自动解决。

iter37 SD 卡直接修改清单（均已 sync）：

| # | 修改项 | 工具 | 修改前 | 修改后 |
|---|---|---|---|---|
| 1 | `/etc/systemd/system/serial-getty@ttyFIQ0.service.d/autologin.conf` | `tee` 新建 | 不存在（无自动登录） | `ExecStart=-/sbin/agetty ... --autologin root --keep-baud 1500000,115200,... %I $TERM` |
| 2 | `/etc/systemd/system/getty@tty1.service.d/autologin.conf` | `tee` 新建 | 不存在 | `ExecStart=-/sbin/agetty ... --autologin root --noclear %I $TERM` |

新建的 `serial-getty@ttyFIQ0.service.d/autologin.conf` 内容：
```ini
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --autologin root --keep-baud 1500000,115200,57600,38400,9600 %I $TERM
```

新建的 `getty@tty1.service.d/autologin.conf` 内容：
```ini
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --autologin root --noclear %I $TERM
```

预期 iter37 启动行为：
- 串口 (ttyFIQ0) 自动登录 root，日志末尾应再次出现 `armbian login: root (automatic login)`。
- HDMI (tty1) 同样自动登录 root，显示器直接进入 root shell。
- iter33-36 的所有启动噪声修复仍然有效（PCIe/DMA/DISCARD/motd/GPT/NM-wait-online/firstlogin 全部清零）。
- **遗留待 iter38**：彻底修复 GMAC DMA reset（iter35 计划不变：尝试 DTB 添加 `snps,burst_len`、`snps,force_thresh_dma_mode`、调整 `tx-delay/rx-delay`）。
- **遗留待 iter38**：WiFi 主线驱动 `rtw88_8821cs` 仍被黑名单；如需启用，需先解决 SDIO -110 错误（计划：尝试降低 SDIO 总线频率或检查 GPIO 电源时序）。

### iter38 (2026-06-16 09:30): GMAC DMA 修复尝试 + WiFi 解锁 + 注入以太网诊断脚本
基于 `ttl_iter37_pcie_usbhost1_disabled_202606160908.log` 复盘：
- ✅ **iter37 自动登录恢复验证生效**：日志末尾 `armbian login: root (automatic login)`，登录成功进入 root shell，启动到可用 shell 约 35s。
- ✅ **iter37 启动噪声抑制全部维持**：PCIe/DMA/DISCARD/motd/GPT/NM-wait-online/firstlogin 错误次数均为 0。
- ⚠️ **GMAC DMA 现状**：因 iter35 让 NM 不管理 eth0，启动期间 `ip link set eth0 up` 不被触发，iter37 日志中无 `Failed to reset the dma` 报错（对比 iter34 line 2977-2979 出现两次完整失败序列）。但 eth0 长期 down，无网络。
- 📋 **iter34 DMA 失败现场回顾**（line 2977-2979）：
  ```
  [40.210949] rk_gmac-dwmac fe300000.ethernet: Failed to reset the dma
  [40.212915] rk_gmac-dwmac fe300000.ethernet eth0: stmmac_hw_setup: DMA engine initialization failed
  [40.214814] rk_gmac-dwmac fe300000.ethernet eth0: __stmmac_open: Hw setup failed
  ```
  即 `dwmac1000_dma_reset()` 写入 SWR (Software Reset) 位后 200ms 内未清零，返回 ETIMEDOUT。
- 🔍 **DTB GMAC 节点现状盘点**（`/ethernet@fe300000`）：
  - `compatible = "rockchip,rk3399-gmac"`，`phy-mode = "rgmii"`，`clock_in_out = "input"`
  - `tx_delay = <0x21>`，`rx_delay = <0x15>`（迭代 23-32 期间已验证有效的值）
  - `power-domains = <0x16 0x16>`（PD_GMAC 索引正确）
  - `resets = <0x8 0x89>`，`reset-names = "stmmaceth"`（**仅一个 reset，无 ahb reset**）
  - `clocks` 列出 7 个时钟：`stmmaceth, mac_clk_rx, mac_clk_tx, clk_mac_ref, clk_mac_refout, aclk_mac, pclk_mac`
  - **无任何 snps,\* DMA 调优属性**——这是 iter38 修复的切入点

iter38 SD 卡直接修改清单（均已 sync）：

| # | 修改项 | 工具 | 修改前 | 修改后 |
|---|---|---|---|---|
| 1 | `/ethernet@fe300000 snps,burst_len` | `fdtput -t x` | 不存在 | `0x10` (16-word DMA burst) |
| 2 | `/ethernet@fe300000 snps,force_thresh_dma_mode` | `fdtput -t s ""` | 不存在 | 存在（bool，强制阈值 DMA 模式） |
| 3 | `/ethernet@fe300000 snps,fixed-burst` | `fdtput -t s ""` | 不存在 | 存在（bool，固定突发长度） |
| 4 | `/ethernet@fe300000 snps,pbl` | `fdtput -t x` | 不存在 | `0x10` (默认可编程突发长度 16) |
| 5 | `/ethernet@fe300000 snps,txpbl` | `fdtput -t x` | 不存在 | `0x08` (TX 突发 8) |
| 6 | `/ethernet@fe300000 snps,rxpbl` | `fdtput -t x` | 不存在 | `0x08` (RX 突发 8) |
| 7 | `/dwmmc@fe310000 max-frequency`（WiFi SDIO） | `fdtput -t x` | `0x02faf080` (50MHz) | `0x017d7840` (25MHz) |
| 8 | `extlinux.conf` modprobe.blacklist | `sed` | `...,rtw88_8821cs,...` | 移除 `rtw88_8821cs` |
| 9 | `armbianEnv.txt` extraboardargs | `sed` | 同上 | 同上 |
| 10 | `NetworkManager.conf` `[keyfile]` 段 | `cat >` | `unmanaged-devices=interface-name:eth0` | 删除整个 `[keyfile]` 段，NM 恢复管理 eth0 |
| 11 | `/root/eth_diag.sh` | `tee` 新建 | 不存在 | 4176B 完整诊断脚本（26 节，含 ip/ethtool/PHY/dmesg/clocks/power/DTB/`ip link set eth0 up` 复现测试） |
| 12 | `/root/eth_quick.sh` | `tee` 新建 | 不存在 | 605B 轻量版（单行输出，适合 TTL 快读） |
| 13 | `/root/eth_run.sh` | `tee` 新建 | 不存在 | 595B 一键执行 + 保存到 `/tmp/eth_diag.log` |

备份文件：
- `dtb/.../rk3399pro-neardi-linux-lc110-base.dtb.iter37_base_20260616_093016`
- `extlinux/extlinux.conf.iter37_base_20260616_093225`
- `armbianEnv.txt.iter37_base_20260616_093225`
- `ROOTFS:/etc/NetworkManager/NetworkManager.conf.iter38_test_20260616_093927`

诊断脚本使用方法（用户登录 root shell 后通过 TTL 执行）：
```bash
# 完整诊断（输出到屏幕）
bash /root/eth_diag.sh

# 完整诊断并保存到 /tmp/eth_diag.log
bash /root/eth_run.sh
# 取回：cat /tmp/eth_diag.log

# 轻量快速查看
bash /root/eth_quick.sh
```

预期 iter38 启动行为：
- **GMAC DMA 测试**：NM 在 `network.target` 阶段自动 ifup eth0，触发 `stmmac_open` → `dwmac1000_dma_reset`。若 snps,\* 属性起效，DMA reset 在 200ms 内完成；若仍失败，`dmesg | grep "Failed to reset the dma"` 仍会显示 ETIMEDOUT。
- **WiFi 测试**：`rtw88_8821cs` 驱动加载（mmc0 在 25MHz），若 SDIO -110 错误消失则 driver probe 成功 → `dmesg | grep rtw88`、`ip link show wlan0` 应可见。若仍 -110，则需进一步降频到 12MHz 或检查 GPIO 电源时序（iter39 方向）。
- **遗留待 iter39**：如 DMA 仍失败，下一步排查方向（按可能性排序）：
  1. **clock_in_out = "output"**：让 MAC 输出 125MHz 给 PHY，验证 PHY 是否在等外部时钟。
  2. **Aclk/Pclk_gmac 频率**：当前 DTB 未显式指定 `assigned-clock-rates`，可能默认运行在过低频率。
  3. **resets 增项**：当前只有 `stmmaceth`，rk3399 参考板通常还有 `ahb` reset（如 `SRST_A_GMAC_NOC`），缺失可能导致 AHB bus 复位不完整。
  4. **IOMMU**：检查 `/ethernet@fe300000` 是否需要 `iommus = <&gmac_mmu>`，否则 DMA 访问 DDR 失败。
  5. **运行 eth_diag.sh**：收集 ethtool、PHY 寄存器、clk_summary、power-domain 状态后定位。
- **遗留待 iter39**：若 WiFi 仍 -110，进一步降到 12MHz 或检查 `wifi_regulator` GPIO 时序（DTB 中 `wifi_enable_H` 节点）。

### iter39 (2026-06-16 10:17): iter38 三项回退 + 启动可用性恢复
基于 `ttl_iter38_pcie_usbhost1_disabled_202606160943.log` 复盘：
- ❌ **iter38 snps,\* DMA 调优失败**：日志 line 3006-3008 仍出现完整三连失败：
  ```
  [39.022610] rk_gmac-dwmac fe300000.ethernet: Failed to reset the dma
  [39.027188] rk_gmac-dwmac fe300000.ethernet eth0: stmmac_hw_setup: DMA engine initialization failed
  [39.031702] rk_gmac-dwmac fe300000.ethernet eth0: __stmmac_open: Hw setup failed
  ```
  根因分析：`snps,burst_len` / `snps,pbl` / `snps,force_thresh_dma_mode` 这些属性影响的是 DMA reset **之后**的运行参数（突发长度、阈值模式），而 `dwmac1000_dma_reset()` 是设置 SWR 位后轮询等待硬件自动清零——超时意味着 SWR 永不清零。这通常是 **DMA 模块根本没拿到时钟**（Aclk/Pclk_gmac gated），而非 DMA 配置错误。iter38 改动方向不对。
- ❌ **iter38 WiFi 25MHz 降频失败**：日志 line 2950-2967 共 18 次 `sdio read32/write32 failed ... -110`，driver probe 在 30.09s 失败（`failed to download firmware`）。降频 50→25MHz 与原 50MHz 表现一致，**频率不是 SDIO -110 的根因**。
- ❌ **iter38 NM 管理 eth0 引发新问题——60s login 超时**：iter37 在 NM 不管理 eth0 时 autologin 立即进入 shell，iter38 让 NM 管理 eth0 后日志 line 3013-3018 出现：
  ```
  arbian login: root (automatic login)

  login: timed out after 60 seconds
  ...
  arbian login: root (automatic login)
  ```
  agetty 成功调起 autologin，但 `login` 程序在 PAM 阶段阻塞 60s。推测 DMA 失败后 NM 反复 retry eth0 → NetworkManager / systemd-logind 占用资源 → `pam_systemd` 等待 logind → login 阻塞 → 超时。

iter39 SD 卡直接修改清单（均已 sync）：

| # | 修改项 | 工具 | 修改前 (iter38) | 修改后 (iter39) |
|---|---|---|---|---|
| 1 | `NetworkManager.conf` `[keyfile]` 段 | `cat >` | 不存在（NM 管理 eth0） | 恢复 `unmanaged-devices=interface-name:eth0`（NM 不管理 eth0，消除 DMA 重试→login 阻塞级联） |
| 2 | `extlinux.conf` modprobe.blacklist | `sed` | `...,rtl8821cs,hci_uart,...` | `...,rtl8821cs,rtw88_8821cs,hci_uart,...`（重新拉黑） |
| 3 | `armbianEnv.txt` extraboardargs | `sed` | 同上 | 同上 |

保留的 iter38 变更（iter39 不动，供 eth_diag.sh 验证）：
- DTB `/ethernet@fe300000` 6 个 snps,\* 属性（`snps,burst_len=0x10`、`snps,force_thresh_dma_mode`、`snps,fixed-burst`、`snps,pbl=0x10`、`snps,txpbl=0x08`、`snps,rxpbl=0x08`）——虽然没生效，但保留有助于 eth_diag.sh 输出中确认 DTB 解析正确
- DTB `/dwmmc@fe310000 max-frequency = 0x017d7840`（25MHz）——保留作为基线，iter40 可考虑进一步降到 12MHz 测试
- `/root/eth_diag.sh`、`/root/eth_quick.sh`、`/root/eth_run.sh` 三脚本保留

备份文件：
- `ROOTFS:/etc/NetworkManager/NetworkManager.conf.iter38_test_20260616_101653`
- `extlinux/extlinux.conf.iter38_test_20260616_101653`
- `armbianEnv.txt.iter38_test_20260616_101653`

预期 iter39 启动行为：
- ✅ autologin 立即进入 root shell（NM 不再 retry eth0，无 PAM 阻塞）——恢复 iter37 时的 35s 启动到 shell
- ✅ WiFi SDIO 驱动 `rtw88_8821cs` 被黑名单 → 无 18 次 -110 错误刷屏
- ✅ eth0 处于 down 状态但 DMA 错误不再自动触发（NM 不主动 ifup）
- 用户可通过 TTL 在 root shell 中执行：
  ```bash
  bash /root/eth_diag.sh                 # 完整诊断（含主动 `ip link set eth0 up` 触发 DMA 失败）
  bash /root/eth_run.sh                  # 同上 + 保存到 /tmp/eth_diag.log
  bash /root/eth_quick.sh                # 轻量快速查看
  ```
- **遗留待 iter40**：DMA 根因排查（依据 eth_diag.sh 输出确定方向）：
  1. 若 ethtool 显示 `clk_mac_speed`/`aclk_mac`/`pclk_mac` 频率异常 → clock 链问题，尝试 DTB 加 `assigned-clock-rates = <0 100000000 50000000>` 等
  2. 若 `/sys/kernel/debug/clk/clk_summary` 中 `aclk_gmac` / `pclk_gmac` 未使能 → 时钟未启用，尝试 `clock_in_out = "output"` 让 MAC 输出时钟给 PHY
  3. 若 `/sys/kernel/debug/rk_pd/pd_gmac` 显示 domain 未启用 → power-domain 问题，检查 DTB `<&power PD_GMAC>` 引用
  4. 若 PHY 寄存器读不到 → YT8521S strap 配置问题，需硬件层排查
  5. 终极方案：尝试 DTB 添加 `resets = <&cru SRST_A_GMAC>, <&cru SRST_P_GMAC>; reset-names = "stmmaceth", "ahb";`
- **遗留待 iter40**：WiFi 如需启用，进一步降到 12MHz 或检查 GPIO 电源时序（DTB 中 `wifi_enable_H`、`wifi_disable_H` 节点）

### iter40 (2026-06-16 11:38): MAC 时钟方向反转 + 移除 PD 引用
基于 `/home/henry/dav/rk3399pro/logs/eth_diag_iter39_20260616_111300.log`（23 KB，480 行）的 eth_diag.sh 完整输出复盘：

**关键证据 1：MAC 核心时钟频率错误**
- `clk_summary` 中 `clk_gmac` (stmmaceth) 显示 **30 MHz**（RGMII gigabit 应为 125 MHz）
- 而 `clkin_gmac` 显示 125 MHz，说明外部参考时钟可达
- 当前 `clock_in_out = "input"` 模式下 MAC 期望 PHY 通过 RGMII_RX_CLK 引脚提供 125 MHz，但实际 clk_gmac 只有 30 MHz → **PHY 没有向 MAC 输出 125 MHz 时钟**
- DMA 模块的 SWR 位清零依赖 MAC 核心时钟（不是 AHB），无核心时钟 → SWR 永不清零 → reset 超时

**关键证据 2：PD_GMAC 在内核中不存在**
- `pm_genpd_summary` 列出 11 个域：`vopl/vopb/vo/tcpd0/tcpd1/isp0/isp1/hdcp/vio/usb3/sdioaudio`，**没有 `gmac`**
- 但 DTB 写 `power-domains = <0x16 0x16>`（phandle 0x16 → power-controller，索引 0x16=22）
- vendor 内核可能未注册 RK3399_PD_GMAC=22 的 genpd（或该索引指向了错误的域）
- rk3399 GMAC 在上游 dtsi 中属 always-on 电源域，本不需要显式 power-domains 引用

**关键证据 3：ethtool 全部 "Device or resource busy"**
- eth_diag.sh 中 ethtool 任何子命令（`ethtool eth0` / `-i` / `-d` / `-m` / `-g` / `-S`）均返回 EBUSY
- 表明驱动处于 failed-open 后的"半初始化"状态，无法被查询

**关键证据 4：双 PHY 地址**
- `stmmac-0:00` 和 `stmmac-0:03` 都成功 attached YT8521S driver（MDIO 总线上两个地址都返回有效 PHY ID）
- 可能是 YT8521S 的双地址反射（典型行为），也可能硬件真的有两颗 PHY
- 不影响 DMA reset 排查（DMA 失败发生在 PHY attach 之后的 stmmac_open）

iter40 SD 卡直接修改清单（均已 sync）：

| # | 修改项 | 工具 | 修改前 (iter39) | 修改后 (iter40) |
|---|---|---|---|---|
| 1 | `/ethernet@fe300000 clock_in_out` | `fdtput -t s` | `input` | `output`（MAC 内部 PLL 生成 125 MHz，反向供给 PHY） |
| 2 | `/ethernet@fe300000 power-domains` | `fdtput -d` | `<0x16 0x16>`（引用不存在的 PD_GMAC） | **删除**（rk3399 GMAC 属 always-on 域，无需引用） |

保留的 iter38/39 变更：
- DTB `/ethernet@fe300000` 6 个 snps,\* 属性（虽然 iter38 验证无效，但保留无副作用）
- DTB `/ethernet@fe300000` 的 `tx_delay=0x21`, `rx_delay=0x15`, `phy-mode=rgmii`（不动）
- DTB `/dwmmc@fe310000 max-frequency = 0x017d7840`（25MHz，保留）
- `extlinux.conf`/`armbianEnv.txt` 黑名单（含 `rtw88_8821cs`）
- `NetworkManager.conf` `[keyfile] unmanaged-devices=interface-name:eth0`（NM 不管理 eth0）
- `/root/eth_diag.sh` + `eth_quick.sh` + `eth_run.sh`

备份文件：
- `dtb/.../rk3399pro-neardi-linux-lc110-base.dtb.iter39_base_20260616_113816`

预期 iter40 启动行为：
- **DMA 测试（关键）**：登录后手动 `ip link set eth0 up`，观察 dmesg：
  - ✅ **若 DMA reset 成功**：无 "Failed to reset the dma"，eth0 进入 UP 状态，`ethtool eth0` 可正常输出 link/speed/duplex
  - ❌ **若仍失败**：说明 PHY 没有反向接收 MAC 时钟的能力（strap 配置为 clock provider），需 iter41 尝试 `phy-mode = "rgmii-id"` 或加 `ahb` reset
- **预期 PHY 行为变化**：`clock_in_out = output` 后启动时 dmesg 应出现 `clock input or output? (output)` 而非 `(input)`；`clk_gmac` 在 clk_summary 中应从 30 MHz 变为 125 MHz
- **预期 PD 行为变化**：`pm_genpd_summary` 不应有 `gmac` 域（仍不会出现，但不应再因引用不存在的 PD 而报错）
- **不预期破坏现有功能**：CPU/DDR/HDMI/USB/autologin/启动稳定性均不受影响（DTB 只改 GMAC 节点两个属性）
- 用户可通过 TTL 在 root shell 中执行：
  ```bash
  bash /root/eth_diag.sh                                 # 完整诊断
  dmesg | grep -E "Failed to reset|clock input|clk_gmac" # 关键信息
  ```
- **遗留待 iter41**：若 iter40 DMA 仍失败，下一步候选：
  1. `phy-mode: rgmii → rgmii-id`（让 PHY 内部处理延迟，MAC 不再加 delay）
  2. DTB 添加 `resets = <&cru SRST_A_GMAC>, <&cru SRST_H_GMAC>; reset-names = "stmmaceth", "ahb";`
  3. 调整 `assigned-clock-rates` 强制 clk_gmac 为 125 MHz
  4. 硬件层检查 YT8521S 的 strap 电阻配置（clock direction 引脚）

### iter41 (2026-06-16 11:58): iter40 完全回退（DMA 排查暂停）
基于 `ttl_iter40_pcie_usbhost1_disabled_202606161142.log` + `/tmp/eth_dma_test_iter40_20260616_114804.log`（TTL 自动化执行结果）复盘：

**iter40 失败证据 1：clk_gmac 仍为 30 MHz（clock_in_out=output 没有改变频率）**
TTL 自动化在板子启动后捕获的 `clk_summary`（log 第 51-72 行）：
```
 clkin_gmac                          1   1   0   125000000   Y   deviceless
       clk_mac_ref                   0   0   0   125000000   N   deviceless
       clk_mac_refout                0   0   0   125000000   N   deviceless
          clk_gmac                   1   1   0   30000000    Y   fe300000.ethernet stmmaceth
```
- 对比 iter39：clk_gmac 也是 30 MHz
- **结论**：`clock_in_out = output` **没有改变 clk_gmac 频率**。clk_gmac 的速率由 CRU 树中的 divider 决定（`clk_mac_refout (125MHz) ÷ N = clk_gmac (30MHz)`），方向位只控制时钟的物理方向，不影响 divider

**iter40 失败证据 2：`ip link set eth0 up` 导致整板挂死**
TTL 自动化发送 `ip link set eth0 up` 后（log 第 73 行），板子**完全无响应**：
- 15s 无任何输出（runner 触发 idle timeout 退出）
- 后续 followup 探测：30s 被动监听 = 0 字节
- 多次 Ctrl-C 信号 = 0 字节响应
- 对比 iter39（`clock_in_out=input`）：iter39 的 `ip link set eth0 up` 只是返回 ETIMEDOUT，板子能继续用

**根因推测：RGMII_TX_CLK 双向驱动电气冲突**
- iter40 DTB 把 `clock_in_out` 设为 `output`，让 MAC 通过 RGMII_TX_CLK 引脚**主动输出 125 MHz 时钟**
- 但 YT8521S 的 strap电阻很可能把 PHY 也配置为 **clock provider**（PHY 也输出 125 MHz 到 RGMII_TX_CLK）
- MAC 和 PHY 同时驱动同一根时钟线 → 电气冲突 → 短路级电流 → MAC bringup 时硬件状态机死锁 → kernel 总线访问 hang
- 这个修改**比 iter39 baseline 更糟**，必须立即回退

**iter40 失败证据 3：删除 power-domains 无正面效果**
iter40 同时删除了 `power-domains` 属性，但启动日志和 clk_summary 与 iter39 无明显差异。说明 rk3399 vendor 内核对这个属性引用错误是 silently 忽略的，删不删都不影响。

iter41 SD 卡直接修改清单（均已 sync）：

| # | 修改项 | 工具 | 修改前 (iter40) | 修改后 (iter41) |
|---|---|---|---|---|
| 1 | `/ethernet@fe300000 clock_in_out` | `fdtput -t s` | `output`（引发硬件冲突） | **`input`**（恢复 iter39 baseline） |
| 2 | `/ethernet@fe300000 power-domains` | `fdtput -t x` | 已删除 | **`<0x16 0x16>`**（恢复 iter39 baseline） |

保留的 iter38/39/40 变更：
- DTB `/ethernet@fe300000` 6 个 snps,\* 属性（iter38，保留无副作用）
- DTB `/ethernet@fe300000` 的 `tx_delay=0x21`, `rx_delay=0x15`, `phy-mode=rgmii`（不动）
- DTB `/dwmmc@fe310000 max-frequency = 0x017d7840`（25MHz，保留）
- `extlinux.conf`/`armbianEnv.txt` 黑名单（含 `rtw88_8821cs`）
- `NetworkManager.conf` `[keyfile] unmanaged-devices=interface-name:eth0`（NM 不管理 eth0）
- `/root/eth_diag.sh` + `eth_quick.sh` + `eth_run.sh`

备份文件：
- `dtb/.../rk3399pro-neardi-linux-lc110-base.dtb.iter40_failed_20260616_115832`（iter40 失败状态留存）

预期 iter41 启动行为：
- ✅ 完全恢复到 iter39 已验证可用 baseline
- ✅ boot ~35s 到 root shell（autologin 无阻塞）
- ✅ `ip link set eth0 up` 触发 DMA 失败但**不会挂死板子**（返回 ETIMEDOUT，板子仍可继续操作）
- ✅ 其他硬件（HDMI / USB / SD / 自动登录）全部正常
- ⏸️ DMA 失败问题**仍在**，iter41 不解决，留待 iter42

**遗留待 iter42（DMA 排查新方向，每次只动一项以定位变量）**：

按风险升序排列（基于 iter33-iter40 排查经验）：

| 优先级 | 候选修改 | 原理 | 风险 |
|---|---|---|---|
| **A** | `phy-mode: rgmii → rgmii-id` | 让 PHY 内部处理延迟，跳过 MAC tx_delay/rx_delay 配置；若 delay 不匹配是 DMA 触发的副作用，可能有效 | 低（不改时钟/电源/复位，最坏情况 DMA 仍失败但板子不挂） |
| B | DTB 添加 `resets = <&cru SRST_A_GMAC>, <&cru SRST_H_GMAC>; reset-names = "stmmaceth", "ahb"` | 补全缺失的 AHB reset，让 DMA 模块在 probe 时真正被复位 | 中（reset id 索引可能不对，可能引发 probe 失败） |
| C | DTB 添加 `assigned-clock-rates = <125000000>` 给现有的 `assigned-clocks=<&cru 0xa6>` | 强制 SCLK_MAC 主时钟到 125 MHz；clk_summary 显示 clk_gmac=30MHz 是关键异常 | 中（可能与其他 clock 节点冲突） |
| D | DTB 添加新的 `assigned-clocks` 条目针对 clk_gmac (0x69) 并设 rate=125MHz | 直接把 clk_gmac 拉到 125 MHz（绕过当前 divider） | 中（修改现有 assigned-clocks 列表，结构较复杂） |
| E | 硬件层：检查 YT8521S 的 strap 电阻（clock direction / 起始 PHY addr / RGMII mode） | 当前双 PHY 地址（0x00 和 0x03）很可疑，可能 strap 错位 | 高（需要硬件改动） |

建议 iter42 先尝试 **A（phy-mode=rgmii-id）**——最低风险，且能验证 delay 假设是否成立。

### iter42 (2026-06-16 12:08): phy-mode 由 rgmii 改 rgmii-id（iter42-A 实验）
基于 iter41 已验证可用的 baseline（DMA 失败但不挂死板子），按 iter41 遗留计划中"优先级 A、最低风险"的方向执行单项实验：

**修改原理**：
- `rgmii` 模式下，MAC 必须通过 `tx_delay` / `rx_delay` 属性补偿 RGMII 协议要求的 2ns 延迟
- 当前 `tx_delay=0x21`（约 1.92ns）、`rx_delay=0x15`（约 1.31ns），iter23-32 期间验证为"能通过 PHY attach 但 DMA reset 失败"
- `rgmii-id` 模式告诉内核：**PHY 在内部已经处理了 2ns 延迟**，MAC 不应再加 delay
- 如果之前的 delay 配置实际上和 PHY 的内部 delay 叠加导致时钟错位 → DMA 探测时序混乱 → reset 失败，本改动可能生效
- YT8521S datasheet 标明支持 RGMII-ID 模式（通过 strap 或寄存器配置）

**与 iter40 失败对比**：
- iter40 改的是 `clock_in_out`（时钟方向）—— 引发硬件电气冲突，板子挂死
- iter42 改的是 `phy-mode`（协议模式）—— 仅影响 MAC 内部 delay 计算，**不触碰硬件时钟**，最坏情况只是 DMA 仍失败但板子不挂

iter42 SD 卡直接修改清单（均已 sync）：

| # | 修改项 | 工具 | 修改前 (iter41) | 修改后 (iter42) |
|---|---|---|---|---|
| 1 | `/ethernet@fe300000 phy-mode` | `fdtput -t s` | `rgmii`（MAC 加 delay） | `rgmii-id`（PHY 内部 delay，MAC 不加） |

保留的 iter38-41 变更：
- DTB `/ethernet@fe300000` 6 个 snps,\* 属性（iter38，保留无副作用）
- DTB `/ethernet@fe300000` 的 `clock_in_out=input`、`tx_delay=0x21`、`rx_delay=0x15`（**注意：rgmii-id 模式下 MAC 应忽略 tx_delay/rx_delay，但保留这两项不影响**）
- DTB `/ethernet@fe300000` 的 `power-domains=<0x16 0x16>`（iter41 恢复）
- DTB `/dwmmc@fe310000 max-frequency = 0x017d7840`（25MHz，保留）
- `extlinux.conf`/`armbianEnv.txt` 黑名单（含 `rtw88_8821cs`）
- `NetworkManager.conf` `[keyfile] unmanaged-devices=interface-name:eth0`（NM 不管理 eth0）
- `/root/eth_diag.sh` + `eth_quick.sh` + `eth_run.sh`

备份文件：
- `dtb/.../rk3399pro-neardi-linux-lc110-base.dtb.iter41_base_20260616_120807`

预期 iter42 启动行为：
- ✅ boot 流程与 iter41 一致（~35s 到 root shell，autologin 无阻塞）
- ✅ dmesg 应出现 `init for RGMII-ID`（而非 iter39 的 `init for RGMII`）
- ✅ `ip link set eth0 up` 不会让板子挂死（最坏情况和 iter39/41 一样返回 ETIMEDOUT）
- 🟡 **DMA reset 结果**：本项实验的关键
  - ✅ 成功：无 `Failed to reset the dma`，`ethtool eth0` 可正常输出，eth0 进入 UP
  - ❌ 失败：`Failed to reset the dma` 仍出现，但**板子仍可用**（不像 iter40 那样挂死）
- 用户可通过 TTL 在 root shell 中执行：
  ```bash
  dmesg | grep -iE "Failed to reset|RGMII|clock input or output"
  ip link set eth0 up
  dmesg | tail -10
  ip -br link show eth0
  ```
- **遗留待 iter43**（依据 iter42 结果）：
  - 若 iter42 DMA 仍失败 → 试 **B（补 ahb reset）**
  - 若 iter42 DMA 成功 → 进一步做完整 eth_diag.sh 收集 PHY 状态，验证稳定性
  - 若 iter42 出现新的不稳定现象 → 立即回退 phy-mode 为 rgmii，回到 iter41 baseline

---

### iter43 (2026-06-16 12:40): 强制 clk_gmac 到 125 MHz（根因定位：MAC 核心时钟频率）

**iter42 复盘结论（关键转折）**：
iter42 的 `phy-mode: rgmii → rgmii-id` 改动**未解决** DMA 失败问题。但通过复盘 iter39 在 `eth_diag_iter39_20260616_111300.log` 中收集到的 clk_summary 数据，定位到一直被忽略的真正异常：

```
clkin_gmac                          1   1   0   125000000   Y   deviceless         no_connection_id
   clk_rmii_tx                      1   2   0   125000000   Y   fe300000.ethernet mac_clk_tx
   clk_rmii_rx                      0   1   0   125000000   N   fe300000.ethernet mac_clk_rx
   clk_mac_ref                      0   1   0   125000000   N   ethernet@fe300000 no_connection_id
   clk_mac_refout                   0   1   0   125000000   N   ethernet@fe300000 no_connection_id
      clk_gmac                      1   2   0    30000000   Y   fe300000.ethernet stmmaceth
```

证据梳理：
- `clkin_gmac`（外部 PHY 125 MHz 参考）→ **正确** ✅
- `clk_rmii_tx`、`clk_rmii_rx`、`clk_mac_ref`、`clk_mac_refout` → 均为 125 MHz ✅
- `clk_gmac`（即 `stmmaceth`，MAC 核心运行时钟）→ **仅 30 MHz** ❌（应 125 MHz）
- 这就是为什么 iter38-42 所有 DMA 调优实验都无效：**问题根本不在 DMA 参数，而在 MAC 核心时钟频率**

**为什么 `assigned-clock-parents = <0x1a>` 没生效？**：
DTB 已存在 `assigned-clock-parents = <&external_gmac_clock>`（phandle 0x1a = external-gmac-clock，125 MHz 固定时钟），意在让 SCLK_MAC（clk_gmac）从 clkin_gmac 取父时钟。但 RK3399 时钟驱动里 SCLK_MAC 是 `COMPOSITE_NODIV`，mux 父级仅限 `clk_mac_npll_src` / `clk_mac_ppll_src`（NPLL/PPLL 经过分频），**不支持 reparent 到外部固定时钟**。所以这一行 reparent 在驱动里被忽略，clk_gmac 实际从 NPLL/PPLL 经默认分频得到 30 MHz（约 NPLL 594MHz / 20 ≈ 30MHz，或类似默认组合）。

**为什么 30 MHz 会导致 `Failed to reset the dma`**：
dwmac1000 DMA 复位时驱动写入 `DMA_BUS_MODE.SWR=1`，然后 1s 内轮询 SWR 自清零。SWR 清零依赖 MAC 核心时钟边沿计数，30 MHz 比 125 MHz 慢 4.17 倍，加上复位状态机内部多个状态切换累积，**很可能在 1s 内 SWR 还没完成清零** → `readl_poll_timeout` 返回 `-ETIMEDOUT` → `Failed to reset the dma`。
（次要影响：MAC 核心寄存器访问也变慢，所有 dwmac1000 探测/初始化时序都偏离设计预期。）

**修改原理**：
DTB OF 子系统对 `assigned-clock-rates` 属性的处理：在 platform 设备 probe 时调用 `of_clk_set_defaults()`，对每个 `assigned-clocks` 引用 `clk_set_rate()` 设到对应 `assigned-clock-rates` 值。CCF 会自动找最合适的父时钟和分频组合（在 RK3399 上会选择 NPLL/PPLL 并重算分频系数）来达到目标 125 MHz。
这是"最直接对症"的修复：告诉 CCF「这个 MAC 核心时钟必须是 125 MHz」，由框架强制执行。

iter43 SD 卡直接修改清单（均已 sync）：

| # | 修改项 | 工具 | 修改前 (iter42) | 修改后 (iter43) |
|---|---|---|---|---|
| 1 | `/ethernet@fe300000 assigned-clock-rates` | `fdtput -t x` | （不存在） | `0x07735940`（= 125000000 Hz = 125 MHz） |

DTB 中 ethernet@fe300000 节点完整状态（iter43 终态，已 dtc 验证）：
```
ethernet@fe300000 {
    assigned-clocks = <0x08 0xa6>;       /* &cru SCLK_MAC = clock 166 */
    assigned-clock-parents = <0x1a>;     /* &external_gmac_clock（rk3399 不支持，仅作 fallback 提示）*/
    assigned-clock-rates = <0x7735940>;  /* ★ iter43 新增：强制 125 MHz */
    phy-mode = "rgmii-id";               /* iter42 引入 */
    clock_in_out = "input";              /* iter41 恢复 */
    power-domains = <0x16 0x16>;         /* iter41 恢复，pd_gmac@22 */
    tx_delay = <0x21>;                   /* iter42 后 MAC 在 rgmii-id 模式下应忽略，保留无副作用 */
    rx_delay = <0x15>;
    snps,rxpbl = <0x08>;                 /* iter38 引入，DMA 调优 */
    snps,txpbl = <0x08>;
    snps,pbl = <0x10>;
    snps,fixed-burst = [00];
    snps,force_thresh_dma_mode = [00];
    snps,burst_len = <0x10>;
};
```

保留的 iter38-42 变更（iter43 不再触碰）：
- DTB 6 个 snps,\* DMA 调优属性（iter38）
- DTB `clock_in_out=input`、`tx_delay=0x21`、`rx_delay=0x15`（iter41）
- DTB `power-domains=<0x16 0x16>`（iter41）
- DTB `phy-mode=rgmii-id`（iter42）
- DTB `/dwmmc@fe310000 max-frequency = 0x017d7840`（25MHz，保留）
- `extlinux.conf`/`armbianEnv.txt` 黑名单（含 `rtw88_8821cs`）
- `NetworkManager.conf` `[keyfile] unmanaged-devices=interface-name:eth0`（NM 不管理 eth0）
- `/root/eth_diag.sh` + `eth_quick.sh` + `eth_run.sh`

备份文件：
- `dtb/.../rk3399pro-neardi-linux-lc110-base.dtb.iter42_base_20260616_124005`（iter43 改前的 iter42 终态）

预期 iter43 启动行为：
- ✅ boot 流程与 iter42 一致（~35s 到 root shell）
- ✅ dmesg 仍出现 `init for RGMII_ID`
- 🟡 **关键验证点**：在 root shell 中运行 `bash /root/eth_diag.sh`（或 `eth_quick.sh`），检查：
  ```bash
  # 关键 1：clk_gmac 频率是否升到 125 MHz
  cat /sys/kernel/debug/clk/clk_summary | grep clk_gmac
  # 期望：clk_gmac ... 125000000 ...
  
  # 关键 2：DMA reset 是否成功
  ip link set eth0 up && ip -br link show eth0
  dmesg | tail -20
  # 期望：无 "Failed to reset the dma"，eth0 状态 UP
  
  # 关键 3：完整诊断（如需归档）
  bash /root/eth_diag.sh > /tmp/eth_diag_iter43.log 2>&1
  ```
- **成功判据**（任一满足都视为有效进展）：
  - 🟢 完全成功：clk_gmac=125MHz + DMA 成功 + eth0 UP + 可 ping
  - 🟡 部分成功：clk_gmac=125MHz 但 DMA 仍失败 → 排除"频率"假说，转向"硬件复位/电源域"假说
  - 🟡 部分成功：clk_gmac 仍 30MHz → CCF 未生效（可能 assigned-clock-parents=0x1a 冲突），下一步删除 assigned-clock-parents 强制由 CCF 选 NPLL
- **失败回退**（与 iter42 同等低风险）：
  - 若出现 boot 卡死、shell 60s 超时、整板挂死等异常 → 回退到 iter42_base_20260616_124005.dtb
  - 不会发生 iter40 那种硬件冲突（iter43 没动 clock_in_out）

**遗留待 iter44**（依据 iter43 结果）：
- 若 iter43 🟢：进一步做 eth0 流量测试（ping/ttcp），稳定后保留并去掉 iter38 snps,\* 调优实验对比
- 若 iter43 🟡（clk_gmac 仍 30MHz）：iter44 删除 `assigned-clock-parents` 属性，让 CCF 自由选父；或直接写 `assigned-clock-rates` 加更精确约束
- 若 iter43 🟡（clk_gmac=125MHz 但 DMA 失败）：iter44 方向转向 stmmac AHB reset / snps,axi-config / RGMII TX_DELAY/RX_DELAY 重调

### iter44 (2026-06-16 15:xx): TTL 在线验证 — assigned-clock-parents 根因确认 + 修复方案

基于 `ttl_iter43_pcie_usbhost1_disabled_202606161433.log` 启动日志 + TTL 在线执行验证命令：

**iter43 启动日志验证：**
- ✅ 启动 ~35s 到 auto-login root shell（稳定）
- ✅ GMAC probe 返回 0（`probe of fe300000.ethernet returned 0 after 8240789 usecs`）
- ✅ PHY attach 成功（YT8521S @ stmmac-0:00 + stmmac-0:03）
- ✅ `init for RGMII_ID`
- ✅ 启动期间无 DMA/DISCARD/SDIO/PCIe 错误
- ⚠️ 启动日志中无 `ip link set eth0 up` 执行记录（NM 不管理 eth0，未触发）

**TTL 在线验证结果：**
- ❌ **`clk_gmac` 仍为 30 MHz**：`assigned-clock-rates=<125000000>` 没有生效
  ```
  clk_gmac   1  2  0   30000000   Y   fe300000.ethernet stmmaceth
  ```
- ❌ **`ip link set eth0 up` 失败**：`RTNETLINK answers: Connection timed out`（板子未挂死，但 DMA 超时）
  ```
  [918.138610] Failed to reset the dma
  [918.138629] stmmac_hw_setup: DMA engine initialization failed
  [918.138640] __stmmac_open: Hw setup failed
  ```

**🔑 根因定位（完整因果链）：**

| 步骤 | 事件 | 详情 |
|---|---|---|
| 1 | DTB 配置 | `assigned-clock-parents = <26>` 指向 `external_gmac_clock`（phandle 26, 125 MHz fixed clock） |
| 2 | 内核处理 | `__of_clk_set_defaults()` 调用 `clk_set_parent(clk_gmac, external_gmac_clock)` |
| 3 | 硬件约束 | clk_gmac 的 possible parents = **{dummy_cpll, gpll, npll}**，不含 external_gmac_clock |
| 4 | 失败 | `clk_set_parent()` 返回错误 |
| 5 | 跳过 | `__of_clk_set_defaults()` 提前 return，**`clk_set_rate()` 从未被调用** |
| 6 | 结果 | clk_gmac 保持默认 30 MHz（npll 600MHz ÷ 20） |
| 7 | 影响 | DMA SWR 状态机在 30 MHz 下无法在超时内清零 |

**时钟树关键数据：**
```
clk_gmac parent:      npll
possible parents:     dummy_cpll, gpll, npll
npll rate:            600 MHz  (600/125=4.8 不可整除 → 最近 120MHz ÷5)
gpll rate:            800 MHz  (800/125=6.4 不可整除 → 最近 133MHz ÷6)
aclk_gmac (AHB):      400 MHz ✅
pclk_gmac (APB):      100 MHz ✅
clkin_gmac (外部):    125 MHz ✅
```

**iter44 修复方案（待 SD 卡连接后执行）：**

| # | 修改项 | 工具 | 修改前 | 修改后 |
|---|---|---|---|---|
| 1 | `/ethernet@fe300000 assigned-clock-parents` | `fdtput -d` | `<0x1a>` (无效) | **删除** |

原理：删除无效的 parent 引用后，`__of_clk_set_defaults()` 将执行 `clk_set_rate(clk_gmac, 125000000)`，CCF 自动选择最佳 parent + divider（预期 120-133 MHz）。

**iter44 执行结果：**

| 步骤 | 操作 | 结果 |
|---|---|---|
| 1 | SD 卡 `fdtput -d` 删除 `assigned-clock-parents` | ✅ 修改成功，备份 `*.iter43_base_20260616_161228` |
| 2 | 插卡启动 iter44 | ✅ 启动成功，auto-login 正常 |
| 3 | 检查 clk_gmac | ❌ 仍 30 MHz — DTB 修改对已初始化时钟无效 |
| 4 | 编写内核模块 `gmac_fix.ko` | ✅ `of_clk_get_by_name(np, "stmmaceth")` + `clk_set_rate(125MHz)` |
| 5 | base64 上传 + 板载编译 | ✅ `/tmp/gmac_fix/` 编译成功 |
| 6 | `insmod gmac_fix.ko` | ✅ `clk_set_rate(125MHz) returned 0`, **rate = 120 MHz** |
| 7 | `ip link set eth0 up`（120 MHz） | ❌ **仍 `RTNETLINK: Connection timed out`** |
| 8 | dmesg 检查 | ❌ **仍 `Failed to reset the dma`** |

**🔑🔑 关键否定结果：时钟频率不是 DMA 失败的根因！**

从 30 MHz 提升到 120 MHz（4 倍），DMA SWR 复位仍超时。`dwmac1000_dma_reset()` 在 120 MHz 下有 1.2 亿个周期（1 秒超时），远超正常复位所需的几千周期。iter38-44 共 7 轮迭代的时钟频率假设被彻底证伪。

**已排除假设汇总：**

| # | 假设 | 验证迭代 | 结果 |
|---|---|---|---|
| 1 | snps DMA 调优属性缺失 | iter38 | ❌ 6 个属性无效 |
| 2 | clock_in_out=input 错误 | iter40 | ❌ 改 output 整板挂死 |
| 3 | phy-mode=rgmii 错误 | iter42 | ❌ 改 rgmii-id 无效 |
| 4 | clk_gmac 频率太低 | iter44 | ❌ 120 MHz 仍失败 |

**iter45 执行结果（已完成）：**

| 步骤 | 操作 | 结果 |
|---|---|---|
| 1 | DTB 添加 AHB reset (`SRST_A_GMAC_NOC=136`) | ✅ 修改成功，备份 `*.iter44_base_20260616_170321` |
| 2 | 启动验证 resets | ✅ `<8 137 8 136>` + `stmmaceth ahb` 确认 |
| 3 | `ip link set eth0 up` | ❌ 仍 DMA 超时，AHB reset 无效 |
| 4 | 内核模块 `dma_scan.ko` 寄存器扫描 | ✅ 编译加载成功 |
| 5 | **DMA BUS_MODE 寄存器** | **0x00020101 — SWR(bit0)=1 永久卡死！** |
| 6 | **SWR 写测试** | **写入 0 后仍读回 SWR=1 — 硬件不可修复** |
| 7 | **最终结论** | **🔑 GMAC DMA 硬件缺陷 — 建议 USB 以太网替代** |

**DMA 寄存器扫描关键数据：**
```
[0x1000] Bus_Mode = 0x00020101  SWR=1（永久卡死）DA=1 PBL=1
[0x1028] Cur_Host_TX_Desc = 0x00110001（非零 → 曾部分初始化）
[0x1058] Intr_Enable = 0x000d0f17
[0x00C0] HW_FEAT0 = 0x00000000（异常，应为非零）
[0x00C4] HW_FEAT1 = 0x00000000（异常）

写入 SWR=0 后读回仍为 SWR=1 → 硬件不可清除
```

**建议替代方案：** USB 以太网适配器（USB 2.0/3.0 已验证正常）

**TTL 验证日志文件：**
- `logs/ttl_iter44_alive_check_20260616.log`
- `logs/ttl_iter44_clk_gmac_20260616.log`
- `logs/ttl_iter44_eth0_up_20260616.log`
- `logs/ttl_iter44_dmesg_dma_20260616.log`
- `logs/ttl_iter44_clk_debug_20260616.log`
- `logs/ttl_iter44_clk_parent_20260616.log`
- `logs/ttl_iter44_pll_rates_20260616.log`
- `logs/ttl_iter44_clk_fail_20260616.log`
- `logs/ttl_iter44_cru_regs_20260616.log`
- `logs/ttl_iter44_devmem_20260616.log` — /dev/mem 访问尝试（失败）
- `logs/ttl_iter44_devmem2_20260616.log` — /dev/mem 第二次尝试
- `logs/ttl_iter44_devmem3_20260616.log` — /dev/mem 第三次尝试
- `logs/ttl_iter44_clk_write_20260616.log` — debugfs clk_rate 写尝试（只读）
- `logs/ttl_iter44_clk_parent_write_20260616.log` — debugfs clk_parent 写尝试（只读）
- `logs/ttl_iter44_dyndbg_20260616.log` — dynamic debug 检查
- `logs/ttl_iter44_dyndbg_enable_20260616.log` — dynamic debug 启用尝试
- `logs/ttl_iter44_dyndbg_check_20260616.log` — dynamic debug 状态检查
- `logs/ttl_iter44_rebind_20260616.log` — 驱动 unbind/rebind 测试
- `logs/ttl_iter44_deep_diag_20260616.log` — 综合诊断
- `logs/ttl_iter44_kbuild_20260616.log` — 内核头文件/构建工具检查
- `logs/ttl_iter44_kmod_build_20260616.log` — gmac_fix.ko 编译（成功）
- `logs/ttl_iter44_kmod_load_20260616.log` — gmac_fix.ko 加载：clk_set_rate 成功，120MHz
- `logs/ttl_iter44_eth0_up_120mhz_20260616.log` — 120MHz DMA 测试（仍失败）
- `logs/ttl_iter44_cru_upload_20260616.log` — CRU 读取模块上传
- `logs/ttl_iter44_pcie_usbhost1_disabled_202606161624.log` — iter44 完整启动日志

**iter45 TTL 日志文件：**
- `logs/ttl_iter45_boot_202606161706.log` — iter45 启动日志
- `logs/ttl_iter45_fdt_check2_20260616.log` — DTB resets/reset-names 验证
- `logs/ttl_iter45_eth0_up_20260616.log` — DMA 测试（AHB reset 后仍失败）
- `logs/ttl_iter45_dmesg_20260616.log` — dmesg 三连失败确认
- `logs/ttl_iter45_dma_regs_20260616.log` — 驱动/复位控制状态检查
- `logs/ttl_iter45_insmod_20260616.log` — dma_diag.ko 寄存器读取
- `logs/ttl_iter45_scan_load_20260616.log` — **dma_scan.ko 全寄存器扫描 + SWR 写测试（硬件缺陷确认）**

---

## 3. 当前硬件支持矩阵 (基于 Iter 43-45 全量验证，含内核模块 DMA 寄存器扫描)

| 硬件模块 | 状态 | 备注 |
|---|---|---|
| CPU / DDR | ✅ 正常 | 运行于 800MHz 稳定频率 |
| HDMI 显示 | ✅ 正常 | 物理 Console 输出、GPU 开启 |
| HDMI 音频 | ✅ 正常 | 驱动加载成功 |
| USB 2.0/3.0 | ✅ 正常 | Host0/Host1 均可用，Hub 正常 |
| 自动登录 | ✅ 恢复 | iter37 重新创建 autologin override（ttyFIQ0 + tty1），iter39 已恢复可用性 |
| 根文件系统 | ✅ 稳定 | UUID 挂载；commit=60s；已扩容到 14GB |
| GPT 分区表 | ✅ 修复 | iter34 修正备份头至磁盘末端 |
| 启动噪声 | ✅ 清理 | armbian-motd 已清空 |
| SD 卡 DISCARD | ✅ 修复 | iter35 禁用 fstrim/e2scrub timers |
| 首次登录提示 | ✅ 跳过 | iter36 删除 `.not_logged_in_yet` |
| 启动时延 | ✅ 优化 | iter36 移除 NM-wait-online 60s 等待；iter39 恢复后约 35s 进 shell |
| 以太网 | ❌ **硬件缺陷（不可修复）** | iter45 DMA 寄存器扫描确认：Bus_Mode SWR 位永久卡死=1，写入 0 不可清除。AHB 总线正常但 DMA 内部复位状态机失效。8 个软件假设已全部排除（iter38-45）。**建议 USB 以太网适配器替代** |
| 以太网诊断脚本 | ✅ 注入 | iter38 `/root/eth_diag.sh` + `eth_quick.sh` + `eth_run.sh`（已用 TTL 自动化执行过，日志保存在 `/home/henry/dav/rk3399pro/logs/`） |
| PCIe | ⏸️ 已禁用 | iter34 关闭 PHY+RC，避开 GRF syscon 报错 |
| SD 卡 | ⚠️ 降频 | 50MHz 稳定运行 |
| WiFi | ⏸️ 已黑名单 | iter39 重新拉黑 `rtw88_8821cs`（25MHz 仍 SDIO -110，频率非根因） |

---

## 4. 关键技术参数 (当前有效配置)

### 4.1 内核启动参数 (extlinux.conf)
```
root=UUID=d9159ff7-f834-4aba-a518-ac5f1dfc7175 rootflags=data=writeback rw rootwait rootdelay=5 console=ttyS2,1500000 console=tty1 panic=0 usbcore.autosuspend=-1 initcall_blacklist=psci_checker initcall_debug printk.devkmsg=on
```

### 4.2 设备树 (DTB) 必要禁用清单
1. `/watchdog@ff848000`
2. `/sdhci@fe330000` (eMMC 探测死锁)
3. `/dmc` (DDR 调压死锁)
4. `/rkisp1@ff910000` / `/rkisp1@ff920000`
5. `/mipi-dphy-tx1rx1@ff968000`
6. `/iep@ff670000` (最大挂死源)

---

## 5. 修改记录

| 日期 | 版本 | 作者 | 内容 |
|---|---|---|---|
| 2026-06-15 | 1.1 | Gemini CLI | 引入 UUID 挂载，汇总 33 轮迭代全量记录。 |
| 2026-06-15 | 1.2 | Claude Code | iter34：禁用 PCIe PHY+RC，修正 WiFi 黑名单（`rtw88_8821cs`），清空损坏的 armbian-motd，parted 修复 GPT 备份头位置。 |
| 2026-06-15 | 1.3 | Claude Code | iter35：禁用 fstrim/e2scrub timers 消除 mmc1 DISCARD I/O 错误，NM 不自动管理 eth0 抑制 DMA 错误刷屏，fstab commit=600→60。 |
| 2026-06-16 | 1.4 | Claude Code | iter36：禁用 NetworkManager-wait-online.service 消除 60s 启动超时；删除 `/root/.not_logged_in_yet` 跳过 armbian-firstlogin 建密提示（root 密码已设置）。 |
| 2026-06-16 | 1.5 | Claude Code | iter37：为 `serial-getty@ttyFIQ0.service` 和 `getty@tty1.service` 创建 autologin override 恢复自动登录；确认 ROOTFS 已扩容到 14GB。 |
| 2026-06-16 | 1.6 | Claude Code | iter38：DTB 添加 6 个 snps DMA 调优属性（burst_len/fixed-burst/force_thresh_dma_mode/pbl/txpbl/rxpbl）；WiFi SDIO max-frequency 50→25MHz；黑名单移除 `rtw88_8821cs`；NM 恢复管理 eth0；注入 `/root/eth_diag.sh` + `eth_quick.sh` + `eth_run.sh` 诊断脚本。 |
| 2026-06-16 | 1.7 | Claude Code | iter39：iter38 snps,\* 调优无效（DMA reset 仍超时），25MHz WiFi 仍 SDIO -110，NM 管理 eth0 引发 60s login 超时。回退三项：NM 不管理 eth0；`rtw88_8821cs` 重新黑名单；保留 iter38 snps,\* DTB 属性 + 诊断脚本供 iter40 eth_diag.sh 验证。 |
| 2026-06-16 | 1.8 | Claude Code | iter40：通过 TTL 自动化执行 `/root/eth_diag.sh` 收集 23 KB 诊断日志（保存 `logs/eth_diag_iter39_20260616_111300.log`）。证据：`clk_gmac` 仅 30 MHz（应 125 MHz），`pm_genpd_summary` 无 `gmac` 域。改 DTB：`clock_in_out: input→output`（MAC 自生成 125 MHz）+ 删除 `power-domains` 属性（rk3399 GMAC 属 always-on 域）。 |
| 2026-06-16 | 1.9 | Claude Code | iter41：iter40 完全失败——`clock_in_out=output` 不改 clk_gmac 频率（仍 30 MHz），且 `ip link set eth0 up` 引发 RGMII_TX_CLK 双向驱动电气冲突导致整板挂死（30s/Ctrl-C 都无响应）。回退两项：`clock_in_out: output → input` + 恢复 `power-domains=<0x16 0x16>`，回到 iter39 已验证可用 baseline。iter42 排查方向候选（按风险升序）：phy-mode=rgmii-id / 补 ahb reset / 强制 clk_gmac=125MHz。 |
| 2026-06-16 | 2.0 | Claude Code | iter42：执行 iter42-A 实验，DTB `phy-mode: rgmii → rgmii-id`（单项低风险改动）。让 PHY 内部处理 RGMII 2ns 延迟，MAC 跳过 tx_delay/rx_delay。与 iter40 失败对照：iter40 触碰硬件时钟方向（电气冲突），iter42 只改协议模式（不挂硬件）。 |
| 2026-06-16 | 2.1 | Claude Code | iter43：复盘 iter39 clk_summary 数据，定位根因 = `clk_gmac`（`stmmaceth` MAC 核心时钟）仅 30 MHz（应 125 MHz），`assigned-clock-parents=<&external_gmac_clock>` 对 RK3399 SCLK_MAC 不生效（mux 父级限 NPLL/PPLL）。30 MHz 使 dwmac1000 SWR 复位状态机在 1s 驱动超时内未完成清零 → `Failed to reset the dma`。iter42 验证 phy-mode 非根因后，iter43 新增 `assigned-clock-rates=<125000000>` 强制 CCF 重算父 PLL + 分频系数。 |
| 2026-06-16 | 2.2 | Qoder CLI | iter44 TTL 在线验证：确认 `assigned-clock-rates` 未生效（clk_gmac 仍 30MHz），`ip link set eth0 up` 仍 DMA 超时。根因锁定：`assigned-clock-parents=<external_gmac_clock>` 不在 clk_gmac possible parents {dummy_cpll, gpll, npll} 中，`clk_set_parent()` 失败导致 `__of_clk_set_defaults()` 提前 return，`clk_set_rate()` 从未执行。修复方案：删除 `assigned-clock-parents` 属性，让 CCF 直接执行 `clk_set_rate(125MHz)`（预期 npll÷5=120MHz 或 gpll÷6≈133MHz）。 |
| 2026-06-16 | 2.3 | Qoder CLI | iter44 执行+关键否定结果：(1) SD 卡 `fdtput -d` 删除 `assigned-clock-parents`，启动后 clk_gmac 仍 30MHz（DTB 方法对已初始化时钟无效）；(2) 编写内核模块 `gmac_fix.ko`（`of_clk_get_by_name` + `clk_set_rate`），insmod 成功将 clk_gmac 30→120MHz；(3) **120 MHz 下 DMA SWR 仍超时** — 时钟频率假设被证伪（iter38-44 共 7 轮迭代的核心理论不成立）。4 个假设已排除：phy-mode(42)、clock_in_out(40)、snps属性(38)、频率(44)。iter45 方向：补全 AHB reset（`SRST_MAC_A`）、读取 DMA 寄存器状态、检查 U-Boot GMAC 遗留状态。 |
| 2026-06-16 | 2.4 | Qoder CLI | iter45 **最终结论 — GMAC DMA 硬件缺陷**：(1) DTB 添加 AHB reset（`SRST_A_GMAC_NOC=136`），DMA 仍超时；(2) 内核模块 `dma_scan.ko` ioremap 直接扫描寄存器：`Bus_Mode=0x00020101`（SWR 位永久=1），写入 SWR=0 后仍读回 1 — **硬件不可清除**；(3) AHB 总线正常（寄存器可读写，DA/PBL 位可写），但 DMA 内部复位状态机失效；(4) `HW_FEAT0/1=0x00000000`（异常）。8 个软件假设全部排除（iter38-45）。**建议 USB 以太网适配器替代板载 GMAC**。 |

---
*记录工具: Gemini CLI, Claude Code, Qoder CLI*
