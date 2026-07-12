# amlogic 2026.07.12 lpa3399pro 镜像审计

- 审计时间：2026-07-12
- 镜像：`Armbian_26.08.0_rockchip_lpa3399pro_trixie_6.18.33_server_2026.07.12.img.gz`
- 本地缓存：`/tmp/lpa3399pro-20260712.img.gz`（约 751MB gzip / 3.45GB raw）
- 对照内核：`downloads/gha_29072024640_0044/Image`
- Action：`29184125150` success / commit `5587740e`

## 内核结论

| 项 | 结果 |
|---|---|
| boot `vmlinuz-6.18.33-rk35xx-ophub` sha256 | `331e45b75fe755ddbd64e10ad53a0ad67011685b6a7e59cb89582960420a2c50` |
| 与 0044 / golden SD Image | **完全一致** |
| `pcie_safe_retrain` | 有 |
| `pcie_deferred` | 有 |
| `npu_acm` | 有 |

**结论：07.12 镜像内核已是 0044，可直接作为系统部署底包。**

## rootfs NPU 结论

### 已有（脚本层）
- `/usr/local/bin/npu_usb_ntb_noep_rknn.sh` 等 noep/golden129 脚本
- `/usr/local/bin/npu_powerctrl-gpiod`
- `/etc/default/npu-usb-workflow`

### 缺失（相对 golden SD）
- `/usr/share/npu_fw_usb_ntb_noep/**`
- `/usr/share/npu_fw_pcie/**`
- `/usr/bin/upgrade_tool`
- `/usr/bin/npu_transfer_proxy`
- `/usr/bin/npu_powerctrl` / vendor helper
- `/usr/local/bin/npu_boot`、`npu_startup.sh`
- `npu_transfer_proxy.service`
- `/opt/rknn_py39`、测试模型（可选）

### 启动 DTB
- 镜像 `armbianEnv.txt`：`fdtfile=rockchip/rk3399pro-neardi-linux-lc110-base.dtb`
- golden SD 当前默认：`lpa3399pro-0030-pd-usb0otg.dtb`（PCIe deferred + USB0 OTG）

## 使用建议

1. 可下载并刷 SD 验证系统/网络。
2. NPU 需按 `docs/NPU_SYNC_FROM_GOLDEN_SD.md` 从 golden SD 补齐后再当生产 NPU 环境。
3. eMMC 固化前先完成 NPU 补齐与一次 noep 冒烟。

## 磁盘

审计用 raw 镜像在 `/tmp`。不用后执行：

```bash
rm -f /tmp/lpa3399pro-20260712.img.gz
rm -rf /tmp/lpa_img_audit_20260712
```

---

## 2026-07-12 后续：min NPU 已打入下一版 amlogic rootfs

- commit: `fecdbba4 lpa3399pro: bundle min NPU runtime into board rootfs`
- 新增约 +40MB：
  - `/usr/share/npu_fw_usb_ntb_noep/**`
  - `/usr/bin/upgrade_tool`、`npu_transfer_proxy` 等
  - `npu_boot` / `npu_startup.sh` / `npu_transfer_proxy.service`
- 未打包：pcie/deferred 研究固件、RKNN venv/模型
- 下一版 release 镜像刷入后可直接尝试：
  `/usr/local/bin/npu_usb_ntb_noep_rknn.sh`

