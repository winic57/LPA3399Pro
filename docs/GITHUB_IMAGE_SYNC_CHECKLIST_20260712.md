# LPA3399Pro 硬件修复 → GitHub / 镜像构建同步清单（2026-07-12）

目标：后续 **编译出的 amlogic 镜像写卡后** 尽量接近当前 `192.168.50.17` 已验证状态，减少 SSH 手工补丁。

## A. LPA3399Pro 仓库（内核 / 文档 / 工具）

### 已在 Git 的关键项
| 项 | 说明 |
|---|---|
| `kernel-6.18` `CONFIG_BT_HCIUART_RTL=y` | RTL8821CS UART BT 必需 |
| `tools/lpa-wifi-bt-bringup.sh` | WiFi reset_gpio + rtw88 |
| `tools/ec20-init.sh` | 4G PWRKEY |
| GHA ophub kernel workflow | 产出 Image/kos/dtbs release |

### 本轮应提交
- 文档：`docs/SD_*`、`WIFI_BT_*`、`4G_*`、`BT_*`、`NPU_ENV_*`、`ARIA2_*`、审计类
- 工具：`tools/aria2_proxy_dl.sh`、`dl_lpa_kernel_release.sh`、`install_rknn_env_from_stage.sh`、`sync_npu_from_golden_sd.sh`、`auto_deploy_bt_*`（aria2 优先）

### 发布要求
- Release `Neardi-LPA3399Pro-kernel-6.18` 使用 **含 BT_HCIUART_RTL** 的构建（验证 build 时间 ≥ 2026-07-12 12:50 UTC）

## B. amlogic-s9xxx-armbian 仓库（镜像）

### 已推送（此前）
- SDK idbloader/uboot/trust + PARTUUID + maxcpus=4
- WiFi/BT/4G overlay、NPU min、BT firmware、DTB bluetooth okay
- 内核 config 镜像 `CONFIG_BT_HCIUART_RTL=y`

### 本轮构建修复（2026-07-12 提交）
| 改动 | 路径 |
|---|---|
| root 默认 **12288 MiB** | `…/lpa3399pro/rootfs/etc/armbian-board-release.conf` |
| modules `6.18.33` → `…-ophub` 软链 | `rebuild` + board_release |
| 允许 first-boot **resize** | `rebuild` 对 lpa3399pro 去掉 `.no_rootfs_resize` |
| 静态 DNS | `…/etc/resolv.conf` + `start_service.sh` fallback |
| first-boot 装 **bluez/gpiod** | `lpa-firstboot-packages.service` |
| 文档 | `usr/share/doc/lpa3399pro/*` |

### 镜像构建 checklist
1. 注入最新 LPA kernel package（BT RTL）
2. `./rebuild -b lpa3399pro …`（勿用全局 `-s` 把 root 压回 3000，除非有意）
3. 写卡后验收：maxcpus=4、wlan0、hci0、2c7c:6005、NPU USB noep
4. RKNN：`install_rknn_env_from_stage.sh` 可选二次安装（不进默认 img）

## C. 仍可选 / 不进默认镜像
- 完整 `/opt/rknn_py39`（~200MB+）
- SIM 注网拨号配置
- USB3 SuperSpeed 外设吞吐测试记录

## D. 当前板端（.17）对照
- 已 SSH 验证：eth / WiFi / BT / 4G 枚举 / NPU `rknn_rc=0`
- 根分区已扩到 14G；镜像侧用 12G + resize 对齐
