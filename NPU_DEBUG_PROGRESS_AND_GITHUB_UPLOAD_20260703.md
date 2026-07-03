# RK3399Pro NPU 调试进度、尝试记录与 GitHub 上传方法（2026-07-03）

## 1. 当前结论

截至 2026-07-03，开发板主控系统可通过 SSH 访问：

```text
root@192.168.50.113
password: 1234
kernel: Linux armbian 6.18.33
```

NPU 当前**尚未正常工作**。

实测现象：

```text
lsusb 中 NPU 仍为：2207:180a
未出现预期运行态：2207:1005
未出现 NPU 自身 RNDIS 网卡
192.168.180.8 ping 不通
```

注意：板上的 `usb0` 不是 NPU，而是 4G 模块 `2c7c:6005` 绑定的 `cdc_ether`。NPU 位于 USB Bus 003，当前是 `2207:180a` Loader/Maskrom/下载模式。

## 2. 关键认知修正

之前测试中存在一个重要误区：

* `upgrade_tool db` / `upgrade_tool rs` 会强行把 NPU 拉入 USB Loader/RAM 下载调试状态；
* 该状态通常表现为 `2207:180a`；
* 这不是最终正常运行状态；
* 正常路径应该是 NPU 从自身独立 eMMC 自动启动。

正确验证路径应为：

1. 将 `parameter.txt`、`uboot.img`、`trust.img`、`boot.img` 永久烧写到 NPU 独立 eMMC；
2. 主控侧只执行 `npu_powerctrl` 复位/上电；
3. 不再执行 `upgrade_tool db` 或 `upgrade_tool rs` 作为启动验证；
4. 等待 NPU 自启动；
5. 主控侧观察是否出现 `2207:1005` 或 RNDIS 网卡；
6. 验证 `192.168.180.8` 是否可 ping 通。

## 3. 已完成的修改

### 3.1 NPU RNDIS 固定 IP 启动脚本

在 SDK NPU rootfs overlay 中新增了启动脚本，用于在 NPU 内部 Linux 启动后自动给 USB/RNDIS 接口设置固定 IP：

```text
LPA3399Pro-SDK-Linux-V3.0/npu/buildroot/board/rockchip/rk3399pro_npu/fs-overlay-64/etc/init.d/S51usb-rndis-ip
```

脚本逻辑：

```text
等待 usb0 / rndis0 / eth0 任一接口出现；
配置 NPU 侧 IP：192.168.180.8/24；
默认网关：192.168.180.1；
```

为了纳入主仓库，已生成 patch 文件：

```text
patches/npu/0001-rk3399pro-npu-rndis-static-ip-overlay.patch
```

### 3.2 GitHub Actions NPU 编译入口

已新增：

```text
.github/workflows/npu_kernel.yml
kdevbuild/npu_kernel.sh
```

功能：

* 支持 GitHub Actions 手动触发；
* 默认构建 NPU kernel；
* 可通过 `build_targets` 指定完整构建，例如：

```text
kernel ramboot firmware updateimg
```

* 若仓库未包含完整 SDK，可通过 `npu_sdk_url` 指定 SDK tarball。

## 4. 已构建并推送到开发板的 NPU 镜像

本地构建命令：

```bash
cd /mnt/sdb3/LPA3399Pro/LPA3399Pro-SDK-Linux-V3.0/npu
./build.sh ramboot
./build.sh firmware
./build.sh updateimg
```

生成文件：

```text
/mnt/sdb3/LPA3399Pro/LPA3399Pro-SDK-Linux-V3.0/npu/rockdev/update.img
```

构建结果：

```text
size: 35834328 bytes
sha256: f781b2265804d87a1133d6c008800df916eaa91276921a39e373067755737a6d
```

已推送到开发板：

```bash
sshpass -p 1234 scp \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/tmp/lpa3399pro_known_hosts \
  /mnt/sdb3/LPA3399Pro/LPA3399Pro-SDK-Linux-V3.0/npu/rockdev/update.img \
  root@192.168.50.113:/root/npu_update_emmc_rndis_20260702.img
```

板端校验：

```bash
sshpass -p 1234 ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/tmp/lpa3399pro_known_hosts \
  root@192.168.50.113 \
  'ls -lh /root/npu_update_emmc_rndis_20260702.img && sha256sum /root/npu_update_emmc_rndis_20260702.img'
```

板端结果：

```text
/root/npu_update_emmc_rndis_20260702.img
sha256: f781b2265804d87a1133d6c008800df916eaa91276921a39e373067755737a6d
```

## 5. 当前板端验证结果

执行检查：

```bash
sshpass -p 1234 ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/tmp/lpa3399pro_known_hosts \
  root@192.168.50.113 '
    uname -a
    lsusb
    ip -br link
    ip -br addr
    ping -c 3 -W 2 192.168.180.8 || true
    dmesg | grep -Ei "2207|180a|1005|rndis|cdc|acm|npu|usb 3-1|gadget" | tail -120 || true
  '
```

结果摘要：

```text
Bus 003 Device xxx: ID 2207:180a Fuzhou Rockchip Electronics Company
未出现 2207:1005
ping 192.168.180.8 失败
```

进一步确认 `usb0` 来源：

```bash
readlink -f /sys/class/net/usb0/device
basename "$(readlink -f /sys/class/net/usb0/device/driver)"
ethtool -i usb0
lsusb -t
```

结论：

```text
usb0 绑定 cdc_ether
路径在 usb7/7-1/7-1.1
对应 4G 模块 2c7c:6005
不是 NPU
```

NPU 实际在：

```text
Bus 003 Port 001
ID 2207:180a
Driver=[none]
```

## 6. 只用 npu_powerctrl 复位的验证

执行：

```bash
sshpass -p 1234 ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/tmp/lpa3399pro_known_hosts \
  root@192.168.50.113 '
    /usr/bin/npu_powerctrl off || true
    sleep 2
    /usr/bin/npu_powerctrl on || true
    for t in 5 10 20 30 45; do
      sleep $t
      echo "--- after additional ${t}s ---"
      lsusb | grep -E "2207|2c7c" || true
      ip -br addr | grep -E "usb|rndis|eth0|wlan0" || true
      ping -c 1 -W 2 192.168.180.8 || true
      dmesg | grep -Ei "2207|180a|1005|rndis|cdc|acm|npu|usb 3-1|gadget" | tail -30 || true
    done
  '
```

结果：

```text
等待到 45 秒后，NPU 仍为 2207:180a
未变为 2207:1005
192.168.180.8 仍不可达
```

另外发现：

```bash
cat /usr/bin/npu_powerctrl
```

内容实际为：

```sh
#!/bin/sh
case "$1" in
    -i)
        /usr/local/bin/npu_boot
        ;;
    -o)
        /usr/local/bin/npu_boot
        ;;
    *)
        /usr/local/bin/npu_boot
        ;;
esac
```

也就是说当前 `npu_powerctrl off/on` 参数并未真正区分上下电，只是统一调用 `/usr/local/bin/npu_boot`。

## 7. 下一步调试建议

### 7.1 确认 NPU eMMC 是否真的烧写成功

当前最需要确认的是：

```text
NPU 独立 eMMC 内是否真的存在正确的 parameter、uboot、trust、boot 分区内容。
```

建议在板端查找已有刷写脚本：

```bash
sshpass -p 1234 ssh root@192.168.50.113 '
  find /usr /root /opt -maxdepth 4 -type f \( -name "*npu*" -o -name "*flash*" -o -name "*.sh" \) -print
'
```

重点关注是否有不依赖 `db/rs` 的 eMMC 写入流程。

### 7.2 谨慎使用 upgrade_tool

不要把 `upgrade_tool db` / `rs` 作为启动验证。

可以只用于确认设备状态或读取信息，例如：

```bash
upgrade_tool LD
```

但如果需要写 eMMC，应明确写入分区后断开 Loader 流程，再走 `npu_powerctrl` 自启动验证。

### 7.3 检查 `/usr/local/bin/npu_boot`

```bash
sshpass -p 1234 ssh root@192.168.50.113 '
  ls -lh /usr/local/bin/npu_boot
  file /usr/local/bin/npu_boot
  strings /usr/local/bin/npu_boot | head -100
'
```

判断它到底是：

* 只拉 GPIO/时钟；
* 还是会触发 Loader；
* 是否会间接调用 `upgrade_tool`；
* 是否导致 NPU 一直留在 `2207:180a`。

### 7.4 检查主控侧 USB/NPU 日志

```bash
dmesg -w | grep -Ei '2207|180a|1005|npu|usb 3-1|rndis|cdc|acm'
```

期望正常路径：

```text
2207:180a 短暂出现或不出现；
随后设备重枚举为 2207:1005 或 RNDIS/CDC 网卡；
出现可配置的 NPU USB 网络接口；
ping 192.168.180.8 成功。
```

当前异常路径：

```text
长期停留 2207:180a；
或反复 USB disconnect / device descriptor read error -71；
无 2207:1005；
无 NPU RNDIS。
```

### 7.5 检查 PCIe/参考时钟影响

历史记录显示：

* 主控启用 PCIe 会导致 6.18.33 内核 hang/死机；
* 禁用 PCIe 后主控稳定，但 NPU 可能缺少某些硬件握手；
* NPU 参考时钟 GPIO0_A2 / `npu-ref-clk` 之前已经被识别为关键项。

后续可继续核查：

```text
当前 DTB 是否仍包含 npu-ref-clk；
PCIe disabled 是否导致 NPU 无法从 eMMC 完整启动；
是否需要只保持 REFCLK 而不初始化 PCIe 控制器。
```

## 8. GitHub 上传方法

目标仓库：

```text
git@github.com:winic57/LPA3399Pro.git
```

Deploy Key：

```text
/home/henry/.ssh/ai_deploy_key1
```

代理：

```text
192.168.50.62:7890
```

### 8.1 查看状态

```bash
cd /mnt/sdb3/LPA3399Pro
git status --short
```

### 8.2 只添加需要提交的文件

示例：

```bash
git add \
  6.18.33_GMAC_PATCH_COMPILE_VERIFY_20260618.md \
  NPU_DEBUG_PROGRESS_AND_GITHUB_UPLOAD_20260703.md \
  .github/workflows/npu_kernel.yml \
  kdevbuild/npu_kernel.sh \
  patches/npu/0001-rk3399pro-npu-rndis-static-ip-overlay.patch
```

不要误提交这些临时目录/日志，除非明确需要：

```text
LPA3399Pro-SDK-Linux-V3.0/
/tmp_unpack/
lpa3399pro-armbian/
ttl_logs/*.log
logs/boot_ttl_capture.log
```

### 8.3 提交

```bash
git diff --cached --stat
git diff --cached --check
git commit -m "docs: record npu debug progress and upload steps"
```

### 8.4 用指定 key 和代理推送

```bash
GIT_SSH_COMMAND="ssh -i /home/henry/.ssh/ai_deploy_key1 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ProxyCommand='nc -x 192.168.50.62:7890 %h %p'" \
  git push origin HEAD:master
```

如果提示远端有新提交：

```bash
GIT_SSH_COMMAND="ssh -i /home/henry/.ssh/ai_deploy_key1 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ProxyCommand='nc -x 192.168.50.62:7890 %h %p'" \
  git pull --rebase origin master

GIT_SSH_COMMAND="ssh -i /home/henry/.ssh/ai_deploy_key1 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ProxyCommand='nc -x 192.168.50.62:7890 %h %p'" \
  git push origin HEAD:master
```

如果 rebase 被本地无关修改阻塞，例如 `logs/boot_ttl_capture.log`：

```bash
git stash push -m keep-local-boot-ttl-log -- logs/boot_ttl_capture.log

GIT_SSH_COMMAND="ssh -i /home/henry/.ssh/ai_deploy_key1 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ProxyCommand='nc -x 192.168.50.62:7890 %h %p'" \
  git pull --rebase origin master

GIT_SSH_COMMAND="ssh -i /home/henry/.ssh/ai_deploy_key1 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ProxyCommand='nc -x 192.168.50.62:7890 %h %p'" \
  git push origin HEAD:master

git stash pop
```

## 9. 最近一次已推送的提交

上一轮已经推送到 GitHub 的提交：

```text
87a1867 npu: add eMMC RNDIS boot fix and CI
```

包含：

```text
.github/workflows/npu_kernel.yml
kdevbuild/npu_kernel.sh
patches/npu/0001-rk3399pro-npu-rndis-static-ip-overlay.patch
6.18.33_GMAC_PATCH_COMPILE_VERIFY_20260618.md 更新
```

## 10. 当前待解决问题

1. NPU 长期停留在 `2207:180a`；
2. 未从 eMMC 自启动到 `2207:1005` 或 RNDIS；
3. `192.168.180.8` 不通；
4. `/usr/bin/npu_powerctrl` 不是严格意义上的 off/on 控制，实际只调用 `/usr/local/bin/npu_boot`；
5. 需要确认 NPU eMMC 是否被正确烧入，以及 `npu_boot` 是否把 NPU 拉进 Loader 模式。

---

## 11. 2026-07-03 转向 mainline USB NTB 路线后的仓库改动

根据 `NPU_MAINLINE_USB_NTB_ANALYSIS_20260703.md`，当前 NPU 调试主线已从“eMMC 自启动 + RNDIS 固定 IP”调整为“mainline USB NTB + npu_transfer_proxy”：

- 不再把 `ping 192.168.180.8` 作为第一成功标准；
- 优先验证 `npu_transfer_proxy devices` 是否出现 `USB_DEVICE`；
- 使用 USB 版 `npu_fw`，通过 `upgrade_tool db/rs` 或 vendor `npu_boot` 将 NPU 从 `2207:180a` 拉起；
- NPU 内部 Linux 默认暴露 FunctionFS NTB，而不是 RNDIS 网卡。

本次新增/修改准备同步到 GitHub：

```text
NPU_MAINLINE_USB_NTB_ANALYSIS_20260703.md
tools/npu_mainline_usb_ntb_boot.sh
tools/npu_mainline_usb_ntb_check.sh
patches/npu/0002-rk3399pro-npu-mainline-usb-ntb-default.patch
kdevbuild/npu_kernel.sh
```

新增验证命令示例：

```bash
# 仅检查当前枚举/日志/proxy 状态
sudo ./tools/npu_mainline_usb_ntb_check.sh

# 使用 /usr/share/npu_fw 下 USB firmware 拉起 NPU
sudo FW_DIR=/usr/share/npu_fw ./tools/npu_mainline_usb_ntb_boot.sh
```

成功标准：

```bash
/usr/bin/npu_transfer_proxy devices
```

输出中出现：

```text
USB_DEVICE
```

### 11.1 同型号官方 4.4 机器 SSH 对照结果

已通过 SSH 检查 `192.168.50.129`：

```text
内核: Linux 4.4.194
lsusb: 2207:1005
npu_transfer_proxy devices: PCIE
clk_wifi_pmu: 24000000
/usr/share/npu_fw/: MiniLoaderAll.bin, uboot.img, trust.img, boot.img, parameter.txt
```

这个结果修正了本轮判断：同型号官方系统可工作状态下 `npu_transfer_proxy devices` 显示的是 `PCIE`，所以后续主控 DTS/电源/clock 仍需要保留 PCIe 分支验证；但无论 USB NTB 还是 PCIe，第一验证标准仍是 `npu_transfer_proxy devices`。
