# LPA3399Pro Armbian 迭代排障记录 (2026-06-13 续)

> 本文件是 `LPA3399Pro_Armbian_Adaptation_Record_20260613.md` 的续篇，记录 Plan E 基础上的多轮迭代调试。

## 基础镜像

```
Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.1.141_server_2026.06.11_hybrid_sdkboot.img
```

内核: `6.1.141-rk35xx-ophub` (aarch64)  
DTB: `rk3399pro-neardi-linux-lc110-base.dtb`  
Boot: extlinux (U-Boot 2017.09 distro boot)

---

## 迭代 1: Plan E 完整实施

**日期**: 2026-06-13 ~19:00

### 修改内容

#### DTB 修改 (4 处):
1. **WiFi SDIO (fe310000)**: `status = "okay"` (从 "disabled" 恢复，保持 PMIC 时钟链)
2. **SD 卡 (fe320000)**: `max-frequency = <0x2faf080>` (50MHz，从 25MHz 恢复)
3. **看门狗 (ff848000)**: `status = "disabled"` (新增，防止 19.5s 硬重启)
4. **蓝牙 (wireless-bluetooth)**: `status = "okay"` (从 "disabled" 恢复)

#### extlinux.conf 修改:
```
APPEND ... modprobe.blacklist=rfkill_rk,rfkill_wlan,bcmdhd,rtl8821cs,hci_uart watchdog.handle_boot_enabled=0
```

### 启动结果

- **看门狗问题**: **已解决** — 日志成功超过 19.5 秒
- **BT/WLAN rfkill**: 仍然加载（驱动为 built-in，modprobe.blacklist 对 built-in 无效）
- **BT/WLAN 初始化**: 这次没有导致死机，完整完成了 `rfkill_wlan_probe` 和 `bt_default device registered`
- **所有存储设备识别成功**:
  - mmc0: WiFi SDIO (50MHz High Speed)
  - mmc1: eMMC DF4016 14.7 GiB (HS400)
  - mmc2: SD 卡 SD16G 14.4 GiB
- **死锁点**: `[19.472s]` — `rockchip-drm display-subsystem: bound ff900000.vop` 后彻底沉默
- **死锁性质**: 硬死锁（非重启、非 panic），TTL 完全无后续输出

### TTL 日志: `ttl_sd_hybrid_retry_202606132006.log`

---

## 迭代 2: 添加 panic=5 loglevel=8

**日期**: 2026-06-13 ~20:30

### 修改内容

在 extlinux.conf APPEND 行末尾追加:
```
panic=5 loglevel=8
```

- `panic=5`: 内核 panic 后 5 秒自动重启，避免静默死锁
- `loglevel=8`: 输出所有 debug 级别日志

### 启动结果

- 死锁点: `[19.537s]` — 比上次多了 2 行输出:
  ```
  [19.535404] dwhdmi-rockchip ff940000.hdmi: Detected HDMI TX controller v2.11a with HDCP (DWC HDMI 2.0 TX PHY)
  [19.537402] vendor storage:20190527 ret = 0
  ```
- 然后彻底沉默
- **无 panic 输出** → 确认为中断被禁用的硬死锁（非 kernel panic），`panic=5` 无法触发
- **关键线索**: `gpu-thermal` 在 10.6s 已报错 `Failed to register thermal zone gpu-thermal: -22`

### TTL 日志: `ttl_sd_panic5_loglevel8_202606132038.log`

---

## 迭代 3: 禁用 GPU (Mali-T860) + drm-logo

**日期**: 2026-06-13 ~20:45

### 修改内容

DTB 新增禁用:
1. **gpu@ff9a0000** (Mali-T860 Midgard): `status = "disabled"`
   - 依据: `gpu-thermal` 注册失败 (-22)，GPU 驱动可能引发死锁
2. **drm-logo@00000000**: `status = "disabled"`
   - 依据: `reg = <0x00 0x00 0x00 0x00>` 地址/大小均为 0，启动时报 reserved memory 失败

### 启动结果

- 死锁点: `[17.667s]` — `rockchip-drm display-subsystem: bound ff900000.vop` 后沉默
- **HDMI 探测行消失**: 上次能看到的 `dwhdmi-rockchip ff940000.hdmi: Detected` 这次没有出现
- 禁用 GPU 改变了探测顺序，但未解决死锁
- **结论**: 问题在 DRM 显示子系统的更深层，不仅仅是 GPU

### TTL 日志: 通过串口实时捕获 (未单独保存文件)

---

## 迭代 4: 禁用 display-subsystem (当前进行中)

**日期**: 2026-06-13 ~20:55

### 修改内容

DTB 新增禁用:
1. **display-subsystem**: `status = "disabled"`
   - 这是 DRM 的总入口节点，禁用后将阻止整个显示驱动链:
     - VOP (ff8f0000 vop-lit, ff900000 vop-big)
     - HDMI (ff940000)
     - DRM framebuffer/console

### 预期结果

- 跳过 VOP/HDMI 死锁点
- 系统无 HDMI 显示输出（预期行为）
- 应能通过串口看到完整的内核启动到登录提示符
- **后续**: 如果启动成功，逐步恢复 VOP/HDMI 以精确定位死锁组件

### 状态: 待烧录测试

---

## 当前 DTB 完整修改清单 (累计)

| 节点 | 修改 | 目的 |
|------|------|------|
| `chosen` | 删除 `bootargs` | 让 extlinux.conf 控制内核参数 |
| `dwmmc@fe310000` (WiFi SDIO) | `status = "okay"` | 保持 PMIC 时钟链 |
| `dwmmc@fe320000` (SD 卡) | `max-frequency = 50MHz` | 从 25MHz 恢复 |
| `watchdog@ff848000` | `status = "disabled"` | 防止 19.5s 硬重启 |
| `wireless-bluetooth` | `status = "okay"` | 保持 PMIC 时钟链 |
| `gpu@ff9a0000` (Mali-T860) | `status = "disabled"` | 排除 GPU 驱动死锁 |
| `drm-logo@00000000` | `status = "disabled"` | 排除 broken reserved memory |
| `display-subsystem` | `status = "disabled"` | 排除整个 DRM 显示链死锁 |

## 当前 extlinux.conf APPEND 参数 (累计)

```
root=UUID=d9159ff7-f834-4aba-a518-ac5f1dfc7175
rootflags=data=writeback
rw rootwait rootfstype=ext4
console=ttyS2,1500000 console=tty1
no_console_suspend consoleblank=0
fsck.fix=yes fsck.repair=yes
net.ifnames=0 max_loop=128
video=HDMI-A-1:1920x1080@60e
plymouth.enable=0
modprobe.blacklist=rfkill_rk,rfkill_wlan,bcmdhd,rtl8821cs,hci_uart
watchdog.handle_boot_enabled=0
panic=5 loglevel=8
```

---

## 关键发现总结

1. **看门狗硬重启已解决**: DTB 禁用 + 内核参数双重防护
2. **BT/WLAN rfkill 是 built-in 驱动**: `modprobe.blacklist` 无效，但启用 BT/WLAN 节点后不再触发启动死锁
3. **19.5s 死锁是 DRM 显示子系统导致**: VOP/HDMI 驱动探测阶段发生硬死锁，不是 kernel panic
4. **GPU (Mali-T860) 有 thermal 兼容问题**: `gpu-thermal` zone 注册失败，但禁用 GPU 单独不能解决死锁
5. **死锁性质**: 中断被禁用的硬死锁，`panic=5` 无法触发重启，TTL 完全沉默

---

---

## 修改建议与迭代 5 准备（2026-06-13 ~22:00）

> 本节为对前 4 轮迭代的复盘与下一步建议，并已生成内置全部建议的预编译镜像。

### 关键判断：前 4 轮迭代的核心症结

死锁点稳定落在 **DRM 显示子系统探测阶段**（`rockchip-drm display-subsystem: bound ff900000.vop` 之后），且：
- `panic=5 loglevel=8` 没有触发任何 panic 输出 → 中断被禁用的硬死锁，不是 kernel panic
- 单独禁用 GPU / drm-logo 都没解决 → 死锁点在 VOP/HDMI 子树更深位置
- 死锁时间漂移（19.472s → 19.537s → 17.667s）说明每次 DTB 微调都会扰动 IRQ 时序

### 五条具体修改建议

#### A. 烧录前追加 APPEND 调试参数（A1）

成本几乎为零，但能让"死锁前最后一个完成的 initcall"显形。一次烧录就能拿到两个答案（display-subsystem 是否为元凶 + 死锁点精确指针）：

```
initcall_debug earlycon=uart8250,mmio32,0xff1a0000,1500000n8 printk.devkmsg=on
```

- `initcall_debug`：逐个打印 init 函数进出，**最后一个完成的 initcall** 就是死锁点的精确指针
- `earlycon`：UART2 (0xff1a0000) 早期控制台，比 ttyS2 早打通
- `printk.devkmsg=on`：避免 printk 在 IRQ-disabled 阶段被静默

#### A. 收紧 APPEND 中的显示/控制台参数（A2）

当前 APPEND 中的两项在死锁未定位前属于"催命参数"，建议改掉：

| 原值 | 改为 | 理由 |
|---|---|---|
| `video=HDMI-A-1:1920x1080@60e` | 删除整段 | 尾字符 `e` = force-enable，强制 DRM 走 attach 路径 |
| `console=ttyS2,1500000 console=tty1` | `console=ttyS2,1500000` | tty1 依赖 DRM fbdev，DRM 未起时探测 tty1 可能阻塞控制台切换 |

#### B. 迭代 4 之后的精准定位路径

display 路径上当前 `status="okay"` 的节点（按 6.1 主线死锁嫌疑度排序）：

| 节点 | 嫌疑度 | 原因 |
|---|---|---|
| `hdmi@ff940000` + `dwhdmi-rockchip` | **极高** | 死锁前最后一行就是 `Detected HDMI TX controller v2.11a`，HDMI PHY 初始化在 6.1 主线 + Rockchip vendor phy 上是常见死点 |
| `vopb_mmu` / `vopl_mmu` (IOMMU) | **高** | 6.1 主线里 RK3399 IOMMU 与 VOP 集成时常因 dma-ranges / iommu-group 死锁 |
| `vpu` (VPU codec) | **中** | 当前是 okay，离 display 路径近 |
| `vopb` / `vopl` 本体 | 低 | 单独禁用本体但保留 MMU 通常无效 |

二分顺序（每次只动一个变量）：
- 若迭代 4 成功（display-subsystem 整禁可启动）→ 把 `display-subsystem` 恢复 okay，**只禁用 `hdmi` + `route_hdmi`** → 若仍能启动 = HDMI 子树是元凶；若死锁回归 = 转 VOP/IOMMU 路径，下一步禁 `vopb_mmu`/`vopl_mmu`
- 若迭代 4 仍死锁 → display-subsystem 不是元凶，怀疑点转向 `gpu-thermal` / `npu` / `fiq-debugger` / BL31 SIP

#### C. `gpu-thermal -22` 的连带处理

`Failed to register thermal zone gpu-thermal: -22` (`-22 = EINVAL`)，禁用 GPU 节点只让 GPU 驱动不绑定，但 `gpu-thermal` zone 仍会尝试注册并失败。若禁了 display-subsystem 还死锁，下一步同时把 `thermal-zones` 中的 `gpu-thermal` 整段删掉（或 status="disabled"）。

#### D. 文档与流程改进

1. **累计修改清单加一列"对应死锁时间"**，便于看 IRQ 时序漂移：

   | 迭代 | 死锁时间 | 最后输出 |
   |---|---|---|
   | 1 | 19.472s | `bound ff900000.vop` |
   | 2 | 19.537s | `vendor storage:20190527 ret = 0` |
   | 3 | 17.667s | `bound ff900000.vop`（HDMI 行消失）|
   | 4 | 待测 | 待测 |

2. **每次保留 DTB 副本**：现有 `*.dtb.PlanC/D` 命名混乱（PlanD 副本实际是早期 25MHz 方案，非迭代日志状态）。后续以 `*.dtb.iter<N>` 命名更清晰。
3. **TTL 命名固定**：`ttl_iter<N>_<short-desc>_<YYYYMMDDHHMM>.log`，避免迭代 3 那种"未单独保存"的遗憾。
4. **写 status 切换脚本**：`./toggle-dtb-node.sh hdmi disabled` 自动完成 `dtc 反编译 → sed → dtc 重编译`，迭代 4 次后回报显著。

---

### 已落实：迭代 5 预编译镜像

为省去 SD 卡上手工修改的反复，已生成内置全部建议的预编译镜像。

**文件**：
```
/mnt/sdb3/LPA3399Pro/lpa3399pro-armbian/build/output/images/
  Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.1.141_server_2026.06.11_iter5.img
  Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.1.141_server_2026.06.11_iter5.img.sha256
```

- 大小：3,699,376,128 字节（3.44 GiB）
- sha256：`dfdf93db47d21b4395735032a3bec8ea97afdcc2182bdb373fc280afe241ad16`
- 基础：`Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.1.141_server_2026.06.11.img`（副本，原镜像未改动）

**DTB 修改（5 处，从早期 dtb 起点叠加，非 PlanD 副本）**：

| # | 节点路径 | 属性 | 值 | 来源迭代 |
|---|---|---|---|---|
| 1 | `/dwmmc@fe320000` | `max-frequency` | `0x2faf080` (50MHz) | 迭代 1 |
| 2 | `/watchdog@ff848000` | `status` | `disabled` | 迭代 1 |
| 3 | `/gpu@ff9a0000` | `status` | `disabled` | 迭代 3 |
| 4 | `/reserved-memory/drm-logo@00000000` | `status` | `disabled` | 迭代 3 |
| 5 | `/display-subsystem` | `status` | `disabled` | 迭代 4 |

注：`dwmmc@fe310000` (WiFi SDIO) 和 `wireless-bluetooth` 原本已是 `okay`，无需修改（符合迭代 1 "保持 PMIC 时钟链"目标）。`dtb/` 和 `dtb-6.1.141-rk35xx-ophub/` 在镜像内是 hard link，一次修改两边都生效。

**启动配置修改（双路径防御）**：

镜像内 `extlinux/extlinux.conf.bak` 已改回 `extlinux.conf`（让 U-Boot distro_bootcmd 走 extlinux），同时 `armbianEnv.txt` 也更新（万一 boot.scr 仍执行也带正确参数）：

```
# extlinux.conf APPEND 行（已删除 video= 和 console=tty1，按 A2）
APPEND root=UUID=... rootflags=data=writeback rw rootwait rootfstype=ext4
       console=ttyS2,1500000 no_console_suspend consoleblank=0
       fsck.fix=yes fsck.repair=yes net.ifnames=0 max_loop=128
       plymouth.enable=0
       modprobe.blacklist=rfkill_rk,rfkill_wlan,bcmdhd,rtl8821cs,hci_uart
       watchdog.handle_boot_enabled=0
       panic=5 loglevel=8
       initcall_debug earlycon=uart8250,mmio32,0xff1a0000,1500000n8 printk.devkmsg=on
```

### 烧录与测试指引

```bash
# 1. 烧录
sudo dd if=Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.1.141_server_2026.06.11_iter5.img \
        of=/dev/sdX bs=4M status=progress oflag=direct
sync

# 2. 上电，串口以 1500000 8N1 抓取 TTL，保存为：
#    logs/ttl_iter5_dispsub_disabled_initdbg_<YYYYMMDDHHMM>.log

# 3. 关注点：
#    a. 是否能进入 login prompt（验证 display-subsystem 是否元凶）
#    b. 若仍死锁：grep "initcall" 最后 5 行，最后一个完成的 initcall 即死锁点指针
#    c. 若进入系统：依次恢复 hdmi / vop_mmu 验证（按 B 节路径）
```

### 期望结果与下一步

| 迭代 5 实际结果 | 结论 | 下一步 |
|---|---|---|
| 进入 login prompt | display-subsystem 是元凶 | 按 B 节二分路径，先恢复 hdmi 测试 |
| 仍死锁，最后一行在 display 路径 | DRM 内更深层死锁 | 看 initcall_debug 输出定位 |
| 仍死锁，最后一行不在 display 路径 | display-subsystem 是误判 | 按 C 节同时禁用 gpu-thermal，转向 npu/fiq-debugger/BL31 排查 |

---

## 迭代 5 修正 → 迭代 6（2026-06-14 ~11:30）

### 关键发现：iter5.img 用错基础镜像

iter5.img 烧录到 SD 卡后，板子仍然从 eMMC 启动 Linux 4.4.194。TTL 抓取（`ttl_sd_hybrid_retry_202606141055.log`）显示 Boot1 直接走 eMMC，根本没尝试加载 SD 的 U-Boot。

**根因**：iter5.img 是以 `Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.1.141_server_2026.06.11.img`（ophub 默认基础）为底做的，**idbloader 是 ophub 默认生成的版本，RK3399 BootROM 不识别**。

通过对比 sector 64 起 8192 字节的 sha256 确认：

| 镜像 | idbloader sha256 | BootROM 识别 |
|---|---|---|
| iter5.img / ophub 默认 | `ff649142877ffafb1204d48d8b857e45325b36920cd1136cdec23e2ece7b6311` | ❌ |
| hybrid_sdkboot.img | `ad8bf9e0a0a9e205cde77d623da8a323f615b9330c871a47c964308722d238cc` | ✅ |

**结论**：DTB 修改本身没问题（5 处都在），但被错误的 idbloader 掩盖了——根本到不了 U-Boot 阶段。

### 迭代 6：基于 hybrid_sdkboot 重建

**基础镜像**：`Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.1.141_server_2026.06.11_hybrid_sdkboot.img`（SDK 修复版 idbloader，BootROM 可识别）

**DTB 修改**：验证 hybrid_sdkboot 的 DTB 已经包含迭代 5 的 5 处修改（display-subsystem/gpu/watchdog/drm-logo disabled，SD max-frequency=50000000），无需重复操作。

**extlinux.conf 修改**（在 iter1-3 基础上）：
- 删除 `video=HDMI-A-1:1920x1080@60e`（A2，force-enable 标志会强制 DRM 走 attach 路径）
- 删除 `console=tty1`（A2，依赖 DRM fbdev，DRM 未起时可能阻塞控制台切换）
- 追加 `initcall_debug earlycon=uart8250,mmio32,0xff1a0000,1500000n8 printk.devkmsg=on`（A1，死锁前最后一个完成的 initcall 即精确指针）

**armbianEnv.txt 同步**：`extraargs` 删 video=、加 A1 调试三参数；`extraboardargs` 加入 modprobe.blacklist 列表（万一 boot.scr 路径生效也有保险）。

**输出镜像**：
```
/mnt/sdb3/LPA3399Pro/lpa3399pro-armbian/build/output/images/
  Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.1.141_server_2026.06.11_iter6.img
  Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.1.141_server_2026.06.11_iter6.img.sha256
```
- 大小：3,699,376,128 字节（与 hybrid_sdkboot 一致，base 完整保留）
- sha256：`2ba82f4df110088d6975798b1e99d012f6b2aab6fbdcf0e0af0ea0cb859f46c4`

### 启动预期

| 阶段 | 期望输出 |
|---|---|
| BootROM | 找到 SD idbloader → 加载 SD sector 0x4000 的 U-Boot（**关键变化**） |
| U-Boot | SD 上的 U-Boot 2017.09，distro_bootcmd 走 extlinux |
| Kernel | `Linux version 6.1.141-rk35xx-ophub` |
| bootargs | 包含 `initcall_debug earlycon=... printk.devkmsg=on` |
| initcall | 大量 `initcall ... returned 0 after ... usecs` 行 |

### 死锁诊断矩阵

启动后根据 TTL 输出对照：

| 实际结果 | 结论 | 下一步 |
|---|---|---|
| 进入 login prompt | display-subsystem 禁用生效 → DRM 是元凶 | 按 B 节二分：先恢复 hdmi 测试 |
| 仍死锁，最后输出在 display 路径 | DRM 内更深层死锁 | grep `initcall` 看最后完成的 initcall |
| 仍死锁，最后输出不在 display 路径 | display-subsystem 是误判 | 按 C 节同时禁 gpu-thermal，转向 npu/fiq-debugger |

### 相关文档

- SD 启动方案（含 saveenv 防御性备份）：`LPA3399Pro_Auto_SD_Boot_Guide_20260614.md`
- TTL 抓取脚本：`/tmp/ttl_capture_robust.py`（捕获 BlockingIOError 的稳健版）

---

*记录工具: Qoder CLI*  
*日期: 2026-06-13 → 2026-06-14*
