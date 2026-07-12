# LPA3399Pro ↔ amlogic-s9xxx-armbian 对齐审计（2026-07-12）

## 结论摘要

| 项 | 状态 |
|---|---|
| Host 补丁源码 0001–0044 | **完全对齐（44/44 SAME）** |
| amlogic 本地 `kdevbuild` 预编译内核（注入前） | **过期**：无 `npu_acm` / `pcie_deferred` 等 NPU marker |
| LPA 最新可用产物 0031（2026-07-09） | **可用**：含 NPU/PCIe 主线 marker；**不含** `pcie_safe_retrain`（0044 在 7/10） |
| 现成 amlogic release 镜像内核 | **未完整下载核验**（代理下载过慢）；从 Stage 逻辑看很可能仍拉 6 月 public release 或旧 package |
| board rootfs NPU 脚本/profile | **缺失**（仅 base DTB + RTL8821CS） |
| 本地 kernel package 注入 0031 | **已完成**（boot/dtb/modules 均已替换，boot cmp OK） |

**eMMC 前不要直接用现成 `2026.07.10` 镜像当“已对齐最终版”，除非完成 boot 内核 marker 核验。**

---

## 已落地工具 / 文档

| 路径 | 作用 |
|---|---|
| `tools/audit_lpa_amlogic_alignment.sh` | 对齐审计：补丁 hash + Image marker + 可选 release 镜像挂载检查 |
| `tools/inject_lpa_kernel_into_amlogic_pkg.sh` | 把 LPA `Image/dtbs/kos` 注入 amlogic ophub kernel package |
| `docs/AMLOGIC_ROOTFS_SYNC_LIST_20260712.md` | amlogic rootfs 应同步的 LPA 文件清单 |
| `docs/LPA_AMLOGIC_ALIGNMENT_AUDIT_20260712.md` | 本文 |

---

## 审计数据

### 1) 补丁源码

- LPA：`kernel-6.18/*.patch` = 44
- amlogic：`compile-kernel/tools/patch/common-kernel-patches/*.patch` = 44
- 结果：**全部 SAME**（含 0044）

### 2) LPA 最新本地产物（0031）

目录：

```text
build_artifacts/pub7e98d1c_run29013248531_0031_20260709_191258/
```

| 文件 | sha256 |
|---|---|
| Image | `52e86106cf6df8b05542b19ed1f57cc4868276671138d6f3506b9931da45ec12` |
| dtbs.tar.gz | `59a4a207e4957f07e43686b7ab851c6aeb4b1ddc77f879fd28349f7b1c131c52` |
| kos.tar.gz | `d3af254037453e3b5565e3ac7afe25d12e5d5f29da3c90577676a1df16448f59` |

关键 marker（strings 计数）：

| marker | 0031 Image |
|---|---:|
| npu_acm | 6 |
| pcie_deferred | 1 |
| pcie_reset_ep | 2 |
| pcie_link_state | 1 |
| dma_start_once | 1 |
| dry_run | 4 |
| failfast | 6 |
| nfatal | 6 |
| **pcie_safe_retrain** | **0（无 0044）** |

说明：对 **USB noep 生产路径**，0031 已足够；若要坚持 0044 PCIe safe retrain，需再编一版含 0044 的 Host kernel。

### 3) 注入前 amlogic package

`kdevbuild/kernel-packages/rk35xx/6.18.33/boot-*.tar.gz` 内 `vmlinuz`：

- sha256：`5eaea3eaec694afb977122974aa456ce2cd4c639154e1919098b0e6d9ec343a1`
- `npu_acm=0` / `pcie_deferred=0` / `failfast=0`
- 与 0031 Image **不同**

这解释了：即使补丁文件已同步，**镜像仍可能打出旧内核**。

### 4) 注入后

已写入：

- `lpa3399pro-armbian/kdevbuild/kernel-packages/rk35xx/6.18.33/{boot,dtb-rockchip,modules}-6.18.33-rk35xx-ophub.tar.gz`
- `lpa3399pro-armbian/build-armbian/kernel/rk35xx/6.18.33/` 同步

验收：

- `boot` 包内 `vmlinuz` **cmp == 0031 Image**
- dtb 包约 1.6M（来自 0031 dtbs）
- modules 包约 83M（来自 0031 kos）

旧文件备份：

- `kdevbuild/kernel-packages/rk35xx/6.18.33.bak_20260712_141259`（若存在）
- `build-armbian/.../modules-*.bak_pre_rtw88` 等历史备份可择机删

### 5) release 镜像下载

尝试过：

- `gh.jasonzeng.dev` 与 `gitproxy.mrhjx.cn` 拉  
  `Armbian_26.08.0_rockchip_lpa3399pro_trixie_6.18.33_server_2026.07.10.img.gz`（约 750MB）

结果：速度过低，已中止并清理 `/tmp` 半成品。

后续核验（下到 `/tmp`，审完即删）：

```bash
URL='https://gitproxy.mrhjx.cn/https://github.com/winic57/amlogic-s9xxx-armbian/releases/download/Armbian_trixie_arm64_server_2026.07/Armbian_26.08.0_rockchip_lpa3399pro_trixie_6.18.33_server_2026.07.10.img.gz'
curl -fL -C - -o /tmp/lpa3399pro.img.gz "$URL"
AMLOGIC_IMG_GZ=/tmp/lpa3399pro.img.gz \
  /mnt/sdb3/LPA3399Pro/tools/audit_lpa_amlogic_alignment.sh
rm -f /tmp/lpa3399pro.img.gz
```

**不建议**用 trunk `6.18.38` 通用镜像做 LPA eMMC（非 `lpa3399pro` 板级产物）。

---

## rootfs 同步清单

详见：`docs/AMLOGIC_ROOTFS_SYNC_LIST_20260712.md`

最小必装：NPU noep 脚本集 + `/etc/default/npu-usb-workflow`；固件 profile 可二次安装。

当前 amlogic board rootfs 只有 base dtb/dts、rtl8821cs、board-release.conf。

---

## 推荐后续：生成可用于 eMMC 的 amlogic image

### 关键风险

GHA `Stage LPA3399Pro kernel` **优先下载** public  
`Neardi-LPA3399Pro-kernel-6.18`（2026-06-22）。  
若不改 workflow / 不更新 public release，云端构建会再次用旧内核覆盖本地注入。

### 路径 A（推荐）：更新 public release + 触发 amlogic image

1. 把 0031 的 `Image/dtbs.tar.gz/kos.tar.gz` 上传到 LPA public release（覆盖或新 tag）
2. 同步 rootfs 脚本（清单 A）
3. push/trigger `amlogic-s9xxx-armbian` image workflow
4. 下载 **lpa3399pro** img.gz 到 `/tmp`，`audit_...` 通过后再 eMMC

### 路径 B：改 workflow 优先仓库 package

1. 本地 package 已注入 0031（完成）
2. 改 Stage 步骤：先用 `kdevbuild/kernel-packages`，下载失败才 fallback
3. commit/push amlogic 仓触发构建

### 路径 C：SD 热替换内核（最快验证）

不重打整镜像，板上替换 Image/modules；eMMC 固化仍建议完整 image。

---

## 磁盘控制

- 大文件只落 `/tmp`（root 分区可用约 220G）
- `/mnt/sdb3` 目前约 29G 可用，勿长期放 release img
- 半成品：`rm -f /tmp/*.img /tmp/*.img.gz`

---

## 变更记录

| 时间 | 事项 |
|---|---|
| 2026-07-12 | 完成补丁/二进制对齐审计 |
| 2026-07-12 | 新增 audit / inject 脚本与 rootfs 清单 |
| 2026-07-12 | 使用 0031 产物注入 amlogic local kernel package |
| 2026-07-12 | release 全量镜像因下载过慢未完成在线核验，保留命令 |

---

## 2026-07-12 后续：rootfs 同步 + Stage 优先本地 package

### 1) rootfs 已同步

路径：`lpa3399pro-armbian/build-armbian/armbian-files/different-files/lpa3399pro/rootfs/`

新增：
- `usr/local/bin/` 下 noep/golden129/powerctrl/pipeline/install 等脚本
- `etc/default/npu-usb-workflow`
- `usr/share/doc/lpa3399pro/NPU_DEFAULT.md`

未打包大体积 NPU firmware profile（需板上 `install_npu_usb_ntb_noep_profile.sh` 或二次安装）。
仍依赖板端/SDK 提供：`/usr/bin/upgrade_tool`、`/usr/bin/npu_transfer_proxy`。

### 2) workflow Stage 优先级已改

文件：`.github/workflows/build-armbian-arm64-server-image.yml`

默认：
1. **优先** `kdevbuild/kernel-packages/rk35xx/6.18.33`（本地已注入 0031）
2. 仅当 local 不完整，或 `vars.LPA_KERNEL_STAGE_PREFER=release` 时，才下载 public release

并增加 staged `vmlinuz` 存在性检查与 marker 打印。

---

## 2026-07-12 后续：注入 0044 并对齐 golden SD 后重编镜像

- 源：`downloads/gha_29072024640_0044/`
- Image sha256：`331e45b75fe755ddbd64e10ad53a0ad67011685b6a7e59cb89582960420a2c50`（与 SD `/boot/Image` 一致）
- markers：`pcie_safe_retrain=1`、`npu_acm=6`、`pcie_deferred=1`
- amlogic commit：`5587740e lpa3399pro: inject 0044 kernel package matching golden SD boot`
- Stage 仍默认 prefer local package，因此新 image 应使用 0044 内核

