# U-Boot 启动脚本损坏修复指南

> 日期: 2026-06-17 21:00
> 问题: boot.scr 损坏导致无法加载 6.18.33 内核
> 解决: 使用 extlinux.conf 或手动 U-Boot 命令

---

## 问题诊断

### 启动日志分析

从 `/mnt/sdb3/LPA3399Pro/ttl_logs/6.18.33_boot_20260617_205448.log` 看到：

```
Line 140: U-Boot 2017.09 (Jun 06 2026 - 14:10:22 +0000)
Line 148: Found IDB in SDcard              ← idbloader 正常 ✅
Line 150: Bootdev(atags): mmc 1            ← 从 SD 卡启动 ✅
Line 200: Found U-Boot script /boot.scr    ← 找到启动脚本
Line 203: Unknown command '������������...' ← 脚本损坏 ❌
Line 203: SCRIPT FAILED: continuing...     ← 脚本执行失败
Line 251: =>                                ← 停在 U-Boot 命令行
```

### 根本原因

**boot.scr 文件损坏或编码错误**，可能原因：
1. 文件系统写入错误
2. SD 卡扇区损坏
3. boot.scr 编译时出错（mkimage）
4. Armbian 构建时未正确生成

---

## 解决方案

### 方案 1：手动 U-Boot 命令启动（立即可用）⭐

不依赖任何启动脚本，直接在 U-Boot 命令行手动加载内核。

#### 操作步骤

1. **连接 TTL 串口并上电**

```bash
picocom -b 1500000 /dev/ttyUSB0
```

2. **板子上电后会自动停在 U-Boot 命令行 `=>`**（因为 boot.scr 失败）

3. **依次执行以下命令**（建议复制整段粘贴）：

```bash
# 切换到 SD 卡
mmc dev 1
mmc rescan

# 检查文件是否存在
ls mmc 1:1 /

# 加载内核镜像
load mmc 1:1 ${kernel_addr_r} /Image

# 加载 initrd
load mmc 1:1 ${ramdisk_addr_r} /uInitrd

# 加载设备树
load mmc 1:1 ${fdt_addr_r} /dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb

# 设置启动参数
setenv bootargs "root=/dev/mmcblk1p2 rootwait rootfstype=ext4 console=ttyS2,1500000 loglevel=7"

# 启动内核
booti ${kernel_addr_r} ${ramdisk_addr_r} ${fdt_addr_r}
```

**如果 ${kernel_addr_r} 等变量未定义**，使用固定地址：

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

### 方案 2：使用 extlinux.conf（需要修改 SD 卡）

Armbian 通常包含 `/boot/extlinux/extlinux.conf` 作为备用启动配置。

#### 前置条件

需要将 SD 卡插回电脑，挂载并修改配置。

#### 操作步骤

```bash
# 1. 插入 SD 卡到电脑
# 2. 挂载 boot 分区
sudo mkdir -p /mnt/sd_boot
sudo mount /dev/sdc1 /mnt/sd_boot

# 3. 检查 extlinux 配置
cat /mnt/sd_boot/extlinux/extlinux.conf

# 4. 如果配置存在且正确，修改 U-Boot 环境让它优先使用 extlinux
# （回到板子 U-Boot 命令行执行）
setenv boot_targets "mmc1"
setenv scan_dev_for_boot_part "part list ${devtype} ${devnum} -bootable devplist; env exists devplist || setenv devplist 1; for distro_bootpart in ${devplist}; do if fstype ${devtype} ${devnum}:${distro_bootpart} bootfstype; then run scan_dev_for_boot; fi; done"
saveenv
reset

# 5. 卸载 SD 卡
sudo umount /mnt/sd_boot
```

---

### 方案 3：重新生成 boot.scr（彻底修复）

#### 在主机上操作

```bash
# 1. 挂载 SD 卡 boot 分区
sudo mount /dev/sdc1 /mnt/sd_boot

# 2. 创建正确的 boot.cmd 源文件
cat > /tmp/boot.cmd << 'EOF'
# Armbian boot script for LPA3399Pro
# Device: /dev/mmcblk1 (SD card)

setenv bootargs "root=/dev/mmcblk1p2 rootwait rootfstype=ext4 console=ttyS2,1500000 no_console_suspend consoleblank=0 loglevel=7"

echo "Loading kernel from SD card..."
load mmc 1:1 ${kernel_addr_r} /Image || load mmc 1:1 0x02080000 /Image
echo "Loading initrd..."
load mmc 1:1 ${ramdisk_addr_r} /uInitrd || load mmc 1:1 0x06000000 /uInitrd
echo "Loading device tree..."
load mmc 1:1 ${fdt_addr_r} /dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb || load mmc 1:1 0x01f00000 /dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb

echo "Booting kernel..."
booti ${kernel_addr_r} ${ramdisk_addr_r} ${fdt_addr_r} || booti 0x02080000 0x06000000 0x01f00000
EOF

# 3. 编译为 U-Boot 脚本
mkimage -C none -A arm -T script -d /tmp/boot.cmd /tmp/boot.scr

# 4. 备份旧的 boot.scr
sudo mv /mnt/sd_boot/boot.scr /mnt/sd_boot/boot.scr.broken

# 5. 复制新的 boot.scr
sudo cp /tmp/boot.scr /mnt/sd_boot/boot.scr

# 6. 同步并卸载
sudo sync
sudo umount /mnt/sd_boot
```

---

### 方案 4：跳过 boot.scr，直接使用 extlinux（推荐）

让 U-Boot 优先查找 extlinux.conf 而非 boot.scr。

#### 在 U-Boot 命令行执行

```bash
# 设置 distro_bootcmd 跳过脚本搜索
setenv boot_prefixes "/ /boot/"
setenv boot_scripts ""
setenv boot_script_dhcp ""
saveenv
reset
```

这样 U-Boot 会直接查找 `/extlinux/extlinux.conf` 或 `/boot/extlinux/extlinux.conf`。

---

## 快速解决流程（推荐）

### 立即启动测试（方案 1）

```bash
# 1. 连接 TTL 并上电
picocom -b 1500000 /dev/ttyUSB0

# 2. 等待 U-Boot 提示符 =>

# 3. 复制粘贴以下命令
mmc dev 1
mmc rescan
load mmc 1:1 0x02080000 /Image
load mmc 1:1 0x06000000 /uInitrd
load mmc 1:1 0x01f00000 /dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb
setenv bootargs "root=/dev/mmcblk1p2 rootwait rootfstype=ext4 console=ttyS2,1500000 loglevel=7"
booti 0x02080000 0x06000000 0x01f00000
```

### 永久修复（方案 3）

测试成功后，将 SD 卡插回电脑，按方案 3 重新生成 boot.scr。

---

## 内存地址说明

### RK3399 标准加载地址

| 组件 | 变量名 | 标准地址 | 备用地址 |
|---|---|---|---|
| Kernel | ${kernel_addr_r} | 0x02080000 | 0x00280000 |
| Initrd | ${ramdisk_addr_r} | 0x06000000 | 0x0a200000 |
| FDT | ${fdt_addr_r} | 0x01f00000 | 0x08300000 |

不同 U-Boot 版本可能使用不同地址，优先尝试标准地址。

---

## 验证清单

### U-Boot 阶段

```
=> mmc dev 1
switch to partitions #0, OK
mmc1 is current device

=> ls mmc 1:1 /
<DIR>       4096 .
<DIR>       4096 ..
<DIR>      12288 extlinux
         xxxxxx Image
         xxxxxx uInitrd
<DIR>       4096 dtb
         ...
```

### 内核启动阶段

```
[    0.000000] Booting Linux on physical CPU 0x0000000000 [0x410fd034]
[    0.000000] Linux version 6.18.33-rk35xx-ophub ...
[    0.000000] Machine model: ...
```

---

## 故障排查

### 问题 1：load 命令失败

**现象**: `Failed to load '/Image'`

**解决**:
```bash
# 检查文件是否存在
ls mmc 1:1 /
ls mmc 1:1 /boot/

# 如果在 /boot/ 子目录下
load mmc 1:1 0x02080000 /boot/Image
```

### 问题 2：booti 失败

**现象**: `Bad Linux ARM64 Image magic!`

**原因**: Image 文件损坏或地址错误

**解决**: 尝试重新烧录 SD 卡镜像

### 问题 3：内核 panic

**现象**: 启动到一半 kernel panic

**原因**: root 参数错误或 rootfs 损坏

**解决**:
```bash
# 尝试不同的 root 参数
setenv bootargs "root=/dev/mmcblk1p2 rootwait rootfstype=ext4 console=ttyS2,1500000"

# 或使用 UUID
setenv bootargs "root=UUID=<UUID> rootwait rootfstype=ext4 console=ttyS2,1500000"
```

---

## 相关文件

- **损坏的启动日志**: `/mnt/sdb3/LPA3399Pro/ttl_logs/6.18.33_boot_20260617_205448.log`
- **测试记录**: `/mnt/sdb3/LPA3399Pro/test_6.18.33_record.md`
- **SD 卡镜像**: `/mnt/sdb3/LPA3399Pro/lpa3399pro-armbian/build/output/images/Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.18.33_server_2026.06.17.img`

---

*创建时间: 2026-06-17 21:00*  
*状态: 待测试*
