# LPA3399Pro Linux 6.18.33 稳定基线记录

> 基线目录：`/mnt/sdb3/LPA3399Pro/baselines/6.18.33_stable_tty_login_20260618_102330`
>
> 创建时间：2026-06-18
> 当前状态：TTL 串口可登录 root，系统可进入 multi-user；板载 GMAC 保持禁用。

## 1. 基线目标

本基线用于在后续继续实验 GMAC / DTB / 内核 patch 前，保留一个已知可启动、可 TTL 登录、可回退的 6.18.33 状态。

当前基线不是“完整功能基线”，而是“稳定启动基线”：

- SD 卡可启动 6.18.33
- rootfs 可挂载
- systemd 可进入 multi-user
- TTL 串口 root autologin 可用
- 无 CPU4/CPU5 Oops
- 无 generator sandbox Oops
- 无 drm/configfs/efi_pstore 早期 panic
- 板载 GMAC 暂时禁用

## 2. 当前核心启动参数

```text
root=PARTUUID=61ec8aeb-3d1a-48fa-a9da-54d744ed8bdf
rootflags=data=writeback
rw rootwait rootdelay=10 rootfstype=ext4
console=ttyS2,1500000 console=tty1
panic=0
usbcore.autosuspend=-1
initcall_blacklist=psci_checker
printk.devkmsg=on
log_buf_len=16M
maxcpus=4
systemd.default_timeout_start_sec=20
plymouth.enable=0
net.ifnames=0
```

关键项：

- `maxcpus=4`：禁用 RK3399 CPU4/5 A72 big cores，避免 systemd 负载下随机 Oops。
- `root=PARTUUID=...`：无 initramfs 直启场景下让内核正确挂载 rootfs。
- `plymouth.enable=0`：避免 plymouth 阻塞/污染串口登录。

## 3. 当前 DTB 策略

| 节点 | 状态 | 说明 |
|---|---|---|
| `/ethernet@fe300000` | disabled | 板载 GMAC 禁用，避免 DMA SWR 卡死 |
| `/pcie@f8000000` | okay | PCIe link training 超时但可优雅失败；保留有利 MMC 时序 |
| display/vop | disabled | 保持最小启动基线 |
| watchdog | disabled | 避免调试期复位 |

## 4. GMAC 当前结论

当前有线网卡不可见不是驱动缺失。

运行时 TTL 证据：

```text
CONFIG_STMMAC_ETH=y
CONFIG_STMMAC_PLATFORM=y
CONFIG_DWMAC_ROCKCHIP=y
CONFIG_PHYLIB=y
CONFIG_MOTORCOMM_PHY=y
/sys/bus/platform/drivers/rk_gmac-dwmac
/proc/device-tree/ethernet@fe300000/status = disabled
```

因此当前无 `eth0` 的直接原因是 DTB 中 GMAC 节点被禁用。

## 5. 已保存内容

### 5.1 文档

保存在：

```text
/mnt/sdb3/LPA3399Pro/baselines/6.18.33_stable_tty_login_20260618_102330/docs/
```

包含：

- `6.18.33_KERNEL_SD_BOOT_MODIFICATIONS.md`
- `6.18.33_boot_20260618_090013_systemd_oops_fix.md`
- `6.18.33_boot_20260618_091732_modprobe_panic_fix.md`
- `6.18.33_boot_20260618_092856_bigcore_disable_fix.md`
- `6.18.33_boot_20260618_093418_analysis.md`
- `6.18.33_boot_20260618_093418_console_plymouth_fix.md`
- `6.18.33_boot_20260618_094016_ttl_runtime_check.md`
- `6.18.33_gmac_driver_presence_analysis.md`
- `iter47_path_b1_plan.md`
- `iter47_path_b1_execution.md`
- `FLASH_GUIDE_6.18.33.md`
- `UBOOT_SD_BOOT_6.18.33.md`

### 5.2 编译/镜像记录

保存在：

```text
/mnt/sdb3/LPA3399Pro/baselines/6.18.33_stable_tty_login_20260618_102330/artifacts/
```

包含：

- `compile.log`
- `compile_plan.md`
- `ARTIFACTS_SHA256.md`

`ARTIFACTS_SHA256.md` 记录了关键大文件/镜像的路径、大小、mtime 和 SHA256，例如：

- `lpa3399pro-armbian/build/output/images/Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.18.33_server_2026.06.17.img`
- SDK `idbloader.img`
- SDK `uboot.img`
- SDK `trust.img`
- `rk3399pro_kernel/compile.log`

为避免重复占用数 GB 空间，当前基线默认保存 hash/路径记录，而不是复制整份 3.7GB 镜像。

### 5.3 TTL 日志

保存在：

```text
/mnt/sdb3/LPA3399Pro/baselines/6.18.33_stable_tty_login_20260618_102330/logs/6.18.33_boot_20260618_094016.log
```

该日志证明当前系统已经进入 TTL root autologin。

## 6. SD 卡快照状态

SD 卡文件级快照已经补齐。已重新挂载 `/dev/sdc1` 和 `/dev/sdc2`，并复制当前 boot/rootfs 关键文件。

已保存：

- `sd_boot/extlinux/`
- `sd_boot/Image`（如果 boot 分区存在）
- `sd_boot/armbianEnv.txt`
- `sd_boot/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb*`
- `sd_rootfs/etc/fstab`
- `sd_rootfs/etc/NetworkManager/`
- `sd_rootfs/etc/default/`
- `sd_rootfs/etc_systemd_system.tar`
- `sd_rootfs/usr_lib_systemd_system_generators.tar`
- `sd_rootfs/manifests/SD_FILE_BASELINE_MANIFEST.md`

当前 manifest：

```text
/mnt/sdb3/LPA3399Pro/baselines/6.18.33_stable_tty_login_20260618_102330/sd_rootfs/manifests/SD_FILE_BASELINE_MANIFEST.md
```

该 manifest 记录了：

- `/dev/sdc1` / `/dev/sdc2` 的 UUID 和 PARTUUID。
- 当前 `extlinux.conf`。
- 当前 DTB 关键节点状态。
- 当前 rootfs `/etc/fstab`。

## 7. 后续 GMAC 实验前要求

后续如要启用 GMAC，必须先复制当前 DTB 为实验版本，不能直接修改稳定 DTB。

推荐做法：

1. 保留 stable 启动项：GMAC disabled。
2. 新增 gmac-test 启动项：复制 DTB 后仅修改 `/ethernet@fe300000/status = okay`。
3. gmac-test 首轮必须 mask NetworkManager，避免自动 ifup 触发 DMA reset。
4. 通过 TTL 只观察 probe 是否出现 `eth0`。
5. 若进入系统，再手动 `ip link set eth0 up` 复现和采集日志。

## 8. 回退原则

任何后续实验失败时，回退到本基线需要恢复：

- `maxcpus=4`
- GMAC disabled
- PCIe okay
- `root=PARTUUID=61ec8aeb-3d1a-48fa-a9da-54d744ed8bdf`
- plymouth disabled
- generators disabled
- drm/configfs/efi_pstore 相关 mask
- `serial-getty@ttyS2` root autologin
