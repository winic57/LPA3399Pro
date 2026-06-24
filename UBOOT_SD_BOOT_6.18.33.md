# LPA3399Pro U-Boot 配置：从 SD 卡启动 6.18.33 内核

> 日期: 2026-06-17
> 目的: 配置 U-Boot 从 SD 卡启动新烧录的 6.18.33 内核测试镜像
> 参考: LPA3399Pro_Auto_SD_Boot_Guide_20260614.md

---

## 当前状态

- ✅ SD 卡已烧录 6.18.33 镜像
- ✅ SD 卡已插入 LPA3399Pro
- ❌ 板子仍从 eMMC 启动 4.4.194 旧内核
- ❌ 需要配置 U-Boot 切换到 SD 卡启动

---

## 方案选择

根据参考文档，有三种方案：

### 方案 A：U-Boot saveenv（推荐）⭐⭐⭐⭐⭐
- **优点**: 持久化配置，一次设置永久生效
- **优点**: 完全可逆，故障可一键恢复
- **优点**: eMMC 无损
- **缺点**: 需要手动中断 U-Boot autoboot

### 方案 B：擦除 eMMC idbloader
- **优点**: 强制 BootROM 走 SD 卡
- **缺点**: eMMC 永久不可启动，需要 maskrom 恢复
- **风险**: 中等

### 方案 C：每次手动输入命令
- **优点**: 零风险，适合测试
- **缺点**: 不持久化，每次启动都要手动操作

**本次测试选择方案 C**（手动验证），验证成功后可升级到方案 A（持久化）。

---

## 操作步骤

### 前置准备

1. **确认 SD 卡已插入 LPA3399Pro**
2. **确认 TTL 串口连接正常**
   - 波特率: **1500000** (非常重要！)
   - 数据位: 8N1
   - 设备: /dev/ttyUSB0 (或其他)
3. **准备串口终端**
   - 推荐: `picocom -b 1500000 /dev/ttyUSB0`
   - 或: `screen /dev/ttyUSB0 1500000`
   - 或: `minicom -D /dev/ttyUSB0 -b 1500000`

---

### 第 1 步：中断 U-Boot 自动启动

```bash
# 1. 打开 TTL 串口监控
picocom -b 1500000 /dev/ttyUSB0

# 2. 给板子上电（或按复位键）

# 3. 看到以下提示时，立刻多次按 Ctrl+C：
#    Hit key to stop autoboot('CTRL+C'):  3
#    Hit key to stop autoboot('CTRL+C'):  2
#    Hit key to stop autoboot('CTRL+C'):  1
#    Hit key to stop autoboot('CTRL+C'):  0
#    ^^^ 在这里狂按 Ctrl+C ^^^

# 4. 成功进入 U-Boot 命令行会看到：
=> 
```

**技巧**:
- 如果错过时机，重新给板子断电再上电
- 可以提前按住 Ctrl+C，看到 "Hit key" 就已经在按了
- 倒计时很短（~3秒），要快速反应

---

### 第 2 步：验证 SD 卡可读

```bash
=> mmc dev 1
# 应显示: switch to partitions #0, OK
#         mmc1 is current device

=> mmc rescan
# 应显示: (无输出表示成功)

=> ls mmc 1:1 /
# 应显示 SD 卡 boot 分区的文件列表：
#   extlinux/
#   Image
#   dtb/
#   uInitrd
#   config-6.18.33-rk35xx-ophub
#   System.map-6.18.33-rk35xx-ophub
#   armbianEnv.txt
#   等等...
```

**如果 `mmc dev 1` 或 `ls mmc 1:1` 报错**:
- 检查 SD 卡是否插紧
- 重新插拔 SD 卡
- 检查 SD 卡是否损坏（用读卡器在电脑上验证）

---

### 第 3 步：加载 6.18.33 内核和设备树

```bash
# 切换到 SD 卡
=> mmc dev 1

# 重新扫描
=> mmc rescan

# 加载内核 (Image) 到内存地址 0x00280000
=> load mmc 1:1 0x00280000 /Image

# 加载 initrd (uInitrd) 到内存地址 0x0a200000
=> load mmc 1:1 0x0a200000 /uInitrd

# 加载设备树 (DTB) 到内存地址 0x08300000
=> load mmc 1:1 0x08300000 /dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb
```

**预期输出**:
```
... bytes read in ... ms (... MB/s)
```

每个 load 命令都应该成功显示读取的字节数。

---

### 第 4 步：获取 SD 卡 rootfs 分区的 UUID

需要知道 SD 卡第二分区（rootfs）的 UUID，用于 bootargs。

**方法 1：从之前的日志查找**

6.18.33 镜像的 rootfs UUID 应该在烧录时已经记录。检查：

```bash
# 在主机上执行（不是在 U-Boot 里）
sudo blkid /dev/sdc2
```

**方法 2：使用文档中的 UUID**

根据参考文档，Armbian iter6 的 UUID 是：
```
d9159ff7-f834-4aba-a518-ac5f1dfc7175
```

但 6.18.33 镜像可能不同！需要确认。

**方法 3：从 U-Boot 查看**

```bash
=> ls mmc 1:2 /etc/
# 如果能看到 etc/ 目录，说明第二分区可读
# UUID 可以稍后从系统内部查看
```

**临时方案**：先使用 `/dev/mmcblk1p2` 作为 root 设备（不用 UUID）。

---

### 第 5 步：设置启动参数 (bootargs)

```bash
=> setenv bootargs "root=/dev/mmcblk1p2 rootflags=data=writeback rw rootwait rootfstype=ext4 console=ttyS2,1500000 no_console_suspend consoleblank=0 fsck.fix=yes fsck.repair=yes net.ifnames=0 loglevel=7 earlycon=uart8250,mmio32,0xff1a0000,1500000n8"
```

**关键参数说明**:
- `root=/dev/mmcblk1p2` - SD 卡第二分区作为根分区
- `console=ttyS2,1500000` - TTL 串口输出
- `loglevel=7` - 详细日志（用于调试 GMAC）
- `earlycon=...` - 早期启动日志输出

---

### 第 6 步：启动内核

```bash
=> booti 0x00280000 0x0a200000 0x08300000
```

**参数说明**:
- `0x00280000` - kernel 地址
- `0x0a200000` - initrd 地址
- `0x08300000` - FDT (设备树) 地址

---

### 第 7 步：观察启动日志

启动后，应该在 TTL 看到：

```
[    0.000000] Booting Linux on physical CPU 0x0
[    0.000000] Linux version 6.18.33-rk35xx-ophub ...
[    0.000000] Machine model: ...
[    x.xxxxx] rockchip-drm display-subsystem: ...
...
```

**关键检查点**:

1. **内核版本**: 必须是 `6.18.33-rk35xx-ophub`
2. **GMAC 驱动加载情况**:
   ```
   # 预期看到错误（因为驱动缺失）:
   [    x.xxxxx] stmmac: No dwmac-rockchip device found
   # 或者根本没有 eth0 相关日志
   ```
3. **其他硬件**:
   - CPU 识别正常
   - 内存识别正常 (4GB)
   - SD 卡识别正常
   - USB、GPU 等

---

## 故障排查

### 问题 1：`mmc dev 1` 失败

**现象**: `Card did not respond to voltage select!`

**原因**: SD 卡接触不良或损坏

**解决**:
```bash
# 1. 断电
# 2. 重新插拔 SD 卡
# 3. 上电重试
```

---

### 问题 2：`load mmc 1:1` 读取失败

**现象**: `Failed to load '/Image'`

**原因**: 文件路径错误或分区损坏

**解决**:
```bash
# 1. 检查文件是否存在
=> ls mmc 1:1 /

# 2. 检查分区表
=> part list mmc 1

# 3. 如果分区异常，重新烧录 SD 卡
```

---

### 问题 3：内核启动失败或 panic

**现象**: 启动到一半 kernel panic 或卡死

**可能原因**:
- bootargs 中的 root 设备不正确
- initrd 损坏
- 设备树不匹配

**解决**:
```bash
# 1. 检查 bootargs 中的 root= 参数
# 2. 尝试使用 UUID 而非设备名
# 3. 验证 DTB 文件是否正确
```

---

### 问题 4：看到的仍是 4.4.194 内核

**现象**: `Linux version 4.4.194` 而非 6.18.33

**原因**: 没有成功从 SD 卡加载，仍从 eMMC 启动

**解决**:
```bash
# 重新执行第 3-6 步，确保：
# 1. mmc dev 1 成功切换到 SD 卡
# 2. load 命令都成功
# 3. booti 使用的是刚 load 的地址
```

---

## 测试清单

启动成功后，在系统内执行以下检查：

```bash
# 登录系统 (root / 1234)

# 1. 确认内核版本
uname -a
# 应显示: Linux ... 6.18.33-rk35xx-ophub ... aarch64 GNU/Linux

# 2. 查看系统信息
cat /etc/os-release
# 应显示: Debian GNU/Linux 13 (trixie)

# 3. 检查 GMAC 驱动
lsmod | grep -i gmac
lsmod | grep -i stmmac
# 预期: 无输出或报错（驱动缺失）

# 4. 检查网络接口
ip link show
# 预期: 只有 lo，没有 eth0

# 5. 查看内核日志中的 GMAC 相关信息
dmesg | grep -i gmac
dmesg | grep -i stmmac
dmesg | grep -i eth
# 分析错误原因

# 6. 检查已加载的 Rockchip 模块
lsmod | grep -i rockchip

# 7. 检查网络驱动目录
ls -lh /lib/modules/6.18.33-rk35xx-ophub/kernel/drivers/net/ethernet/
# 查看是否有 stmmac 目录
```

---

## 持久化配置（可选）

如果测试成功，想要永久从 SD 卡启动，参考文档方案 A：

```bash
# 在 U-Boot 命令行执行：

# 1. 设置 sd_boot 脚本
setenv sd_boot 'mmc dev 1; mmc rescan; load mmc 1:1 0x00280000 /Image; load mmc 1:1 0x0a200000 /uInitrd; load mmc 1:1 0x08300000 /dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb; setenv bootargs "root=/dev/mmcblk1p2 rootflags=data=writeback rw rootwait rootfstype=ext4 console=ttyS2,1500000 no_console_suspend consoleblank=0 loglevel=7 earlycon=uart8250,mmio32,0xff1a0000,1500000n8"; booti 0x00280000 0x0a200000 0x08300000'

# 2. 备份原 bootcmd
setenv emmc_boot ${bootcmd}

# 3. 设置新的 bootcmd（优先 SD）
setenv bootcmd 'run sd_boot'

# 4. 持久化保存
saveenv

# 5. 重启验证
reset
```

**恢复到 eMMC 启动**:
```bash
=> setenv bootcmd ${emmc_boot}
=> saveenv
=> reset
```

---

## 相关文件

- **测试镜像**: `/mnt/sdb3/LPA3399Pro/lpa3399pro-armbian/build/output/images/Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.18.33_server_2026.06.17.img`
- **启动日志**: `/mnt/sdb3/LPA3399Pro/ttl_logs/6.18.33_boot-01_20260617_202315.log` (当前是 4.4.194)
- **测试记录**: `/mnt/sdb3/LPA3399Pro/test_6.18.33_record.md`
- **参考文档**: `/mnt/sdb3/LPA3399Pro/LPA3399Pro_Auto_SD_Boot_Guide_20260614.md`

---

## 快速命令备忘

```bash
# 中断 autoboot
Ctrl+C (多次按)

# 完整启动序列
mmc dev 1
mmc rescan
load mmc 1:1 0x00280000 /Image
load mmc 1:1 0x0a200000 /uInitrd
load mmc 1:1 0x08300000 /dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb
setenv bootargs "root=/dev/mmcblk1p2 rootflags=data=writeback rw rootwait rootfstype=ext4 console=ttyS2,1500000 no_console_suspend consoleblank=0 loglevel=7 earlycon=uart8250,mmio32,0xff1a0000,1500000n8"
booti 0x00280000 0x0a200000 0x08300000

# 查看环境变量
printenv

# 恢复默认环境（故障恢复）
env default -a
saveenv
reset
```

---

*创建时间: 2026-06-17*
*用途: LPA3399Pro 6.18.33 内核测试启动配置*
