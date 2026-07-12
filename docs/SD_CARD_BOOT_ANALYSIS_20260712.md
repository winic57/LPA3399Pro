# SD 卡启动分析（本机 /dev/sdc）— 2026-07-12

## 设备识别

| 项 | 值 |
|---|---|
| 设备 | `/dev/sdc`（USB STORAGE DEVICE，14.4G） |
| 分区 | `sdc1` LABEL=BOOT ext4 511M；`sdc2` LABEL=ROOTFS ext4 13.9G |
| 系统 | Armbian OS 26.05.0 trixie（Debian 13） |
| hostname | armbian |
| 挂载分析 | 只读挂载到 `/tmp/sd_audit_*` |

## 内核版本结论（最重要）

当前 BOOT 上的运行内核 **不是** 本地保留的 `0031` 产物，而是 **0044** 产物。

| 文件 | sha256 | 说明 |
|---|---|---|
| `/boot/Image` | `331e45b7...2c50` | 当前启动内核 |
| `/boot/vmlinuz-6.18.33-rk35xx-ophub` | 同上 | 与 Image 相同 |
| 备份 `Image.pre_gha...0044...` | `975ae71c...fa24` | 刷 0044 前备份 |
| 本地 `build_artifacts/...0031.../Image` | `52e86106...ec12` | 更旧一档 |
| 本地 `downloads/gha_29072024640_0044/Image` | `331e45b7...2c50` | **与 SD 当前内核完全一致** |

部署记录文件：

```text
/boot/deploy_gha29072024640_0044_c25c019_20260710_135201.sha256
```

时间线：

1. 曾部署 `pub7e98d1c ... 0031`（extlinux 备份名可见）
2. 之后于 **2026-07-10 13:52** 部署 `gha29072024640 / 0044 / c25c019`
3. 因此卡上是 **比 0031 更新的 LPA 编译产物（含 pcie_safe_retrain）**

### marker 对比

| marker | SD(0044) | 本地0031 |
|---|---:|---:|
| pcie_safe_retrain | 1 | 0 |
| pcie_deferred | 1 | 1 |
| npu_acm | 6 | 6 |
| dma_start_once | 1 | 1 |
| failfast | 7 | 7 |
| nfatal | 11 | 6 |

内核字符串：`Linux version 6.18.33 ... aarch64-linux-gnu-gcc 11.4.0`

## 启动配置

### 实际启动入口：extlinux

`DEFAULT dwc30030_pdotg`

```text
LINUX /Image
FDT /dtb/rockchip/lpa3399pro-0030-pd-usb0otg.dtb
APPEND root=PARTUUID=61ec8aeb-3d1a-48fa-a9da-54d744ed8bdf ...
  console=ttyS2,1500000 console=tty1
  maxcpus=4
  usbcore.autosuspend=-1
  initcall_blacklist=psci_checker
  ...
```

注意：

- 启动走 **extlinux**，不是 `armbianEnv.txt` 的 `fdtfile=...base.dtb`
- 当前默认 DTB 名称带 `0030`，但是 **PCIe deferred + display + USB0 OTG** 变体
- DTB model：`Neardi LPA3399Pro LC110 PCIe deferred display USB0 OTG A/B`

### 当前 DTB 关键节点

| 节点 | 状态/要点 |
|---|---|
| `pcie@f8000000` | `okay`，`rockchip,deferred=<1>`，`dma_trx_enabled=1` |
| `npu-refclk-keepalive` | `okay` |
| `usb@fe800000` (usb0/dwc3) | `okay`，`dr_mode=otg` |
| `usb@fe900000` | `okay`，`dr_mode=host` |
| GMAC | `okay` |

含义：Host PCIe 以 **deferred** 方式存在（适合 NPU 后上电再 link），USB0 为 OTG，便于 NPU USB 枚举路径。

## 模块

`/lib/modules`：

- `6.18.33/`：主模块树 + 多轮 `extra-0031` … `extra-0044` 叠加
- `6.18.33-rk35xx-ophub/`：旧 ophub 树残留

`extra-0044` 与 `extra-0031` 均约 1434 个 `.ko`，说明采用“保留历史 extra + 叠加最新”部署策略。  
rootfs 模块区体积较大（`/lib/modules` 侧约数百 MB 级，ROOTFS 已用 11G/14G ≈ 80%）。

## NPU 用户态（已具备，可工作）

| 路径 | 状态 |
|---|---|
| `/usr/local/bin/npu_usb_ntb_noep_rknn.sh` | 有 |
| `/usr/local/bin/npu_powerctrl-gpiod` | 有 |
| `/usr/local/bin/npu_mainline_usb_ntb_boot.sh` | 有 |
| `/etc/default/npu-usb-workflow` | 有（golden129 + USB noep） |
| `/usr/share/npu_fw_usb_ntb_noep/` | 有完整 profile |
| `/usr/share/npu_fw_pcie/` | 有 |
| `/usr/share/npu_fw_usb_ntb_pcie_deferred/` | 有（研究用） |
| `/usr/bin/npu_transfer_proxy` | 有 |
| `/usr/bin/upgrade_tool` | 有 |

默认 NPU 生产路径配置指向：

- `USB_FW_DIR=/usr/share/npu_fw_usb_ntb_noep`
- `NPU_PRECISE_POWERUP_PROFILE=golden129`
- `SET_PCIE_DMA_SAFE=1`
- `RUN_RKNN=0`（默认不自动跑模型）

## 与 amlogic 镜像构建的关系

| 项 | SD 现状 | amlogic 刚推送的构建输入 |
|---|---|---|
| 内核 | **0044**（更新） | 注入的是 **0031** package |
| NPU 脚本/profile | 完整（含 firmware） | 仅脚本，无大固件 profile |
| DTB 默认 | 0030-pd-usb0otg（deferred+OTG） | board base DTB |

结论：

1. 这张 SD 卡是 **比当前 amlogic 仓库注入包更新的已验证运行态**。
2. 若要以 SD 为准做 eMMC，应优先把 **0044 Image/dtbs/kos** 注入 amlogic package，而不是 0031。
3. 0044 本地副本已在：`downloads/gha_29072024640_0044/`。

## 空间与清理建议（可选）

- BOOT：227M/463M（51%），历史 DTB archive / Image 备份较多，可清理旧 archive。
- ROOTFS：11G/14G（80%），`/lib/modules/6.18.33/extra-*` 多版本叠加占空间；可只保留 `extra-0044` + 主树。
- 未改动任何 SD 内容（只读分析）。

## 总结

- SD 可正常启动，内核是 LPA 主线 **6.18.33 + 0044 补丁级产物**（含 `pcie_safe_retrain`）。
- 比本地 `0031` 更新；与 `downloads/gha_29072024640_0044` 一致。
- 启动 DTB 为 **PCIe deferred + display + USB0 OTG**。
- NPU USB noep 黄金路径脚本与 firmware 已在 rootfs，配置完整。
- 若目标是“eMMC 对齐这张能跑的 SD”，应以 **0044 + 当前 DTB/脚本/profile** 为基准，而不是 0031。
