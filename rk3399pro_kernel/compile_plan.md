# 手动编译 6.18.33 rk35xx 内核 — rk3399pro_kernel

> 目标: 编译 6.18.33 mainline 内核,打包成 ophub 格式,命名为 rk3399pro_kernel
> 原因: ophub/kernel 仓库无预编译的 6.18.y rk35xx 包

---

## 编译环境

- 工作目录: `/mnt/sdb3/LPA3399Pro/rk3399pro_kernel/`
- 内核版本: `6.18.33`
- 目标架构: `arm64`
- 目标平台: `RK3399 / RK3399Pro`
- 交叉编译器: `aarch64-linux-gnu-` (Ubuntu 预装)
- 代理: `192.168.50.62:7890`

---

## 执行步骤

### Step 1: 下载内核源码 (进行中)

```bash
cd /mnt/sdb3/LPA3399Pro/rk3399pro_kernel
export http_proxy=http://192.168.50.62:7890
export https_proxy=http://192.168.50.62:7890
wget -c https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.33.tar.xz
```

**预计耗时**: 5-15 分钟 (取决于网络)

### Step 2: 解压源码

```bash
tar -xf linux-6.18.33.tar.xz
cd linux-6.18.33
```

### Step 3: 配置内核 — 使用 defconfig + rockchip 特定配置

```bash
# 安装交叉编译工具链(如果没有)
sudo apt-get install -y gcc-aarch64-linux-gnu make bison flex libssl-dev \
    libncurses-dev bc kmod cpio

# 使用 arm64 defconfig 作为基础
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig

# 启用 Rockchip 支持
cat >> .config << 'EOF'
# Rockchip Platform
CONFIG_ARCH_ROCKCHIP=y
CONFIG_ROCKCHIP_PM_DOMAINS=y
CONFIG_ROCKCHIP_IOMMU=y

# RK3399 Clock
CONFIG_COMMON_CLK_RK808=y
CONFIG_CLK_RK3399=y

# RK3399 GMAC (重点)
CONFIG_DWMAC_ROCKCHIP=y
CONFIG_STMMAC_ETH=y
CONFIG_STMMAC_PLATFORM=y

# RK3399 PHY
CONFIG_ROCKCHIP_PHY=y
CONFIG_PHY_ROCKCHIP_DP=y
CONFIG_PHY_ROCKCHIP_EMMC=y
CONFIG_PHY_ROCKCHIP_INNO_HDMI=y
CONFIG_PHY_ROCKCHIP_INNO_USB2=y
CONFIG_PHY_ROCKCHIP_PCIE=y
CONFIG_PHY_ROCKCHIP_TYPEC=y
CONFIG_PHY_ROCKCHIP_USB=y

# Motorcomm YT8521S PHY (GMAC PHY 芯片)
CONFIG_MOTORCOMM_PHY=y

# RK3399 Pinctrl
CONFIG_PINCTRL_ROCKCHIP=y

# RK3399 GPU
CONFIG_DRM_ROCKCHIP=y
CONFIG_ROCKCHIP_DW_HDMI=y
CONFIG_ROCKCHIP_ANALOGIX_DP=y
CONFIG_ROCKCHIP_DW_MIPI_DSI=y
CONFIG_ROCKCHIP_INNO_HDMI=y

# RK3399 VPU
CONFIG_VIDEO_ROCKCHIP_VDEC=m
CONFIG_VIDEO_HANTRO=m

# RK3399 Thermal
CONFIG_ROCKCHIP_THERMAL=y

# RK3399 Regulators
CONFIG_REGULATOR_RK808=y
CONFIG_REGULATOR_PWM=y

# RK3399 I2C/SPI/UART
CONFIG_I2C_RK3X=y
CONFIG_SPI_ROCKCHIP=y
CONFIG_SERIAL_8250_DW=y

# RK3399 MMC
CONFIG_MMC_DW=y
CONFIG_MMC_DW_ROCKCHIP=y
CONFIG_MMC_SDHCI_OF_ARASAN=y

# RK3399 USB
CONFIG_USB_DWC3=y
CONFIG_USB_DWC3_OF_SIMPLE=y

# RK3399 PCIe
CONFIG_PCIE_ROCKCHIP_HOST=y

# Misc
CONFIG_PWM_ROCKCHIP=y
CONFIG_RTC_DRV_RK808=y
CONFIG_CRYPTO_DEV_ROCKCHIP=m
EOF

# 运行 olddefconfig 合并配置
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
```

### Step 4: 编译内核

```bash
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
     -j$(nproc) \
     Image modules dtbs
```

**预计耗时**: 1-3 小时(首次编译)

### Step 5: 安装 modules 到临时目录

```bash
mkdir -p /mnt/sdb3/LPA3399Pro/rk3399pro_kernel/output/modules
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
     modules_install \
     INSTALL_MOD_PATH=/mnt/sdb3/LPA3399Pro/rk3399pro_kernel/output/modules
```

### Step 6: 复制内核 + DTB

```bash
mkdir -p /mnt/sdb3/LPA3399Pro/rk3399pro_kernel/output/boot/dtb/rockchip

# 复制内核 Image
cp arch/arm64/boot/Image \
   /mnt/sdb3/LPA3399Pro/rk3399pro_kernel/output/boot/vmlinuz-6.18.33-rk35xx-ophub

# 复制 RK3399 DTB
cp arch/arm64/boot/dts/rockchip/rk3399*.dtb \
   /mnt/sdb3/LPA3399Pro/rk3399pro_kernel/output/boot/dtb/rockchip/

# 复制 RK3399Pro DTB
cp arch/arm64/boot/dts/rockchip/rk3399pro*.dtb \
   /mnt/sdb3/LPA3399Pro/rk3399pro_kernel/output/boot/dtb/rockchip/
```

### Step 7: 打包成 ophub 格式 tar.gz

```bash
cd /mnt/sdb3/LPA3399Pro/rk3399pro_kernel/output

# 创建 ophub 内核包结构
mkdir -p kernel/6.18.33-rk35xx-ophub
cp -a boot kernel/6.18.33-rk35xx-ophub/
cp -a modules/lib/modules/6.18.33 kernel/6.18.33-rk35xx-ophub/modules

# 打包
tar -czf 6.18.33-rk35xx-ophub.tar.gz kernel/

# 移动到 ophub kernel 目录
mkdir -p /mnt/sdb3/LPA3399Pro/lpa3399pro-armbian/build-armbian/kernel/rk35xx/6.18.33
mv 6.18.33-rk35xx-ophub.tar.gz \
   /mnt/sdb3/LPA3399Pro/lpa3399pro-armbian/build-armbian/kernel/rk35xx/6.18.33/
```

### Step 8: 创建 ophub 格式的辅助文件

```bash
cd /mnt/sdb3/LPA3399Pro/lpa3399pro-armbian/build-armbian/kernel/rk35xx/6.18.33

# 生成 sha256sum
sha256sum 6.18.33-rk35xx-ophub.tar.gz > 6.18.33-rk35xx-ophub.tar.gz.sha256

# 创建 version 文件
echo "6.18.33" > version.txt

# 创建其他辅助文件(占位,ophub 脚本需要)
touch boot-6.18.33-rk35xx-ophub.tar.gz
touch dtb-rockchip-6.18.33-rk35xx-ophub.tar.gz
```

### Step 9: 用 rebuild 重新打包镜像

```bash
cd /mnt/sdb3/LPA3399Pro/lpa3399pro-armbian

# 禁用自动内核查询,强制使用本地 6.18.33
sudo ./rebuild -b lpa3399pro -k 6.18.33 -a false
```

### Step 10: 验证生成的镜像

```bash
ls -lh build/output/images/*lpa3399pro*6.18.33*

# 期望:
# Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.18.33_server_*.img
```

---

## 关键配置项说明

### GMAC 相关(最重要)

```
CONFIG_DWMAC_ROCKCHIP=y          # RK 平台 GMAC 驱动
CONFIG_STMMAC_ETH=y              # stmmac 核心
CONFIG_MOTORCOMM_PHY=y           # YT8521S PHY 驱动
```

### RK3399 时钟

```
CONFIG_CLK_RK3399=y              # RK3399 时钟树
CONFIG_COMMON_CLK_RK808=y        # PMIC 时钟
```

### RK3399 电源域

```
CONFIG_ROCKCHIP_PM_DOMAINS=y     # 电源域管理
```

---

## 风险评估

| 风险 | 可能性 | 缓解措施 |
|---|---|---|
| 编译失败(配置错误) | 中 | 逐步验证 .config,参考 6.1.141 配置 |
| 生成的内核无法 boot | 中 | 保留 6.1.141 备份,可回退 |
| GMAC 仍失败 | 中 | 进入 Path C (vendor 4.4.194) |
| 编译耗时过长 | 高 | 已知风险,预计 3-4 小时 |

---

## 回退方案

如果编译失败或内核无法工作:
1. 从 SD 卡备份恢复 6.1.141 内核
2. 执行 Path C: 换 vendor 4.4.194 内核(100% 保证工作)

---

*开始时间: 2026-06-17 ~14:30*
*预计完成: 2026-06-17 ~18:00 (3.5 小时)*
*当前步骤: Step 1 下载内核源码*
