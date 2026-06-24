# LPA3399Pro 双内核稳定基线复现指南

> 日期: 2026-06-18
> 目的: 从零开始复现 6.1.141 和 6.18.33 两个内核的稳定基线
> 原则: 直接修改 SD 卡，不生成新 .img 文件
> 配套文档: `LPA3399Pro_DUAL_KERNEL_SUMMARY_20260618.md`

---

## 一、前置条件

### 1.1 硬件环境

| 项目 | 要求 |
|---|---|
| 板子 | LPA3399Pro (Neardi LC110 方案, RK3399Pro) |
| SD 卡 | 14.4GB 或更大，Class 10 / UHS-I |
| TTL 串口 | USB-TTL，波特率 1500000（RK3399 默认） |
| 工作机 | Linux x86_64，有 SD 卡读卡器 |
| eMMC | 板载 14.7GB（调试期间不从 eMMC 启动） |

### 1.2 软件环境

工作机需安装以下工具：

```bash
# Debian/Ubuntu
sudo apt-get install -y \
  u-boot-tools \
  device-tree-compiler \
  parted \
  e2fsprogs \
  coreutils

# 验证关键工具
which dd fdtput fdtget losetup mkimage parted resize2fs
```

### 1.3 关键文件清单与校验

以下文件均已验证存在于 `/mnt/sdb3/LPA3399Pro/`：

| 文件 | 路径 | 大小 | 用途 |
|---|---|---|---|
| 6.1.141 镜像 | `lpa3399pro-armbian/build/output/images/Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.1.141_server_2026.06.11.img` | ~2GB | 6.1.141 基础镜像（hybrid_sdkboot） |
| 6.18.33 镜像 | `lpa3399pro-armbian/build/output/images/Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.18.33_server_2026.06.17.img` | ~2GB | 6.18.33 基础镜像 |
| SDK idbloader | `LPA3399Pro-SDK-Linux-V3.0/idbloader.img` | 203036 B | BootROM 识别的 SD 引导loader |
| SDK uboot | `LPA3399Pro-SDK-Linux-V3.0/u-boot/uboot.img` | 4194304 B | U-Boot 2017.09 (vendor) |
| 6.18.33 boot 包 | `lpa3399pro-armbian/build-armbian/kernel/rk35xx/6.18.33/boot-6.18.33-rk35xx-ophub.tar.gz` | 16MB | 内核 Image + config |
| 6.18.33 dtb 包 | `lpa3399pro-armbian/build-armbian/kernel/rk35xx/6.18.33/dtb-rockchip-6.18.33-rk35xx-ophub.tar.gz` | 624KB | 主线 DTB 集合 |
| 6.18.33 modules 包 | `lpa3399pro-armbian/build-armbian/kernel/rk35xx/6.18.33/modules-6.18.33-rk35xx-ophub.tar.gz` | 85MB | 内核模块 |
| 稳定基线 | `baselines/6.18.33_stable_tty_login_20260618_102330/` | — | 6.18.33 已保存基线（参考） |

校验命令：

```bash
cd /mnt/sdb3/LPA3399Pro

# 校验 SDK bootloader
md5sum LPA3399Pro-SDK-Linux-V3.0/idbloader.img
# 期望: 3fa843da66820d758f6000266af7934f（文档记录值）

ls -la LPA3399Pro-SDK-Linux-V3.0/idbloader.img
# 期望: 203036 字节

ls -la LPA3399Pro-SDK-Linux-V3.0/u-boot/uboot.img
# 期望: 4194304 字节
```

---

## 二、通用准备

### 2.1 SD 卡识别

```bash
# 插入 SD 卡后识别设备
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE,LABEL

# 确认 SD 卡设备（本文档以 /dev/sdc 为例）
# 警告: 确保设备路径正确，否则会破坏其他磁盘数据
SD_DEV=/dev/sdc

# 确认 SD 卡大小（应约 14.4GB）
lsblk ${SD_DEV} -o SIZE
```

### 2.2 烧录基础镜像

```bash
# 选择要烧录的镜像（二选一）
# 6.1.141:
IMG=/mnt/sdb3/LPA3399Pro/lpa3399pro-armbian/build/output/images/Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.1.141_server_2026.06.11.img

# 6.18.33:
# IMG=/mnt/sdb3/LPA3399Pro/lpa3399pro-armbian/build/output/images/Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.18.33_server_2026.06.17.img

# 烧录（危险操作，请确认 SD_DEV 正确）
SD_DEV=/dev/sdc
sudo umount ${SD_DEV}? 2>/dev/null
sudo dd if=${IMG} of=${SD_DEV} bs=4M conv=fsync status=progress
sync

# 确认分区
sudo parted ${SD_DEV} print
# 期望: 两个分区
#   sdc1: BOOT (ext4, ~511M)
#   sdc2: ROOTFS (ext4, ~2.9G，剩余空间未分配)
```

### 2.3 挂载 SD 卡分区

```bash
# 创建挂载点
sudo mkdir -p /mnt/sdboot /mnt/sdroot

# 挂载
sudo mount ${SD_DEV}1 /mnt/sdboot
sudo mount ${SD_DEV}2 /mnt/sdroot

# 确认
ls /mnt/sdboot/
# 期望: extlinux/ dtb/ Image boot.scr 等

ls /mnt/sdroot/
# 期望: bin boot dev etc lib ... usr var
```

---

## 三、复现 6.1.141 稳定基线

> 基于 iter37 + iter46a 的最终稳定状态
> 基础镜像 `hybrid_sdkboot` 已含 SDK 引导链，无需单独替换 idbloader

### 3.1 烧录 hybrid_sdkboot 镜像

按 2.2 节烧录 6.1.141 镜像。

**确认引导链**（hybrid_sdkboot 已含）：
```bash
# 检查 sector 64 处的 idbloader（应非全 0）
sudo dd if=${SD_DEV} bs=512 skip=64 count=1 2>/dev/null | xxd | head -3
# 期望: 非全 0（SDK idbloader 已写入）

# 检查 sector 0x4000 (16384) 处的 uboot
sudo dd if=${SD_DEV} bs=512 skip=16384 count=1 2>/dev/null | xxd | head -3
# 期望: 非全 0（SDK uboot 已写入）
```

### 3.2 配置 extlinux.conf

```bash
# 备份原始文件
sudo cp -p /mnt/sdboot/extlinux/extlinux.conf \
           /mnt/sdboot/extlinux/extlinux.conf.orig_$(date +%Y%m%d_%H%M%S)

# 获取 ROOTFS 分区的 UUID
ROOT_UUID=$(sudo blkid -s UUID -o value ${SD_DEV}2)
echo "ROOT_UUID=${ROOT_UUID}"

# 创建 extlinux.conf
# 注意: root=UUID 使用上面获取的实际值
sudo tee /mnt/sdboot/extlinux/extlinux.conf > /dev/null << EOF
LABEL Armbian
  LINUX /Image
  FDT /dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb
  APPEND root=UUID=${ROOT_UUID} rootflags=data=writeback rw rootwait rootdelay=5 rootfstype=ext4 console=ttyS2,1500000 console=tty1 panic=0 usbcore.autosuspend=-1 initcall_blacklist=psci_checker printk.devkmsg=on net.ifnames=0
EOF

# 确认
cat /mnt/sdboot/extlinux/extlinux.conf
```

### 3.3 修改 DTB（禁用硬挂死源）

```bash
DTB=/mnt/sdboot/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb

# 备份原始 DTB
sudo cp -p ${DTB} ${DTB}.orig_$(date +%Y%m%d_%H%M%S)

# iter5-13: 禁用硬挂死源
sudo fdtput -t s ${DTB} /display-subsystem status disabled
sudo fdtput -t s ${DTB} /vop@ff8f0000 status disabled
sudo fdtput -t s ${DTB} /vop@ff900000 status disabled
sudo fdtput -t s ${DTB} /watchdog@ff848000 status disabled
sudo fdtput -t s ${DTB} /sdhci@fe330000 status disabled
sudo fdtput -t s ${DTB} /dmc status disabled
sudo fdtput -t s ${DTB} /rkisp1@ff910000 status disabled
sudo fdtput -t s ${DTB} /rkisp1@ff920000 status disabled
sudo fdtput -t s ${DTB} /mipi-dphy-tx1rx1@ff968000 status disabled
sudo fdtput -t s ${DTB} /iep@ff670000 status disabled

# iter34: 禁用 PCIe（6.1.141 基线禁用 PCIe）
sudo fdtput -t s ${DTB} /pcie-phy status disabled
sudo fdtput -t s ${DTB} /pcie@f8000000 status disabled

# 验证
for node in /display-subsystem /vop@ff8f0000 /vop@ff900000 \
            /watchdog@ff848000 /sdhci@fe330000 /dmc \
            /rkisp1@ff910000 /rkisp1@ff920000 \
            /mipi-dphy-tx1rx1@ff968000 /iep@ff670000 \
            /pcie-phy /pcie@f8000000; do
  echo "$node: $(sudo fdtget -t s ${DTB} ${node} status)"
done
# 期望: 全部 disabled
```

### 3.4 GMAC 节点保持 vendor baseline（iter46a 修正）

> 重要: iter38-45 把正确的 DTB 改坏了。iter46a 确认 Armbian 出厂 DTB 的 GMAC 节点与 vendor DTS 完全一致，**不要添加任何 snps,* 属性或修改 phy-mode**。
> 由于基础镜像的 DTB 已经是 vendor baseline，此处只需验证，不需修改。

```bash
DTB=/mnt/sdboot/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb

# 验证 GMAC 节点保持 vendor baseline
echo "=== GMAC 节点验证 ==="
echo "phy-mode: $(sudo fdtget -t s ${DTB} /ethernet@fe300000 phy-mode)"
# 期望: rgmii

echo "clock_in_out: $(sudo fdtget -t s ${DTB} /ethernet@fe300000 clock_in_out)"
# 期望: input

echo "tx_delay: $(sudo fdtget -t x ${DTB} /ethernet@fe300000 tx_delay)"
# 期望: 0x21

echo "rx_delay: $(sudo fdtget -t x ${DTB} /ethernet@fe300000 rx_delay)"
# 期望: 0x15

echo "status: $(sudo fdtget -t s ${DTB} /ethernet@fe300000 status)"
# 期望: okay

# 确认没有 iter38-45 添加的多余属性
echo "=== 确认无多余属性 ==="
sudo fdtget -t x ${DTB} /ethernet@fe300000 snps,burst_len 2>&1
# 期望: failed to read（属性不存在）

sudo fdtget -t x ${DTB} /ethernet@fe300000 assigned-clock-rates 2>&1
# 期望: failed to read（属性不存在）
```

### 3.5 rootfs 稳定化（iter34-37）

#### 3.5.1 iter34: GPT 备份头修复 + motd 清理 + WiFi 黑名单

```bash
# GPT 备份头修复（在 SD 卡未挂载时执行）
sudo umount /mnt/sdboot /mnt/sdroot
sudo parted ${SD_DEV} print
# 如果提示 "GPT:XXX != YYY"，选择 Fix
# 交互式 parted:
sudo parted ---pretend-input-tty ${SD_DEV} print
# 输入 Fix

# 重新挂载
sudo mount ${SD_DEV}1 /mnt/sdboot
sudo mount ${SD_DEV}2 /mnt/sdroot

# iter34: 清空损坏的 armbian-motd
sudo cp -p /mnt/sdroot/etc/default/armbian-motd \
           /mnt/sdroot/etc/default/armbian-motd.orig_$(date +%Y%m%d_%H%M%S) 2>/dev/null
sudo truncate -s 0 /mnt/sdroot/etc/default/armbian-motd

# iter34: 修正 WiFi 黑名单（vendor 名 rtl8821cs → 主线驱动名 rtw88_8821cs）
# 在 extlinux.conf 和 armbianEnv.txt 中确保黑名单含 rtw88_8821cs
ARMENV=/mnt/sdboot/armbianEnv.txt
if [ -f ${ARMENV} ]; then
  sudo cp -p ${ARMENV} ${ARMENV}.orig_$(date +%Y%m%d_%H%M%S)
  # 确保黑名单含 rtw88_8821cs
  sudo sed -i 's/rtl8821cs/rtl8821cs,rtw88_8821cs/g' ${ARMENV}
fi
```

#### 3.5.2 iter35: 禁用 fstrim/e2scrub + NM 不管理 eth0 + fstab 优化

```bash
# iter35: 禁用 fstrim.timer（避免 SD 卡 DISCARD I/O 错误）
sudo mv /mnt/sdroot/etc/systemd/system/timers.target.wants/fstrim.timer \
        /mnt/sdroot/etc/systemd/system/timers.target.wants/fstrim.timer.disabled.bak 2>/dev/null

# iter35: 禁用 e2scrub_all.timer
sudo mv /mnt/sdroot/etc/systemd/system/timers.target.wants/e2scrub_all.timer \
        /mnt/sdroot/etc/systemd/system/timers.target.wants/e2scrub_all.timer.disabled.bak 2>/dev/null

# iter35: fstab commit=600 → commit=60（降低 journal 后台 IO 风暴）
sudo cp -p /mnt/sdroot/etc/fstab /mnt/sdroot/etc/fstab.orig_$(date +%Y%m%d_%H%M%S)
sudo sed -i 's/commit=600/commit=60/g' /mnt/sdroot/etc/fstab

# iter35: NetworkManager 不管理 eth0（避免 DMA 失败重试→login 阻塞）
NM_CONF=/mnt/sdroot/etc/NetworkManager/NetworkManager.conf
sudo cp -p ${NM_CONF} ${NM_CONF}.orig_$(date +%Y%m%d_%H%M%S)
# 追加 [keyfile] 段（如果不存在）
sudo grep -q '\[keyfile\]' ${NM_CONF} || sudo tee -a ${NM_CONF} > /dev/null << 'EOF'

[keyfile]
unmanaged-devices=interface-name:eth0
EOF
```

#### 3.5.3 iter36: 禁用 NM-wait-online + 跳过首次登录建密

```bash
# iter36: 禁用 NetworkManager-wait-online.service（避免 60s 启动超时）
sudo mv /mnt/sdroot/etc/systemd/system/network-online.target.wants/NetworkManager-wait-online.service \
        /mnt/sdroot/etc/systemd/system/network-online.target.wants/NetworkManager-wait-online.service.disabled.bak 2>/dev/null

# iter36: 删除首次登录标记（跳过 armbian-firstlogin 建密提示）
if [ -f /mnt/sdroot/root/.not_logged_in_yet ]; then
  sudo mv /mnt/sdroot/root/.not_logged_in_yet \
          /mnt/sdroot/root/.not_logged_in_yet.disabled.bak
fi
```

#### 3.5.4 iter37: 恢复自动登录

```bash
# iter37: 创建 serial-getty@ttyFIQ0 autologin override
sudo mkdir -p /mnt/sdroot/etc/systemd/system/serial-getty@ttyFIQ0.service.d
sudo tee /mnt/sdroot/etc/systemd/system/serial-getty@ttyFIQ0.service.d/autologin.conf > /dev/null << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --autologin root --keep-baud 1500000,115200,57600,38400,9600 %I $TERM
EOF

# iter37: 创建 getty@tty1 autologin override（HDMI）
sudo mkdir -p /mnt/sdroot/etc/systemd/system/getty@tty1.service.d
sudo tee /mnt/sdroot/etc/systemd/system/getty@tty1.service.d/autologin.conf > /dev/null << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --autologin root --noclear %I $TERM
EOF
```

### 3.6 ROOTFS 扩容

```bash
# 卸载
sudo umount /mnt/sdboot /mnt/sdroot

# 扩展 sdc2 分区到 SD 卡末尾
sudo parted ${SD_DEV} resizepart 2 100%

# 检查并修复文件系统
sudo e2fsck -f ${SD_DEV}2

# 扩展文件系统
sudo resize2fs ${SD_DEV}2

# 重新挂载验证
sudo mount ${SD_DEV}2 /mnt/sdroot
df -h /mnt/sdroot
# 期望: 约 13G 可用（14.4G SD 卡 - 511M boot - 分区开销）

sudo umount /mnt/sdroot
```

### 3.7 6.1.141 验证清单

```bash
# 同步并卸载
sync
sudo umount /mnt/sdboot /mnt/sdroot 2>/dev/null

# 将 SD 卡插入板子，连接 TTL 串口（1500000 baud）
# 上电，观察 TTL 日志

# === 期望启动流程 ===
# 1. BootROM: Found IDB in SDcard
# 2. U-Boot 2017.09 (vendor) 加载 extlinux.conf
# 3. 加载 Image + DTB
# 4. Linux 6.1.141 启动
# 5. ~35s 到 root shell（自动登录）
```

**登录后验证**：

```bash
# 在板子 root shell 执行
uname -r
# 期望: 6.1.141-rk35xx-ophub

# 检查 HDMI 显示（iter22 恢复）
# 期望: 显示器有 console 输出

# 检查 SD 卡
lsblk
# 期望: mmcblk1 (SD 卡) + mmcblk1p1/p2

# 检查 USB
lsusb
# 期望: 列出 USB 设备

# 检查 GMAC（预期失败，但不应挂死板子）
ip link set eth0 up
# 期望: 命令返回（可能超时），板子不挂死
dmesg | grep -i "Failed to reset the dma"
# 期望: 出现 DMA reset failed（iter46 确认根因在驱动侧，非硬件缺陷）
ip -br link show eth0
# 期望: eth0 存在但 DOWN

# 检查启动噪声（应全部清零）
dmesg | grep -cE "DISCARD|Card stuck being busy"
# 期望: 0
dmesg | grep -cE "command not found"
# 期望: 0（armbian-motd 已清空）
```

---

## 四、复现 6.18.33 稳定基线

> 基于修改1-11 的最终稳定状态
> 当前稳定基线已保存到 `baselines/6.18.33_stable_tty_login_20260618_102330/`

### 4.1 烧录 6.18.33 镜像

按 2.2 节烧录 6.18.33 镜像。

```bash
IMG=/mnt/sdb3/LPA3399Pro/lpa3399pro-armbian/build/output/images/Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.18.33_server_2026.06.17.img
SD_DEV=/dev/sdc

sudo umount ${SD_DEV}? 2>/dev/null
sudo dd if=${IMG} of=${SD_DEV} bs=4M conv=fsync status=progress
sync

sudo parted ${SD_DEV} print
# 期望: sdc1 (BOOT, ext4, ~511M) + sdc2 (ROOTFS, ext4, ~2.9G)

sudo mount ${SD_DEV}1 /mnt/sdboot
sudo mount ${SD_DEV}2 /mnt/sdroot
```

### 4.2 替换 SDK idbloader（修改1）

```bash
# ophub 默认 idbloader 无法被 RK3399 BootROM 识别
# 替换为 SDK idbloader
sudo dd if=/mnt/sdb3/LPA3399Pro/LPA3399Pro-SDK-Linux-V3.0/idbloader.img \
        of=${SD_DEV} seek=64 conv=notrunc,fsync

# 验证
sudo dd if=${SD_DEV} bs=512 skip=64 count=1 2>/dev/null | xxd | head -3
# 期望: 非全 0
```

### 4.3 禁用 boot.scr + 创建 extlinux.conf（修改2）

```bash
# 备份并禁用 boot.scr（vendor U-Boot 环境变量损坏导致 boot.scr 乱码）
if [ -f /mnt/sdboot/boot.scr ]; then
  sudo cp -p /mnt/sdboot/boot.scr /mnt/sdboot/boot.scr.orig_$(date +%Y%m%d_%H%M%S)
  sudo mv /mnt/sdboot/boot.scr /mnt/sdboot/boot.scr.disabled
fi

# 获取 ROOTFS 分区的 PARTUUID（6.18.33 无 initramfs，需用 PARTUUID）
ROOT_PARTUUID=$(sudo blkid -s PARTUUID -o value ${SD_DEV}2)
echo "ROOT_PARTUUID=${ROOT_PARTUUID}"

# 创建 extlinux.conf
# 注意: root=PARTUUID 使用上面获取的实际值
sudo tee /mnt/sdboot/extlinux/extlinux.conf > /dev/null << EOF
LABEL Armbian
  LINUX /Image
  FDT /dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb
  APPEND root=PARTUUID=${ROOT_PARTUUID} rootflags=data=writeback rw rootwait rootdelay=10 rootfstype=ext4 console=ttyS2,1500000 console=tty1 panic=0 usbcore.autosuspend=-1 initcall_blacklist=psci_checker printk.devkmsg=on log_buf_len=16M net.ifnames=0 plymouth.enable=0 maxcpus=4
EOF

cat /mnt/sdboot/extlinux/extlinux.conf
```

**extlinux.conf 参数说明**：

| 参数 | 作用 | 来源 |
|---|---|---|
| `root=PARTUUID=...` | 无 initramfs 直启，用 GPT PARTUUID | 修改8 |
| `console=ttyS2,1500000` | TTL 串口控制台 | 主线 DTB |
| `console=tty1` | HDMI 控制台（display 禁用后无效但保留） | — |
| `rootwait rootdelay=10` | 等待 SD 卡就绪 | — |
| `panic=0` | 不自动重启 | — |
| `usbcore.autosuspend=-1` | USB 稳定性 | iter1-13 |
| `initcall_blacklist=psci_checker` | 避免 PSCI 死锁 | iter1-13 |
| `printk.devkmsg=on` | 详细启动日志 | — |
| `log_buf_len=16M` | 避免 printk 消息丢弃 | 修改5 |
| `plymouth.enable=0` | 禁用 plymouth | 修改11 |
| `maxcpus=4` | 禁用 A72 big cores | 修改10 |

### 4.4 替换为主线 DTB（修改3）

```bash
# 解压主线 DTB 包
TMPDIR=$(mktemp -d)
sudo tar -xzf /mnt/sdb3/LPA3399Pro/lpa3399pro-armbian/build-armbian/kernel/rk35xx/6.18.33/dtb-rockchip-6.18.33-rk35xx-ophub.tar.gz -C ${TMPDIR}

# 查找主线 rk3399pro-rock-pi-n10.dtb
MAINLINE_DTB=$(find ${TMPDIR} -name "rk3399pro-rock-pi-n10.dtb" | head -1)
echo "MAINLINE_DTB=${MAINLINE_DTB}"

# 备份 vendor DTB
DTB=/mnt/sdboot/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb
sudo cp -p ${DTB} ${DTB}.vendor.bak

# 替换为主线 DTB
sudo cp -f ${MAINLINE_DTB} ${DTB}

# 验证
sudo fdtget -t s ${DTB} / compatible
# 期望: radxa,rockpi-n10 vamrs,rk3399pro-vmarc-som rockchip,rk3399pro

ls -la ${DTB}
# 期望: 约 59KB（vendor DTB 为 100KB）
```

### 4.5 禁用 DRM/VOP/watchdog（修改4）

```bash
DTB=/mnt/sdboot/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb

# 备份（禁用前）
sudo cp -p ${DTB} ${DTB}.mainline_pre_disable.bak

# 禁用 DRM/display（参考 iter7 经验，避免初始化死锁）
sudo fdtput -t s ${DTB} /display-subsystem status disabled
sudo fdtput -t s ${DTB} /vop@ff8f0000 status disabled
sudo fdtput -t s ${DTB} /vop@ff900000 status disabled

# 禁用 watchdog（调试阶段避免异常复位）
sudo fdtput -t s ${DTB} /watchdog@ff848000 status disabled

# 验证
for node in /display-subsystem /vop@ff8f0000 /vop@ff900000 /watchdog@ff848000; do
  echo "$node: $(sudo fdtget -t s ${DTB} ${node} status)"
done
# 期望: 全部 disabled
```

### 4.6 禁用 GMAC + 保持 PCIe okay（修改6+7）

```bash
DTB=/mnt/sdboot/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb

# 备份
sudo cp -p ${DTB} ${DTB}.pre_gmac_disable.bak

# 禁用 GMAC（DMA 硬件缺陷/DMA reset failed，主线 stmmac 会触发问题）
sudo fdtput -t s ${DTB} /ethernet@fe300000 status disabled

# 重要: 保持 PCIe okay（修改7 结论）
# PCIe link training 超时是优雅失败，且提供 fe320000.mmc 时序隔离
# 禁用 PCIe 会导致 fe320000/fe310000 竞态，挂死点提前
# 验证 PCIe 状态
echo "PCIe status: $(sudo fdtget -t s ${DTB} /pcie@f8000000 status)"
# 期望: okay（主线 DTB 默认就是 okay）

# 验证 GMAC 状态
echo "GMAC status: $(sudo fdtget -t s ${DTB} /ethernet@fe300000 status)"
# 期望: disabled
```

### 4.7 rootfs 稳定化（修改9 + iter34-37 同类项）

#### 4.7.1 绕过 systemd generator sandbox Oops（修改9）

```bash
# systemd 257 执行 generators 阶段触发内核 Oops
# 备份并清空 system-generators 目录
GEN_DIR=/mnt/sdroot/usr/lib/systemd/system-generators
sudo cp -a ${GEN_DIR} ${GEN_DIR}.orig_$(date +%Y%m%d_%H%M%S).bak

# 清空目录内容（保留目录本身）
sudo rm -f ${GEN_DIR}/*

# 确认
ls -la ${GEN_DIR}/
# 期望: 空目录
```

#### 4.7.2 禁用 fstrim/e2scrub（同 iter35）

```bash
sudo mv /mnt/sdroot/etc/systemd/system/timers.target.wants/fstrim.timer \
        /mnt/sdroot/etc/systemd/system/timers.target.wants/fstrim.timer.disabled.bak 2>/dev/null

sudo mv /mnt/sdroot/etc/systemd/system/timers.target.wants/e2scrub_all.timer \
        /mnt/sdroot/etc/systemd/system/timers.target.wants/e2scrub_all.timer.disabled.bak 2>/dev/null
```

#### 4.7.3 禁用 NM-wait-online + mask 首次登录（同 iter36）

```bash
# mask NetworkManager-wait-online.service
sudo ln -sf /dev/null /mnt/sdroot/etc/systemd/system/NetworkManager-wait-online.service

# 删除首次登录标记
if [ -f /mnt/sdroot/root/.not_logged_in_yet ]; then
  sudo mv /mnt/sdroot/root/.not_logged_in_yet \
          /mnt/sdroot/root/.not_logged_in_yet.disabled.bak
fi
```

#### 4.7.4 修复 fstab（修改9）

```bash
# 获取实际 PARTUUID
ROOT_PARTUUID=$(sudo blkid -s PARTUUID -o value ${SD_DEV}2)

sudo cp -p /mnt/sdroot/etc/fstab /mnt/sdroot/etc/fstab.orig_$(date +%Y%m%d_%H%M%S)

# 修改 root 行: 使用 PARTUUID + commit=60
# 具体修改视原 fstab 内容而定，示例:
sudo sed -i "s|^[^#].* / .*|PARTUUID=${ROOT_PARTUUID} / ext4 defaults,noatime,commit=60 0 1|" /mnt/sdroot/etc/fstab

# 验证
cat /mnt/sdroot/etc/fstab
# 期望: root 行使用 PARTUUID + commit=60
```

#### 4.7.5 自动登录 + 串口修复（修改11）

```bash
# 确保串口 getty 在 ttyS2（主线 DTB 使用 ttyS2，不是 ttyFIQ0）
sudo mkdir -p /mnt/sdroot/etc/systemd/system/serial-getty@ttyS2.service.d
sudo tee /mnt/sdroot/etc/systemd/system/serial-getty@ttyS2.service.d/autologin.conf > /dev/null << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --autologin root --keep-baud 1500000,115200,57600,38400,9600 %I $TERM
EOF

# HDMI getty autologin
sudo mkdir -p /mnt/sdroot/etc/systemd/system/getty@tty1.service.d
sudo tee /mnt/sdroot/etc/systemd/system/getty@tty1.service.d/autologin.conf > /dev/null << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --autologin root --noclear %I $TERM
EOF

# mask 错误的 ttyAML0 getty（主线 DTB 无 ttyAML0）
sudo ln -sf /dev/null /mnt/sdroot/etc/systemd/system/serial-getty@ttyAML0.service

# mask plymouth 全套
for svc in plymouth-start.service plymouth-quit.service plymouth-quit-wait.service \
           plymouth-read-write.service; do
  sudo ln -sf /dev/null /mnt/sdroot/etc/systemd/system/${svc}
done
```

#### 4.7.6 mask 首次启动噪声服务（修改10-11）

```bash
# 降低早期并发负载（maxcpus=4 下减少 A53 负担）
for svc in systemd-udev-trigger.service systemd-resolved.service \
           systemd-random-seed.service armbian-zram-config.service \
           console-setup.service keyboard-setup.service; do
  sudo ln -sf /dev/null /mnt/sdroot/etc/systemd/system/${svc}
done

# mask apt/man-db/unattended-upgrades 首次启动噪声
for svc in apt-daily.service apt-daily-upgrade.service \
           man-db.service unattended-upgrades.service; do
  sudo ln -sf /dev/null /mnt/sdroot/etc/systemd/system/${svc}
done
```

### 4.8 ROOTFS 扩容

```bash
sudo umount /mnt/sdboot /mnt/sdroot

sudo parted ${SD_DEV} resizepart 2 100%
sudo e2fsck -f ${SD_DEV}2
sudo resize2fs ${SD_DEV}2

# 验证
sudo mount ${SD_DEV}2 /mnt/sdroot
df -h /mnt/sdroot
sudo umount /mnt/sdroot
```

### 4.9 6.18.33 验证清单

```bash
sync
sudo umount /mnt/sdboot /mnt/sdroot 2>/dev/null

# 将 SD 卡插入板子，连接 TTL 串口（1500000 baud）
# 上电，观察 TTL 日志

# === 期望启动流程 ===
# 1. BootROM: Found IDB in SDcard
# 2. U-Boot 2017.09 (vendor): bad CRC warning（正常，extlinux 不依赖环境变量）
# 3. Scanning mmc 1:1... Found /extlinux/extlinux.conf
# 4. 加载 /Image (6.18.33) + 主线 DTB
# 5. Linux 6.18.33 启动
# 6. ~0.7s fe320000.mmc 探测（PCIe 时序隔离）
# 7. ~0.77s SD 卡检测: mmcblk1: mmc1:0001 SD16G 14.4 GiB
# 8. ~1.4s PCIe link training 超时 (-110)，系统继续
# 9. (跳过 GMAC，已禁用)
# 10. EXT4-fs (mmcblk1p2): mounted filesystem
# 11. systemd 启动 → multi-user
# 12. root@armbian:~# 自动登录
```

**登录后验证**：

```bash
uname -a
# 期望: Linux armbian 6.18.33 #1 SMP PREEMPT ... aarch64 GNU/Linux

# 检查 CPU（应只有 4 核 A53）
nproc
# 期望: 4

cat /proc/cpuinfo | grep -c processor
# 期望: 4

# 检查网络接口（GMAC 已禁用，只有 lo）
ip -br link show
# 期望: lo + 可能的 USB 网卡（如有插入）

# 检查 GMAC 确实未加载（预期行为）
dmesg | grep -iE "stmmac|gmac|eth0"
# 期望: 空（GMAC 节点 disabled，不触发 probe）

# 检查启动噪声
dmesg | grep -cE "DISCARD|Card stuck being busy"
# 期望: 0

dmesg | grep -cE "Failed to reset the dma"
# 期望: 0（GMAC 未触发）

# 检查 systemd 状态
systemctl is-system-running
# 期望: running 或 degraded（不应是 starting/stopped）
```

---

## 五、GMAC 测试 DTB 制作（可选）

> 用于在 6.18.33 稳定基线上继续排查 GMAC 问题
> 警告: 启用 GMAC 后 eth0 open 阶段会 DMA reset failed，但不会挂死板子

### 5.1 基础测试 DTB（status=okay）

```bash
sudo mount ${SD_DEV}1 /mnt/sdboot
DTB_BASE=/mnt/sdboot/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb
DTB_TEST=/mnt/sdboot/dtb/rockchip/gmac-test.dtb

# 复制稳定基线 DTB
sudo cp -p ${DTB_BASE} ${DTB_TEST}

# 仅启用 GMAC
sudo fdtput -t s ${DTB_TEST} /ethernet@fe300000 status okay

# 验证
sudo fdtget -t s ${DTB_TEST} /ethernet@fe300000 status
# 期望: okay

# 切换 extlinux.conf 指向测试 DTB
sudo cp -p /mnt/sdboot/extlinux/extlinux.conf \
           /mnt/sdboot/extlinux/extlinux.conf.gmac-test.bak
sudo sed -i 's|rk3399pro-neardi-linux-lc110-base.dtb|gmac-test.dtb|' \
           /mnt/sdboot/extlinux/extlinux.conf

sync
sudo umount /mnt/sdboot
```

### 5.2 测试矩阵（已验证全部失败的组合，供参考）

以下 8 种 DTB 修改在 6.18.33 上**全部 DMA reset failed**，不要再重复尝试：

| # | 修改方向 | 基础 DTB | fdtput 命令 |
|---|---|---|---|
| 1 | status=okay | gmac-test.dtb | `fdtput -t s DTB /ethernet@fe300000 status okay` |
| 2 | rx_delay=0x20 | gmac-rx20-test.dtb | `fdtput -t x DTB /ethernet@fe300000 rx_delay 0x20` |
| 3 | reset-gpio=PC0 | gmac-pc0-test.dtb | `fdtput -t x DTB /ethernet@fe300000 snps,reset-gpio 23 10 1` |
| 4 | clock_in_out=output | gmac-clockout-test.dtb | `fdtput -t s DTB /ethernet@fe300000 clock_in_out output` |
| 5 | vendor neardi 参数 | gmac-neardi-vendor-delay-test.dtb | tx=0x21 rx=0x15 + PB7 + input |
| 6 | + vcc_phy | gmac-vccphy-test.dtb | 新增 vcc-phy-regulator 节点 + phy-supply |
| 7 | + phy-handle | gmac-phyhandle-pll-test.dtb | 新增 mdio/ethernet-phy@0 子节点 |
| 8 | 一致 output | gmac-output-consistent-test.dtb | output + 删除 assigned-clocks/parents |

**结论**：DTB 层面已排除，转向驱动侧（见第六节）。

### 5.3 测试 DTB 的运行时验证

```bash
# 启动后登录 root shell
# GMAC probe 应成功
dmesg | grep -E "rk_gmac|stmmac|YT8521"
# 期望:
#   rk_gmac-dwmac fe300000.ethernet: clock input or output? (input).
#   rk_gmac-dwmac fe300000.ethernet: TX delay(0x28).
#   rk_gmac-dwmac fe300000.ethernet: RX delay(0x11).
#   rk_gmac-dwmac fe300000.ethernet: init for RGMII
#   YT8521 Gigabit Ethernet stmmac-0:00: attached PHY driver

# eth0 open 应失败（预期）
ip link set eth0 up
# 期望: RTNETLINK answers: Connection timed out（板子不挂死）

dmesg | tail -10
# 期望:
#   Failed to reset the dma
#   stmmac_hw_setup: DMA engine initialization failed
#   __stmmac_open: Hw setup failed

# DMA 寄存器检查（关键证据）
ethtool -d eth0
# 记录 Reg0/Reg10/Reg22 值

ip link set eth0 up
ethtool -d eth0
# 对比前后值（预期: 几乎不变，说明驱动没推进状态切换）
```

---

## 六、驱动补丁验证流程（下一步）

> 当前 patch 草案: `patches/0001-rk3399pro-gmac-debug-and-rxc-workaround.patch`
> 状态: 草案已生成，尚未编译验证

### 6.1 获取驱动源码

```bash
# vendor 4.4 参考源码（已存在）
ls /mnt/sdb3/LPA3399Pro/LPA3399Pro-SDK-Linux-V3.0/kernel/drivers/net/ethernet/stmicro/stmmac/dwmac-rk.c

# mainline 6.18 源码（需从 ophub boot 包提取或 kernel.org 下载）
# 从 boot 包提取:
TMPDIR=$(mktemp -d)
sudo tar -xzf /mnt/sdb3/LPA3399Pro/lpa3399pro-armbian/build-armbian/kernel/rk35xx/6.18.33/boot-6.18.33-rk35xx-ophub.tar.gz -C ${TMPDIR}
ls ${TMPDIR}/
# 期望: 含 Image, config-6.18.33-rk35xx-ophub 等

# 完整源码需从 kernel.org 下载 6.18.33
# 或从 ophub/kernel 仓库获取
```

### 6.2 应用 patch

```bash
# 进入源码目录
cd /path/to/linux-6.18.33

# 应用 patch
patch -p1 < /mnt/sdb3/LPA3399Pro/patches/0001-rk3399pro-gmac-debug-and-rxc-workaround.patch

# 确认修改
git diff drivers/net/ethernet/stmicro/stmmac/dwmac-rk.c
```

### 6.3 编译

```bash
# 使用 ophub config
cp /path/to/config-6.18.33-rk35xx-ophub .config

make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- oldconfig
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) Image modules
```

### 6.4 替换到 SD 卡

```bash
# 备份当前 Image
sudo mount ${SD_DEV}1 /mnt/sdboot
sudo cp -p /mnt/sdboot/Image /mnt/sdboot/Image.orig_$(date +%Y%m%d_%H%M%S)

# 替换内核
sudo cp arch/arm64/boot/Image /mnt/sdboot/

# 替换模块
sudo mount ${SD_DEV}2 /mnt/sdroot
sudo rm -rf /mnt/sdroot/lib/modules/6.18.33-rk35xx-ophub
sudo make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- modules_install INSTALL_MOD_PATH=/mnt/sdroot

sync
sudo umount /mnt/sdboot /mnt/sdroot
```

### 6.5 验证 patch 效果

```bash
# 使用 gmac-phyhandle-pll-test.dtb（最保守的测试 DTB）
sudo mount ${SD_DEV}1 /mnt/sdboot
sudo sed -i 's|rk3399pro-neardi-linux-lc110-base.dtb|gmac-phyhandle-pll-test.dtb|' \
           /mnt/sdboot/extlinux/extlinux.conf
sync
sudo umount /mnt/sdboot

# 启动后 TTL 观察 patch 新增日志
dmesg | grep -E "rk3399 rgmii applied|external PHY reset|powerup start|powerup done"
# 期望: 出现 patch 新增的 GRF readback / PHY reset / powerup 日志

# 测试 eth0 open
ip link set eth0 up
dmesg | tail -20
# 期望: 不再报 "Failed to reset the dma"
ip -br link show eth0
# 期望: eth0 UP
```

---

## 七、回退方案

### 7.1 6.1.141 回退到出厂状态

```bash
SD_DEV=/dev/sdc
sudo mount ${SD_DEV}1 /mnt/sdboot
sudo mount ${SD_DEV}2 /mnt/sdroot

# 恢复 extlinux.conf
sudo cp /mnt/sdboot/extlinux/extlinux.conf.orig_* /mnt/sdboot/extlinux/extlinux.conf

# 恢复 DTB
sudo cp /mnt/sdboot/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb.orig_* \
        /mnt/sdboot/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb

# 恢复 rootfs 配置（按需恢复 .bak 文件）
sudo cp /mnt/sdroot/etc/fstab.orig_* /mnt/sdroot/etc/fstab
sudo cp /mnt/sdroot/etc/NetworkManager/NetworkManager.conf.orig_* \
        /mnt/sdroot/etc/NetworkManager/NetworkManager.conf

sync
sudo umount /mnt/sdboot /mnt/sdroot
```

### 7.2 6.18.33 回退到稳定基线

```bash
# 方法1: 从基线目录恢复（推荐）
BASELINE=/mnt/sdb3/LPA3399Pro/baselines/6.18.33_stable_tty_login_20260618_102330

sudo mount ${SD_DEV}1 /mnt/sdboot
sudo mount ${SD_DEV}2 /mnt/sdroot

# 恢复 boot 分区
sudo cp -a ${BASELINE}/sd_boot/* /mnt/sdboot/

# 恢复 rootfs 关键文件
sudo cp -a ${BASELINE}/sd_rootfs/etc/fstab /mnt/sdroot/etc/
# 其他文件按需从 etc_systemd_system.tar 解包

sync
sudo umount /mnt/sdboot /mnt/sdroot

# 方法2: 重新烧录 + 按第四节重新操作
```

### 7.3 紧急回退（板子无法启动）

如果修改后板子无法启动：
1. 拔出 SD 卡，插入工作机
2. 检查 TTL 日志确定卡死位置
3. 挂载 SD 卡，回退最近修改
4. 如果无法确定，按 7.1 或 7.2 完整回退

---

## 八、常见问题

### Q1: TTL 串口无输出

**检查项**：
- 波特率必须是 1500000（RK3399 默认，不是 115200）
- TTL 电平 3.3V
- TX/RX 是否接反
- SD 卡 idbloader 是否已替换为 SDK 版本（6.18.33 必须）

### Q2: BootROM 跳过 SD 卡从 eMMC 启动

**原因**：idbloader 无法被 BootROM 识别
**解决**：确认 SDK idbloader 已写入 sector 64
```bash
sudo dd if=/mnt/sdb3/LPA3399Pro/LPA3399Pro-SDK-Linux-V3.0/idbloader.img \
        of=/dev/sdc seek=64 conv=notrunc,fsync
```

### Q3: U-Boot 报 "SCRIPT FAILED" 或乱码

**原因**：vendor U-Boot 环境变量 CRC 失效，boot.scr 中的 `${devtype}` 等变量未定义
**解决**：禁用 boot.scr，使用 extlinux.conf
```bash
sudo mv /mnt/sdboot/boot.scr /mnt/sdboot/boot.scr.disabled
```

### Q4: 内核启动时报 "clk: couldn't get clock 5"

**原因**：vendor DTB 时钟绑定格式与主线内核不兼容
**解决**：替换为主线 DTB（见 4.4 节）

### Q5: 日志在 YT8521 PHY attach 后停止

**原因**：GMAC DMA reset failed（主线 stmmac probe 阶段或 open 阶段）
**解决**：禁用 GMAC 节点
```bash
sudo fdtput -t s ${DTB} /ethernet@fe300000 status disabled
```

### Q6: 启动到一半随机 Oops，首次 Oops 在 CPU4/CPU5

**原因**：A72 big core OPP/电源/时钟与主线 DTB 不匹配
**解决**：添加 `maxcpus=4` 到 extlinux.conf APPEND 行

### Q7: systemd 报 "Failed to fork off sandboxing environment"

**原因**：systemd 257 generator sandbox 在主线内核下触发 Oops
**解决**：清空 `/usr/lib/systemd/system-generators`（见 4.7.1 节）

### Q8: 启动卡在 "plymouth-quit-wait.service"

**原因**：plymouth 等待显示子系统，但 display 已禁用
**解决**：添加 `plymouth.enable=0` + mask plymouth 服务（见 4.7.5 节）

### Q9: rootfs 挂载失败 "Cannot open root device"

**原因**：无 initramfs 时 `root=UUID=` 无法被内核解析（内核打印的 available partitions 是 PARTUUID）
**解决**：改用 `root=PARTUUID=...`（见 4.3 节）

### Q10: GMAC eth0 open 报 "Failed to reset the dma"

**现状**：DTB 层面 8 种修改全部失败，根因在驱动侧
**临时方案**：保持 GMAC disabled，使用 USB 以太网适配器
**彻底方案**：应用驱动 patch（见第六节，待编译验证）

---

## 九、文件备份命名约定

所有备份文件使用以下格式：
```
<原文件名>.<修改说明>_<日期>_<时间>[.bak]
```

示例：
- `extlinux.conf.orig_20260618_120000`
- `rk3399pro-neardi-linux-lc110-base.dtb.vendor.bak`
- `fstab.orig_20260618_120000`
- `fstrim.timer.disabled.bak`

---

## 十、文档参考

### 主文档
- `LPA3399Pro_SDCard_Full_Adaptation_Log_20260615.md` — 6.1.141 iter1-45 全量记录
- `6.18.33_KERNEL_SD_BOOT_MODIFICATIONS.md` — 6.18.33 修改1-11 + GMAC 测试 1-8

### 关键分析文档
- `LPA3399Pro_iter46_plan_after_debian10_evidence_20260616.md` — 推翻硬件缺陷结论
- `6.18.33_GMAC_ETHERNET_MODIFICATION_PLAN_FOR_NEXT_AGENT_20260618.md` — 驱动侧方案
- `6.18.33_GMAC_PATCH_DRAFT_20260618.md` — patch 草案说明

### 稳定基线
- `baselines/6.18.33_stable_tty_login_20260618_102330/BASELINE_README.md`

### 总结文档
- `LPA3399Pro_DUAL_KERNEL_SUMMARY_20260618.md` — 双内核调试总结（本文档配套）

---

*生成时间: 2026-06-18*
*所有文件路径均已验证存在*
*所有命令均基于文档记录的实际操作*
*遵循"不生成新 .img"原则: 所有操作直接修改 SD 卡*
