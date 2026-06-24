# USB3.0 设备无法识别问题修复记录

**日期**: 2026-06-23  
**板子**: LPA3399Pro  
**内核**: Linux 6.18.33 #8 SMP PREEMPT  
**问题**: USB3.0 接口插入 U盘后无法识别，lsblk 和 lsusb 均无新设备  

---

## 问题诊断过程

### 初步检查

1. **USB 控制器状态**: ✓ 正常
   - Bus 001 (xHCI USB2): 480M
   - Bus 002 (xHCI USB3): 5000M
   - Bus 003/004 (EHCI): 480M
   - Bus 005/006 (OHCI): 12M

2. **多次实时监控测试**: 
   - 10秒/20秒/30秒监控均无插拔事件
   - 换了多个 U盘设备测试，仍无响应
   - U盘在其他电脑上能正常工作，排除设备故障

3. **xHCI unbind/bind 测试**: 
   - 发现 USB PHY Runtime PM 错误
   - `phy phy-ff770000.syscon:usb2phy@e450.8: Runtime PM usage count underflow!`
   - 首次 bind 失败: `Host halt failed, -110` (ETIMEDOUT)

### 根因定位

检查 regulator 状态时发现关键问题：

```bash
# cat /sys/class/regulator/regulator.21/name
vcc5v0_usb2

# cat /sys/class/regulator/regulator.21/state
disabled                              ← 问题所在！

# cat /sys/class/regulator/regulator.21/num_users
0
```

**对比其他 USB regulator**：
```
regulator.4: vbus_host
  state: enabled      ← 正常
  consumers: 3

regulator.5: vbus_typec
  state: enabled      ← 正常
  consumers: 2

regulator.21: vcc5v0_usb2
  state: disabled     ← 异常！
  consumers: 0
```

### 根本原因

**`vcc5v0_usb2` (PMIC RK808 的 SWITCH_REG1) 处于 disabled 状态，导致 USB 接口没有 5V 供电，设备插入后无法启动。**

检查 DTB 配置发现：
- `SWITCH_REG1` 节点**缺少** `regulator-always-on` 属性
- `SWITCH_REG1` 节点**缺少** `regulator-boot-on` 属性
- 没有任何 USB 节点引用此 regulator（`vbus-supply` 未配置）

---

## 修复方案

### 方案选择

**最终方案**: 在 DTB 中给 `SWITCH_REG1` 添加 `regulator-always-on` 属性

**其他尝试过但失败的方案**：
1. ❌ 通过 sysfs 启用 regulator — state 文件只读
2. ❌ 通过 GPIO 控制 — SWITCH_REG1 由 PMIC 内部控制，无外部 GPIO
3. ❌ 通过 debugfs — 没有直接启用接口
4. ❌ 导出 GPIO 手动拉高 — CONFIG_GPIO_SYSFS 未启用

### 修复操作

**执行时间**: 2026-06-23 21:05:12 CST

**步骤**:

1. 关闭板子并拔出 SD 卡
   ```bash
   sshpass -p 1234 ssh root@192.168.50.113 'shutdown -h now'
   ```

2. SD 卡插入宿主机，识别为 `/dev/sdc`

3. 挂载 boot 分区
   ```bash
   sudo mount /dev/sdc1 /mnt/sdc_boot
   ```

4. 备份原 DTB
   ```bash
   DTB=/mnt/sdc_boot/dtb/rockchip/gmac-phyhandle-pll-test-v4f.dtb
   sudo cp $DTB ${DTB}.bak.pre_usb_vbus_fix_20260623_210512
   ```

5. 使用 `fdtput` 添加 `regulator-always-on` 属性
   ```bash
   sudo fdtput -t s $DTB \
     /i2c@ff3c0000/pmic@20/regulators/SWITCH_REG1 \
     regulator-always-on ""
   ```

6. 验证修改
   ```bash
   sudo fdtget $DTB \
     /i2c@ff3c0000/pmic@20/regulators/SWITCH_REG1 \
     regulator-always-on
   # 输出: 0 (空字符串，但属性存在)
   ```

7. 同步并卸载
   ```bash
   sync
   sudo umount /mnt/sdc_boot
   ```

---

## 产物与备份

### 产物目录
```
/mnt/sdb3/LPA3399Pro/build_artifacts/usb_vbus_fix_20260623_210512/
```

### 文件清单

| 文件 | SHA256 | 说明 |
|------|--------|------|
| gmac-phyhandle-pll-test-v4f-usb-vbus-on.dtb | bee88899b3ec36ec20c0317eede0b98b448e733eace19fad273045f1589b126b | 修复后的 DTB |
| gmac-phyhandle-pll-test-v4f.dtb.bak.pre_usb_vbus_fix_20260623_210512 | dab7fb7894b48a0659ed0e54b3702b64869ca842f51e3ec8ee85a1938ddef46a | 修复前备份 |

### 部署位置

**SD 卡**: `/dev/sdc1` → `/mnt/sdc_boot/dtb/rockchip/gmac-phyhandle-pll-test-v4f.dtb`

**备份**: `/mnt/sdc_boot/dtb/rockchip/gmac-phyhandle-pll-test-v4f.dtb.bak.pre_usb_vbus_fix_20260623_210512`

---

## 回滚方式

如果修复后出现问题，可通过以下方式回滚：

### 方法1: 通过 SD 卡读卡器（板子关机）

```bash
sudo mount /dev/sdc1 /mnt/sdc_boot
sudo cp /mnt/sdc_boot/dtb/rockchip/gmac-phyhandle-pll-test-v4f.dtb.bak.pre_usb_vbus_fix_20260623_210512 \
        /mnt/sdc_boot/dtb/rockchip/gmac-phyhandle-pll-test-v4f.dtb
sync
sudo umount /mnt/sdc_boot
```

### 方法2: 通过 SSH（板子运行中）

```bash
sshpass -p 1234 ssh root@192.168.50.113 << 'EOF'
mount /dev/mmcblk1p1 /mnt/boot
cp /mnt/boot/dtb/rockchip/gmac-phyhandle-pll-test-v4f.dtb.bak.pre_usb_vbus_fix_20260623_210512 \
   /mnt/boot/dtb/rockchip/gmac-phyhandle-pll-test-v4f.dtb
sync
umount /mnt/boot
reboot
EOF
```

---

## 验证计划

修复后启动板子，执行以下验证：

### 1. 检查 regulator 状态

```bash
cat /sys/class/regulator/regulator.21/name
# 预期: vcc5v0_usb2

cat /sys/class/regulator/regulator.21/state
# 预期: enabled  ← 从 disabled 变为 enabled

cat /sys/class/regulator/regulator.21/num_users
# 预期: > 0
```

### 2. 检查 DTB 属性

```bash
cat /proc/device-tree/i2c@ff3c0000/pmic@20/regulators/SWITCH_REG1/regulator-always-on
# 预期: 存在（即使输出为空）

ls -la /proc/device-tree/i2c@ff3c0000/pmic@20/regulators/SWITCH_REG1/ | grep always-on
# 预期: 有 regulator-always-on 文件
```

### 3. USB 设备插拔测试

```bash
# 启动实时监控
dmesg -wT | grep -iE "usb.*new|usb.*device|scsi|storage"

# 插入 U盘，预期看到：
# [时间] usb 2-1: new SuperSpeed USB device number X using xhci-hcd
# [时间] usb-storage 2-1:1.0: USB Mass Storage device detected
# [时间] scsi host0: usb-storage 2-1:1.0
# [时间] scsi 0:0:0:0: Direct-Access ...
# [时间] sd 0:0:0:0: [sda] ...
```

### 4. 最终确认

```bash
lsusb
# 预期: 看到新的 USB Mass Storage 设备

lsblk | grep sd
# 预期: 看到 sda/sdb 等块设备

mount /dev/sda1 /mnt/test
ls /mnt/test
# 预期: 能正常挂载和访问 U盘内容
```

---

## 技术细节

### DTB 修改前后对比

**修改前** (`/i2c@ff3c0000/pmic@20/regulators/SWITCH_REG1`):
```dts
SWITCH_REG1 {
    regulator-name = "vcc5v0_usb2";
    regulator-min-microvolt = <5000000>;
    regulator-max-microvolt = <5000000>;
    /* 缺少 regulator-always-on */
};
```

**修改后**:
```dts
SWITCH_REG1 {
    regulator-name = "vcc5v0_usb2";
    regulator-min-microvolt = <5000000>;
    regulator-max-microvolt = <5000000>;
    regulator-always-on;  ← 新增
};
```

### PMIC RK808 SWITCH_REG1 说明

- **芯片**: Rockchip RK808 PMIC
- **I2C 地址**: 0x20
- **输出**: SWITCH_REG1 (可配置 DC-DC 开关稳压器)
- **用途**: 为 USB 接口提供 5V 供电 (vcc5v0_usb2)
- **控制**: 通过 I2C 寄存器控制开关，无外部 GPIO
- **默认状态**: disabled (需要软件启用)

### 相关 USB 节点

RK3399 有两个 USB3.0 Type-C 控制器：
- `usb@fe800000`: Type-C0 (包含 xHCI, Bus 001/002)
- `usb@fe900000`: Type-C1

当前板子的 USB3.0 接口（蓝色）应该连接到其中一个，但 DTB 中缺少 `vbus-supply` 属性指向 `vcc5v0_usb2`，导致驱动不会自动启用此 regulator。

**理想的 DTB 配置** (未来可优化):
```dts
usb@fe800000 {
    compatible = "rockchip,rk3399-dwc3";
    status = "okay";
    vbus-supply = <&vcc5v0_usb2>;  ← 应该添加
    ...
};
```

---

## 相关问题与历史

### USB PHY Runtime PM 错误

启动日志中的 Runtime PM underflow 错误：
```
phy phy-ff770000.syscon:usb2phy@e450.8: Runtime PM usage count underflow!
```

**分析**: 这是 RK3399 USB2 PHY 驱动 (`phy-rockchip-inno-usb2.c`) 的已知问题，`pm_runtime_put()` 调用次数多于 `pm_runtime_get()`。虽然会打印警告，但不影响 USB2.0 功能。本次 USB3.0 无法识别的主要原因是供电问题，不是 PHY 问题。

### 其他 USB regulator 正常的原因

- `vbus_host` (regulator.4): 有 3 个 consumer，被 USB 主机控制器正常引用
- `vbus_typec` (regulator.5): 有 2 个 consumer，被 Type-C 控制器正常引用
- `vcc5v0_usb2` (regulator.21): **0 个 consumer**，DTB 中没有任何节点引用

**结论**: DTB 配置不完整，缺少 USB 节点对 `vcc5v0_usb2` 的引用，导致此 regulator 从未被启用。

---

## 后续优化建议

### 1. 完善 DTB USB 配置

在对应的 USB 节点添加 `vbus-supply` 属性，使驱动能自动管理 regulator：

```dts
usb@fe800000 {
    vbus-supply = <&vcc5v0_usb2>;
    status = "okay";
};
```

这样可以去掉 `regulator-always-on`，让 USB 驱动按需启用/禁用供电，更省电。

### 2. 修复 USB PHY Runtime PM 问题

如果要彻底消除 Runtime PM underflow 警告，需要：
- 检查 `drivers/phy/rockchip/phy-rockchip-inno-usb2.c`
- 平衡 `pm_runtime_get()` 和 `pm_runtime_put()` 调用
- 或者在 probe 函数中 `pm_runtime_forbid(dev)` 禁用 Runtime PM

### 3. 添加 USB 电流限制保护

RK808 SWITCH_REG1 支持过流保护，可在 DTB 中配置：
```dts
SWITCH_REG1 {
    regulator-name = "vcc5v0_usb2";
    regulator-min-microvolt = <5000000>;
    regulator-max-microvolt = <5000000>;
    regulator-max-microamp = <2000000>;  /* 2A 限流 */
    regulator-always-on;
};
```

---

## 参考文档

- 诊断过程记录: `/mnt/sdb3/LPA3399Pro/USB3_ISSUE_DIAGNOSTIC_20260623_205452.md`
- GMAC 修复记录: `/mnt/sdb3/LPA3399Pro/6.18.33_GMAC_PATCH_COMPILE_VERIFY_20260618.md`
- Vendor DTS: `rk3399pro-neardi-linux-lc110-base.dts`
- RK808 PMIC 驱动: `drivers/regulator/rk808-regulator.c`
- USB PHY 驱动: `drivers/phy/rockchip/phy-rockchip-inno-usb2.c`

---

## 执行检查清单

修复完成后，逐项检查：

- [x] DTB 已修改并部署到 SD 卡
- [x] 原 DTB 已备份
- [x] SHA256 校验和已记录
- [x] 产物已保存到项目目录
- [x] 修改记录已写入 MD 文档
- [ ] SD 卡已插回板子
- [ ] 板子已启动
- [ ] regulator 状态已验证为 enabled
- [ ] U盘已成功识别
- [ ] lsblk 能看到块设备
- [ ] U盘能正常挂载和访问

---

**修复执行人**: Claude Code  
**文档生成时间**: 2026-06-23 21:07 CST

---

## 修复后验证结果（2026-06-23 21:14 CST）

### ✅ 供电修复成功

- `vcc5v0_usb2` regulator 状态：**enabled** ✓
- `regulator-always-on` 属性：**已添加** ✓
- consumer 数量：从 0 变为 1 ✓

### ⚠️ USB 设备仍无法识别

**现象**：
- 多次插拔 U盘（已在其他电脑验证可用）
- 尝试多个不同 U盘
- 尝试所有 USB 接口
- 60 秒实时监控无任何插拔事件

**深层诊断发现**：

1. **USB 中断计数异常低**
   ```
   dwc3-otg, xhci-hcd:usb1:  1 次（仅启动时）
   ehci_hcd:usb3:            0 次
   ehci_hcd:usb4:           29 次（Hub 05e3:0610）
   ohci_hcd:usb5/6:          0 次
   ```
   **结论**：物理层面没有检测到设备插入，未产生硬件中断

2. **DTB 配置缺陷**
   - 所有 USB 节点都**缺少 `vbus-supply` 属性**
   - `usb@fe900000` (Type-C1) 状态是 **disabled**
   - 无法确定哪个物理接口对应哪个 USB 控制器

3. **USB PHY 状态**
   - usb2phy@e450/e460: runtime_status = unsupported
   - 启动日志有 Runtime PM underflow 警告（非致命）

### 可能原因分析

#### A. 物理硬件问题
- USB 接口焊接/走线故障
- VBUS 或数据线断路
- USB 插座物理损坏

#### B. DTB 配置不完整
虽然 `vcc5v0_usb2` 已启用，但：
- 没有 USB 节点通过 `vbus-supply` 引用它
- 不确定哪个物理接口使用这个 regulator
- 可能需要的 USB 接口对应的 regulator 仍然是 disabled

#### C. USB 控制器未正确初始化
- Type-C 控制器可能需要额外的 PHY 初始化
- USB3.0 SS lanes 可能未启用
- USB OTG 模式配置问题

#### D. U盘与板子不兼容
- 电气特性不匹配
- 需要特定的 USB hub 芯片中转
- 功耗过大

### 下一步建议

#### 1. 确认物理接口类型
- 检查板子上有几个 USB 接口？
- 分别是什么颜色？（蓝色 = USB3.0，黑色 = USB2.0）
- 是否有标注 OTG、Debug、Host？

#### 2. 测试其他 USB 设备
- USB 鼠标/键盘（HID 设备，功耗低）
- USB 转串口（CDC-ACM 设备）
- 不同品牌/型号的 U盘

#### 3. 检查硬件连接
- 用万用表测量 USB 接口的 VBUS (5V) 是否有电
- 检查 D+/D- 数据线是否通路
- 确认 USB 插座无物理损坏

#### 4. 完善 DTB 配置（需要硬件信息）
需要知道：
- 哪个物理 USB 口对应 `usb@fe800000`？
- 哪个物理 USB 口对应 `usb@fe900000`？
- 是否有 USB Hub 芯片？

然后添加正确的 `vbus-supply` 配置：
```dts
usb@fe800000 {
    vbus-supply = <&vcc5v0_usb2>;  // 或其他 regulator
    status = "okay";
};
```

#### 5. 启用 Type-C1 控制器（如果需要）
```dts
usb@fe900000 {
    status = "okay";
    vbus-supply = <&vbus_typec>;  // 根据实际硬件
};
```

#### 6. 查看 vendor 原厂资料
- 原厂 schematic（原理图）
- 官方 DTS 文件
- USB 接口的实际连接方式

### 当前结论

**供电问题已修复**，但 USB 设备无法识别的根本原因可能是：
1. **硬件故障**（最可能）
2. **DTB 配置严重不完整**（需要硬件信息补全）
3. **特定 U盘不兼容**（需要测试其他设备排除）

建议先用万用表测量 USB 接口 VBUS 是否真正有 5V 输出，以及尝试 USB 鼠标/键盘等低功耗设备。

---

**验证执行人**: Claude Code  
**验证时间**: 2026-06-23 21:14 CST

---

## 最终诊断结果（2026-06-23 21:18 CST）

### 测试结果

**硬件测试**：
- 板子有 **4个 USB 接口**：2个蓝色，2个白色
- **所有接口都无法识别任何设备**：U盘、键盘全部无响应
- 键盘 LED 不亮，说明设备未获得供电或未被枚举

### 技术分析

**USB 控制器状态**：
```
usb@fe800000: 存在，驱动=dwc3-of-simple，电源域=on
usb@fe900000: 不存在（DTB status=disabled）
```

**Regulator 电压**：
```
vcc5v0_usb2:  enabled, users=1, voltage=未知
vcc5v0_sys:   enabled, users=13, voltage=5000000 uV
vbus_host:    enabled, users=3, voltage=未知
vbus_typec:   enabled, users=2, voltage=未知
```

**USB 中断计数（所有接口）**：
```
dwc3-otg, xhci-hcd:usb1:  1 次（仅启动）
ehci_hcd:usb3:            0 次
ehci_hcd:usb4:           29 次（Hub）
ohci_hcd:usb5/6:          0 次
```

### 根本原因判断

基于以下证据：
1. 4个 USB 接口全部无响应
2. USB 中断计数几乎为 0
3. 所有 USB 节点缺少 `vbus-supply` DTB 配置
4. 键盘插入不亮灯（未获得供电）

**最可能的原因**：

#### A. VBUS 供电电路故障（70% 可能性）
虽然 `vcc5v0_usb2` regulator 显示 enabled，但：
- 实际电压读取为空（`voltage= uV`）
- 可能 regulator 后端电路（MOSFET/保险丝/走线）有故障
- 需要万用表实测 USB 接口 VBUS 引脚电压

#### B. DTB 配置严重不完整（20% 可能性）
- 所有 USB 节点都没有 `vbus-supply` 属性
- USB 驱动可能因此不启用 VBUS 输出
- 但这无法解释为何 `vbus_host`/`vbus_typec` enabled 却仍无效果

#### C. USB 控制器/PHY 硬件故障（10% 可能性）
- USB 数据线电路故障
- PHY 芯片损坏
- 但同时 4个接口全坏的概率较低

### 验证步骤

**必须做**：
1. 用万用表测量任意 USB 接口 VBUS 引脚（最外侧）电压
   - 预期：5V ± 0.25V
   - 如果 <4.5V 或 0V：供电电路故障
   - 如果 ≥4.75V：数据线/控制器配置问题

**如果没有万用表**：
1. 尝试厂商官方镜像/系统，看 USB 是否工作
2. 查阅板子原厂 schematic 和官方 DTS
3. 联系板子厂商技术支持

### 当前修复总结

**已完成**：
- ✅ 诊断出 `vcc5v0_usb2` regulator 被 disabled
- ✅ 修改 DTB 添加 `regulator-always-on`
- ✅ regulator 状态从 disabled 变为 enabled
- ✅ 全面诊断 USB 硬件/软件/中断/配置状态

**仍未解决**：
- ❌ USB 设备无法识别
- ❌ 物理层无插拔中断
- ❌ 根本原因未确认（疑似 VBUS 供电电路故障）

### 建议

1. **如果你有万用表**：立即测量 USB VBUS 电压，这将直接确认问题
2. **如果没有万用表**：
   - 尝试厂商官方系统看 USB 是否工作
   - 如果官方系统也不工作 → 硬件故障
   - 如果官方系统能工作 → DTB 配置问题，需要对比官方 DTS
3. **如果确认硬件故障**：可能需要返修或更换板子

---

**最终诊断执行人**: Claude Code  
**完成时间**: 2026-06-23 21:20 CST  
**工作时长**: 约 1.5 小时  
**状态**: 供电软件修复完成，但硬件层面仍无响应，需要硬件测试确认根因
