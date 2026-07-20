# LPA3399Pro HDMI 保守启用（6.18.33）

日期：2026-07-20
目标板：`<board-user>@<board-ip>`（Armbian 6.18.33，SD，使用既有板端凭据）
目标：在**不丢当前已适配项**的前提下恢复 HDMI 视频输出，并处理文字模糊。

## 1. 现象

- 插视频线无输出
- SSH/系统正常
- 无 `/dev/dri`、无 `/dev/fb*`
- dmesg 几乎没有 `rockchip-drm` / VOP probe 日志

## 2. 根因

当前启动 DTB 是**无显示基线** `rk3399pro-neardi-linux-lc110-base.dtb`：

| 节点 | 原状态 | 说明 |
|---|---|---|
| `/display-subsystem` | disabled | DRM 总开关，历史为规避早期 boot hang |
| `/vop@ff8f0000` (LIT) | disabled | 无 VOP 则无法出图 |
| `/vop@ff900000` (BIG) | disabled | 无 VOP 则无法出图 |
| `/hdmi@ff940000` | okay | 单独开着也只是半截链路 |
| `/gpu@ff9a0000` (Mali) | disabled | 3D 加速，非扫描输出必需 |

早期 6.18 启动日志里，`display-subsystem` bind VOP 后曾出现 hang，所以 base 默认关显示，只保留 TTL/SSH。

## 3. 为何不能直接换仓库 `base-display.dtb`

`kernel-6.18/rk3399pro-neardi-linux-lc110-base-display.dts` 本身是适配正确的 display 变体：

```dts
/include/ "rk3399pro-neardi-linux-lc110-base.dts"
/* 仅翻转 */
display-subsystem / vop-lit / vop-big / gpu -> okay
```

与 `temp_unpack_new/dtbs/*-base-display.dtb` 对比后确认：

- **与当前 6.18 base 同源**，不是旧 4.4/工厂 DTB
- 相对 local base **只改 4 个 status**
- 但板子当前 DTB 额外已 bake：`/serial@ff180000/bluetooth = okay`
- 直接替换 display 包会丢掉该 bake-in（虽有 `rk3399pro-bt-enable` overlay 可补）

因此采用更稳妥路径：**从板子当前正在跑的 DTB 派生 conservative display 版**。

## 4. 实施步骤（已做）

### 4.1 备份

```text
/root/display_enable_backup_<timestamp>/
  armbianEnv.txt
  extlinux.conf
  rk3399pro-neardi-linux-lc110-base.dtb
  board_before.dts
  rollback.sh
  README.txt
```

回退：

```bash
bash /root/display_enable_backup_<timestamp>/rollback.sh && reboot
```

### 4.2 生成 conservative DTB

从当前 base 复制后只启用显示扫描链路（**GPU 仍 disabled**）：

```bash
SRC=/boot/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb
DST=/boot/dtb/rockchip/rk3399pro-neardi-linux-lc110-base-display-conservative.dtb
cp -a "$SRC" "$DST"
fdtput -t s "$DST" /display-subsystem status okay
fdtput -t s "$DST" /vop@ff8f0000 status okay
fdtput -t s "$DST" /vop@ff900000 status okay
# /gpu@ff9a0000 保持 disabled
```

关键状态校验：

```text
/display-subsystem=okay
/vop@ff8f0000=okay
/vop@ff900000=okay
/gpu@ff9a0000=disabled
/hdmi@ff940000=okay
/serial@ff180000/bluetooth=okay
```

### 4.3 改启动配置

`/boot/armbianEnv.txt`：

```text
fdtfile=rockchip/rk3399pro-neardi-linux-lc110-base-display-conservative.dtb
overlays=rk3399pro-bt-enable
```

`/boot/extlinux/extlinux.conf`：

```text
FDT /dtb/rockchip/rk3399pro-neardi-linux-lc110-base-display-conservative.dtb
```

然后 `reboot`。

## 5. 启用后验证（成功）

| 检查项 | 结果 |
|---|---|
| 启动 | 正常，无 display hang |
| SSH/网络 | 正常（eth0 已取得板端地址） |
| `/dev/dri/card0` | 有 |
| `/dev/fb0` | 有，`rockchipdrmfb` |
| connector | `card0-HDMI-A-1` = connected / enabled / dpms=On |
| EDID | 256 bytes，显示器名 `TS35505` |
| DRM bind | VOP-BIG + VOP-LIT + HDMI 全部 bound |

关键 dmesg：

```text
rockchip-drm display-subsystem: bound ff900000.vop
rockchip-drm display-subsystem: bound ff8f0000.vop
dwhdmi-rockchip ff940000.hdmi: Detected HDMI TX controller v2.11a with HDCP (DWC HDMI 2.0 TX PHY)
rockchip-drm display-subsystem: bound ff940000.hdmi
[drm] Initialized rockchip 1.0.0 for display-subsystem on minor 0
rockchip-drm display-subsystem: [drm] fb0: rockchipdrmfb frame buffer device
```

内核配置侧支持齐全：

- `CONFIG_DRM_ROCKCHIP=m`
- `CONFIG_ROCKCHIP_VOP=y`
- `CONFIG_ROCKCHIP_DW_HDMI=y`
- `CONFIG_DRM_FBDEV_EMULATION=y`

## 6. 文字模糊排查

### 6.1 现象

HDMI 已有输出，但屏幕文字/字母发糊、看不清。

### 6.2 证据

`modetest -c` / EDID 解析：

| 项 | 值 |
|---|---|
| 显示器 | `TS35505` |
| EDID preferred | **1024x768@60**（DTD0，type: preferred） |
| 另有 timing | 1920x1080@60、1360x768@60 等 |
| 当时实际 mode | **1920x1080@60**（cmdline `video=HDMI-A-1:1920x1080@60e` 强制） |
| 时钟 | `pll_vpll` / `dclk_vop0` = 148500000（与 1080p60 一致） |

结论：

1. 该屏 **原生/首选是 1024x768**
2. 系统被强制到 1080p 后，显示器做缩放 → 文字边缘发糊
3. `video=...@60e` 的 `e` 还会 force connector enable，进一步锁定强制 mode

### 6.3 纯色 / 图案确认

已在 `/dev/fb0` 用 Python 直接写帧缓冲验证链路（非黑屏）：

1. 红 / 绿 / 蓝 / 白 / 黑 纯色
2. SMPTE 式彩条
3. 32px checker
4. 1px 网格（用于判断是否几何模糊）

并安装：

```bash
apt-get install -y libdrm-tests   # 提供 modetest
```

运行时切到 preferred mode 测试：

```bash
modetest -s 55:1024x768 -P 34@40:1024x768@XR24
# 或封装脚本：
/usr/local/sbin/lpa-hdmi-mode.sh 1024x768
```

### 6.4 启动参数修正（已写入）

把强制 1080p 改为 EDID preferred：

```text
# armbianEnv.txt extraargs / extlinux APPEND
video=HDMI-A-1:1024x768@60
```

（去掉 `e` force，分辨率改为 1024x768）

重启后期望：

- fb0 / crtc mode = `1024x768@60`
- 文字边缘明显比 1080p 强制时清晰
- 若仍糊：再试 `1280x720`，或检查线材/显示器缩放菜单（1:1 / pixel-to-pixel）

## 7. 常用检查命令

```bash
# 节点状态
for n in display-subsystem vop@ff8f0000 vop@ff900000 gpu@ff9a0000 hdmi@ff940000; do
  echo -n "$n "; tr '\0' ' ' </sys/firmware/devicetree/base/$n/status; echo
done

# DRM / FB
ls -l /dev/dri /dev/fb0
cat /sys/class/drm/card0-HDMI-A-1/{status,enabled,dpms}
cat /sys/class/drm/card0-HDMI-A-1/modes
cat /sys/class/graphics/fb0/{name,virtual_size,modes}

# 当前时序
mount -t debugfs none /sys/kernel/debug 2>/dev/null
sed -n '/crtc\[40\]:/,/crtc\[53\]:/p' /sys/kernel/debug/dri/0/state | head -30

# 连接器/模式
modetest -c
modetest -p

# 时钟
grep -iE 'hdmi|vop|dclk|vpll' /sys/kernel/debug/clk/clk_summary | head -40
```

纯色自检脚本（板端）：

```bash
python3 - <<'PY'
import mmap, time
w,h=map(int, open('/sys/class/graphics/fb0/virtual_size').read().split(','))
stride=int(open('/sys/class/graphics/fb0/stride').read().strip() or w*4)
fb=open('/dev/fb0','r+b',buffering=0)
mm=mmap.mmap(fb.fileno(), stride*h, mmap.MAP_SHARED, mmap.PROT_WRITE|mmap.PROT_READ)
def fill(r,g,b):
    px=bytes((b,g,r,0xff)); line=(px*w)+b'\x00'*(stride-w*4)
    for y in range(h):
        mm[y*stride:(y+1)*stride]=line[:stride]
for c in [(255,0,0),(0,255,0),(0,0,255),(255,255,255),(0,0,0)]:
    fill(*c); time.sleep(2)
mm.close(); fb.close()
PY
```

## 8. 当前落盘文件

| 路径 | 作用 |
|---|---|
| `/boot/dtb/rockchip/rk3399pro-neardi-linux-lc110-base-display-conservative.dtb` | 当前使用的显示 DTB |
| `/boot/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb` | 原 base（保留，可回退） |
| `/boot/armbianEnv.txt` | `fdtfile=...display-conservative.dtb`，`video=HDMI-A-1:1024x768@60` |
| `/boot/extlinux/extlinux.conf` | 同上 FDT + APPEND |
| `/usr/local/sbin/lpa-hdmi-mode.sh` | 运行时切 mode：`1024x768\|1280x720\|1920x1080` |
| `/usr/local/sbin/lpa-hdmi-clock-fix.sh` | 开机触发完整 modeset，校正 65 MHz 时钟并锁 8 bpc |
| `/etc/systemd/system/lpa-hdmi-clock-fix.service` | HDMI 时钟修正服务 |
| `/root/display_enable_backup_<timestamp>/` | 完整备份 + `rollback.sh` |
| `/root/hdmi_phy_1024_backup_<timestamp>/` | PHY 表/1024 启动参数修改前备份 + 回退脚本 |

## 9. 后续可选

1. **确认 1024x768 清晰后固化**（已写 boot 参数，重启验证）
2. 若需要 1080p 且屏支持像素级显示：先在显示器 OSD 关缩放/开 1:1，再试
   `video=HDMI-A-1:1920x1080@60`（不要盲目加 `e`）
3. 需要 3D/GPU 时再单独启用 `/gpu@ff9a0000` + `panfrost`（与扫描输出解耦）
4. 验证稳定后，可把 conservative 变更合回 `kernel-6.18` 的 base/display 源 DTS 流水线

## 10. 黑屏续查（2026-07-20 同日）

用户反馈切换 1024x768 后“屏幕没有内容”。现场复查：

| 项 | 值 |
|---|---|
| DRM | `card0` + `HDMI-A-1 connected/enabled/dpms=On` |
| CRTC | active，mode 已设定 |
| 关键发现 | 启动后 **`/sys/class/graphics/fb0/blank = 4`（powerdown）** |
| getty@tty1 | active，但 fb 掉电时 tty 内容不可见 |

说明：内核 DRM 链路已起来，但 **framebuffer 被 blank/powerdown**，显示器侧就像“没内容”。
这与“之前 1080p 时能看到模糊字”不矛盾——当时至少未处于 blank=4，或用户看到的是短暂有内容窗口。

处理：

1. 排查时曾临时改回 `video=HDMI-A-1:1920x1080@60`；最终确认时钟问题后已恢复为 `1024x768@60`
2. 增加开机 unblank：
   - `/usr/local/sbin/lpa-hdmi-unblank.sh`
   - `lpa-hdmi-unblank.service`（enable）
   - `/etc/udev/rules.d/99-lpa-hdmi-unblank.rules`
3. 手动 `echo 0 > /sys/class/graphics/fb0/blank` 后，用 fb mmap 刷红/绿/蓝/白/棋盘格验证

若 unblank 后仍完全无画面，则更像 **线材/显示器输入源/物理接口** 或 HDMI PHY 电气问题；软件侧 CRTC active + blank=0 + 纯色写入已满足“应有信号”条件。

手动立刻恢复画面：

```bash
echo 0 > /sys/class/graphics/fb0/blank
chvt 1
printf '\033[2J\033[H HDMI LIVE\n' > /dev/tty1
```

## 11. PHY 表与实际时钟（2026-07-20）

厂商 4.4 DTB 的 `hdmi@ff940000` 携带以下 `rockchip,phy-table`，已同步到
`kernel-6.18/rk3399pro-neardi-linux-lc110-base.dts`，并写入板端当前
`base-display-conservative.dtb`（live DT 属性长度 80 字节）。

需要区分 DT 属性和驱动行为：当前 6.18.33 的 `dw_hdmi-rockchip` 不读取
该属性，RK3399 表是在驱动中静态编译的，且与上述值一致。对 1024x768 的
65 MHz 像素时钟会命中第一档 `74250000 / 0x8009 / 0x0004 / 0x0272`，
因此“缺属性”本身不是当前内核的 PHY 配置缺陷。

真正影响观感的是启动时 DRM 的 seamless 路径：状态报告 65 MHz，但实际
曾出现 `pll_vpll=54000000`、`dclk_vop0=61538462`。板端已安装并启用：

```text
/usr/local/sbin/lpa-hdmi-clock-fix.sh
lpa-hdmi-clock-fix.service
```

它通过一次临时 1920x1080 modeset 触发恢复到 1024x768 的真实 atomic
modeset，然后锁 `max bpc=8`、解除 fb blank，并检查 `dclk_vop0=65000000`。
重启实测服务成功，HDMI 为 `1024x768 / RGB / blank=0`，VPLL 与 dclk 均为
65 MHz，且没有 PHY/DRM 错误日志。

HDMI TX 寄存器也确认没有被切成灰度/YUV：`VP_PR_CD=0x40`（8 bpc）、
`VP_CONF=0x47`（RGB bypass）、`FC_AVICONF0=0x60`（RGB AVI）、
`FC_AVICONF2=0x08`（RGB full range）。因此若屏上仍只见黑白，下一步应
检查显示器 OSD 的色彩/单色模式、输入端口或线材，而不是继续改 PHY 表。

## 12. 一句话总结

- **无输出（首因）**：base DTB 关了 `display-subsystem` + VOP
- **恢复方式**：从当前已适配 DTB 只开显示链路（GPU 先不动）
- **发糊**：屏 EDID 首选 1024x768，强制 1080p 会被缩放
- **无内容（次因）**：fb0 `blank=4` 掉电空白；需 unblank 服务 + 确认显示器输入
- **当前默认 mode**：`video=HDMI-A-1:1024x768@60` + 开机 unblank + 时钟修正
- **PHY 表**：已补进源 DTS/当前 DTB；当前主线驱动使用等价的内置表
