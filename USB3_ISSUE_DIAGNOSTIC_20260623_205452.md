# USB3.0 设备无法识别问题诊断

**日期**: 2026-06-23 20:55 CST  
**板子**: LPA3399Pro  
**内核**: Linux 6.18.33 #8 SMP PREEMPT  
**网络**: SSH 192.168.50.113 正常，GMAC 稳定  

## 问题描述

用户在 USB3.0 接口插入设备后，`lsblk` 看不到，`lsusb` 也没有新设备。

## 测试过程

### 1. USB 控制器状态
- **Bus 001** (xHCI USB2): 480M ✓ 正常
- **Bus 002** (xHCI USB3): 5000M ✓ 正常
- **Bus 003/004** (EHCI USB2): 480M ✓ 正常
- **Bus 005/006** (OHCI USB1): 12M ✓ 正常

### 2. 实时监控测试（3次）
- 10秒监控：无插拔事件
- 20秒监控 + 倒计时：无插拔事件
- 30秒监控（xHCI重置后）：无插拔事件

### 3. xHCI unbind/bind 测试
- unbind 成功
- 首次 bind 失败：`Host halt failed, -110` (ETIMEDOUT)
- 第二次 bind 成功
- **暴露问题**: USB PHY Runtime PM 错误反复出现

### 4. 关键错误日志

```
[23667.841216] phy phy-ff770000.syscon:usb2phy@e450.8: Runtime PM usage count underflow!
[23667.842338] phy phy-ff770000.syscon:usb2phy@e450.8: Runtime PM usage count underflow!
[23669.851489] phy phy-ff770000.syscon:usb2phy@e450.8: Runtime PM usage count underflow!
[23669.901344] xhci-hcd xhci-hcd.0.auto: Host halt failed, -110
[23669.901880] xhci-hcd xhci-hcd.0.auto: can't setup: -110
[23669.904315] xhci-hcd xhci-hcd.0.auto: probe with driver xhci-hcd failed with error -110
```

启动时也有类似错误：
```
[    1.191444] phy phy-ff770000.syscon:usb2phy@e450.8: Runtime PM usage count underflow!
[    1.198676] phy phy-ff770000.syscon:usb2phy@e450.8: Runtime PM usage count underflow!
[    1.208062] phy phy-ff770000.syscon:usb2phy@e450.7: Runtime PM usage count underflow!
[    1.214538] phy phy-ff770000.syscon:usb2phy@e460.9: Runtime PM usage count underflow!
```

## 根本原因分析

### USB PHY Runtime PM 问题

RK3399 的 USB2 PHY 驱动 (`phy-rockchip-inno-usb2.c`) 在电源管理上有问题：
- `Runtime PM usage count underflow` 说明 `pm_runtime_put()` 比 `pm_runtime_get()` 多
- 这会导致 PHY 提前进入低功耗状态
- 可能影响 USB 接口供电或信号检测

### 可能原因

1. **设备本身问题**
   - 设备损坏
   - 设备功耗过大，板子供电不足
   - 设备不兼容（某些 USB3 设备对 PHY 时序敏感）

2. **物理接口问题**
   - USB3.0 物理接口故障
   - 接触不良
   - 未插在正确的 USB3 口

3. **驱动/DTB 问题**
   - USB PHY Runtime PM 错误导致供电异常
   - DTB 中 USB VBUS 供电 GPIO 未配置或错误
   - USB3 PHY 初始化时序问题

## 待确认信息

1. **设备信息**：品牌型号、类型、在其他设备上是否正常
2. **物理状态**：LED 是否亮、插在哪个口、是否插紧
3. **测试其他设备**：换其他 U盘或鼠标是否能识别

## 下一步建议

### A. 硬件排查
1. 尝试其他 USB 设备（U盘/鼠标/键盘）
2. 尝试插在 USB2.0 口（黑色）看是否识别
3. 检查 USB 设备是否有物理损坏

### B. 软件修复（如果是 PHY 问题）

#### 方案1：修复 DTB 中的 USB VBUS 供电配置

检查 vendor DTS 中是否有 `usb_host_vbus` regulator 配置缺失。

#### 方案2：修复 USB PHY Runtime PM

在内核中禁用 USB2 PHY 的 Runtime PM：

```c
// drivers/phy/rockchip/phy-rockchip-inno-usb2.c
// 在 probe 函数中添加：
pm_runtime_get_sync(dev);
pm_runtime_forbid(dev);  // 禁止自动suspend
```

#### 方案3：内核命令行禁用 USB autosuspend（已设置）

当前已设置：`usbcore.autosuspend=-1`

### C. 调试命令

```bash
# 检查 USB VBUS 供电 GPIO
grep -r "usb.*vbus\|vcc.*usb" /proc/device-tree/

# 检查 USB PHY 寄存器
cat /sys/kernel/debug/phy/phy-ff770000.syscon\:usb2phy@e450.8/*

# 强制 USB PHY 保持唤醒
echo on > /sys/devices/platform/ff770000.syscon/ff770000.syscon:usb2phy@e450/power/control
```

## 参考文档

- 原始诊断记录: `/mnt/sdb3/LPA3399Pro/6.18.33_GMAC_PATCH_COMPILE_VERIFY_20260618.md` (行5133-6000)
- Vendor DTS: `rk3399pro-neardi-linux-lc110-base.dts`
- USB PHY 驱动: `drivers/phy/rockchip/phy-rockchip-inno-usb2.c`
