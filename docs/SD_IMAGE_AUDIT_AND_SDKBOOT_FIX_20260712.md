# SD 镜像板载审计 + SDK idbloader / PARTUUID 修复（2026-07-12）

## A. 在 eMMC 4.4 系统上检查 SD 新镜像

检查路径：
- BOOT: `/mnt/sdcard` (`mmcblk0p1`)
- ROOTFS: `/media/neardi/ROOTFS1` (`mmcblk0p2`)

### A1. 正常项

| 项 | 结果 |
|---|---|
| 内核 | `vmlinuz-6.18.33-rk35xx-ophub`，sha=`331e45b7…`（0044） |
| markers | `pcie_safe_retrain` / `npu_acm` / `pcie_deferred` 有 |
| base DTB | `dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb` 有 |
| armbianEnv root UUID | 原镜像为 `UUID=d17798c7-…`（与 ROOTFS FS UUID 一致） |
| modules | `6.18.33-rk35xx-ophub`，约 1434 个 `.ko` |
| NPU min 包 | **完整**：noep fw、upgrade_tool、npu_transfer_proxy、脚本、service |
| OS | Armbian-unofficial 26.08.0-trunk trixie |

### A2. 明显问题

| 问题 | 严重度 | 状态 |
|---|---|---|
| **idbloader 区（sector 64）全 0** | 致命（BootROM 无法从 SD 启动） | **已写入 SDK idbloader** |
| **缺 uboot/trust 保留扇区** | 致命 | **已写入 SDK uboot@16384 + trust@24576** |
| **`extlinux/extlinux.conf` 缺失**（仅有 `.bak`） | 高 | **已重建（无 INITRD）** |
| **无 `uInitrd`** | 中（`boot.scr` 依赖它；extlinux 可无） | 保留现状，extlinux 不引用 INITRD |
| **`root=UUID=` 无 initramfs 无法解析** | 致命（进核后 panic） | **已改为 `root=PARTUUID=`** |
| NPU 二进制权限曾为 644 | 中 | 已 chmod 0755 |
| 默认 DTB 为 base，非 golden 的 0030-pd-usb0otg | 低/中 | 未改；可后续按需切换 |

### A3. 修复后校验（主机 /dev/sdc，2026-07-12 19:00）

```text
sector64 sha256 = 5502529203ded86d8fc2867461e6ea38c6537631e51c7c18f95277b3b79817b2
(= SDK idbloader first 8K)
uboot@16384: LOADER magic OK
trust@24576: BL3X magic OK
extlinux.conf:
  root=PARTUUID=c5c5cac8-cd7b-4f5f-ab90-55bda89d18a0
armbianEnv.txt:
  rootdev=PARTUUID=c5c5cac8-cd7b-4f5f-ab90-55bda89d18a0
ROOTFS blkid PARTUUID matches above
NPU_MIN=yes
```

## B. TTL 断电重启结果（修复 idbloader 后、改 PARTUUID 前）

日志：`/tmp/ttl_poweron_20260712_184718.log`

| 阶段 | 状态 |
|---|---|
| Boot1 / SD 初始化 | 正常 |
| SDK U-Boot 2017.09 | 正常 |
| 扫描 SD `mmc1:1`，读 `extlinux` / `Image` / DTB | 正常 |
| 启动 Linux 6.18.33 | 正常 |
| 挂载 root=`UUID=d17798c7-…` | **失败 → Kernel panic**（无 initramfs） |

可用块设备仅列出 PARTUUID，故 bare kernel 不能解析 `root=UUID=`。

## C. 构建侧永久修复（amlogic-s9xxx-armbian）

目标：镜像写入 SD 后即可从 SD 启动 6.18，无需再手工补 loader / 改 root。

| 改动 | 路径 |
|---|---|
| SDK loaders 入库（tracked） | `build-armbian/armbian-files/different-files/lpa3399pro/u-boot/{idbloader.bin,uboot.img,trust.bin}` |
| rebuild 写 loader 前 overlay | `rebuild` rockchip bootloader 段 |
| rockchip 使用 `PARTUUID=` 作 root | `rebuild` `refactor_bootfs` |
| 无 uInitrd 时去掉 extlinux INITRD 行 | `rebuild` |
| LPA3399Pro 默认 BOOT_CONF | `model_database.conf` `r436` → `extlinux.conf` |

### Rockchip SD loader 布局

```text
idbloader -> seek=64
uboot     -> seek=16384
trust     -> seek=24576
```

来源：`LPA3399Pro-SDK-Linux-V3.0`

## D. 下一步

1. **安全卸载 SD，插回板子断电重启**，确认进入 6.18.33 且 root 挂载成功。
2. 进系统后 NPU 冒烟：`/usr/local/bin/npu_usb_ntb_noep_rknn.sh`
3. push amlogic-s9xxx-armbian 后重跑 GHA，验证新 release 镜像写卡即用。

## E. 2026-07-12 晚：PARTUUID 后仍 kill-init panic

完整冷启动日志：`/tmp/ttl_boot_20260712_194232.log`

- root=`PARTUUID=c5c5cac8-...` **已成功挂载**，systemd 已启动
- 但 cmdline **缺 `maxcpus=4`**，CPU4/CPU5（A72）起来后：
  - `Oops: 0000000096000004` in `link_path_walk`
  - `Comm: systemd` on CPU4
  - `Attempted to kill init` → Kernel panic
- 与 2026-06-18 历史结论一致：见
  - `6.18.33_KERNEL_SD_BOOT_MODIFICATIONS.md` §11.10–11.12
  - `6.18.33_boot_20260618_092856_bigcore_disable_fix.md`
  - golden cmdline 含 `maxcpus=4 initcall_blacklist=psci_checker rootdelay=10 panic=0 ...`

### E1. 已对当前 SD 应用的稳定 cmdline

`extlinux.conf` APPEND 增加：
`rootdelay=10 panic=0 usbcore.autosuspend=-1 initcall_blacklist=psci_checker printk.devkmsg=on log_buf_len=16M maxcpus=4 systemd.default_timeout_start_sec=20`

rootfs 临时 mask（对齐历史降并发）：
- `systemd-resolved.service`
- `plymouth-read-write.service`
- `console-setup.service`
- `keyboard-setup.service`

### E2. 构建侧

`amlogic-s9xxx-armbian` 的 `rebuild` 对 `board=lpa3399pro` 自动追加上述 stable args。
