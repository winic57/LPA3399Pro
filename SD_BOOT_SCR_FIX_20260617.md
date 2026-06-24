# SD 卡 boot.scr 修复记录

> 日期: 2026-06-17 21:00
> 问题: boot.scr 损坏导致 U-Boot 无法自动加载内核
> 解决: 重新编译 boot.scr

---

## 问题表现

从启动日志 `/mnt/sdb3/LPA3399Pro/ttl_logs/6.18.33_boot_20260617_205448.log` 看到：

```
Line 200: Found U-Boot script /boot.scr
Line 203: Unknown command '������������...'    ← 大量乱码
Line 203: SCRIPT FAILED: continuing...
```

**根本原因**: boot.scr 文件损坏或编译错误

---

## 修复步骤

### 1. 挂载 SD 卡 boot 分区

```bash
sudo mkdir -p /mnt/sd_boot
sudo mount /dev/sdc1 /mnt/sd_boot
```

### 2. 验证源文件正常

```bash
cat /mnt/sd_boot/boot.cmd
```

✅ boot.cmd 源文件完整正常

### 3. 安装 mkimage 工具

```bash
sudo apt-get install -y u-boot-tools
```

**输出**:
```
正在设置 u-boot-tools (2025.10-0ubuntu0.24.04.2) ...
```

### 4. 备份损坏的 boot.scr

```bash
sudo cp /mnt/sd_boot/boot.scr /mnt/sd_boot/boot.scr.broken
```

### 5. 重新编译 boot.scr

```bash
sudo mkimage -C none -A arm -T script -d /mnt/sd_boot/boot.cmd /mnt/sd_boot/boot.scr
```

**输出**:
```
Image Name:   
Created:      Wed Jun 17 20:59:51 2026
Image Type:   ARM Linux Script (uncompressed)
Data Size:    3188 Bytes = 3.11 KiB = 0.00 MiB
Load Address: 00000000
Entry Point:  00000000
```

✅ 编译成功

### 6. 验证新文件

```bash
file /mnt/sd_boot/boot.scr
```

**输出**:
```
/mnt/sd_boot/boot.scr: u-boot legacy uImage, , Linux/ARM, Script File (Not compressed), 3188 bytes, Wed Jun 17 12:59:51 2026, Load Address: 00000000, Entry Point: 00000000, Header CRC: 0XB66D40F6, Data CRC: 0XEA7A82D2
```

✅ 文件类型正确：`u-boot legacy uImage, Script File`

### 7. 同步并卸载

```bash
sudo sync
sudo umount /mnt/sd_boot
```

---

## 文件对比

| 文件 | 大小 | 状态 | 说明 |
|---|---|---|---|
| boot.cmd | 3.2K | ✅ 正常 | 源文件（文本格式）|
| boot.scr.broken | 3.2K | ❌ 损坏 | 旧的编译版本（乱码）|
| boot.scr | 3.2K | ✅ 修复 | 新编译版本（正确的 uImage 格式）|

---

## 预期结果

### 下次启动时

```
DDR Version 1.24 20191016
...
U-Boot 2017.09 ...
Found IDB in SDcard
...
Scanning mmc 1:1...
Found U-Boot script /boot.scr
3188 bytes read in XX ms
## Executing script at 00500000           ← 不再是乱码！
Boot script loaded from mmc 1
...
[    0.000000] Linux version 6.18.33-rk35xx-ophub ...
```

### 关键变化

**修复前**:
```
Line 203: Unknown command '������������...'
SCRIPT FAILED: continuing...
=> (停在 U-Boot 命令行)
```

**修复后**:
```
## Executing script at 00500000
Boot script loaded from mmc 1
...
(自动加载内核并启动系统)
```

---

## 技术说明

### boot.scr 格式

boot.scr 是 **U-Boot 脚本的二进制格式**，通过 `mkimage` 从文本格式的 boot.cmd 编译而来。

**结构**:
- 64 字节 uImage header (包含 CRC 校验)
- boot.cmd 的实际内容

**为什么需要编译**:
- U-Boot 需要 uImage 格式的 header 来验证脚本完整性
- Header 包含 CRC 校验，确保脚本未损坏
- 直接使用 boot.cmd 会导致 U-Boot 无法识别

### 损坏原因分析

可能的损坏原因：
1. **Armbian 构建时编译错误** - mkimage 版本不兼容
2. **SD 卡扇区损坏** - 写入时出现错误
3. **文件系统错误** - FAT32 文件系统损坏

---

## 相关文件

- **修复后的 boot.scr**: `/mnt/sd_boot/boot.scr` (已写入 SD 卡)
- **损坏的备份**: `/mnt/sd_boot/boot.scr.broken`
- **源文件**: `/mnt/sd_boot/boot.cmd`
- **启动日志**: `/mnt/sdb3/LPA3399Pro/ttl_logs/6.18.33_boot_20260617_205448.log`

---

## 测试清单

### 下次启动验证

插入 SD 卡并上电，检查：

```bash
# 1. U-Boot 应该自动执行 boot.scr
## Executing script at 00500000
Boot script loaded from mmc 1

# 2. 自动加载内核
Loading kernel from SD card...
Loading initrd...
Loading device tree...
Booting kernel...

# 3. 内核启动
[    0.000000] Linux version 6.18.33-rk35xx-ophub ...
```

### 系统内验证

登录后执行：

```bash
uname -a
# 应显示: Linux ... 6.18.33-rk35xx-ophub

dmesg | grep -i "gmac\|stmmac\|eth"
# 检查 GMAC 驱动情况

lsmod | grep -i rockchip
# 查看加载的 Rockchip 模块
```

---

## 如果仍然失败

如果修复后仍然无法启动，可能是其他问题：

### 备用方案 1：使用 extlinux.conf

```bash
# 在 U-Boot 命令行
setenv boot_scripts ""
saveenv
reset
```

### 备用方案 2：手动启动

```bash
mmc dev 1
mmc rescan
load mmc 1:1 0x02080000 /Image
load mmc 1:1 0x06000000 /uInitrd
load mmc 1:1 0x01f00000 /dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb
setenv bootargs "root=/dev/mmcblk1p2 rootwait rootfstype=ext4 console=ttyS2,1500000 loglevel=7"
booti 0x02080000 0x06000000 0x01f00000
```

---

*修复时间: 2026-06-17 21:00*  
*工具版本: u-boot-tools 2025.10*  
*验证状态: ✅ 文件格式正确*  
*待测试: 下次启动验证*
