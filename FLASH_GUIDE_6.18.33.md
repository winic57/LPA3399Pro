# LPA3399Pro 6.18.33 内核测试烧录指南

## ⚠️ 重要提醒

**已知问题**: 此镜像缺少 `dwmac-rockchip` 驱动，**以太网将无法工作**。
**测试目的**: 验证内核启动、DTB 兼容性和基本硬件功能。
**回滚方案**: 已备份 6.1.141 工作镜像，可随时恢复。

---

## 镜像文件信息

**测试镜像**:
- 文件名: `Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.18.33_server_2026.06.17.img`
- 路径: `/mnt/sdb3/LPA3399Pro/lpa3399pro-armbian/build/output/images/`
- 大小: 3.5 GB
- SHA256: `1ec72f12e3eceea2946a34844fb6b225685dc8c10ce287f28da9dd57cfdbbff6`
- 内核: 6.18.33-rk35xx-ophub

**备份镜像** (工作正常):
- 文件名: `Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.1.141_server_2026.06.11.img`
- 大小: 3.5 GB
- 内核: 6.1.141-rk35xx-ophub (GMAC 已验证工作)

---

## 烧录步骤

### 方法 1: Windows 使用 Rufus / balenaEtcher

1. 下载镜像到 Windows:
   ```bash
   # 在 Linux 上压缩以便传输
   cd /mnt/sdb3/LPA3399Pro/lpa3399pro-armbian/build/output/images/
   zip Armbian_6.18.33_test.zip Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.18.33_server_2026.06.17.img
   ```

2. 使用 balenaEtcher:
   - 下载: https://etcher.balena.io/
   - 选择镜像 → 选择 SD 卡 → Flash

3. 或使用 Rufus:
   - 下载: https://rufus.ie/
   - 设备选择 SD 卡
   - 引导类型选择 "DD 镜像"
   - 选择 .img 文件 → 开始

### 方法 2: Linux 使用 dd

```bash
# 1. 确认 SD 卡设备 (小心选择！)
lsblk

# 2. 卸载所有分区 (假设 SD 卡是 /dev/sdX)
sudo umount /dev/sdX*

# 3. 烧录镜像
sudo dd if=/mnt/sdb3/LPA3399Pro/lpa3399pro-armbian/build/output/images/Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.18.33_server_2026.06.17.img \
        of=/dev/sdX \
        bs=4M \
        status=progress \
        conv=fsync

# 4. 验证校验和 (可选)
sudo dd if=/dev/sdX bs=4M count=875 | sha256sum
# 应该匹配: 1ec72f12e3eceea2946a34844fb6b225685dc8c10ce287f28da9dd57cfdbbff6
```

---

## 启动测试

### 1. 硬件连接
- [ ] 插入烧录好的 SD 卡
- [ ] 连接串口 TTL (GND, TX, RX) - 波特率 115200
- [ ] 连接 HDMI 显示器 (可选)
- [ ] 连接以太网线 (虽然预期不工作)
- [ ] 上电启动

### 2. 观察启动日志

**通过串口监控** (推荐):
```bash
# Linux
sudo minicom -D /dev/ttyUSB0 -b 115200

# 或使用 screen
sudo screen /dev/ttyUSB0 115200

# Windows 使用 PuTTY 或 MobaXterm
```

**关键检查点**:
```
[  0.000000] Booting Linux on physical CPU 0x0
[  0.000000] Linux version 6.18.33-rk35xx-ophub ...
[  0.000000] Machine model: LPA3399Pro / RK3399Pro ...
[  x.xxxxx] rockchip-drm display-subsystem: ... (GPU 初始化)
[  x.xxxxx] dwmmc_rockchip ... (eMMC/SD 控制器)
[  x.xxxxx] rockchip-spi ... (SPI 总线)
[  x.xxxxx] dw-apb-uart ... (串口)
```

**预期错误** (GMAC 相关):
```
[  x.xxxxx] stmmac: No dwmac-rockchip device found
# 或者完全没有 eth0 相关日志
```

### 3. 登录系统

**默认凭据**:
- 用户名: `root`
- 密码: `1234` (首次登录会要求修改)

**登录后立即执行**:
```bash
# 收集系统信息
uname -a
cat /proc/cpuinfo
free -h
df -h
lsmod | grep -i rockchip
dmesg | grep -i gmac
dmesg | grep -i stmmac
dmesg | grep -i eth
ip link show
```

---

## 测试检查清单

### 基本启动 (必须通过)
- [ ] U-Boot 成功加载
- [ ] 内核成功启动到登录提示符
- [ ] 可以通过串口登录
- [ ] CPU 正确识别 (6 核心)
- [ ] 内存正确识别 (4GB)
- [ ] eMMC/SD 卡可访问

### 硬件功能 (预期部分失败)
- [ ] GPU/DRM 初始化成功 (dmesg | grep drm)
- [ ] USB 端口工作
- [ ] HDMI 显示输出
- [ ] ❌ **以太网 eth0 不存在** (预期)
- [ ] ❌ **无法 ping 网关** (预期)

### 关键日志收集
```bash
# 保存完整日志用于分析
dmesg > /tmp/dmesg_6.18.33.log
lsmod > /tmp/lsmod_6.18.33.log
ip addr > /tmp/ip_6.18.33.log
cat /proc/cpuinfo > /tmp/cpuinfo_6.18.33.log

# 如果有 USB 存储，复制出来
mount /dev/sda1 /mnt
cp /tmp/*.log /mnt/
umount /mnt
```

---

## 回滚到工作镜像

如果测试失败或需要恢复网络功能:

```bash
# 烧录 6.1.141 备份镜像
sudo dd if=/mnt/sdb3/LPA3399Pro/lpa3399pro-armbian/build/output/images/Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.1.141_server_2026.06.11.img \
        of=/dev/sdX \
        bs=4M \
        status=progress \
        conv=fsync
```

---

## 测试后下一步

### 如果内核能正常启动
→ **重新编译 6.18.33** 并正确配置 GMAC 驱动

### 如果内核无法启动
→ **切换到 Path C: vendor 4.4.194 内核** (Rockchip 官方)

### 无论结果如何
→ 更新 `/mnt/sdb3/LPA3399Pro/test_6.18.33_record.md` 中的测试结果

---

## 技术支持信息

**测试镜像构建详情**:
- 编译主机: Ubuntu 24.04 (noble)
- 构建工具: ophub/amlogic-s9xxx-armbian rebuild 脚本
- 内核源码: https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.33.tar.xz
- 编译时间: 2026-06-17 15:53 - 17:38 (1h 45m)
- DTB: rk3399pro-neardi-linux-lc110-base.dtb

**已知配置缺陷**:
```
# 配置时使用的是追加方式
make ARCH=arm64 defconfig
cat .config-rockchip-addon >> .config
make ARCH=arm64 olddefconfig

# 问题: olddefconfig 可能丢弃了 GMAC 相关选项或依赖项未满足
# 需要使用 scripts/config 工具或 menuconfig 手动验证
```

---

**测试记录文档**: `/mnt/sdb3/LPA3399Pro/test_6.18.33_record.md`
**编译日志**: `/mnt/sdb3/LPA3399Pro/rk3399pro_kernel/compile.log`
