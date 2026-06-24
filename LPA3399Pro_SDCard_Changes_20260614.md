# LPA3399Pro SD 卡修改日志

> 本文件记录对 SD 卡的所有修改，作为后续迭代的复现依据。
> 基础镜像（已确认 BootROM 可识别）：`Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.1.141_server_2026.06.11_hybrid_sdkboot.img`
> 节省磁盘原则：不再生成新的 iter<N>.img，每次直接修改 SD 卡

---

## 0. 工作流（节省磁盘版）

```bash
# 1. 关板子电源，拔 SD 卡，插到主机
lsblk  # 确认 SD 卡设备名，假设为 /dev/sdX

# 2. 挂载 boot 和 root 分区
sudo mkdir -p /mnt/sd_boot /mnt/sd_root
sudo mount /dev/sdX1 /mnt/sd_boot
sudo mount /dev/sdX2 /mnt/sd_root

# 3. 应用本文档列出的修改（用 Edit 工具改 extlinux.conf / armbianEnv.txt / DTB）

# 4. 备份原文件（可选，做对比用）
sudo cp /mnt/sd_boot/extlinux/extlinux.conf{,.bak.<date>}

# 5. 卸载
sync
sudo umount /mnt/sd_boot /mnt/sd_root

# 6. 拔回板子，上电
```

---

## 1. 当前 SD 卡状态：iter7 配置（2026-06-14 12:16）
... (略) ...

---

## 2. 历史迭代记录

### iter1-iter16 (略)

#### 实测结果（2026-06-15 10:25，TTL `ttl_iter17_pcie_usbhost1_disabled_202606151025.log`）
- 结论：**重大突破！系统已成功启动至登录界面。**

#### 实测结果（2026-06-15 11:18，TTL `ttl_iter22_pcie_usbhost1_disabled_202606151118.log`）
- 结论：**HDMI 显示全面恢复**。HDMI 成功初始化并显示 console。

#### 实测结果（2026-06-15 13:41，TTL `ttl_iter31_pcie_usbhost1_disabled_202606151341.log`）

| 指标 | iter30 | iter31（回退 Syscon 尝试）|
|---|---|---|
| 系统状态 | ✅ 稳定登录 | **✅ 稳定登录** |
| HDMI 显示 | ✅ | **✅ 正常显示** |
| 以太网 (U-Boot) | ❌ No ethernet found | ❌ 依然报 `No ethernet found` |
| 以太网 (Kernel) | ❌ 失败 | ❌ 依然报 `Failed to reset the dma` |
| WiFi 状态 | ⚠️ -110 | ⚠️ 50MHz 下依然报 -110 |

**结论**：**系统基础“稳态”已确立。** 串口登录、HDMI Console、USB Host、HDMI 音频均已正常。以太网和 WiFi 的问题具有深度驱动不兼容特征。特别观察到开启 WiFi SDIO 节点会导致 U-Boot 丢失网卡识别。

### iter32（2026-06-15 13:55，**待测**）
- 改动方式：直接改 SD 卡 DTB
- DTB 修改：禁用 WiFi 以验证以太网冲突，恢复 Syscon 基准

#### 变更内容

**DTB**:
- **禁用 WiFi**：将 `/dwmmc@fe310000` 设为 `disabled`。
    - *目的：验证启用 WiFi 节点是否是导致 U-Boot 丢失网卡及内核 DMA 重置失败的资源竞争诱因。*
- **恢复 Syscon 基准**：将 `/syscon@ff770000` 恢复为标准的 `"rockchip,rk3399-grf", "syscon", "simple-mfd"`，并删除 experimental 的 PCIe GRF 引用。

#### 目的
1.  **验证冲突假设**：通过彻底移除 WiFi 节点，观察以太网（尤其是 U-Boot 识别）是否能恢复正常。
2.  **固化基准版**：将系统状态恢复至已知最稳定的“纯净版”，作为适配成果的基石。

#### 当前 SD 卡 DTB 完整修改清单（10 处累计）

| # | 节点路径 | 属性 | 值 | 来源 |
|---|---|---|---|---|
| 1 | `/dwmmc@fe320000` (SD) | `max-frequency` | `0x2faf080` (50MHz) | iter1 |
| 2 | `/watchdog@ff848000` | `status` | `disabled` | iter1 |
| 3 | `/sdhci@fe330000` (eMMC host) | `status` | `disabled` | iter11 |
| 4 | `/dmc` (DDR devfreq) | `status` | `disabled` | iter12 |
| 5 | `/rkisp1@ff910000` | `status` | `disabled` | iter13 |
| 6 | `/rkisp1@ff920000` | `status` | `disabled` | iter13 |
| 7 | `/mipi-dphy-tx1rx1@ff968000` | `status` | `disabled` | iter13 |
| 8 | `/iep@ff670000` | `status` | `disabled` | iter25 |
| 9 | `/iommu@ff670800` | `status` | `disabled` | iter25 |
| 10| `/dwmmc@fe310000` (WiFi) | `status` | `disabled` | iter32 |

---

## 6. 修改记录

| 日期 | 版本 | 作者 | 内容 |
|---|---|---|---|
| 2026-06-15 | 2.9 | Gemini CLI | iter30 验证失败。回退 Syscon。系统基准功能稳定。 |
| 2026-06-15 | 3.0 | Gemini CLI | iter31 验证成功。开启 WiFi 导致以太网冲突假设测试。 |

---

*记录工具: Gemini CLI*
