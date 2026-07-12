# SD → eMMC 安全克隆脚本说明（2026-07-12/13）

## 脚本

`tools/sd_to_emmc_safe_clone.sh`

```bash
# 状态
tools/sd_to_emmc_safe_clone.sh status

# 仅备份 eMMC（压缩到主机）
tools/sd_to_emmc_safe_clone.sh backup

# 备份 + 写入 eMMC（需确认 YES，或 --yes）
tools/sd_to_emmc_safe_clone.sh clone --yes

# 从备份恢复 eMMC
tools/sd_to_emmc_safe_clone.sh restore-emmc backups/emmc_clone/emmc_mmcblk0_XXXX.img.gz
```

环境变量：`BOARD` `PASS` `BACKUP_DIR` `SD_DEV` `EMMC_DEV` `SKIP_SD_BACKUP=1`

## 安全策略

1. **仅当 root 在 SD（mmcblk1p2）时允许写 eMMC**
2. **写前强制备份 eMMC** 到主机 `BACKUP_DIR`（pigz 流式）
3. **禁止**在“从 SD 启动”时对 live root 做整盘 `dd if=SD of=eMMC`  
   - 实测会卡在 `folio_wait_bit`（D 状态），约写到 12GB 后挂死
4. 采用 **hybrid**：
   - 从 SD 复制 GPT 布局 + Rockchip loader 扇区（64 / 16384 / 24576）
   - `mkfs` BOOT/ROOTFS
   - `rsync` 活动系统 → eMMC（排除 /dev /proc /sys /tmp /run /boot…）
   - `rsync` /boot
   - `sgdisk -G` 随机 PARTUUID；`tune2fs -U random` 独立 FS UUID
   - 改 eMMC `extlinux` / `armbianEnv` 的 `root=PARTUUID=`
   - 改 eMMC `fstab` 的 UUID
   - 扩容 root 到 eMMC 末尾

## 2026-07-12 实机结果（192.168.50.17）

| 项 | 结果 |
|---|---|
| eMMC 备份 | `backups/emmc_clone/emmc_mmcblk0_20260712_225508.img.gz`（~1.16GiB，原盘 ~14.7GiB） |
| 首轮 full dd | 卡住；已 kill |
| 收尾 hybrid | eMMC 变为 2 分区 Armbian 布局，root 扩到 ~14500MiB |
| eMMC root PARTUUID | `b65fc0a5-43ab-4ab7-abcb-1af54cbd442f` |
| loaders | idb@64 / LOADER@16384 / BL3X@24576 非空 |
| SD | **未改动**，仍可作救援启动 |

## 刷完后操作

```text
1. poweroff
2. 拔掉 SD（否则 BootROM/U-Boot 可能仍从 SD 起）
3. 上电，应从 eMMC 进 6.18.33
4. 失败：插回 SD 启动，restore-emmc 恢复厂商盘
```

## 与 16G/64G

hybrid 安装后 root 会 `resizepart 2 100%`，同一流程适用于更大 eMMC；  
备份体积随 eMMC 内容变，主机需足够空间。

## 恢复厂商 eMMC

```bash
tools/sd_to_emmc_safe_clone.sh restore-emmc \
  /mnt/sdb3/LPA3399Pro/backups/emmc_clone/emmc_mmcblk0_20260712_225508.img.gz
```

恢复后为原厂 6 分区布局（uboot/trust/boot/recovery/backup/rootfs）。
