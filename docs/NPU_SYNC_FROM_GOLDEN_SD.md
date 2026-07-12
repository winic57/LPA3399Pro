# 从 golden SD 一键补齐 NPU 到新 amlogic 镜像系统

## 目标

把当前可工作 SD（`/dev/sdc`，ROOTFS）上的 NPU 运行时，同步到新刷的 amlogic 07.12 系统（SD/eMMC）。

## 体积分级

| 级别 | 内容 | 约大小 |
|---|---|---|
| **最小可用** | noep firmware + upgrade_tool + npu_transfer_proxy + 关键脚本/服务 | **~46MB** |
| **推荐** | 最小 + `npu_fw_pcie`（研究/备份源） | **~86MB** |
| **完整研究** | 推荐 + deferred profile + RKNN venv/模型 | **~300MB+** |

生产建议先做 **最小可用** 或 **推荐**。

## 必拷清单（最小可用）

### A. NPU firmware（生产默认）
```text
/usr/share/npu_fw_usb_ntb_noep/
  MiniLoaderAll.bin
  uboot.img
  trust.img
  boot.img
  parameter.txt
  SHA256SUMS
  README.noep-usb-ntb
```
noep `boot.img` sha256：
`de281a4458e6ba51d65d637c53ba65f4226f9bd2bd5bc40d1f3ef3eff027a401`

### B. Host 工具二进制
```text
/usr/bin/upgrade_tool
/usr/bin/npu_transfer_proxy
/usr/bin/npu_powerctrl                 # 小脚本/兼容
/usr/bin/npu_powerctrl.vendor129       # 若存在
/usr/bin/npu_upgrade
/usr/bin/npu_upgrade_pcie
/usr/bin/npu-image.sh
```

### C. 额外脚本（镜像可能已有部分，覆盖无妨）
```text
/usr/local/bin/npu_boot
/usr/local/bin/npu_startup.sh
/usr/local/bin/npu_usb_ntb_noep_rknn.sh
/usr/local/bin/npu_usb_loader_rs_rknn_pipeline.sh
/usr/local/bin/npu_mainline_usb_ntb_boot.sh
/usr/local/bin/npu_mainline_usb_ntb_boot_golden129_usb.sh
/usr/local/bin/npu_mainline_usb_ntb_check.sh
/usr/local/bin/npu_powerctrl-gpiod
/usr/local/bin/npu_transfer_proxy_launcher.sh
/usr/local/bin/npu_make_noep_ntb_boot.py
/usr/local/bin/install_npu_usb_ntb_noep_profile.sh
```

### D. 配置与服务
```text
/etc/default/npu-usb-workflow
/etc/systemd/system/npu_transfer_proxy.service
```
然后：
```bash
systemctl daemon-reload
# 按需 enable；建议先手动跑通 noep 再 enable
# systemctl enable npu_transfer_proxy.service
```

## 推荐附加

```text
/usr/share/npu_fw_pcie/          # 源 firmware / PCIe 研究
/usr/share/npu_fw/               # 含 factory 变体（更大）
```

## 研究附加（可不拷）

```text
/usr/share/npu_fw_usb_ntb_pcie_deferred/
/usr/share/npu_fw_usb_ntb_pcie_deferred_29080426571/
/opt/rknn_py39/
/root/npu_deep_test/
/root/npu_deep_manual/
```

## 启动 DTB 对齐（强烈建议）

golden SD 当前默认（extlinux）：
```text
lpa3399pro-0030-pd-usb0otg.dtb
# model: PCIe deferred + display + USB0 OTG
```

07.12 镜像默认：
```text
rockchip/rk3399pro-neardi-linux-lc110-base.dtb
```

从 golden SD 拷贝对应 DTB 到新系统 `/boot/dtb/rockchip/`，并改 extlinux/armbianEnv 指向  
`lpa3399pro-0030-pd-usb0otg.dtb`（或你验证过的等价 DTB）。

## 一键脚本

见：`tools/sync_npu_from_golden_sd.sh`

典型用法（本机同时插着 golden SD 和新系统盘时要非常小心设备名）：

```bash
# 1) 在已启动的新系统上，把 golden SD 的 ROOTFS 只读挂上
# 2) 执行：
sudo GOLDEN_ROOT=/mnt/golden_root \
  TARGET_ROOT=/ \
  MODE=min \
  /path/to/sync_npu_from_golden_sd.sh
```

或在 PC 上离线同步两块盘的 rootfs：

```bash
sudo GOLDEN_ROOT=/mnt/sd_golden \
  TARGET_ROOT=/mnt/new_root \
  MODE=recommended \
  ./tools/sync_npu_from_golden_sd.sh
```

## 同步后验收

```bash
ls -l /usr/share/npu_fw_usb_ntb_noep/boot.img
ls -l /usr/bin/upgrade_tool /usr/bin/npu_transfer_proxy
test -x /usr/local/bin/npu_usb_ntb_noep_rknn.sh
# 手动冒烟（确认电源/USB 连接）
# /usr/local/bin/npu_usb_ntb_noep_rknn.sh
```

成功时通常可见：
- USB `2207:0019`（或文档约定 ID）
- `npu_transfer_proxy devices` 含 `USB_DEVICE`
