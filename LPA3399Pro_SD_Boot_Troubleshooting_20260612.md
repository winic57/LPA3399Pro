# LPA3399Pro SD 卡启动排障与混合引导测试记录

**日期**: 2026-06-12
**目标**: 将基于 `ophub/amlogic-s9xxx-armbian` 编译的 Armbian 6.1 (Trixie) 镜像烧录至 SD 卡，并引导 LPA3399Pro 开发板启动。

## 阶段一：尝试通过 eMMC 原厂 U-Boot 引导 SD 卡

*   **现象**: 系统默认从 eMMC 启动进入 Linux 4.4.194 (Neardi SDK)。通过 TTL 串口 (`1500000` 波特率) 发送中断信号，成功进入 eMMC 的 U-Boot (`=>`) 交互环境。
*   **测试指令与结果**:
    *   `mmc list`：显示 `sdhci@fe330000: 0 (eMMC)` 和 `dwmmc@fe320000: 1` (推测为 SD 卡)。
    *   `mmc dev 1`：报错 `mmc_init: -110, time 511` (超时) 或 `-95` (电压协商失败)。
*   **Linux 下对比**: 在 eMMC 启动的 Linux 环境中，内核成功识别了 SD 卡 (`mmc0: new ultra high speed SDR104 SDHC card`)，说明硬件插槽和 SD 卡均正常。
*   **结论**: eMMC 固化的旧版 U-Boot (v2017.09) 在初始化当前高速 SD 卡（SDR104）时，存在驱动兼容性或相位训练 (Phase Tuning) 失败的问题，导致它无法在引导阶段读取 SD 卡，自动 fallback 到了 eMMC 启动。

## 阶段二：原生 Armbian 镜像直接启动测试

*   **操作**: 使用 `zcat image.img.gz | sudo dd of=/dev/sdd` 将完整的 Armbian 镜像刷入 SD 卡。
*   **现象**: 将 SD 卡插入开发板并重启后，TTL 串口 (`1500000` 和 `115200` 波特率) **完全没有任何输出（静默死机）**，同时系统也没有从 eMMC 启动。
*   **分析**: 
    1.  插上 SD 卡后 eMMC 也没有启动，证明 RK3399Pro 的底层 BootROM 成功识别了 SD 卡，并尝试加载了 SD 卡扇区 64 上的初始引导程序 (SPL / idbloader)。
    2.  串口毫无输出，说明在最初始的阶段就崩溃了。这通常是因为通用 RK3399 的 SPL 无法正确完成 LPA3399Pro 特殊的 **LPDDR4 内存初始化**，导致 CPU 挂死，连串口 Pinmux 都没来得及配置。

## 阶段三：混合引导方案（原厂 U-Boot + Armbian Rootfs）

为了解决内存初始化问题，决定采用“混合引导方案”：用原厂 SDK 验证过的 U-Boot 替换 Armbian 镜像中的开源 U-Boot。

### 1. 生成正确的 SD 卡引导格式 (rksd)
RK3399Pro 从 SD 卡/eMMC 启动时，要求引导扇区必须具有特定的 `rksd` 头部和 RC4 加密。SDK 中现成的 `rk3399pro_loader_v1.24.126.bin` 头部是 `BOOT`（用于 USB 线刷），直接使用 `dd` 写入会导致 BootROM 无法识别。

**正确的生成方法**:
利用 SDK 提供的 `mkimage` 工具，将 DDR 初始化 bin 和 Miniloader 重新打包成 SD 卡专用的 `idbloader.img`：
```bash
cd /mnt/sdb3/LPA3399Pro/LPA3399Pro-SDK-Linux-V3.0/
./u-boot/tools/mkimage -n rk3399pro -T rksd -d rkbin/bin/rk33/rk3399pro_ddr_800MHz_v1.24.bin idbloader.img
cat rkbin/bin/rk33/rk3399pro_miniloader_v1.26.bin >> idbloader.img
```

### 2. 底层覆盖刷写 (dd seek)
在不破坏 Armbian 文件系统分区（`/boot` 和 `/`）的前提下，将原厂引导文件精确覆盖到 SD 卡的保留扇区：

```bash
# 1. 写入包含 rksd 头部的 idbloader.img (Sector 64)
sudo dd if=idbloader.img of=/dev/sdd seek=64 conv=notrunc

# 2. 写入 uboot.img (Sector 16384)
sudo dd if=u-boot/uboot.img of=/dev/sdd seek=16384 conv=notrunc

# 3. 写入 trust.img (Sector 24576)
sudo dd if=u-boot/trust.img of=/dev/sdd seek=24576 conv=notrunc
sync
```

## 结论与复用建议

1. **LPA3399Pro 不兼容通用 Armbian U-Boot**：凡是刷写基于通用 RK3399/RK35xx 源码编译的镜像，大概率都会遭遇“插卡无输出死机”的内存不兼容问题。
2. **Bootloader 格式是关键**：在 Linux 下向块设备 (`/dev/sdd` 或 `/dev/mmcblkX`) 写入引导时，千万不要直接写入由 `boot_merger` 生成的 USB 线刷固件 (带有 `BOOT` 魔数)，必须使用 `mkimage -T rksd` 生成的固件。
3. **长效解决方案**：未来如果要在 Actions 中自动构建 LPA3399Pro 的 Armbian 固件，应该将上述打包正确的 `idbloader.img`, `uboot.img`, `trust.img` 放入 Armbian 构建环境的 `u-boot/rockchip/lpa3399pro/` 目录下，让打包脚本自动使用它们，而不是从源码编译主线 U-Boot。
