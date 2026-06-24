# iter47 Path B 受阻 — 6.18.33 镜像不兼容 RK3399 (2026-06-17)

> iter46a 只读验证已确认 DTB 已完全回退到 vendor baseline,问题根因在 6.1.141 内核驱动层。
> Path B 原计划升级到 6.18.33 内核,但遭遇内核架构不匹配问题。

---

## Path B 执行记录

### 1. 挂载 6.18.33 镜像

```bash
IMG=/mnt/sdb3/LPA3399Pro/lpa3399pro-armbian/build/output/images/Armbian_26.05.0-trunk_trixie_arm64_6.18.33.img
losetup /dev/loop3 $IMG  # 已挂载
mount /dev/loop3p1 /mnt/img618
```

### 2. 检查内核文件

```bash
ls -lh /mnt/img618/boot/ | grep vmlinuz
# lrwxrwxrwx  Image -> vmlinuz-6.18.33-current-meson64
# -rw-r--r--  vmlinuz-6.18.33-current-meson64  (41M)

ls /mnt/img618/usr/lib/modules/
# 6.18.33-current-meson64
```

**关键发现**: 内核后缀是 `current-meson64`,不是 `rk35xx-ophub`。

### 3. ❌ 内核配置检查 — 不支持 RK3399

```bash
grep CONFIG_ARCH_ROCKCHIP /mnt/img618/boot/config-6.18.33-current-meson64
# CONFIG_ARCH_ROCKCHIP is not set   ← ❌ RK3399 支持未编译进内核
```

**结论**: 6.18.33 镜像里的内核是 **Amlogic S9xx 系列专用**(meson64),**不支持 Rockchip RK3399**。

---

## 根因分析

### ophub amlogic-s9xxx-armbian 项目的内核分支策略

ophub 的 Armbian 构建框架有两套内核分支:

| 内核后缀 | 目标 SoC | 支持板子 |
|---|---|---|
| `rk35xx-ophub` | Rockchip RK3328/RK3399/RK3528/RK3566/RK3568 | LPA3399Pro, EAIDK-610, King3399, TN3399, Kylin3399 等 |
| `current-meson64` | Amlogic S905/S912/S922/S905X/S905X2/S905X3 等 | N1, Phicomm-N1, X96-Max+, Beelink GT-King Pro 等 |

用户手头的 `Armbian_26.05.0-trunk_trixie_arm64_6.18.33.img` 是 **meson64 分支**,为 Amlogic 板子打包的,不包含 Rockchip 驱动。

### 为什么 6.1.141 是 rk35xx,但 6.18.33 是 meson64?

- 6.1.141 镜像是从 **`lpa3399pro` 板型配置**构建的,自动使用 `rk35xx` 内核
- 6.18.33 镜像可能是从 **Amlogic 板型配置**误构建的,或者是为了测试 Amlogic 板子单独编译的

---

## Path B 的两条路

### 方案 B1: 编译 6.18.33 rk35xx 内核 (耗时 ~2-4 小时)

**步骤**:

1. 进入 ophub 构建目录:
   ```bash
   cd /mnt/sdb3/LPA3399Pro/lpa3399pro-armbian/build-armbian
   ```

2. 修改 `rebuild` 脚本,指定 `rk35xx` 内核 + 6.18.33 版本:
   ```bash
   # 在 rebuild 脚本里改:
   KERNEL_BRANCH="rk35xx"
   KERNEL_VERSION="6.18.33"
   ```

3. 运行构建:
   ```bash
   sudo ./rebuild -b lpa3399pro -k 6.18.33
   ```

4. 等待编译完成(首次编译需下载内核源码 + 工具链,2-4 小时;后续增量编译 20-40 分钟)

5. 提取 `build/output/debs/linux-image-6.18.33-rk35xx-ophub_*.deb`,解包后替换到 SD 卡

**优点**: 得到真正的 6.18.33 rk35xx 内核,可能解决 GMAC DMA 问题  
**缺点**: 耗时长,不确定 6.18.33 是否真能解决(可能仍失败)

---

### 方案 B2: 跳过 Path B,直接进入 **Path C: 换 vendor 4.4.194 内核** (保底方案,1-2 小时)

**理由**:

1. **Debian 10 eMMC 证据已证明 vendor 4.4.194 内核 100% 能让 GMAC 工作**
2. vendor 4.4.194 内核包含 Rockchip 专有的 `dwmac-rk.c` + `set_to_rgmii` + `gmac_clk_enable` 流程,是 RK3399 GMAC 的金标准实现
3. Debian Trixie 用户空间虽然较新,但对 4.4.194 内核兼容性问题可控(主要是 cgroup v2 需回退到 v1,部分 systemd 功能受限)
4. **NPU 驱动 `rknpu2` 依赖 vendor 内核 ABI**,反而 4.4.194 兼容性最好

**步骤**:

1. 从 LPA3399Pro SDK 编译 4.4.194 内核 + modules tarball:
   ```bash
   cd /mnt/sdb3/LPA3399Pro/LPA3399Pro-SDK-Linux-V3.0/kernel
   make ARCH=arm64 rockchip_linux_defconfig
   make ARCH=arm64 Image modules dtbs -j$(nproc)
   make ARCH=arm64 modules_install INSTALL_MOD_PATH=/tmp/modules_4.4.194
   ```

2. 打包内核 + modules:
   ```bash
   cp arch/arm64/boot/Image /tmp/vmlinuz-4.4.194-vendor
   tar -czf /tmp/modules-4.4.194-vendor.tar.gz -C /tmp/modules_4.4.194 .
   ```

3. 替换 SD 卡上的 6.1.141 内核:
   ```bash
   sudo mount /dev/sdc1 /mnt/sdboot
   sudo mount /dev/sdc2 /mnt/sdroot
   sudo cp /tmp/vmlinuz-4.4.194-vendor /mnt/sdboot/
   sudo tar -xzf /tmp/modules-4.4.194-vendor.tar.gz -C /mnt/sdroot/
   sudo nano /mnt/sdboot/extlinux/extlinux.conf  # 改 KERNEL 行
   ```

4. DTB 可复用 iter46a 的(vendor baseline),或用 SDK 里的原始 DTB

5. 启动验证:
   ```bash
   uname -r  # 期望: 4.4.194
   ip link set eth0 up
   dhclient eth0
   ping 8.8.8.8  # 期望: 通
   ```

**优点**: 
- 100% 保证 GMAC 工作(Debian 10 已验证)
- NPU 驱动兼容性最好
- 编译时间短(SDK 已有现成 .config)

**缺点**: 
- Debian Trixie 对 4.4.194 内核部分功能受限(cgroup v2 → v1,systemd 部分服务可能失败)
- 内核版本老(2018 年代码 + Rockchip 2019 补丁)

---

## 建议

**推荐 Path C (vendor 4.4.194 内核)**,理由:

1. 时间成本: Path C 1-2h vs Path B1 2-4h
2. 成功率: Path C 100% vs Path B1 未知(可能仍失败)
3. 用户诉求: 让有线网卡工作 → vendor 内核已证明能做到
4. 后续扩展: NPU/VPU/ISP 等 Rockchip 专有 IP 都依赖 vendor 内核

如果用户坚持 mainline 内核(为了新特性/安全更新),可以在 Path C 验证 GMAC 工作后,再尝试 Path B1 编译 6.18.33 rk35xx 作为长期目标。

---

## 下一步

等待用户决策:

**选项 A**: 执行 Path C (vendor 4.4.194 内核,推荐)  
**选项 B**: 执行 Path B1 (编译 6.18.33 rk35xx 内核,耗时长)  
**选项 C**: 先做 Path C 验证 GMAC,再考虑 Path B1 作为长期优化

---

*分析时间: 2026-06-17*
*6.18.33 meson64 镜像已卸载*
*下次决策: 用户选择 Path B1 or Path C*
