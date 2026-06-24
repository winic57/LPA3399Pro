# LPA3399Pro Armbian 适配规划

## 背景

基于 [ophub/amlogic-s9xxx-armbian](https://github.com/ophub/amlogic-s9xxx-armbian) 项目（已 clone 到 `/mnt/sdb3/LPA3399Pro/lpa3399pro-armbian/`），参考 Neardi LPA3399Pro SDK（`/mnt/sdb3/LPA3399Pro/LPA3399Pro-SDK-Linux-V3.0/`）为 LPA3399Pro 工业板适配 Armbian 系统。

## SDK 关键资产盘点

| 资产 | 路径 | 用途 |
|------|------|------|
| Device Tree (主) | `kernel/arch/arm64/boot/dts/rockchip/rk3399pro-neardi-linux-lc110-base.dts` | 板级硬件描述 |
| Device Tree (include) | `rk3399pro-neardi-linux-ld110-{hdmi,wifibt,phy,peripheral,usb,cam}.dtsi` | 外设子模块描述 |
| Device Tree (base) | `rk3399pro.dtsi`, `rk3399pro-npu.dtsi`, `rk3399pro-evb-v13*.dts` | SoC 基础描述 |
| U-Boot defconfig | `u-boot/configs/rk3399pro_defconfig` | Bootloader 配置 |
| rkbin 固件 | `rkbin/bin/rk33/rk3399pro_{ddr,bl31,bl32,miniloader,usbplug}_v*.bin` | DDR/ATF/Trust/Loader |
| RKBOOT 配置 | `rkbin/RKBOOT/RK3399PROMINIALL.ini` | idbloader 打包配置 |
| RKTRUST 配置 | `rkbin/RKTRUST/RK3399PROTRUST.ini` | trust.img 打包配置 |
| Kernel config | `kernel/.config` (4.4.194) | 内核配置参考 |
| NPU 驱动/SDK | `external/rknpu/`, `external/rknn-toolkit/`, `external/rknn_demo/` | NPU 用户态库 |
| NPU kernel | `npu/kernel/` (独立内核+DTS) | NPU 协处理器固件 |
| Mali GPU | `external/libmali/` | GPU 用户态驱动 |
| MPP 媒体 | 内核内 mpp 驱动 | 硬件编解码 |

## 实施步骤

### 第一步：添加 Board 定义到 model_database.conf

在 `build-armbian/armbian-files/common-files/etc/model_database.conf` 末尾添加 LPA3399Pro 条目。

参考 rk3399 现有格式（如 r401 EAIDK-610）：

```
r430    :LPA3399Pro                                     :rk3399pro:rk3399pro-neardi-linux-lc110-base.dtb    :trust.bin                    :uboot.img                           :idbloader.bin                  :4GB-LPDDR4,32G-eMMC,NPU,1Gb-Nic,WiFi/BT  :rk35xx/6.1.y          :rockchip    :rk3399pro    :armbianEnv.txt  :henry                                              :lpa3399pro         :yes
```

**关键字段说明：**
- `SOC`: `rk3399pro`（区别于 rk3399，因为有内置 NPU/RK1808）
- `FDTFILE`: `rk3399pro-neardi-linux-lc110-base.dtb`（从 SDK 移植）
- `UBOOT_OVERLOAD`: `trust.bin`（Rockchip trust 镜像）
- `MAINLINE_UBOOT`: `uboot.img`
- `BOOTLOADER_IMG`: `idbloader.bin`
- `FAMILY`: `rk3399pro`（新建 family，区别于 rk3399）
- `KERNEL_TAGS`: 先用 `rk35xx/6.1.y`（ophub 项目为 rk3328/rk3399 系列提供的专用内核）

### 第二步：创建板级文件目录

创建 `build-armbian/armbian-files/different-files/lpa3399pro/` 目录结构：

```
lpa3399pro/
└── bootfs/
    ├── boot.cmd          # U-Boot 启动脚本（参考 firefly-rk3399）
    ├── boot.scr          # boot.cmd 的编译版本
    └── extlinux/
        └── extlinux.conf.bak  # extlinux 备用配置
```

**boot.cmd** 基于 firefly-rk3399 的 boot.cmd 修改，主要调整：
- `console` 改为 `ttyS2,1500000`（SDK 中 fiq_debugger 使用 serial-id=2, baudrate=1500000）
- `fdtfile` 指向 `rk3399pro-neardi-linux-lc110-base.dtb`
- 添加 NPU 相关 bootargs（如需要）

### 第三步：移植 Device Tree

**3.1 收集 DTS 源文件**

从 SDK 复制到 Armbian 项目的 kernel patch 目录：

```
源文件列表（SDK kernel/arch/arm64/boot/dts/rockchip/）：
├── rk3399pro.dtsi                          # SoC 基础
├── rk3399pro-npu.dtsi                      # NPU 节点
├── rk3399pro-evb-v13.dtsi                  # EVB v13 基础
├── rk3399pro-evb-v13-linux.dts             # EVB v13 Linux 配置
├── rk3399pro-evb-v13-multi-cam.dts         # 多摄像头配置
├── rk3399pro-neardi-linux-lc110-base.dts   # Neardi 主 DTS
├── rk3399pro-neardi-linux-ld110-hdmi.dtsi      # HDMI
├── rk3399pro-neardi-linux-ld110-wifibt.dtsi    # WiFi/BT (RTL8821CS)
├── rk3399pro-neardi-linux-ld110-phy.dtsi       # USB PHY
├── rk3399pro-neardi-linux-ld110-peripheral.dtsi # 外设
├── rk3399pro-neardi-linux-ld110-usb.dtsi       # USB
└── rk3399pro-neardi-linux-ld110-cam.dtsi       # 摄像头
```

**适配策略（直接使用 6.1.y 主线内核，开发板/原型验证用途）：**
- 使用 ophub 项目提供的 `rk35xx/6.1.y` 内核，系统现代（Debian Bookworm）
- 优先保证基础启动 + 网络 + USB + 存储可用
- NPU/GPU/摄像头等作为后续迭代目标
- DTS 需要从 4.4 语法适配到 6.1 语法（主要涉及 regulator、pinctrl、fiq-debugger 等 binding 变化）
- 6.1 内核中 RK3399Pro 的基本支持（CPU/GPU/USB/PCIe/eMMC）已有主线驱动
- GPU（Mali-T860）可通过 panfrost 主线驱动支持
- NPU（RK1808 via USB3）在 6.1 主线无官方支持，后续可用 vendor 模块或社区补丁

### 第四步：构建 U-Boot

**4.1 编译 rk3399pro U-Boot**

使用 SDK 的 u-boot 源码和 rk3399pro_defconfig 编译三板文件：

```bash
# 在 SDK 中编译 u-boot（或用已有产物）
cd /mnt/sdb3/LPA3399Pro/LPA3399Pro-SDK-Linux-V3.0/u-boot/
make rk3399pro_defconfig
make -j$(nproc)
```

**4.2 生成 idbloader 和 trust**

使用 rkbin 工具：
```bash
cd /mnt/sdb3/LPA3399Pro/LPA3399Pro-SDK-Linux-V3.0/rkbin/

# 生成 idbloader (DDR + miniloader)
./tools/boot_merger RKBOOT/RK3399PROMINIALL.ini

# 生成 trust.img (BL31 + BL32)
./tools/trust_merger RKTRUST/RK3399PROTRUST.ini
```

**4.3 产物文件**

编译后需要的文件（SDK 中已有部分成品）：
- `rk3399pro_loader_v1.24.126.bin`（即 idbloader，SDK u-boot/ 中已有）
- `uboot.img`（SDK u-boot/ 中已有）
- `trust.img`（SDK u-boot/ 中已有）

这些文件需要放到 ophub 项目的内核 release 或 Armbian 构建流程可获取的位置。

### 第五步：NPU 与 Vendor 驱动打包（后续迭代）

> 注意：此步骤为后续增强项，不在初始最小系统构建范围内。初始版本使用 6.1.y 主线内核，NPU 暂不可用。

**5.1 创建 NPU overlay 包**

创建 `build-armbian/armbian-files/different-files/lpa3399pro/rootfs/` 目录，放置：

```
rootfs/
├── lib/firmware/           # NPU 固件（从 SDK 提取）
├── usr/lib/
│   ├── librknn*.so*        # RKNN 运行时库
│   ├── librknn_runtime/    # RKNN runtime 依赖
│   └── libmali/            # Mali GPU 用户态驱动
├── usr/bin/
│   └── rknn_server         # NPU 服务
├── etc/ld.so.conf.d/
│   └── rknn.conf           # 动态库路径
└── usr/lib/systemd/system/
    └── rknn_server.service  # NPU 服务 systemd unit
```

**5.2 创建 NPU 内核模块**

NPU 驱动需要从 SDK 提取：
- `npu/kernel/` 中的 `rknpu.ko` 内核模块
- 需要与目标内核版本匹配编译

**建议方案**：将 NPU 驱动打包为 DKMS 模块或预编译 .ko，在 Armbian 首次启动时自动安装。

### 第六步：配置 GitHub Actions

修改 `.github/workflows/` 中的构建 workflow，添加 LPA3399Pro 构建矩阵：

```yaml
- board: lpa3399pro
  release: bookworm
  variant: minimal
  kernel: rk35xx/6.1.y
  build_target: armbian
```

构建输出应包含：
- `Armbian_*_lpa3399pro_bookworm_minimal.img.xz`
- SHA256SUM 校验文件

### 第七步：本地构建测试

```bash
cd /mnt/sdb3/LPA3399Pro/lpa3399pro-armbian/
sudo ./rebuild -b lpa3399pro -d bookworm -k rk35xx/6.1.y -t minimal
```

烧录到 SD 卡测试：
```bash
xz -d Armbian_*.img.xz
sudo dd if=Armbian_*.img of=/dev/sdX bs=4M status=progress
sync
```

## 验证清单

### 初始版本（必须）
- [ ] 系统启动到 login prompt
- [ ] 串口 UART2（1500000 baud）调试输出
- [ ] eMMC/SD 卡识别
- [ ] 网络（以太网 1Gb）
- [ ] USB 接口（USB2.0 + USB3.0）
- [ ] rootfs 自动扩容
- [ ] apt 包管理可用

### 后续迭代（按需）
- [ ] HDMI 输出
- [ ] WiFi/BT（RTL8821CS）
- [ ] GPU（Mali-T860，panfrost 驱动）
- [ ] NPU（RK1808，需 vendor 模块）
- [ ] 视频编解码（MPP）
- [ ] 摄像头（MIPI CSI）
- [ ] PCIe（4x lanes）
- [ ] 温度传感器
- [ ] 电源管理（suspend/resume）

## 风险与注意事项

1. **内核版本差异**：SDK 用 4.4.194，Armbian rk35xx 用 6.1.y，DTS 和驱动 API 有差异
2. **NPU 兼容性**：RK1808 NPU 在主线内核支持有限，可能需要 vendor kernel
3. **磁盘空间**：当前剩 26G，构建 Armbian 需要约 15-20G（Docker 方式），需确保空间
4. **rkbin 固件版本**：使用 SDK 提供的 rk3399pro 专用固件（DDR v1.24, miniloader v1.26），不要混用 rk3399 的
5. **U-Boot 分支**：SDK 的 U-Boot 是 Rockchip vendor 分支（含 rk3399pro 支持），不同于 ophub 项目的 mainline U-Boot

## 推荐执行顺序

1. **DTS 适配**：将 SDK 的 DTS 文件移植到 6.1.y 语法，生成可编译的 dtb
2. **U-Boot 编译**：用 SDK 的 u-boot + rk3399pro_defconfig 编译 idbloader/uboot.img/trust.img
3. **Board 注册**：在 model_database.conf 添加 lpa3399pro 条目，创建板级文件目录
4. **最小系统构建**：用 rebuild 脚本构建 minimal Armbian 镜像（Debian Bookworm + 6.1.y）
5. **SD 卡验证**：烧录到 SD 卡，验证启动、串口、网络、USB、eMMC
6. **DTS 调试**：根据启动日志修复 DTS 兼容性问题
7. **迭代增强**：逐步添加 GPU (panfrost)、WiFi/BT、NPU 等支持

---

## 审阅补充建议（2026-06-11）

以下内容为对当前计划的可行性审阅补充，不覆盖前文原始规划。结论是：总体方向可行，但需要修正若干会影响构建和启动的细节。

### 必须修正项

1. **model_database.conf 的 ID 不能使用 r430**

   当前 `model_database.conf` 中 `r430` 已被 `NanoPC-T4` 占用。新增 LPA3399Pro 时应使用下一个空闲 ID，例如：

   ```text
   r436    :LPA3399Pro                                     :rk3399pro:rk3399pro-neardi-linux-lc110-base.dtb    :trust.bin                    :uboot.img                           :idbloader.bin                  :4GB-LPDDR4,32G-eMMC,NPU,1Gb-Nic,WiFi/BT  :rk35xx/6.1.y          :rockchip    :rk3399pro    :armbianEnv.txt  :henry                                              :lpa3399pro         :yes
   ```

2. **bootloader 文件必须放到 rebuild 能识别的位置**

   `rebuild` 对 Rockchip 平台会从以下目录读取 bootloader：

   ```text
   build-armbian/u-boot/rockchip/<BOARD>/
   ```

   对 `lpa3399pro` 应创建：

   ```bash
   cd /mnt/sdb3/LPA3399Pro/lpa3399pro-armbian/
   mkdir -p build-armbian/u-boot/rockchip/lpa3399pro

   cp /mnt/sdb3/LPA3399Pro/LPA3399Pro-SDK-Linux-V3.0/u-boot/rk3399pro_loader_v1.24.126.bin \
      build-armbian/u-boot/rockchip/lpa3399pro/idbloader.bin

   cp /mnt/sdb3/LPA3399Pro/LPA3399Pro-SDK-Linux-V3.0/u-boot/uboot.img \
      build-armbian/u-boot/rockchip/lpa3399pro/uboot.img

   cp /mnt/sdb3/LPA3399Pro/LPA3399Pro-SDK-Linux-V3.0/u-boot/trust.img \
      build-armbian/u-boot/rockchip/lpa3399pro/trust.bin
   ```

   说明：SDK 里是 `trust.img`，但计划中的 `model_database.conf` 字段使用 `trust.bin`，因此需要复制时重命名。否则 `rebuild` 不会按预期写入 trust 镜像。

3. **DTS/DTB 移植路径需要明确**

   当前 `lpa3399pro-armbian` 仓库不是完整内核源码树，`rebuild` 会下载并解包 ophub/kernel release 中的 `dtb-rockchip-*.tar.gz`。因此“复制到 Armbian 项目的 kernel patch 目录”这一步不够准确，需要选择以下方案之一：

   - 正规方案：fork/构建 `ophub/kernel` 的 `rk35xx/6.1.y` 发布包，把 `rk3399pro-neardi-linux-lc110-base.dtb` 加入发布包。
   - 快速验证方案：先在外部内核源码中编译出 `rk3399pro-neardi-linux-lc110-base.dtb`，再通过 `different-files/lpa3399pro/rootfs/etc/armbian-board-release.conf` 的 `adjust_kernel_files_cmd` 注入到 `/boot/dtb/rockchip/`。

   快速验证方案示例：

   ```bash
   mkdir -p build-armbian/armbian-files/different-files/lpa3399pro/rootfs/etc
   ```

   `armbian-board-release.conf` 可定义：

   ```bash
   adjust_kernel_files="yes"

   adjust_kernel_files_cmd() {
       install -Dm644 /path/to/rk3399pro-neardi-linux-lc110-base.dtb \
           "${tag_bootfs}/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb"
   }
   ```

   注意：上面 `/path/to/...dtb` 需要替换为实际构建出的 dtb 路径；如果希望文件随仓库保存，更建议放入 `different-files/lpa3399pro/rootfs/usr/lib/lpa3399pro/` 后再从该路径复制。

4. **本地构建命令需要修正**

   当前 `rebuild` 参数中没有 `-d bookworm`；`-t` 表示 rootfs 文件系统类型，不是 `minimal`。应改为：

   ```bash
   cd /mnt/sdb3/LPA3399Pro/lpa3399pro-armbian/
   sudo ./rebuild -b lpa3399pro -k 6.1.y -t ext4
   ```

   另外，`rebuild` 不是从零生成 Debian/Ubuntu rootfs，它需要先存在基础 Armbian 镜像：

   ```text
   build/output/images/*-trunk_*.img
   ```

   因此计划中应补充“先准备或构建 bookworm Armbian 基础镜像”。

### 建议补充项

1. **boot.cmd 不一定需要单独复制**

   Rockchip 平台默认 `boot.cmd` 已经使用：

   ```text
   console=ttyS2,1500000
   ```

   并且 `fdtfile` 会在构建阶段根据 `model_database.conf` 自动替换。因此最小启动阶段可以优先复用平台默认文件，只在确实需要特殊 bootargs 时再创建 `different-files/lpa3399pro/bootfs/boot.cmd` 和重新生成 `boot.scr`。

2. **FAMILY 字段需根据 overlay 策略决定**

   `FAMILY=rk3399pro` 会让最终 `/boot/armbianEnv.txt` 中的 `overlay_prefix` 变为 `rk3399pro`。如果暂时不用 overlays，这样可以接受；如果希望复用现有 `rk3399` overlay，建议首版先使用：

   ```text
   FAMILY=rk3399
   ```

3. **6.1 内核支持范围应保守表述**

   建议将“6.1 内核中 RK3399Pro 的基本支持已有”调整为更保守的描述：

   - RK3399 主体驱动可作为基础复用。
   - RK3399Pro/RK1808/NPU 相关节点不应假设主线可用。
   - 首版 DTS 应尽量禁用 NPU、camera、vendor-only 节点，优先保证 CPU、UART、SD/eMMC、GMAC、USB。

4. **磁盘空间需要预留更多**

   当前 `/mnt/sdb3` 可用空间约 26G，已经接近风险边界。考虑基础镜像、kernel 包、临时 loop 镜像、解包 rootfs 和日志，建议在正式构建前至少预留 40G 以上可用空间。

### 建议后的优先执行顺序

1. 添加 `model_database.conf` 条目，使用未占用 ID，如 `r436`。
2. 准备 `build-armbian/u-boot/rockchip/lpa3399pro/` 下的 `idbloader.bin`、`uboot.img`、`trust.bin`。
3. 准备最小可编译 DTB，并确认能被放入 `/boot/dtb/rockchip/`。
4. 先复用 Rockchip 默认 `boot.cmd` 和 `armbianEnv.txt`，只在必要时创建板级覆盖文件。
5. 准备 `build/output/images/*-trunk_*.img` 基础镜像。
6. 执行 `sudo ./rebuild -b lpa3399pro -k 6.1.y -t ext4`。
7. 烧录 SD/TF 卡，优先验证串口、启动日志、rootfs 挂载、eMMC/SD、以太网、USB。
8. 基础系统稳定后，再逐步启用 HDMI、WiFi/BT、GPU、NPU、摄像头等功能。
