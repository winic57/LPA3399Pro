# LPA3399Pro SD 混合引导写卡与 TTL 抓取记录

**日期**: 2026-06-13  
**依据**: `LPA3399Pro_SD_Boot_Static_Compare_20260613.md`  
**目标**: 按静态对比报告建议，制作并写入 “SDK 原厂 bootloader + Armbian rootfs/boot 分区” 的混合 SD 卡，然后抓取 TTL 启动日志验证。

## 1. 输入文件

原始 Armbian 镜像：

```text
lpa3399pro-armbian/build/output/images/Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.1.141_server_2026.06.11.img
```

SDK bootloader 三件套：

```text
LPA3399Pro-SDK-Linux-V3.0/idbloader.img
LPA3399Pro-SDK-Linux-V3.0/u-boot/uboot.img
LPA3399Pro-SDK-Linux-V3.0/u-boot/trust.img
```

目标 SD 卡：

```text
/dev/sdc
```

识别信息：

```text
NAME   PATH       SIZE TYPE FSTYPE LABEL  MODEL          TRAN
sdc    /dev/sdc  29.1G disk               STORAGE DEVICE usb
├─sdc1 /dev/sdc1  511M part ext4   BOOT
└─sdc2 /dev/sdc2  2.9G part ext4   ROOTFS
```

## 2. 生成混合镜像

生成的派生镜像：

```text
lpa3399pro-armbian/build/output/images/Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.1.141_server_2026.06.11_hybrid_sdkboot.img
```

大小：

```text
3.5G
```

SHA256：

```text
281a7b665ba66ffa3e44ef137f3f40e956897fa880fea7655716740324e6ab92
```

### 2.1 保留原始镜像

原始 Armbian 镜像未直接修改，先复制出 `_hybrid_sdkboot.img`：

```bash
cp --reflink=auto --sparse=always \
  lpa3399pro-armbian/build/output/images/Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.1.141_server_2026.06.11.img \
  lpa3399pro-armbian/build/output/images/Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.1.141_server_2026.06.11_hybrid_sdkboot.img
```

### 2.2 修正 BOOT 分区 extlinux 文件名

问题：Armbian BOOT 分区里只有：

```text
/extlinux/extlinux.conf.bak
```

缺少 vendor U-Boot 默认扫描的：

```text
/extlinux/extlinux.conf
```

处理方式：

1. 按 GPT 分区布局抽取 BOOT 分区。
2. 使用 `debugfs` 将 `extlinux.conf.bak` 复制为 `extlinux.conf`。
3. 将 BOOT 分区写回派生整盘镜像。

最终 SD 卡上读回确认：

```text
/extlinux/extlinux.conf.bak
/extlinux/extlinux.conf
```

`extlinux.conf` 内容：

```text
LABEL Armbian
  LINUX /Image
  INITRD /uInitrd
  FDT /dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb
  APPEND root=UUID=d9159ff7-f834-4aba-a518-ac5f1dfc7175 rootflags=data=writeback rw rootwait rootfstype=ext4 console=ttyS2,1500000 console=tty1 no_console_suspend consoleblank=0 fsck.fix=yes fsck.repair=yes net.ifnames=0 max_loop=128 video=HDMI-A-1:1920x1080@60e plymouth.enable=0
```

### 2.3 写入 SDK bootloader 三件套到镜像

写入位置：

```text
idbloader.img -> sector 64
uboot.img     -> sector 16384
trust.img     -> sector 24576
```

命令：

```bash
dd if=LPA3399Pro-SDK-Linux-V3.0/idbloader.img \
  of=lpa3399pro-armbian/build/output/images/Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.1.141_server_2026.06.11_hybrid_sdkboot.img \
  seek=64 conv=notrunc status=none

dd if=LPA3399Pro-SDK-Linux-V3.0/u-boot/uboot.img \
  of=lpa3399pro-armbian/build/output/images/Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.1.141_server_2026.06.11_hybrid_sdkboot.img \
  seek=16384 conv=notrunc status=none

dd if=LPA3399Pro-SDK-Linux-V3.0/u-boot/trust.img \
  of=lpa3399pro-armbian/build/output/images/Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.1.141_server_2026.06.11_hybrid_sdkboot.img \
  seek=24576 conv=notrunc status=none
```

镜像内三段读回校验结果：

```text
idbloader region OK
uboot region OK
trust region OK
```

## 3. 写入 SD 卡

写入前 `/dev/sdc1`、`/dev/sdc2` 自动挂载在：

```text
/media/henry/BOOT
/media/henry/ROOTFS
```

先卸载：

```bash
umount /media/henry/BOOT /media/henry/ROOTFS
```

整盘写入：

```bash
sudo dd \
  if=lpa3399pro-armbian/build/output/images/Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.1.141_server_2026.06.11_hybrid_sdkboot.img \
  of=/dev/sdc \
  bs=16M conv=fsync status=progress
```

写入统计：

```text
3699376128 bytes (3.7 GB, 3.4 GiB) copied
220+1 records in
220+1 records out
```

## 4. 写入后校验

写入后曾成功读回分区表：

```text
NR   START     END SECTORS SIZE NAME    UUID
 1   32768 1079295 1046528 511M primary d29276ea-ca1c-48e2-ba3f-eac39a651791
 2 1081344 7223295 6141952 2.9G primary f9314f92-7c5f-44cb-ba26-b509e9232444
```

分区标签与 UUID：

```text
/dev/sdc1: LABEL="BOOT"   UUID="13ca210a-e6d7-4ce6-a15d-0d642b2abd5b" PARTUUID="d29276ea-ca1c-48e2-ba3f-eac39a651791"
/dev/sdc2: LABEL="ROOTFS" UUID="d9159ff7-f834-4aba-a518-ac5f1dfc7175" PARTUUID="f9314f92-7c5f-44cb-ba26-b509e9232444"
```

三段 bootloader 从 SD 卡读回对比通过：

```text
idbloader on SD OK
uboot on SD OK
trust on SD OK
```

SD 卡 BOOT 分区内 `extlinux.conf` 读回通过：

```text
/extlinux/extlinux.conf.bak
/extlinux/extlinux.conf
```

备注：后续一次 `partx -s /dev/sdc` 返回 `failed to read partition table`，但同一时间 `lsblk` 仍能看到 `sdc1/sdc2`，`blkid` 也能读出 BOOT/ROOTFS 标签和 UUID。前面的分区表、bootloader、extlinux 校验均已成功。

## 5. TTL 抓取

串口设备：

```text
/dev/ttyUSB0
```

串口参数：

```text
1500000 8N1
```

抓取脚本：

```text
/home/henry/dav/rk3399pro/scripts/ttl_capture.py
```

### 5.1 90 秒抓取

命令：

```bash
python3 /home/henry/dav/rk3399pro/scripts/ttl_capture.py \
  --port /dev/ttyUSB0 \
  --baud 1500000 \
  --seconds 90 \
  --show-speed \
  --log /home/henry/dav/rk3399pro/logs/ttl_sd_hybrid_boot_20260613_110651.log
```

波特率回读：

```text
termios2 ispeed=1500000 ospeed=1500000
```

日志结果：

```text
3 bytes
00000000: c0 00 c0
```

无可读字符串。

### 5.2 波特率扫描

扫描波特率：

```text
115200
921600
1000000
1500000
2000000
3000000
```

结果：

```text
ttl_sd_hybrid_boot_baud_115200_110859.log  0 bytes
ttl_sd_hybrid_boot_baud_921600_110905.log  0 bytes
ttl_sd_hybrid_boot_baud_1000000_110912.log 0 bytes
ttl_sd_hybrid_boot_baud_1500000_110918.log 0 bytes
ttl_sd_hybrid_boot_baud_2000000_110924.log 0 bytes
ttl_sd_hybrid_boot_baud_3000000_110930.log 0 bytes
```

没有抓到可读启动文本。

### 5.3 180 秒断电重上电窗口抓取

命令：

```bash
python3 /home/henry/dav/rk3399pro/scripts/ttl_capture.py \
  --port /dev/ttyUSB0 \
  --baud 1500000 \
  --seconds 180 \
  --show-speed \
  --log /home/henry/dav/rk3399pro/logs/ttl_sd_hybrid_powercycle_20260613_111002.log
```

波特率回读：

```text
termios2 ispeed=1500000 ospeed=1500000
```

日志结果：

```text
1 byte
00000000: 00
```

无可读字符串。

## 6. 当前结论

1. SD 卡写入本身成功，且三段 bootloader 与 BOOT 分区 `extlinux.conf` 均已读回验证。
2. 混合镜像中的 `idbloader.img`、`uboot.img`、`trust.img` 已正确写入 SD 卡对应保留扇区。
3. TTL 在 `1500000` 波特率下能打开并回读正确速率，但本次混合 SD 启动没有输出可读 U-Boot/Linux 文本。
4. 若 180 秒抓取窗口内确实完成过断电重上电，则当前失败点仍在极早期，早于 U-Boot 正常串口输出。
5. 这与此前“通用 Armbian 直接插卡完全静默”的现象接近，说明仅替换为当前 SDK 生成的 `rksd idbloader + uboot + trust` 尚未让板子进入可见 U-Boot 阶段。

## 7. 建议下一步

### P0: 做 eMMC 对照抓取

拔掉 SD 卡，只从 eMMC 原厂系统启动，抓取 TTL：

```bash
python3 /home/henry/dav/rk3399pro/scripts/ttl_capture.py \
  --port /dev/ttyUSB0 \
  --baud 1500000 \
  --seconds 90 \
  --show-speed \
  --log /home/henry/dav/rk3399pro/logs/ttl_emmc_control_20260613.log
```

目的：

- 确认 TTL 接线、CP2102、波特率和当前主机环境仍然能稳定看到原厂 U-Boot/Linux 输出。
- 如果 eMMC 有日志而 SD 没日志，则问题继续锁定在 SD 的 BootROM -> idbloader/DDR/miniloader 阶段。

### P1: 对比 eMMC 实际使用的 loader

当前 SD 用的是 SDK 重新打包的：

```text
LPA3399Pro-SDK-Linux-V3.0/idbloader.img
```

但它未必与板上 eMMC 当前可启动固件的 loader 完全一致。下一步应尽量从 eMMC 或官方刷机包里确认真实在用的 DDR/miniloader 版本，再生成 SD 专用 `rksd` 版。

### P2: 若 eMMC 对照正常，继续聚焦 idbloader/DDR

不建议优先改 kernel/rootfs/DTB，因为本次仍没有进入 U-Boot 文本阶段，内核和 DTB 尚未被加载。
