# 原厂 SDK 分区 vs 当前 Armbian 镜像：16G / 64G eMMC 适配（2026-07-12）

## 1. 原厂 SDK 分区表（`parameter.txt`）

文件：`LPA3399Pro-SDK-Linux-V3.0/device/rockchip/rk3399pro/parameter.txt`

```text
CMDLINE: mtdparts=rk29xxnand:
  0x2000@0x4000(uboot),
  0x2000@0x6000(trust),
  0x10000@0xa000(boot),
  0x30000@0x1a000(recovery),
  0x10000@0x4a000(backup),
  -@0xc7a000(rootfs:grow)
uuid:rootfs=614e0000-0000-4b53-8000-1d28000054a9
TYPE: GPT
```

| 分区 | 作用 | 大小策略 |
|---|---|---|
| uboot / trust / boot / recovery / backup | 固定扇区 | 与 eMMC 总容量无关 |
| **rootfs:grow** | 系统根 | **最后一分区，吃掉介质剩余空间** |

要点：原厂**不是**按 16G/64G 做两套表，而是 **固定前缀 + 最后 rootfs grow**。  
同参数刷 16G 或 64G eMMC 时，前面分区一样，rootfs 终点不同。

### 实机对照（.17 上 16G eMMC 厂商布局）

```text
mmcblk0 ~15.8GB GPT
  p1 uboot    4M
  p2 trust    4M
  p3 boot    32M
  p4 recovery 96M
  p5 backup  32M
  p6 rootfs  ~15.6G  (一直到盘尾)
```

与 `rootfs:grow` 语义一致（具体起始扇区可能随量产 parameter 微调）。

NPU 侧 `parameter-npu.txt` 是另一套（misc/resource/kernel/boot），**不是**主 SoC 系统盘表。

---

## 2. 当前 Armbian / amlogic rebuild 镜像布局

**不是**原厂 6 分区，而是 ophub 双分区：

```text
[ 16MiB skip: idbloader@64 + uboot@16384 + trust@24576 ]
[ p1 BOOT  ~512MiB  ext4 LABEL=BOOT ]
[ p2 ROOTFS  镜像内默认 ~12GiB，mkpart 到镜像文件 100% ]
```

板级默认（`armbian-board-release.conf`）：

- `boot_mb=512`
- `root_mb=12288` → 整包约 **12.5GiB**

### 自动扩容机制（与原厂 grow 对等的部分）

| 组件 | 行为 |
|---|---|
| `/root/.no_rootfs_resize` 内容 **`yes`** | 首次启动 `start_service.sh` 调 `armbian-tf` |
| `armbian-tf` | 要求 **恰好 2 个分区**；`resizepart 2 100%` + `resize2fs`；然后把 flag 写成 `no` |
| 介质大于镜像 | 同一 img 可铺满 16G / 32G / 64G… |
| 介质小于镜像 | **不能**完整 dd |

> 注意：flag 文件名 historically 叫 `no_rootfs_resize`，但 ophub 逻辑是 **`yes` = 待扩容**。  
> 2026-07-12 曾误删该文件；已改回对 lpa 保持 `yes`。

---

## 3. 16GB / 64GB 适配结论

| 场景 | 是否适配 | 说明 |
|---|---|---|
| **同一 Armbian img → 16G eMMC/SD** | **可以** | 介质 ≥ ~12.5GiB；首启 `armbian-tf` 把 root 扩到盘尾（约 15G） |
| **同一 Armbian img → 64G eMMC/SD** | **可以** | 同样写入；首启扩到约 63G 级 |
| **同一厂商 SDK 包 → 16G/64G eMMC** | **可以**（原厂设计） | `rootfs:grow` |
| **Armbian img 当“厂商 6 分区升级包”** | **不可以直接等价** | 分区模型不同；会覆盖整盘为 2 分区 GPT |
| **在厂商 6 分区 eMMC 上只跑 armbian-tf** | **不会成功** | `armbian-tf` 发现分区数 ≠ 2 会 abort |

### 实操建议

1. **SD 启动 / 整盘刷 Armbian 到 eMMC**  
   - 用当前 rebuild 产物 dd 整盘  
   - 保证容量 ≥ 镜像  
   - 保留 `.no_rootfs_resize=yes` 直到首启扩容完成  

2. **保留原厂 eMMC 多分区、只换系统**  
   - 不要 dd 整份 Armbian img  
   - 应挂载厂商 `rootfs` 分区做 rsync/替换，或单独做“只写 p6”的安装流程  

3. **镜像体积策略**  
   - `root_mb=12288`：兼顾 NPU/modules，且仍小于 16G 介质  
   - 若要支持 **8G** 卡，需把 `root_mb` 降到 ≤~7000 并控制 rootfs 内容  
   - 64G **无需**单独出 64G 专用镜像  

---

## 4. 与原厂设计的对齐度

| 能力 | 原厂 SDK | 当前 Armbian 镜像 |
|---|---|---|
| 固定 loader 区 | uboot/trust 独立分区 | skip 扇区写 idbloader/uboot/trust（非独立 GPT 名） |
| 最后分区吃满容量 | `rootfs:grow` | 2 分区 + `armbian-tf` 100% |
| 16G/64G 一包通用 | 是 | **是**（整盘 Armbian 布局前提下） |
| recovery/backup 分区 | 有 | **无** |
| 与量产 parameter UUID 兼容 | 固定 rootfs UUID | 每次 rebuild 随机 UUID/PARTUUID |

---

## 5. 验证清单（建议）

```bash
# 写盘后、扩容前
parted /dev/mmcblkX unit MiB print   # 应见 2 分区，p2 约 12G
cat /root/.no_rootfs_resize          # 期望 yes

# 首启后
parted /dev/mmcblkX unit MiB print   # p2 应接近盘尾
df -h /                              # 16G 介质 ~14–15G；64G 介质 ~60G+
cat /root/.no_rootfs_resize          # 期望 no
```

手动补扩：`armbian-tf`（仅 2 分区磁盘）。
