# LPA3399Pro SD 启动下一步建议与本机镜像静态对比

**日期**: 2026-06-13  
**依据**: `LPA3399Pro_SD_Boot_Troubleshooting_20260612.md`  
**目标**: 在不改写 SD 卡、不启动板子的前提下，对本机原厂镜像、SDK 产物和 Armbian 镜像做静态验证，确认下一步最小风险测试路径。

## 1. 下一步总体建议

当前最值得推进的是 **原厂 bootloader + Armbian 分区** 的最小闭环验证：

1. 重新刷写 Armbian 镜像到 SD 卡。
2. 用 SD 专用 `idbloader.img` 覆盖 sector 64。
3. 用原厂/SDK `uboot.img` 覆盖 sector 16384。
4. 用原厂/SDK `trust.img` 覆盖 sector 24576。
5. 串口使用 `1500000` 波特率冷启动观察。

判断标准：

- 仍然完全无串口输出：问题仍在 BootROM -> idbloader/DDR 初始化阶段。
- 出现 DDR/miniloader/U-Boot 输出：第一阶段已修复，继续处理 U-Boot 自动启动配置。
- 能加载内核但卡住：转向 kernel cmdline、DTB、驱动兼容性排查。

## 2. 对比对象

### Armbian 镜像

- `lpa3399pro-armbian/build/output/images/Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.1.141_server_2026.06.11.img`

静态分区布局：

```text
NR   START     END SECTORS SIZE NAME    UUID
 1   32768 1079295 1046528 511M primary d29276ea-ca1c-48e2-ba3f-eac39a651791
 2 1081344 7223295 6141952 2.9G primary f9314f92-7c5f-44cb-ba26-b509e9232444
```

结论：第一分区从 sector 32768，也就是 16MiB 开始。覆盖 sector 64、16384、24576 均在分区前保留区内，不会覆盖 Armbian 的 `/boot` 或 `/` 分区。

### 本机原厂/解包镜像

- `/home/henry/dav/rk3399pro/update_20260201Feb/rockdev/update.img`
- `/home/henry/dav/rk3399pro/LZ11000001_RL_DA_BASE_221114A/LZ11000001_RL_DA_BASE_221114A.img`
- `/home/henry/dav/rk3399pro/unpack_firmware_official/Image/`
- `/home/henry/dav/rk3399pro/unpack_update_official/`
- `/home/henry/dav/rk3399pro/uboot_fix_output/`

### SDK 产物

- `LPA3399Pro-SDK-Linux-V3.0/idbloader.img`
- `LPA3399Pro-SDK-Linux-V3.0/u-boot/uboot.img`
- `LPA3399Pro-SDK-Linux-V3.0/u-boot/trust.img`

## 3. Bootloader 静态对比

### 3.1 Hash 对比

```text
444d2b25567206e8abb7c984407a0b9d18758cb9dc3621542cd6ac152d70bd6e  LPA3399Pro-SDK-Linux-V3.0/idbloader.img
3c58a959ac3049e4b7575ef6807fbef162c0a8b356ba606cb02ce766683c2e71  LPA3399Pro-SDK-Linux-V3.0/u-boot/uboot.img
c82b6b7ea2160c7bdedcd5048b479bb5028434e0811c125fbc2b0080543a6f32  LPA3399Pro-SDK-Linux-V3.0/u-boot/trust.img

d7b0d484824b1df287609decd8cb717fdf63a563c34c419eb598aa22916d6177  /home/henry/dav/rk3399pro/uboot_fix_output/rk3399pro_loader_v1.24.126.bin
3c58a959ac3049e4b7575ef6807fbef162c0a8b356ba606cb02ce766683c2e71  /home/henry/dav/rk3399pro/uboot_fix_output/uboot.img
c82b6b7ea2160c7bdedcd5048b479bb5028434e0811c125fbc2b0080543a6f32  /home/henry/dav/rk3399pro/uboot_fix_output/trust.img

1ba0c710f18883fcbe44b8a4c567ffd57a228f82a4f42880090b1ad37510d3c8  /home/henry/dav/rk3399pro/unpack_firmware_official/Image/MiniLoaderAll.bin
5c6aa8923fc6965a2fb894d28230a90ccf39f756d499fe4492511e7d40f8943d  /home/henry/dav/rk3399pro/unpack_firmware_official/Image/uboot.img
c82b6b7ea2160c7bdedcd5048b479bb5028434e0811c125fbc2b0080543a6f32  /home/henry/dav/rk3399pro/unpack_firmware_official/Image/trust.img
```

结论：

- `trust.img` 在 SDK、`uboot_fix_output`、官方解包件中完全一致。
- `uboot_fix_output/uboot.img` 与 SDK `u-boot/uboot.img` 完全一致。
- 官方解包的 `Image/uboot.img` 与 SDK/修复输出的 `uboot.img` 不一致，但字符串显示两者均为 U-Boot 2017.09 系列，并都包含 `distro_bootcmd`/`extlinux` 支持。
- `MiniLoaderAll.bin` 和 `rk3399pro_loader_v1.24.126.bin` 都不是 SD 直接可用的 `rksd` 形式，不能直接 `dd seek=64`。

### 3.2 Loader 头部格式

`LPA3399Pro-SDK-Linux-V3.0/idbloader.img` 开头是 RC4 后的数据形态，没有明文 `BOOT`：

```text
00000000: 3b8c dcfc be9f 9d51 eb30 34ce 2451 1f98  ;......Q.04.$Q..
```

`rk3399pro_loader_v1.24.126.bin` 和官方 `MiniLoaderAll.bin` 开头是 `BOOT`：

```text
00000000: 424f 4f54 6600 0f01 ...  BOOTf...
```

结论：SD 卡 sector 64 应使用 `mkimage -T rksd` 生成的 `idbloader.img`，不要使用 `BOOT` 头的 USB 线刷 loader。

### 3.3 U-Boot 能力

SDK `uboot.img` 和官方 `uboot.img` 均能看到类似环境字符串：

```text
bootcmd=boot_android ${devtype} ${devnum};bootrkp;run distro_bootcmd;
boot_targets=mmc1 mmc0 usb0 pxe dhcp
boot_extlinux=sysboot ${devtype} ${devnum}:${distro_bootpart} any ${scriptaddr} ${prefix}extlinux/extlinux.conf
scan_dev_for_extlinux=if test -e ${devtype} ${devnum}:${distro_bootpart} ${prefix}extlinux/extlinux.conf; then ...
U-Boot 2017.09
```

结论：如果 U-Boot 能成功初始化 SD 卡并访问第一分区，它理论上可以从 `/extlinux/extlinux.conf` 启动 Armbian。

## 4. Armbian `/boot` 静态检查

BOOT 分区被只读抽取到 `/tmp/lpa3399pro_armbian_boot.img` 后检查。

根目录主要内容：

```text
armbianEnv.txt
boot.cmd
boot.scr
dtb/
extlinux/
config-6.1.141-rk35xx-ophub
initrd.img-6.1.141-rk35xx-ophub
uInitrd-6.1.141-rk35xx-ophub
vmlinuz-6.1.141-rk35xx-ophub
uInitrd -> uInitrd-6.1.141-rk35xx-ophub
Image -> vmlinuz-6.1.141-rk35xx-ophub
dtb-6.1.141-rk35xx-ophub -> dtb
```

`/extlinux` 目录内容：

```text
extlinux.conf.bak
```

关键发现：`/extlinux/extlinux.conf` 不存在，只有 `/extlinux/extlinux.conf.bak`。

`extlinux.conf.bak` 内容：

```text
LABEL Armbian
  LINUX /Image
  INITRD /uInitrd
  FDT /dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb
  APPEND root=UUID=d9159ff7-f834-4aba-a518-ac5f1dfc7175 rootflags=data=writeback rw rootwait rootfstype=ext4 console=ttyS2,1500000 console=tty1 no_console_suspend consoleblank=0 fsck.fix=yes fsck.repair=yes net.ifnames=0 max_loop=128 video=HDMI-A-1:1920x1080@60e plymouth.enable=0
```

`armbianEnv.txt` 内容摘要：

```text
fdtfile=rockchip/rk3399pro-neardi-linux-lc110-base.dtb
rootdev=UUID=d9159ff7-f834-4aba-a518-ac5f1dfc7175
rootfstype=ext4
overlay_prefix=rk3399pro
extraargs=rw rootwait video=HDMI-A-1:1920x1080@60e plymouth.enable=0
extraboardargs=net.ifnames=0 max_loop=128
```

结论：

- `extlinux.conf.bak` 本身路径和内容合理。
- 当前缺失正式文件名 `extlinux.conf`，会导致 vendor U-Boot 的 `scan_dev_for_extlinux` 默认找不到配置。
- 这不是“插卡完全静默”的原因；完全静默仍是更早的 idbloader/DDR/SPL 阶段问题。但一旦 U-Boot 跑起来，这会成为下一处启动阻塞点。

## 5. DTB 静态对比

Armbian BOOT 分区中的目标 DTB：

```text
/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb
```

Hash 对比：

```text
d7b3b29688d4c80af309056d596a9d02fcfe3199374a41c845f9353da86c632e  /tmp/armbian_rk3399pro-neardi-linux-lc110-base.dtb
d7b3b29688d4c80af309056d596a9d02fcfe3199374a41c845f9353da86c632e  /home/henry/dav/rk3399pro/remote_sdk_dtb_check/rk3399pro-neardi-linux-lc110-base.dtb
25ae5cd8813862845b4d6839e60d9d78ffa302764f671dc093282a2d6ab65912  /home/henry/dav/rk3399pro/out/rk-kernel.dtb
3a72ad9e9a1554fa585a593b5d9db2144a677a0ad03376ace8506083cceceb69  /home/henry/dav/rk3399pro/extracted/dtb/update_kernel_fdt_30765492.dtb
```

DTB 基本属性：

```text
model = "Rockchip RK3399pro evb v13 linux board with multi camera"
compatible = "rockchip,rk3399pro-evb-v13-linux", "rockchip,rk3399pro"
```

结论：

- Armbian 镜像中的 `rk3399pro-neardi-linux-lc110-base.dtb` 与 `remote_sdk_dtb_check` 中的 SDK DTB 完全一致。
- 因此当前 Armbian 镜像不是单纯使用通用 RK3399 DTB，板级 DTB 已经放入 BOOT 分区。
- DTB 不是“插卡完全静默”的首要嫌疑；完全静默发生在内核和 DTB 加载之前。

## 6. 原厂镜像关系

大文件 hash：

```text
2576c41c641a332dbb9cc7340e3be2eb42b7b4b250e2618eda1ee6909bb5fb08  /home/henry/dav/rk3399pro/update_20260201Feb/rockdev/update.img
fc8dc4bbccaa5d16bdf75175f0725c3efdec3945540aef600cd44031fd5645c2  /home/henry/dav/rk3399pro/LZ11000001_RL_DA_BASE_221114A/LZ11000001_RL_DA_BASE_221114A.img
3e1e986ca142ec988f85852c42a304830801b1260a5e17d66d65d1599b05e899  /home/henry/dav/rk3399pro/unpack_update_official/firmware.img
1ba0c710f18883fcbe44b8a4c567ffd57a228f82a4f42880090b1ad37510d3c8  /home/henry/dav/rk3399pro/unpack_update_official/boot.bin
```

官方解包 `Image/parameter.txt`：

```text
FIRMWARE_VER: 1.4.0
MACHINE_MODEL: RK3399
MACHINE_ID: 007
MANUFACTURER: RK3399
TYPE: GPT
CMDLINE: mtdparts=rk29xxnand:0x00002000@0x00004000(uboot),0x00002000@0x00006000(trust),0x00010000@0x0000a000(boot),0x00030000@0x0001a000(recovery),0x00010000@0x0004a000(backup),-@0x0005a000(rootfs:grow)
uuid:rootfs=614e0000-0000-4b53-8000-1d28000054a9
```

对应分区偏移：

- `uboot`: `0x4000` sectors = 16384 sectors = 8MiB
- `trust`: `0x6000` sectors = 24576 sectors = 12MiB
- `boot`: `0xa000` sectors = 40960 sectors = 20MiB

这和 SD 混合引导建议中的 `uboot.img`、`trust.img` 写入位置一致。Armbian 第一分区从 16MiB 开始，和原厂 `boot` 分区 20MiB 起点不同，但 U-Boot/trust 写入位置仍一致。

## 7. 静态结论

1. `idbloader.img` 应继续使用 SDK 中由 `mkimage -T rksd` 生成的版本，不应使用 `MiniLoaderAll.bin` 或 `rk3399pro_loader_v1.24.126.bin` 直接写入 SD。
2. `trust.img` 三处完全一致，可以继续使用 SDK 或 `uboot_fix_output` 的版本。
3. `uboot.img` 存在两个版本：
   - SDK/`uboot_fix_output`: `3c58a959...`，构建时间 `Jun 06 2026`。
   - 官方解包: `5c6aa892...`，构建时间 `Feb 01 2026`。
4. 两个 U-Boot 都包含 `distro_bootcmd` 和 `extlinux` 支持。优先建议使用和当前 SDK 产物配套的 `LPA3399Pro-SDK-Linux-V3.0/u-boot/uboot.img`，因为它与已生成的 `idbloader.img` 和 `trust.img` 同源。
5. Armbian BOOT 分区缺失 `/extlinux/extlinux.conf`，只有 `.bak`。这会影响 U-Boot 自动加载，但不会解释“完全静默”。
6. Armbian 中目标 DTB 与 SDK `rk3399pro-neardi-linux-lc110-base.dtb` 完全一致，DTB 已经较合理。

## 8. 建议执行顺序

### P0: 修正 Armbian BOOT 分区里的 extlinux 文件名

在写入 SD 前或写入 SD 后，确保：

```text
/extlinux/extlinux.conf
```

存在，内容可以直接复制当前：

```text
/extlinux/extlinux.conf.bak
```

理由：vendor U-Boot 的默认扫描路径是 `${prefix}extlinux/extlinux.conf`。

### P1: 刷写混合引导 SD

建议使用以下三件套：

```text
LPA3399Pro-SDK-Linux-V3.0/idbloader.img
LPA3399Pro-SDK-Linux-V3.0/u-boot/uboot.img
LPA3399Pro-SDK-Linux-V3.0/u-boot/trust.img
```

写入位置：

```bash
sudo dd if=LPA3399Pro-SDK-Linux-V3.0/idbloader.img of=/dev/sdX seek=64 conv=notrunc
sudo dd if=LPA3399Pro-SDK-Linux-V3.0/u-boot/uboot.img of=/dev/sdX seek=16384 conv=notrunc
sudo dd if=LPA3399Pro-SDK-Linux-V3.0/u-boot/trust.img of=/dev/sdX seek=24576 conv=notrunc
sync
```

注意：将 `/dev/sdX` 替换成实际 SD 设备，避免写错磁盘。

### P2: 串口分层验证

冷启动后按现象分支：

- 完全静默：回到 `idbloader.img`/DDR 初始化，尝试从正在运行的 eMMC 固件中确认真实 loader 版本。
- 到 U-Boot：执行 `mmc list`、`mmc dev 1`、`part list mmc 1`、`ls mmc 1:1 /`、`ls mmc 1:1 /extlinux/`。
- 找到 extlinux 但启动失败：读取 U-Boot 报错，重点检查 `Image`、`uInitrd`、`FDT` 路径和 ext4/symlink 支持。
- 内核启动后失败：再进入 DTB、cmdline、rootfs UUID 和驱动兼容性排查。

## 9. 当前不建议做的事

- 不建议继续直接测试通用 RK3399/RK35xx Armbian SPL，因为此前已经表现为插卡完全静默。
- 不建议把 `BOOT` 头的 `MiniLoaderAll.bin` 或 `rk3399pro_loader_v1.24.126.bin` 直接写到 sector 64。
- 不建议优先改 kernel/rootfs，因为当前最早失败点还在内核加载之前。
- 不建议先替换 DTB；当前 Armbian 中的目标 DTB 已与 SDK 检查版本一致。
