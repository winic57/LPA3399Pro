# SD 卡 idbloader 修复记录

> 日期: 2026-06-17 20:30
> 目的: 替换 SD 卡上的 idbloader 为 SDK 版本，使 BootROM 能识别并从 SD 卡启动

---

## 问题诊断

### 现象
- SD 卡已烧录 6.18.33 镜像
- 板子上电后仍从 eMMC 启动 4.4.194 旧内核
- TTL 日志显示 BootROM 跳过 SD 卡，直接加载 eMMC 的 U-Boot

### 根本原因
根据 `LPA3399Pro_Auto_SD_Boot_Guide_20260614.md` 的分析：

**Armbian/ophub 默认的 idbloader 无法被 RK3399 BootROM 识别**。

| 镜像来源 | idbloader 类型 | BootROM 识别？ | 结果 |
|---|---|---|---|
| ophub 默认（iter5） | ophub 生成 | ❌ | 跳过 SD → 走 eMMC |
| SDK 修复版（iter6/hybrid_sdkboot） | SDK `make.sh --idblock` | ✅ | 直接走 SD |

---

## 解决方案

### 方法：替换 SD 卡上的 idbloader（sector 64）

不需要重新烧录整个镜像，只需替换 idbloader 部分。

---

## 操作步骤

### 1. 确认源文件

```bash
ls -lh /mnt/sdb3/LPA3399Pro/LPA3399Pro-SDK-Linux-V3.0/idbloader.img
```

**输出**:
```
-rwxrwxrwx 1 root root 199K  6月 12 21:35 idbloader.img
```

**文件大小**: 203036 字节  
**MD5**: `3fa843da66820d758f6000266af7934f`

---

### 2. 确认 SD 卡设备

```bash
lsblk | grep sdc
```

**输出**:
```
sdc                  8:32   1  14.4G  0 disk 
├─sdc1               8:33   1   511M  0 part 
└─sdc2               8:34   1   2.9G  0 part
```

**SD 卡设备**: `/dev/sdc`

---

### 3. 写入 SDK idbloader 到 SD 卡 sector 64

```bash
sudo dd if=/mnt/sdb3/LPA3399Pro/LPA3399Pro-SDK-Linux-V3.0/idbloader.img \
        of=/dev/sdc \
        seek=64 \
        conv=notrunc,fsync \
        status=progress
```

**参数说明**:
- `seek=64` - 从 sector 64 开始写（RK3399 idbloader 标准位置）
- `conv=notrunc` - 不截断目标文件（只修改指定位置）
- `conv=fsync` - 写完立即同步到磁盘

**输出**:
```
输入了 396+1 块记录
输出了 396+1 块记录
203036 字节 (203 kB, 198 KiB) 已复制，0.107828 s，1.9 MB/s
```

---

### 4. 验证写入结果

```bash
# 读取 SD 卡上写入的数据并计算 MD5
sudo dd if=/dev/sdc bs=1 skip=$((64*512)) count=203036 2>/dev/null | md5sum
```

**输出**:
```
3fa843da66820d758f6000266af7934f  -
```

✅ **验证成功**：MD5 与源文件完全匹配

---

### 5. 同步并安全移除

```bash
sudo sync
```

✅ 已同步到磁盘，可以安全移除 SD 卡

---

## 修改详情

### 修改的位置

| 位置 | Sector | 字节偏移 | 大小 | 内容 |
|---|---|---|---|---|
| idbloader | 64 | 32768 | 203036 字节 | SDK 版 idbloader |

### 未修改的部分

| 位置 | Sector | 内容 | 状态 |
|---|---|---|---|
| MBR/GPT | 0-63 | 分区表 | 保持不变 ✓ |
| U-Boot | 0x4000 | U-Boot 2017.09 (Armbian) | 保持不变 ✓ |
| boot 分区 | sdc1 | 6.18.33 内核、DTB、initrd | 保持不变 ✓ |
| rootfs 分区 | sdc2 | Armbian Debian 13 (trixie) | 保持不变 ✓ |

**关键点**：只替换了 idbloader，其他所有内容（包括 Armbian 的 U-Boot 和系统）完全保持不变。

---

## 工作原理

### BootROM 启动流程（修改后）

```
上电
  ↓
BootROM (RK3399 芯片内置)
  ↓
检查 SD 卡 sector 64 的 idbloader
  ↓ (SDK 版本，BootROM 能识别 ✅)
加载 SD 卡 sector 0x4000 的 U-Boot
  ↓ (Armbian U-Boot 2017.09)
U-Boot 加载 SD 卡 /boot 分区的内核
  ↓
Linux 6.18.33-rk35xx-ophub 启动
  ↓
Armbian Debian 13 (trixie)
```

### 关键技术点

1. **RK3399 idbloader 位置**：sector 64（32768 字节偏移）
2. **BootROM 识别标准**：idbloader 必须包含正确的 rksd 头和 DDR init 代码
3. **ophub 的问题**：使用的 idbloader 缺少 BootROM 所需的某些字段
4. **SDK 的优势**：`make.sh --idblock` 生成的 idblock.bin 完全符合 BootROM 规范

---

## 预期结果

### 下次启动时

1. **插入 SD 卡** → BootROM 识别 SD idbloader → 从 SD 启动 6.18.33
2. **拔掉 SD 卡** → BootROM 找不到 SD → 回退到 eMMC 启动 4.4.194

**完全无损可逆**：
- eMMC 完全未动
- 拔卡即恢复原厂系统
- SD 卡数据完整（只修改了 bootloader 部分）

---

## 测试清单

### 启动后验证

插入 SD 卡并上电，通过 TTL 检查：

```bash
# 1. 内核版本（必须是 6.18.33）
[    0.000000] Linux version 6.18.33-rk35xx-ophub ...

# 2. BootROM 路径（应该看到 SD 卡初始化）
DDR Version 1.24 20191016
...
Boot1 Release Time: May 29 2020 17:36:36
...
SdmmcInit=0 0          # SD 卡被识别
UserCapSize=14748MB    # 显示 SD 卡大小

# 3. U-Boot 加载位置（应该是 SD 的 U-Boot）
U-Boot 2017.09 (Feb 01 2026 - 05:43:12 +0000)
...
```

### 系统内验证

登录后执行：

```bash
uname -a
# 应显示: Linux ... 6.18.33-rk35xx-ophub

dmesg | grep -i "gmac\|stmmac\|eth0"
# 检查 GMAC 驱动加载情况（预期失败）

lsmod | grep -i rockchip
# 查看已加载的 Rockchip 模块
```

---

## 故障恢复

### 情况 1：启动失败，黑屏无输出

**原因**: idbloader 损坏或写入错误

**解决**:
1. 物理拔掉 SD 卡
2. 上电 → 板子从 eMMC 启动（恢复正常）
3. 重新烧录完整的 SD 卡镜像

### 情况 2：仍然从 eMMC 启动

**原因**: 可能 SD 卡座接触不良

**解决**:
1. 重新插拔 SD 卡
2. 检查 SD 卡是否完全插入
3. 如果还不行，尝试另一张 SD 卡

### 情况 3：想恢复 ophub 原始 idbloader

```bash
# 从原始镜像提取 idbloader
sudo dd if=/mnt/sdb3/LPA3399Pro/lpa3399pro-armbian/build/output/images/Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.18.33_server_2026.06.17.img \
        of=/tmp/original_idbloader.img \
        bs=512 \
        skip=64 \
        count=397

# 写回 SD 卡
sudo dd if=/tmp/original_idbloader.img \
        of=/dev/sdc \
        seek=64 \
        conv=notrunc,fsync
```

---

## 相关文件

- **SDK idbloader**: `/mnt/sdb3/LPA3399Pro/LPA3399Pro-SDK-Linux-V3.0/idbloader.img`
- **SD 卡镜像**: `/mnt/sdb3/LPA3399Pro/lpa3399pro-armbian/build/output/images/Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.18.33_server_2026.06.17.img`
- **参考文档**: `/mnt/sdb3/LPA3399Pro/LPA3399Pro_Auto_SD_Boot_Guide_20260614.md`
- **测试记录**: `/mnt/sdb3/LPA3399Pro/test_6.18.33_record.md`

---

## 技术参考

### RK3399 启动布局

| Sector | 偏移 | 大小 | 内容 |
|---|---|---|---|
| 0-63 | 0-32KB | 32 KB | MBR/GPT 分区表 |
| **64-460** | **32KB-230KB** | **198 KB** | **idbloader.img** |
| 16384 (0x4000) | 8MB | ~1 MB | u-boot.itb 或 u-boot.img |
| ... | ... | ... | ... |

### dd 命令技术细节

```bash
# 写入到指定 sector
dd if=源文件 of=/dev/sdX seek=起始sector conv=notrunc

# conv=notrunc 的作用
# - 默认 dd 会截断目标文件
# - notrunc 只修改指定位置，保留其他内容

# conv=fsync 的作用
# - 强制将缓存写入磁盘
# - 确保数据真正落盘
```

---

*操作时间: 2026-06-17 20:30*  
*操作者: Kiro*  
*验证状态: ✅ MD5 校验通过*
