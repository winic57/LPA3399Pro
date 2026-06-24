# 6.18.33 内核测试记录

## 镜像信息
- **文件名**: Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.18.33_server_2026.06.17.img
- **路径**: /mnt/sdb3/LPA3399Pro/lpa3399pro-armbian/build/output/images/
- **大小**: 3.5G (解压后), 739M (压缩)
- **创建时间**: 2026-06-17 18:25
- **内核版本**: 6.18.33-rk35xx-ophub

## 编译配置
- **源码**: Linux 6.18.33 (kernel.org)
- **架构**: arm64 / aarch64
- **交叉编译器**: aarch64-linux-gnu-gcc (Ubuntu 13.3.0-6ubuntu2) 13.3.0
- **配置方法**: defconfig + Rockchip addon 追加
- **编译时长**: ~1小时45分钟

## 已知问题
- ❌ **dwmac-rockchip.ko 驱动缺失** - GMAC 以太网不可用
- ⚠️ 配置文件 (config-6.18.33-rk35xx-ophub) 为空文件

## 已验证的模块
- ✅ Rockchip PHY 驱动存在
- ✅ Rockchip GPU/DRM 驱动存在
- ✅ Rockchip 音频驱动存在
- ✅ Rockchip 加密驱动存在
- ✅ 其他 stmmac/dwmac 驱动（sun8i, meson, imx 等）存在

## 测试目标
1. 验证内核是否能启动
2. 检查 DTB 兼容性
3. 确认串口/TTL 输出
4. 检查基本硬件识别
5. **确认 GMAC 故障现象** (eth0 不存在)

## 回滚方案
- **原始工作镜像**: Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.1.141_server_2026.06.11.img
- **位置**: /mnt/sdb3/LPA3399Pro/lpa3399pro-armbian/build/output/images/
- **大小**: 3.5G
- **内核**: 6.1.141-rk35xx-ophub (已验证 GMAC 工作)

## 测试日志

### [待填写] 烧录信息
- 烧录工具:
- 目标设备:
- 烧录时间:

### [待填写] 启动测试
- 启动状态:
- U-Boot 输出:
- 内核启动日志:
- 错误信息:

### [待填写] 网络测试
- eth0 状态:
- dmesg | grep -i gmac:
- dmesg | grep -i stmmac:
- ifconfig 输出:

### [待填写] 系统基本信息
- uname -a:
- lsmod | grep -i rockchip:
- cat /proc/cpuinfo:
- free -h:

## 测试结论
[待填写]

## 下一步行动
[待填写]

### 烧录信息（已完成）
- **烧录工具**: dd (Linux)
- **目标设备**: /dev/sdc (14.4 GB SD 卡)
- **烧录时间**: 2026-06-17 20:00 (约 4.5 分钟)
- **数据大小**: 3.7 GB (3,699,376,128 字节)
- **平均速度**: 13.4 MB/s
- **分区结果**: 
  - /dev/sdc1: 511M (boot 分区)
  - /dev/sdc2: 2.9G (rootfs 分区)
- **SHA256**: 1ec72f12e3eceea2946a34844fb6b225685dc8c10ce287f28da9dd57cfdbbff6

### 启动测试（进行中）

#### 第一次尝试 - 2026-06-17 20:23
- **日志**: `/mnt/sdb3/LPA3399Pro/ttl_logs/6.18.33_boot-01_20260617_202315.log`
- **结果**: ❌ 仍从 eMMC 启动 4.4.194 内核
- **原因**: idbloader 问题，BootROM 无法识别 SD 卡

#### idbloader 修复 - 2026-06-17 20:30
- **操作**: 替换 SD 卡 idbloader 为 SDK 版本
- **源文件**: `/mnt/sdb3/LPA3399Pro/LPA3399Pro-SDK-Linux-V3.0/idbloader.img`
- **写入位置**: sector 64
- **大小**: 203036 字节
- **MD5验证**: ✅ `3fa843da66820d758f6000266af7934f`
- **文档**: `/mnt/sdb3/LPA3399Pro/SD_IDBLOADER_FIX_20260617.md`

#### 第二次尝试 - 2026-06-17 20:54
- **日志**: `/mnt/sdb3/LPA3399Pro/ttl_logs/6.18.33_boot_20260617_205448.log`
- **结果**: ✅ idbloader 工作 / ❌ boot.scr 损坏
- **现象**: 
  - `Found IDB in SDcard` ✓
  - `Bootdev(atags): mmc 1` ✓
  - `Found U-Boot script /boot.scr` ✓
  - `Unknown command '������...'` ✗ (乱码)
  - `SCRIPT FAILED: continuing...` ✗
- **停止位置**: U-Boot 命令行 `=>`

#### boot.scr 修复尝试 1 - 2026-06-17 21:00
- **操作**: 使用 mkimage 重新编译 boot.scr
- **工具**: u-boot-tools (2025.10)
- **命令**: `mkimage -C none -A arm -T script -d boot.cmd boot.scr`
- **验证**: 文件格式正确 `u-boot legacy uImage, Script File`

#### 第三次尝试 - 2026-06-17 21:02
- **日志**: `/mnt/sdb3/LPA3399Pro/ttl_logs/6.18.33_boot_20260617_210238.log`
- **结果**: ❌ 仍然是乱码
- **分析**: 可能 SD 卡未正确插入或缓存问题

#### boot.scr 修复尝试 2 - 2026-06-17 21:05
- **操作**: 从原始镜像提取经过验证的 boot.scr
- **源**: `Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.18.33_server_2026.06.17.img`
- **Header CRC**: `0X2F9F5E88` (原始镜像)
- **Data CRC**: `0XEA7A82D2`
- **验证**: ✅ 与原始镜像完全一致
- **文档**: `/mnt/sdb3/LPA3399Pro/SD_BOOT_SCR_FIX_20260617.md`

#### 第四次尝试 - 2026-06-17 21:06
- **日志**: `/mnt/sdb3/LPA3399Pro/ttl_logs/6.18.33_boot_with_fixed_bootscr_20260617_210634.log`
- **结果**: ❌ 仍然是乱码
- **关键发现**: `*** Warning - bad CRC, using default environment` (Line 158)
- **根本原因**: **U-Boot 环境变量损坏**，导致：
  - 内存地址变量可能未定义或错误
  - boot.scr 执行地址不正确
  - 脚本解释器配置错误

#### 当前状态（2026-06-17 21:10）
- **idbloader**: ✅ 已修复（SDK 版本）
- **boot.scr**: ✅ 文件正确（与原始镜像一致）
- **U-Boot 环境**: ❌ 损坏（bad CRC）
- **板子状态**: 停在 U-Boot 命令行 `=>`

#### 下一步行动
**方案**: 绕过 boot.scr，直接在 U-Boot 手动执行启动命令

**手动启动命令**（在 `=>` 提示符执行）:
```bash
# 方法 1: 使用环境变量
mmc dev 1
mmc rescan
load mmc 1:1 ${kernel_addr_r} /Image
load mmc 1:1 ${ramdisk_addr_r} /uInitrd
load mmc 1:1 ${fdt_addr_r} /dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb
setenv bootargs "root=/dev/mmcblk1p2 rootwait rootfstype=ext4 console=ttyS2,1500000 loglevel=7"
booti ${kernel_addr_r} ${ramdisk_addr_r} ${fdt_addr_r}

# 方法 2: 固定地址（如果方法1失败）
mmc dev 1
mmc rescan
load mmc 1:1 0x02080000 /Image
load mmc 1:1 0x06000000 /uInitrd
load mmc 1:1 0x01f00000 /dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb
setenv bootargs "root=/dev/mmcblk1p2 rootwait rootfstype=ext4 console=ttyS2,1500000 loglevel=7"
booti 0x02080000 0x06000000 0x01f00000
```

**参考文档**: `/mnt/sdb3/LPA3399Pro/UBOOT_SD_BOOT_6.18.33.md`

