# LPA3399Pro Armbian 适配与排障全记录 (2026-06-13)

## 1. 背景与初始状态
在之前的尝试中，制作的 “SDK 原厂 bootloader + Armbian rootfs” 混合卡无法启动，表现为 TTL 串口完全静默或在 Loader 阶段卡死。

## 2. 关键阶段一：修正 Bootloader (idbloader)
**依据**: `LPA3399Pro_SD_Hybrid_Write_TTL_Result_20260613.md` 静态对比发现 idbloader 格式异常。

*   **问题诊断**: 之前的 `idbloader.img` 是通过手动 `cat` 拼接 DDR 固件和 Miniloader 生成的，缺少 Rockchip BootROM 要求的 `rksd` 结构头。
*   **解决方案**: 使用 SDK 标准脚本重新生成标准 IDB 块。
    ```bash
    cd LPA3399Pro-SDK-Linux-V3.0/u-boot
    make rk3399pro_defconfig
    ./make.sh --idblock
    ```
*   **结果**: 生成了 204,800 字节的 `idblock.bin`。写入 SD 卡 Sector 64 后，TTL 成功输出 `DDR Version 1.24` 和 `U-Boot 2017.09` 日志。

## 3. 阶段二：解决内核挂载与控制台中断问题
*   **问题诊断**: 内核启动后，日志显示 `Kernel command line` 被 DTB 中硬编码的参数覆盖，指向了错误的 `PARTUUID` (eMMC 分区) 且 console 切换到了 `ttyFIQ0`。
*   **解决方案**:
    1.  反编译 `rk3399pro-neardi-linux-lc110-base.dtb`。
    2.  彻底删除 `chosen` 节点下的 `bootargs` 属性。
    3.  重编译并写回镜像。
*   **结果**: 内核成功识别 `extlinux.conf` 传递的 `root=UUID=...` 参数，并能持续在 `ttyS2 (1500000)` 输出日志。

## 4. 阶段三：攻克内核死锁 (Plan A, B, C, D, E)
**故障现象**: 系统在识别到 SD 卡或初始化无线模块时，出现 RCU Stall 报错或瞬时挂起。

### 方案 A 系列: 降速与降压隔离
*   **Plan A v2**: 在 DTB 中禁用了 WiFi (`fe310000`) 和 SD 卡 (`fe320000`) 的 SDR50/104 模式，强制回退到 High-Speed (50MHz)。
*   **Plan D**: 极端降速实验，将 SD 卡频率强制锁定在 25MHz (SDR12)，以排除高频电气干扰。
*   **结论**: 即使在低频下，硬件初始化无线模块时仍会诱发死锁。

### 方案 B/C: 硬件节点禁用实验
*   **Plan B**: 在 DTB 中将 WiFi 设为 `disabled`。
*   **Plan C**: 进一步将蓝牙 (`wireless-bluetooth`) 和电源序列 (`sdio-pwrseq`) 设为 `disabled`。
*   **风险发现**: 禁用这些节点会导致内核时钟框架关闭 PMIC 外部时钟，引发 I2C 总线死锁（`rk3x-i2c timeout`），表现为启动 17 秒后完全无日志。

### 方案 E: 终极内核黑名单 (当前推荐)
*   **问题诊断**: 16GB 新卡日志显示系统在 17.55s 探测蓝牙 `[BT_RFKILL]` 时瞬间死机。确认为 6.1 内核下的无线驱动触发了致命的 GPIO/电源冲突。
*   **解决方案**: 不修改设备树（保持时钟开启），但在 `/extlinux/extlinux.conf` 中追加内核参数：
    `modprobe.blacklist=rfkill_rk,rfkill_wlan,bcmdhd,rtl8821cs,hci_uart`
*   **技术目标**: 从软件层面禁止内核触碰“有毒”的无线模块 GPIO，保障根系统挂载流程。

## 5. 关键发现：主机 USB/SD 链路稳定性
*   **现象**: `dd` 烧录速度异常（显示 2.5 GB/s 且瞬间完成），但卡内数据未更新。
*   **诊断**: 主机内核日志出现 `device offline error` 和 `Unable to enumerate USB device`。
*   **结论**: 频繁的硬挂起重启和高速写入导致读卡器或 USB 端口进入不稳定状态。
*   **对策**: 必须物理插拔读卡器并更换 USB 端口，确保 `lsblk` 识别容量正常且 `oflag=direct` 写入显示真实的物理速度 (10-30 MB/s)。

## 6. 当前镜像状态
*   **镜像版本**: Plan E (Plan A v2 DTB + Kernel Blacklist)
*   **主要修正**:
    1.  **Loader**: 正确的 `idblock.bin`。
    2.  **DTB**: 移除了 `bootargs`，限制了 SD 最高主频 (50MHz)。
    3.  **Bootargs**: 彻底拉黑了无线驱动以防止启动崩溃。

---
*记录人: Gemini CLI*  
*日期: 2026-06-13*

