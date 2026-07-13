# 为何 /dev/root 显示 14G，以及如何让 GHA 镜像 boot=300M

日期：2026-07-13  
板端：eMMC 启动已验证

## 1. 当前实盘分区（已“用满分区表”）

```text
eMMC 标称 16GB
  原始字节: 15_758_000_128
  = 15028 MiB
  = 14.676 GiB   ← 厂商 “16GB” 的十进制 vs 系统 GiB

GPT:
  skip / loader 区:  0 → 16 MiB
  p1 BOOT:          16 → 527 MiB   (511 MiB)   → df 约 463M（ext4 元数据后）
  p2 ROOT:         528 → 15028 MiB (14500 MiB) → df 显示 14G
```

| 名称 | 含义 |
|---|---|
| 芯片 16GB | 十进制约 16×10⁹ 字节 |
| `parted` 15028MiB | 二进制 1024 进制整盘 |
| **`/dev/root` 14G** | **仅 p2 根分区** 的文件系统容量（~14.16 GiB） |
| `/boot` 463M | p1 格式化后可用容量（分区 511MiB） |

**不是**“少分了 2G 没进分区表”。  
少的那部分主要是：

1. **GiB 换算**（16e9 B → 14.7 GiB）  
2. **BOOT 511MiB + loader 16MiB** 不计入 `/`  
3. **ext4 元数据 / 预留** 使 `df` 略小于分区原始字节  

空闲 **11G** = 根文件系统里还没写数据，属于正常。

```text
整盘 14.68 GiB
  - loader ~0.02
  - boot  ~0.50
  - root  ~14.16  →  df Size 14G, Used 3.1G, Avail 11G
```

## 2. 若 boot 改为 300MiB，能多给系统多少？

| boot | p2 约略大小 | 相对现在 |
|---|---|---|
| 511 MiB（当前） | ~14500 MiB ≈ 14.16 GiB | 现状 |
| **300 MiB** | ~14712 MiB ≈ 14.37 GiB | **约 +211 MiB 给 root** |

boot 实际占用约 **48MiB**（单内核 Image），300MiB 足够再放一份备份内核。

**在线把现盘 boot 缩到 300M 并不能自动把 211MiB 并进 `/`**：  
p2 起点钉在 528MiB，只缩 p1 会在中间留洞；要把洞并进 root 必须左移 p2（离线、风险高）。  
**正确做法：新镜像构建时就用 boot_mb=300，刷机后 first-boot 扩 root 到盘尾。**

## 3. GHA / 镜像侧如何实现（已改仓库）

文件：

`amlogic-s9xxx-armbian`  
`build-armbian/armbian-files/different-files/lpa3399pro/rootfs/etc/armbian-board-release.conf`

```bash
boot_mb="300"    # 原 512
root_mb="12288"  # 镜像文件内 root 预分配；刷到更大 eMMC 后 armbian-tf 扩到 100%
```

`rebuild` 逻辑（已有）：

```text
IMG_SIZE = skip(16) + boot_mb + root_mb
mkpart p1: skip → skip+boot-1
mkpart p2: skip+boot → 100% of image
first boot: .no_rootfs_resize=yes → armbian-tf 把 p2 扩到介质末尾
```

因此：

- **GHA 编出来的 lpa3399pro 镜像**刷 16G/64G eMMC/SD：  
  - boot ≈ 300MiB  
  - root = 介质剩余几乎全部  
- **不必**再手工改现网 14G 板子的分区（收益仅 ~200MiB）

### 构建注意

- 注入内核仍须含 `CONFIG_BT_HCIUART_RTL=y`  
- 不要用 `-s` 覆盖掉 board 的 `boot_mb`/`root_mb`（除非有意）  
- `boot_mb` 下限校验为 **256**，300 合法  

## 4. 现网板子（可选）

| 方案 | 说明 |
|---|---|
| **推荐** | 保持现状；等新 GHA 镜像再整盘刷 |
| 不推荐现在做 | 在线缩 p1 + 搬 p2：易变砖，只多 ~200MiB |
| 可接受 | 仅清理 `/boot` 旧备份（已做过修复，现 48M used） |

## 5. 一句话

- **`/dev/root` 14G** = 16G 芯片去掉换算差 + boot/loader 后的**根分区**大小，分区表已铺满。  
- **boot→300M 并尽量给系统**：改镜像 `boot_mb=300`，GHA 出图后整盘刷入即可；不必在现盘上硬挤 200MiB。
