# LPA3399Pro 自动从 SD 卡启动配置指南

> 日期: 2026-06-14
> 适用场景: LPA3399Pro + Armbian iter6 (SD 卡) + eMMC 原厂系统共存时，自动从 SD 启动

---

## 0. 修订记录（2026-06-14 上午）

**关键修正**：早期版本（§1.1）误判 BootROM 永远优先 eMMC。验证 hybrid_sdkboot.img / iter6.img 的 idbloader 哈希后，确认：

| 镜像 | idbloader hash（sector 64, 8192B）| BootROM 识别？ | 结果 |
|---|---|---|---|
| iter5.img（ophub 默认基础） | `ff649142877f...` | ❌ | BootROM 跳过 SD → 走 eMMC |
| hybrid_sdkboot.img / **iter6.img** | `ad8bf9e0a0a9...`（SDK 修复版） | ✅ | BootROM 直接走 SD |

**结论**：用 iter6.img（基于 hybrid_sdkboot）时，**BootROM 会直接加载 SD 的 U-Boot**，根本不经过 eMMC U-Boot，**无需 saveenv**。

**saveenv 方案的角色**：从"必需"降级为"防御性备份"——
- **主路径**：SD 卡 idbloader 正常 → BootROM 直接启动 SD
- **回退路径**：SD 卡 idbloader 损坏 / 用户拔卡 / 想强制每次都从 SD 启动（即便 SD 损坏也不走 eMMC） → 此时才需要 saveenv

后续章节保留 saveenv 的完整操作流程作为参考。

---

## 1. 背景

### 1.1 当前启动行为（取决于 SD 卡 idbloader 是否被 BootROM 接受）

**情况 A — SD 卡用 ophub 默认 idbloader（如 iter5.img）**：

通过 TTL 抓取（`ttl_sd_hybrid_retry_202606141055.log`）确认：

```
BootROM → Boot1 v1.26 → 同时检测到 SD 卡(15GB) 和 eMMC(14.7GB)
                          ↓
                  从 eMMC 的 GPT 找到 uboot 分区
                          ↓
                  从 eMMC sector 0x4000 加载 U-Boot
                          ↓
                  U-Boot 2017.09 (vendor) → 加载 eMMC 内核
                          ↓
                  Linux 4.4.194 (eMMC 原厂系统)
```

**根本原因**：iter5.img 的 idbloader 是 ophub 默认生成的（hash `ff649142...`），RK3399 BootROM 无法识别其 rksd 结构头，遂跳过 SD 走 eMMC。**这并非 BootROM 优先级问题，而是 SD idbloader 兼容性问题**。

**情况 B — SD 卡用 SDK 修复版 idbloader（如 hybrid_sdkboot.img / iter6.img）**：

```
BootROM → 检测 SD 卡 idbloader（hash ad8bf9e0..., SDK 修复版）
                          ↓
                  校验通过，加载 SD sector 0x4000 的 U-Boot
                          ↓
                  SD 的 U-Boot 2017.09 → 加载 Armbian 内核
                          ↓
                  Linux 6.1.141 (Armbian trixie)
```

**关键差别**：idbloader 的来源决定了启动路径。SDK `make.sh --idblock` 生成的 idblock.bin 包含正确的 rksd 头和 DDR init，能被 BootROM 直接识别。

### 1.2 解决思路

根据 SD 卡 idbloader 是否被 BootROM 接受，分两条路径：

**路径 1（推荐，零侵入）**：使用 iter6.img（hybrid_sdkboot + 全部 iter5 修改 + A1 调试参数）
- BootROM 直接识别 SD → 加载 SD U-Boot → 启动 Armbian
- eMMC 完全不动，拔卡即回原厂系统
- **无需本文档后续的 saveenv 操作**

**路径 2（防御性备份）**：在路径 1 之上叠加 saveenv 配置
- 让 eMMC 的 U-Boot 在 SD 损坏时也能从 SD 加载内核
- 适合"绝对不允许启动 eMMC 原厂系统"的场景（比如生产部署）
- 见 §3

这两条路径可单独使用，也可叠加。路径 1 是默认推荐。

---

## 2. 方案对比

| 方案 | 持久性 | 可恢复性 | 风险 | 推荐度 |
|---|---|---|---|---|
| **A. U-Boot `saveenv`** | 永久（写 eMMC env 分区） | 易恢复 | 低 | ⭐⭐⭐⭐⭐ |
| B. 擦除 eMMC idbloader | 永久（破坏 eMMC 启动） | 需重烧 eMMC | 中 | ⭐⭐⭐ |
| C. 每次手动 U-Boot 命令 | 临时 | 无需恢复 | 无 | ⭐⭐ |
| D. 改 OTP BOOT_ORDER | 永久不可逆 | 不可恢复 | 极高 | ❌ |

**首选方案 A**：一次配置，永久生效，eMMC 完全无损，故障可一键恢复。

---

## 3. 方案 A：U-Boot `saveenv` 持久化（推荐）

### 3.1 前置条件

- eMMC 上有可启动的 vendor U-Boot（当前已确认）
- SD 卡上烧录了 Armbian iter5（已确认字节级正确）
- TTL 串口连接正常（CP2102，1500000 8N1）
- TTL 终端软件支持发送 `Ctrl+C`（minicom/screen/picocom 都行）

### 3.2 操作步骤

#### 第 1 步：上电并中断 U-Boot autoboot

```bash
# 在 TTL 终端窗口（1500000 8N1）：
# 1. 给板子上电
# 2. 看到下面这行时立刻按 Ctrl+C（多次重复按保险）：
#    Hit key to stop autoboot('CTRL+C'):  0
# 3. 出现 => 提示符表示成功进入 U-Boot 命令行
=>
```

#### 第 2 步：验证 SD 卡可读

```
=> mmc dev 1
=> mmc rescan
=> ls mmc 1:1 /
```

预期看到（确认 SD 卡 boot 分区可读）：
```
extlinux/
Image
dtb/
initrd.img-6.1.141-rk35xx-ophub
uInitrd
armbianEnv.txt
boot.scr
...
```

如果 `ls mmc 1:1` 报错 → SD 卡座接触不良或 SD 卡未插紧，重插后再试。

#### 第 3 步：设置 `sd_boot` 命令脚本

把完整的 SD 启动逻辑封装为一个环境变量。**整段一次性粘贴**：

```
setenv sd_boot 'mmc dev 1; mmc rescan; load mmc 1:1 0x00280000 /Image; load mmc 1:1 0x0a200000 /uInitrd; load mmc 1:1 0x08300000 /dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb; setenv bootargs "root=UUID=d9159ff7-f834-4aba-a518-ac5f1dfc7175 rootflags=data=writeback rw rootwait rootfstype=ext4 console=ttyS2,1500000 no_console_suspend consoleblank=0 fsck.fix=yes fsck.repair=yes net.ifnames=0 max_loop=128 plymouth.enable=0 modprobe.blacklist=rfkill_rk,rfkill_wlan,bcmdhd,rtl8821cs,hci_uart watchdog.handle_boot_enabled=0 panic=5 loglevel=8 initcall_debug earlycon=uart8250,mmio32,0xff1a0000,1500000n8 printk.devkmsg=on"; booti 0x00280000 0x0a200000 0x08300000'
```

地址说明：
- `0x00280000` — kernel 加载地址（vendor U-Boot 默认）
- `0x0a200000` — initrd 加载地址
- `0x08300000` — FDT 加载地址

#### 第 4 步：保存原 bootcmd 作为 fallback（推荐）

```
setenv emmc_boot ${bootcmd}
setenv bootcmd 'if test "${sd_force}" = "no"; then run emmc_boot; else run sd_boot; fi'
setenv sd_force yes
saveenv
```

逻辑：
- `sd_force=yes`（默认）→ 走 SD 启动
- `sd_force=no` → 走原 eMMC 启动（应急用）
- `saveenv` 持久化到 eMMC env 分区

#### 第 5 步：重启验证

```
=> reset
```

板子重启后，应该看到：
- DDR init → Boot1 → U-Boot（这些都从 eMMC 走，不变）
- U-Boot 启动后**自动执行 SD 启动脚本**
- 加载 Armbian 6.1.141 内核
- 进入 Armbian 系统

### 3.3 验证清单

启动成功后，在 TTL 看到：

| 检查项 | 期望输出 |
|---|---|
| 内核版本 | `Linux version 6.1.141-rk35xx-ophub` |
| 发行版 | `Armbian` / `Debian GNU/Linux 13 (trixie)` |
| bootargs | 包含 `initcall_debug`、`modprobe.blacklist=...` |
| initcall | 大量 `initcall ... returned 0 after ... usecs` |
| WiFi 驱动 | 不应加载（8821cs 已 blacklist） |

### 3.4 故障恢复

#### 情况 1：开机完全无响应

按 Ctrl+C 中断 U-Boot，执行：
```
=> env default -a
=> saveenv
=> reset
```
恢复出厂 U-Boot 环境，回到默认从 eMMC 启动。

#### 情况 2：U-Boot 命令行进不去

可能 bootcmd 配置错误导致 U-Boot 卡死。解决：
- 物理拔掉 SD 卡
- 上电 → U-Boot 的 `sd_boot` 会因 `mmc dev 1` 失败而中断
- 进入 `=>` 后执行 `env default -a; saveenv; reset`

#### 情况 3：想临时切回 eMMC 启动（不擦 env）

```
=> setenv sd_force no
=> reset
```
本次启动走 eMMC。下次想回 SD：`setenv sd_force yes; saveenv; reset`。

---

## 4. 方案 B：擦除 eMMC idbloader（永久）

### 4.1 适用场景

- 方案 A 不奏效（saveenv 失败）
- 希望彻底绕过 Boot1 从 eMMC 加载的过程
- 让 BootROM 直接走 SD 启动

### 4.2 操作步骤

启动到 eMMC 原厂系统后，在 root shell 执行：

```bash
# 1. 备份 eMMC 前 4MB（保险）
dd if=/dev/mmcblk0 of=/tmp/emmc_head_backup.bin bs=512 count=8192

# 2. 把备份拷到 U 盘或网络（千万别存在 eMMC 上）
scp /tmp/emmc_head_backup.bin user@<host>:/path/

# 3. 抹除 eMMC 前 4MB（idbloader + GPT + uboot 分区头）
dd if=/dev/zero of=/dev/mmcblk0 bs=512 count=8192
sync

# 4. 关机
poweroff
```

下次开机：
- BootROM 在 eMMC sector 64 找不到有效 idbloader → 跳过 eMMC
- BootROM 转 SDMMC1 (SD 卡) → 找到 SD idbloader → 加载 SD 的 U-Boot → 启动 Armbian

### 4.3 风险与恢复

**风险**：
- eMMC 永久不能启动（这是目标，但意味着以后只能用 SD）
- 如果 SD 卡启动失败，板子变砖（除非有 maskrom 救砖）

**恢复**（重新让 eMMC 可启动）：
- 短路 maskrom 引脚 + 上电
- 用 `rkdeveloptool` 或 `upgrade_tool` 通过 USB 把备份的 `emmc_head_backup.bin` 写回 eMMC sector 0
- 命令：`rkdeveloptool db MiniLoaderAll.bin && rkdeveloptool wl 0 emmc_head_backup.bin`

### 4.4 不推荐的理由

- 一旦操作失误，恢复需要 maskrom + USB 工具
- 方案 A 已经能实现相同效果，且完全可逆

---

## 5. 方案 C：每次手动 U-Boot 命令（应急）

不持久化，每次开机都手动操作。适合方案 A 配置前的第一次验证。

### 5.1 步骤

```
# 1. 上电，Ctrl+C 中断 autoboot
=> mmc dev 1
=> mmc rescan
=> load mmc 1:1 0x00280000 /Image
=> load mmc 1:1 0x0a200000 /uInitrd
=> load mmc 1:1 0x08300000 /dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb
=> setenv bootargs "root=UUID=d9159ff7-f834-4aba-a518-ac5f1dfc7175 rootflags=data=writeback rw rootwait rootfstype=ext4 console=ttyS2,1500000 no_console_suspend consoleblank=0 fsck.fix=yes fsck.repair=yes net.ifnames=0 max_loop=128 plymouth.enable=0 modprobe.blacklist=rfkill_rk,rfkill_wlan,bcmdhd,rtl8821cs,hci_uart watchdog.handle_boot_enabled=0 panic=5 loglevel=8 initcall_debug earlycon=uart8250,mmio32,0xff1a0000,1500000n8 printk.devkmsg=on"
=> booti 0x00280000 0x0a200000 0x08300000
```

验证能成功启动后，再按方案 A 持久化。

---

## 6. 操作流程推荐

```
第 1 次启动验证（用方案 C 手动）
        ↓ 验证 SD 能启动 Armbian
第 2 次启动用方案 A 持久化
        ↓ 配置 saveenv
后续每次开机自动 SD 启动
        ↓ 万一出问题
方案 A 的故障恢复（env default -a）
```

---

## 7. 附录

### 7.1 iter5 完整 bootargs 模板

```
root=UUID=d9159ff7-f834-4aba-a518-ac5f1dfc7175 rootflags=data=writeback rw rootwait rootfstype=ext4 console=ttyS2,1500000 no_console_suspend consoleblank=0 fsck.fix=yes fsck.repair=yes net.ifnames=0 max_loop=128 plymouth.enable=0 modprobe.blacklist=rfkill_rk,rfkill_wlan,bcmdhd,rtl8821cs,hci_uart watchdog.handle_boot_enabled=0 panic=5 loglevel=8 initcall_debug earlycon=uart8250,mmio32,0xff1a0000,1500000n8 printk.devkmsg=on
```

各参数作用：

| 参数 | 作用 |
|---|---|
| `root=UUID=...` | 指定 rootfs（SD 卡第二分区） |
| `console=ttyS2,1500000` | TTL 串口控制台 |
| `modprobe.blacklist=...` | 屏蔽无线驱动（防 19.5s 死锁） |
| `watchdog.handle_boot_enabled=0` | 关闭 watchdog 触发的硬重启 |
| `panic=5 loglevel=8` | panic 5s 重启 + 最高日志级别 |
| `initcall_debug` | 打印每个 initcall（定位死锁用） |
| `earlycon=uart8250,mmio32,0xff1a0000,1500000n8` | 早期控制台 |
| `printk.devkmsg=on` | 避免 IRQ-disabled 阶段 printk 静默 |

### 7.2 U-Boot 常用调试命令

```
=> printenv              # 查看所有环境变量
=> printenv bootcmd      # 查看特定变量
=> mmc dev 0             # 切换到 eMMC
=> mmc dev 1             # 切换到 SD
=> mmc info              # 当前 mmc 信息
=> ls mmc 1:1 /          # 列 SD 卡第一分区根目录
=> ls mmc 1:2 /          # 列 SD 卡第二分区（rootfs）
=> help                  # U-Boot 命令帮助
=> env default -a        # 恢复默认环境
=> saveenv               # 保存到 eMMC env 分区
=> reset                 # 重启
```

### 7.3 相关文件

- 当前镜像：`/mnt/sdb3/LPA3399Pro/lpa3399pro-armbian/build/output/images/Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.1.141_server_2026.06.11_iter6.img`
  - sha256: `2ba82f4df110088d6975798b1e99d012f6b2aab6fbdcf0e0af0ea0cb859f46c4`
  - 基础：hybrid_sdkboot.img（SDK 修复版 idbloader）
  - 5 处 DTB 修改已落实：display-subsystem/gpu/watchdog/drm-logo disabled，SD 50MHz
  - extlinux.conf 加入 A1 调试参数（initcall_debug, earlycon, printk.devkmsg），删除 video= 和 console=tty1
- 迭代日志：`/mnt/sdb3/LPA3399Pro/LPA3399Pro_Armbian_Iteration_Log_20260613.md`
- 启动顺序诊断 TTL：`/home/henry/dav/rk3399pro/logs/ttl_sd_hybrid_retry_202606141055.log`

---

## 8. 修改记录

| 日期 | 版本 | 作者 | 内容 |
|---|---|---|---|
| 2026-06-14 | 1.0 | Qoder CLI | 初版，方案 A/B/C 完整流程 |
| 2026-06-14 | 1.1 | Qoder CLI | 加入 §0：澄清 BootROM 行为取决于 idbloader hash；iter5.img 不工作是 idbloader 问题而非 BootROM 优先级；提供路径 1（直接启动）/路径 2（saveenv 备份）双选 |

---

*记录工具: Qoder CLI*
