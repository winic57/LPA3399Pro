# amlogic-s9xxx-armbian lpa3399pro rootfs 应同步的 LPA3399Pro 文件清单

- 日期：2026-07-12
- 目标树：`lpa3399pro-armbian/build-armbian/armbian-files/different-files/lpa3399pro/rootfs/`
- 源仓库：`/mnt/sdb3/LPA3399Pro`
- 原则：
  - **eMMC 默认走 USB noep + golden129**，不默认启用 PCIe EP deferred
  - 大固件 profile 可选打包；没有 profile 时至少装脚本，板上再 `install_*`
  - 控制镜像体积：优先脚本/配置，固件包单独 release 或首次 boot 安装

镜像重建时，`rebuild` 会把 `different-files/<board>/rootfs/` 整树 `cp -af` 到 rootfs。

---

## A. 必装（eMMC 生产最小集）

### A1. NPU 启动 / 校验脚本 → `/usr/local/bin/`

| 源（LPA3399Pro） | 目标（amlogic rootfs） | 说明 |
|---|---|---|
| `tools/npu_usb_ntb_noep_rknn.sh` | `usr/local/bin/npu_usb_ntb_noep_rknn.sh` | **默认验证/生产入口** |
| `tools/npu_usb_loader_rs_rknn_pipeline.sh` | `usr/local/bin/npu_usb_loader_rs_rknn_pipeline.sh` | pipeline 核心 |
| `tools/npu_mainline_usb_ntb_boot.sh` | `usr/local/bin/npu_mainline_usb_ntb_boot.sh` | USB NTB boot |
| `tools/npu_mainline_usb_ntb_boot_golden129_usb.sh` | `usr/local/bin/npu_mainline_usb_ntb_boot_golden129_usb.sh` | golden129 wrapper |
| `tools/npu_mainline_usb_ntb_check.sh` | `usr/local/bin/npu_mainline_usb_ntb_check.sh` | 检查脚本 |
| `tools/npu_powerctrl_gpiod.sh` | `usr/local/bin/npu_powerctrl-gpiod` | gpiod 精确上电（注意目标名） |
| `tools/npu_powerctrl_gpiod_vendor_wrapper.sh` | `usr/local/bin/npu_powerctrl_gpiod_vendor_wrapper.sh` | 兼容 wrapper |
| `tools/npu_transfer_proxy_launcher.sh` | `usr/local/bin/npu_transfer_proxy_launcher.sh` | proxy 启动 |
| `tools/npu_make_noep_ntb_boot.py` | `usr/local/bin/npu_make_noep_ntb_boot.py` | noep boot 生成 |
| `tools/install_npu_usb_ntb_noep_profile.sh` | `usr/local/bin/install_npu_usb_ntb_noep_profile.sh` | profile 安装器 |

权限：`0755`，owner root。

### A2. 默认配置 → `/etc/default/`

建议新增（若板端已有则同步内容）：

| 目标 | 关键内容 |
|---|---|
| `etc/default/npu-usb-workflow` | `NPU_PRECISE_POWERUP_PROFILE=golden129`、`USB_FW_DIR=/usr/share/npu_fw_usb_ntb_noep`、`SET_PCIE_DMA_SAFE=1`、`FORCE_USB_DEVICE=1` |
| `etc/default/npu-pcie-safe`（可选） | Host PCIe 安全默认：`dma_reg_trace_live_mmio=0`、`dma_link_failfast=1` 等 sysfs 说明/oneshot 脚本引用 |

### A3. 板级说明 / 版本钉扎

| 源/内容 | 目标 |
|---|---|
| 已有 `etc/armbian-board-release.conf` | 保留并追加 kernel artifact tag / git sha |
| 新增简短 README | `usr/share/doc/lpa3399pro/NPU_DEFAULT.md`：说明默认 noep，不写 eMMC 时改 PCIe profile |

### A4. 已有、继续保留

| 已有路径 | 说明 |
|---|---|
| `usr/lib/lpa3399pro/rk3399pro-neardi-linux-lc110-base.dtb` | base DTB |
| `usr/lib/lpa3399pro/rk3399pro-neardi-linux-lc110-base.dts` | 源码对照 |
| `usr/lib/firmware/rtl_bt/rtl8821cs_*` | BT firmware |

---

## B. 强烈建议（功能完整，但体积可控）

### B1. 调试/对比工具

| 源 | 目标 |
|---|---|
| `tools/npu_usb3_phy_role_snapshot.sh` | `usr/local/bin/` |
| `tools/npu_usb_precise_compare_collect.sh` | `usr/local/bin/` |
| `tools/pcie_dev_sniffer.c` | `usr/src/lpa3399pro/pcie_dev_sniffer.c`（源码，不强制预编译） |

### B2. NPU firmware profile（体积大，二选一）

**方案 1（推荐，控体积）：**

- 镜像内不塞完整 `/usr/share/npu_fw_*`
- 首次上线从 U 盘/release 安装：
  - `install_npu_usb_ntb_noep_profile.sh`
  - 或 scp 板端已验证的 `/usr/share/npu_fw_usb_ntb_noep`

**方案 2（开箱即用）：**

从当前可用板（.254）或 artifacts 打包：

| 源 | 目标 | 约大小 |
|---|---|---|
| 板端 `/usr/share/npu_fw_usb_ntb_noep/*` | `usr/share/npu_fw_usb_ntb_noep/` | 数十～百 MB 级 |
| （可选）`/usr/share/npu_fw_pcie/*` 作为 SRC | `usr/share/npu_fw_pcie/` | 更大 |

**不要**默认打包 PCIe deferred/nonblock profile 为开机默认；若打包，放到：

- `usr/share/npu_fw_usb_ntb_pcie_deferred/`（仅研究）

### B3. userspace 二进制

| 组件 | 建议 |
|---|---|
| `npu_transfer_proxy` | 从 SDK/板端拷到 `usr/local/bin/npu_transfer_proxy` |
| `upgrade_tool` / rockusb 相关 | 若 boot 脚本依赖，一并放入 `usr/local/bin/` 或 `usr/bin/` |
| RKNN runtime / 测试模型 | 可选；体积大，建议 `/opt/rknn_*` 二次安装 |

---

## C. 不要同步进默认 rootfs

| 路径/类型 | 原因 |
|---|---|
| `patches/npu/0001-pcie-dw-rockchip-ep-nonblocking-probe.patch` | NPU vendor kernel 补丁，不是 Host rootfs |
| `LPA3399Pro-SDK-Linux-V3.0/**` | 过大 |
| `build_artifacts/**` 整树 | 中间产物 |
| `logs/**` | 调试日志 |
| Host `kernel-6.18/*.patch` | 应走 amlogic `common-kernel-patches` + kernel package，不进 rootfs |
| 开发机专用 `deploy_*_to_254.sh` / `monitor_private_gha_*` | 含环境假设/密码模式，不宜进镜像 |

---

## D. 建议的 rootfs 目录树（目标）

```text
different-files/lpa3399pro/rootfs/
├── etc/
│   ├── armbian-board-release.conf
│   └── default/
│       └── npu-usb-workflow
├── usr/
│   ├── local/bin/
│   │   ├── npu_usb_ntb_noep_rknn.sh
│   │   ├── npu_usb_loader_rs_rknn_pipeline.sh
│   │   ├── npu_mainline_usb_ntb_boot.sh
│   │   ├── npu_mainline_usb_ntb_boot_golden129_usb.sh
│   │   ├── npu_mainline_usb_ntb_check.sh
│   │   ├── npu_powerctrl-gpiod
│   │   ├── npu_powerctrl_gpiod_vendor_wrapper.sh
│   │   ├── npu_transfer_proxy_launcher.sh
│   │   ├── npu_make_noep_ntb_boot.py
│   │   ├── install_npu_usb_ntb_noep_profile.sh
│   │   └── npu_transfer_proxy                 # 若有二进制
│   ├── lib/
│   │   ├── lpa3399pro/
│   │   │   ├── rk3399pro-neardi-linux-lc110-base.dtb
│   │   │   └── rk3399pro-neardi-linux-lc110-base.dts
│   │   └── firmware/rtl_bt/...
│   └── share/
│       ├── doc/lpa3399pro/NPU_DEFAULT.md
│       └── npu_fw_usb_ntb_noep/               # 可选
└── opt/                                        # 可选 RKNN
```

---

## E. 一键同步示例（只复制脚本，不含大固件）

在 `LPA3399Pro` 根目录执行：

```bash
ROOT=/mnt/sdb3/LPA3399Pro
DST=$ROOT/lpa3399pro-armbian/build-armbian/armbian-files/different-files/lpa3399pro/rootfs
BIN=$DST/usr/local/bin
mkdir -p "$BIN" "$DST/etc/default" "$DST/usr/share/doc/lpa3399pro"

install -m 0755 \
  $ROOT/tools/npu_usb_ntb_noep_rknn.sh \
  $ROOT/tools/npu_usb_loader_rs_rknn_pipeline.sh \
  $ROOT/tools/npu_mainline_usb_ntb_boot.sh \
  $ROOT/tools/npu_mainline_usb_ntb_boot_golden129_usb.sh \
  $ROOT/tools/npu_mainline_usb_ntb_check.sh \
  $ROOT/tools/npu_powerctrl_gpiod_vendor_wrapper.sh \
  $ROOT/tools/npu_transfer_proxy_launcher.sh \
  $ROOT/tools/npu_make_noep_ntb_boot.py \
  $ROOT/tools/install_npu_usb_ntb_noep_profile.sh \
  "$BIN/"

install -m 0755 $ROOT/tools/npu_powerctrl_gpiod.sh "$BIN/npu_powerctrl-gpiod"
```

然后补 `etc/default/npu-usb-workflow` 与文档，再提交 amlogic 仓触发镜像构建。

---

## F. 与内核产物的关系（重要）

rootfs 脚本再全，也替代不了 **Host 6.18 最新内核二进制**：

1. 用 LPA 最新 `Image + dtbs.tar.gz + kos.tar.gz` 注入 amlogic Stage kernel / `kdevbuild/kernel-packages`
2. 再 rebuild lpa3399pro image
3. 镜像验收：`strings /boot/Image | grep npu_acm` 等

见：

- `tools/audit_lpa_amlogic_alignment.sh`
- `tools/inject_lpa_kernel_into_amlogic_pkg.sh`
- `docs/LPA_AMLOGIC_ALIGNMENT_AUDIT_20260712.md`
