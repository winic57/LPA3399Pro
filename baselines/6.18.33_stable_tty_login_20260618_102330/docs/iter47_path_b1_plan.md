# iter47 Path B1 执行计划 — 编译 6.18.33 rk35xx 内核 (2026-06-17)

> 已确认 ophub rebuild 脚本支持 6.18.y,但 rk35xx 默认配置为 6.1.y。
> 需修改配置强制使用 6.18.y,然后编译并替换到 SD 卡。

---

## 前置检查

### ✅ 已确认

- rebuild 脚本路径: `/mnt/sdb3/LPA3399Pro/lpa3399pro-armbian/rebuild`
- 内核仓库: `https://github.com/ophub/kernel`
- rk35xx 默认内核: `6.1.y` (第 95 行)
- 支持的内核版本: `6.1.y / 6.6.y / 6.12.y / 6.18.y` (第 97 行)
- `-k` 参数: 可手动指定内核版本

### ❌ 未确认(需在线检查)

- ophub kernel 仓库是否有预编译的 6.18.y rk35xx 包
- 如果没有,rebuild 脚本会自动从 kernel.org 下载源码编译

---

## 执行步骤

### Step 1: 修改 rebuild 脚本,强制 rk35xx 使用 6.18.y

```bash
cd /mnt/sdb3/LPA3399Pro/lpa3399pro-armbian
sudo cp rebuild rebuild.bak_$(date +%Y%m%d_%H%M%S)

# 方法 A: 直接修改脚本第 95 行
sudo sed -i 's/rk35xx_kernel=("6.1.y")/rk35xx_kernel=("6.18.y")/' rebuild

# 验证
grep 'rk35xx_kernel=' rebuild
# 期望: rk35xx_kernel=("6.18.y")
```

### Step 2: 运行 rebuild,指定 lpa3399pro + 6.18.y 内核

```bash
# 方法 1: 用修改后的默认配置(推荐)
sudo ./rebuild -b lpa3399pro

# 方法 2: 用 -k 参数强制指定(如果方法 1 不生效)
sudo ./rebuild -b lpa3399pro -k 6.18.y
```

**预期行为**:
1. 脚本从 ophub/kernel 仓库下载 6.18.y rk35xx tar.gz 包(如果存在)
2. 如果不存在,脚本从 kernel.org 下载 6.18.33 源码,编译 rk35xx config
3. 生成新镜像到 `build/output/images/Armbian_*_lpa3399pro_*_6.18.y_*.img`

**耗时估算**:
- 有预编译包: 5-10 分钟(下载 + 打包)
- 无预编译包,首次编译: 2-4 小时(下载源码 + 编译 + 打包)
- 无预编译包,增量编译: 20-40 分钟(已有 .config 和工具链)

### Step 3: 检查编译输出

```bash
ls -lh build/output/images/ | grep 6.18

# 如果成功,应看到类似:
# Armbian_26.05.0_rockchip_lpa3399pro_trixie_6.18.33_server_*.img
```

### Step 4: 挂载新镜像,验证内核配置

```bash
NEW_IMG=$(ls build/output/images/*lpa3399pro*6.18*.img | head -1)
sudo losetup -fP --show "$NEW_IMG"
# 假设返回 /dev/loop4

sudo mkdir -p /mnt/img618rk
sudo mount /dev/loop4p1 /mnt/img618rk

# 验证内核版本
ls -lh /mnt/img618rk/boot/ | grep vmlinuz
# 期望: vmlinuz-6.18.33-rk35xx-ophub

# 验证内核配置
grep -E "CONFIG_ARCH_ROCKCHIP|CONFIG_CLK_RK3399|CONFIG_DWMAC_ROCKCHIP" \
     /mnt/img618rk/boot/config-6.18.33-rk35xx-ophub
# 期望:
# CONFIG_ARCH_ROCKCHIP=y
# CONFIG_CLK_RK3399=y
# CONFIG_DWMAC_ROCKCHIP=y
```

### Step 5: 提取内核文件到 SD 卡

```bash
# 备份 SD 卡当前 6.1.141 内核
TS=$(date +%Y%m%d_%H%M%S)
sudo mount /dev/sdc1 /mnt/sdboot
sudo mount /dev/sdc2 /mnt/sdroot

sudo cp -a /mnt/sdboot/vmlinuz-6.1.141-rk35xx-ophub \
           /mnt/sdboot/vmlinuz-6.1.141-rk35xx-ophub.iter46a_${TS}
sudo cp -a /mnt/sdroot/lib/modules/6.1.141-rk35xx-ophub \
           /mnt/sdroot/lib/modules/6.1.141-rk35xx-ophub.iter46a_${TS}
sudo cp -a /mnt/sdboot/extlinux/extlinux.conf \
           /mnt/sdboot/extlinux/extlinux.conf.iter46a_${TS}

# 复制 6.18.33 内核到 SD 卡
sudo cp /mnt/img618rk/boot/vmlinuz-6.18.33-rk35xx-ophub \
        /mnt/sdboot/
sudo cp /mnt/img618rk/boot/initrd.img-6.18.33-rk35xx-ophub \
        /mnt/sdboot/ 2>/dev/null
sudo cp -a /mnt/img618rk/usr/lib/modules/6.18.33-rk35xx-ophub \
           /mnt/sdroot/lib/modules/

# DTB 保留 iter46a 的(已回退到 vendor baseline)
# 不替换 /mnt/sdboot/dtb/
```

### Step 6: 修改 extlinux.conf 指向新内核

```bash
cat /mnt/sdboot/extlinux/extlinux.conf
# 当前应该是:
# LABEL Armbian
#   KERNEL /vmlinuz-6.1.141-rk35xx-ophub
#   INITRD /initrd.img-6.1.141-rk35xx-ophub
#   FDT /dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb

sudo nano /mnt/sdboot/extlinux/extlinux.conf
# 改成:
# LABEL Armbian
#   KERNEL /vmlinuz-6.18.33-rk35xx-ophub
#   INITRD /initrd.img-6.18.33-rk35xx-ophub
#   FDT /dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb  ← 保持不变(iter46a DTB)
```

### Step 7: sync + 卸载

```bash
sync
sudo umount /mnt/sdboot /mnt/sdroot /mnt/img618rk
sudo losetup -d /dev/loop4
sudo rmdir /mnt/img618rk
```

### Step 8: 插回 SD 卡,TTL 验证

```bash
# 板子启动后
uname -r
# 期望: 6.18.33-rk35xx-ophub

# 检查 GMAC probe
dmesg | grep -iE "rk_gmac|stmmac|Failed to reset"
# 期望: 无 "Failed to reset the dma"

# 检查 clk_gmac 频率
cat /sys/kernel/debug/clk/clk_summary | grep clk_gmac
# 期望: clk_gmac 不再是 30 MHz(可能变成 125 MHz 或其他值)

# 尝试 link-up
ip link set eth0 up
# 期望: 立即返回,无 "Connection timed out"

dmesg | tail -20
# 期望: 无 DMA 错误

# 取 IP 并测试
dhclient eth0
ip addr show eth0
ping -c 3 8.8.8.8
# 期望: 能 ping 通
```

---

## 风险评估

| 风险 | 可能性 | 缓解措施 |
|---|---|---|
| 6.18.33 编译失败 | 中 | 检查编译日志,调整 .config |
| 6.18.33 boot 失败 | 低 | 从备份恢复 6.1.141 |
| 6.18.33 GMAC 仍失败 | 中 | 进入 Path C (vendor 4.4.194) |
| SD 卡写入损坏 | 极低 | 已备份所有文件 |

---

## 回退方案

如果 6.18.33 失败(boot 不起来或 GMAC 仍失败):

```bash
sudo mount /dev/sdc1 /mnt/sdboot
sudo mount /dev/sdc2 /mnt/sdroot

# 恢复 6.1.141 内核
sudo cp /mnt/sdboot/vmlinuz-6.1.141-rk35xx-ophub.iter46a_* \
        /mnt/sdboot/vmlinuz-6.1.141-rk35xx-ophub

# 恢复 extlinux.conf
sudo cp /mnt/sdboot/extlinux/extlinux.conf.iter46a_* \
        /mnt/sdboot/extlinux/extlinux.conf

# 恢复 modules(可选,如果 6.18.33 modules 有问题)
sudo rm -rf /mnt/sdroot/lib/modules/6.18.33-rk35xx-ophub
sudo cp -a /mnt/sdroot/lib/modules/6.1.141-rk35xx-ophub.iter46a_* \
           /mnt/sdroot/lib/modules/6.1.141-rk35xx-ophub

sync
sudo umount /mnt/sdboot /mnt/sdroot
```

---

## 下一步(如果 6.18.33 仍失败)

**Path C: 换 vendor 4.4.194 内核**

理由:
1. Debian 10 eMMC 已证明 vendor 4.4.194 能让 GMAC 100% 工作
2. vendor 驱动包含 Rockchip 专有的 `dwmac-rk.c` + `clk_mac_speed` + `set_to_rgmii` 等 RK3399 GMAC 专用逻辑
3. mainline 6.1.141/6.18.33 缺少这些专有实现

---

*计划时间: 2026-06-17*
*预计总耗时: 2-4 小时(首次编译) 或 30-60 分钟(有预编译包)*
*开始时间: 等待用户确认*
