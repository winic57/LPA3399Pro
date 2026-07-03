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

---

## 12. 192.168.50.113 最新 NPU 固件测试前建议与执行计划

当前可以在 `192.168.50.113` 上测试 NPU，但不建议一开始就直接刷写或替换最新 NPU firmware。原因是同型号官方 4.4 对照机器 `192.168.50.129` 的可工作状态为：

```text
lsusb: 2207:1005
npu_transfer_proxy devices: PCIE
clk_wifi_pmu: 24000000
```

这说明 LPA3399Pro 官方路径很可能是 PCIe NPU，而不是单纯 USB NTB。因此在 `192.168.50.113` 上应先做无破坏性状态检查，确认当前链路类型和固件状态，再决定是否测试或替换最新固件。

建议检查命令：

```bash
uname -a
lsusb | grep -Ei '2207|rockchip|rk3xxx' || true
ps -ef | grep -Ei 'npu|rknn|transfer' | grep -v grep || true
/usr/bin/npu_transfer_proxy devices || true
ls -lh /usr/share/npu_fw/ || true
sha256sum /usr/share/npu_fw/* 2>/dev/null || true
dmesg | grep -Ei '2207|180a|1808|0019|1005|npu|rknn|ntb|pcie|firmware changed|SuperSpeed|error -71|disconnect' | tail -150
cat /sys/kernel/debug/clk/clk_wifi_pmu/clk_rate 2>/dev/null || true
cat /sys/kernel/debug/clk/rk808-clkout2/clk_rate 2>/dev/null || true
```

判断标准：

- 如果 `npu_transfer_proxy devices` 显示 `PCIE` 或 `USB_DEVICE`，说明 NPU 链路已通，优先测试 RKNN demo，不要急着刷固件；
- 如果停留在 `2207:180a`，再考虑使用主线 USB NTB 拉起路径；
- 如果官方 4.4 系统上显示 `PCIE`，应优先沿 vendor PCIe 路线排查 DTS、clock、GPIO、PCIe reset 和 `npu_powerctrl`；
- 无论 PCIe 还是 USB NTB，第一成功标准都是 `npu_transfer_proxy devices`，不是单独依赖 `ping 192.168.180.8`。

本轮计划先对 `192.168.50.113` 执行上述只读检查并保存结果。

### 12.1 192.168.50.113 只读检查结果记录

已执行只读 SSH 检查，完整日志保存到：

```text
/mnt/sdb3/LPA3399Pro/NPU_192.168.50.113_STATUS_20260703_181346.log
```

后续应基于该日志判断 `192.168.50.113` 当前是 `PCIE`、`USB_DEVICE`、`2207:1005` 还是停留在 `2207:180a`，再决定是否替换最新 NPU firmware。

### 12.2 192.168.50.113 只读检查结论

根据日志 `NPU_192.168.50.113_STATUS_20260703_181346.log`，`192.168.50.113` 当前状态如下：

```text
系统: Armbian 26.05.0 trixie / Linux 6.18.33
lsusb: 未发现 2207:* Rockchip NPU 设备
npu_transfer_proxy devices: 仅打印表头，无 PCIE / USB_DEVICE 设备
NPU tools: npu_powerctrl / npu_boot / upgrade_tool / npu_transfer_proxy 均存在
NPU firmware: /usr/share/npu_fw/ 下存在 MiniLoaderAll.bin、uboot.img、trust.img、boot.img、parameter.txt
clk_wifi_pmu: 24000000, 但 clk_enable_count=0
rk808-clkout2: 32768, clk_enable_count=1
PCIe sysfs: 只看到 regulator / pcie-phy，未看到可工作的 f8000000.pcie host 或 pcie_reset_ep
usb0: UP，但该机器同时有 Quectel 4G 模块，usb0 不能直接等价为 NPU RNDIS
```

结论：**目前不适合直接在 `192.168.50.113` 上刷写或替换最新 NPU firmware。** 当前 NPU 链路没有被 `npu_transfer_proxy` 识别，`lsusb` 也没有出现 `2207:*`，所以优先问题不是 firmware 版本，而是 NPU 上电/复位/clock/PCIe 或 USB 枚举链路未通。

下一步建议：

1. 先确认 `/usr/bin/npu_powerctrl` 的脚本内容和 `/usr/local/bin/npu_boot` 的实际执行效果；
2. 手动执行一次 `npu_powerctrl` 或 `npu_boot` 后立即观察 `lsusb`、`dmesg`、`npu_transfer_proxy devices`；
3. 若仍无 `2207:*`，优先修主控 DTS/clock/GPIO/PCIe reset，不要先刷 NPU firmware；
4. 若出现 `2207:180a`，再考虑 USB firmware 拉起路径；
5. 若出现 `2207:1005` 或 `npu_transfer_proxy devices` 显示 `PCIE` / `USB_DEVICE`，再进入 RKNN demo 或 firmware 替换测试。

---

## 13. 192.168.50.113 执行 npu_powerctrl / npu_boot 非刷写验证

已按上一节建议对 `192.168.50.113` 执行非刷写验证：

- 检查 `/usr/bin/npu_powerctrl`；
- 检查 `/usr/local/bin/npu_boot`；
- 执行 `/usr/bin/npu_powerctrl`；
- 执行 `/usr/local/bin/npu_boot`；
- 每一步后采集 `lsusb`、`dmesg`、`npu_transfer_proxy devices`、clock 状态。

完整日志保存到：

```text
/mnt/sdb3/LPA3399Pro/NPU_192.168.50.113_POWER_BOOT_TEST_20260703_181800.log
```

本次操作未执行 `upgrade_tool db/rs/uf/wl` 等固件下载或写入命令。

### 13.1 192.168.50.113 npu_powerctrl / npu_boot 验证结论

根据 `NPU_192.168.50.113_POWER_BOOT_TEST_20260703_181800.log`：

```text
执行前：lsusb 无 2207:*，npu_transfer_proxy devices 无设备
执行 /usr/bin/npu_powerctrl 后：lsusb 出现 2207:180a
执行 /usr/local/bin/npu_boot 后：仍为 2207:180a
npu_transfer_proxy devices：仍只有表头，无 PCIE / USB_DEVICE
npu_transfer_proxy 日志：服务可启动，但未发现 NTB 设备
```

这说明当前 `192.168.50.113` 上的 `npu_powerctrl` / `npu_boot` 只完成了 NPU 上电、24MHz clock 设置和 reset release，使 NPU 进入 Rockchip Maskrom/Loader USB 设备状态：

```text
2207:180a
```

但它没有继续把 NPU firmware 推送并跳转到可被 `npu_transfer_proxy` 识别的运行态。因此现在仍不建议直接刷写/覆盖 NPU 固件。下一步更合适的是“RAM boot / USB 拉起验证”：

1. 使用当前 `/usr/share/npu_fw/` 下的 `MiniLoaderAll.bin`、`uboot.img`、`trust.img`、`boot.img`；
2. 通过 `upgrade_tool db/rs` 将 NPU 从 `2207:180a` 拉起；
3. 观察是否从 `2207:180a` 断开并重新枚举为 `2207:1005` / `2207:1808` / `2207:0019`；
4. 再用 `npu_transfer_proxy devices` 判断是否出现 `PCIE` 或 `USB_DEVICE`。

如果 RAM boot 成功，再考虑是否要写入或替换持久化 firmware；如果 RAM boot 都失败，应先修主控 USB3/PCIe/reset/clock/DTS，而不是刷写。

### 14.1 192.168.50.113 RAM boot 验证结论

根据 `NPU_192.168.50.113_RAMBOOT_TEST_20260703_182211.log`，本次 RAM boot 验证结果如下：

```text
初始/上电后：2207:180a，upgrade_tool LD 显示 Mode=Maskrom
db MiniLoaderAll.bin：成功，db_rc=0
DB 后：2207:180a USB-MSC，upgrade_tool LD 显示 Mode=Loader
rs 0x00200000 0x08400000 0x02000000 uboot/trust/boot：超过约 2 分钟未返回，已终止 SSH 会话并清理远端可能残留的 upgrade_tool
终止后：仍停留 2207:180a USB-MSC / Mode=Loader
npu_transfer_proxy devices：仍无 PCIE / USB_DEVICE
```

结论：

1. `npu_powerctrl` 能把 NPU 拉到 Maskrom：`2207:180a`；
2. `upgrade_tool db MiniLoaderAll.bin` 能成功把 NPU 从 Maskrom 推到 Loader：`2207:180a USB-MSC` / `Mode=Loader`；
3. 当前 `upgrade_tool rs` 参数或 firmware 组合未能成功跳转到 NPU 运行态；
4. NPU 未重新枚举为 `2207:1005` / `2207:1808` / `2207:0019`；
5. `npu_transfer_proxy devices` 仍无设备。

下一步不应刷写 eMMC，而应优先确认官方 `rs` 地址和 firmware 组合：

- 从同型号 4.4 工作机器或官方脚本中提取 `upgrade_tool rs` 具体参数；
- 对比 `/usr/share/npu_fw/*` 和官方工作机器 `/usr/share/npu_fw/*` 的 sha256，必要时先用 factory 组固件做同样 RAM boot 测试；
- 检查 6.18.33 主控侧 USB3/PCIe/DTS 是否缺少 NPU 运行态重新枚举所需链路。

---

## 15. RS 参数/固件对比与 factory RAM boot 验证

已按上一节建议继续执行：

1. 从同型号工作机器 `192.168.50.129` 和当前测试机器 `192.168.50.113` 搜索 `upgrade_tool rs/db`、`npu_boot`、systemd/init、shell history 等引用；
2. 对比两台机器 `/usr/share/npu_fw/*` 的文件大小与 sha256；
3. 在 `192.168.50.113` 上使用 `*_factory` 固件组执行一次非写入 RAM boot 测试；
4. `rs` 使用 `timeout 90s` 限制，避免再次无限挂起；
5. 未执行 `upgrade_tool wl`、`upgrade_tool uf` 或任何写入 eMMC/分区的命令。

完整日志：

```text
/mnt/sdb3/LPA3399Pro/NPU_RS_PARAMS_AND_FW_COMPARE_20260703_183332.log
/mnt/sdb3/LPA3399Pro/NPU_192.168.50.113_FACTORY_RAMBOOT_TEST_20260703_183332.log
```

后续结论应基于上述日志判断：当前问题更像是 `rs` 地址/固件组合问题，还是 6.18.33 主控侧 USB3/PCIe/DTS 运行态链路问题。

---

## 16. 192.168.50.113 使用历史 RS 地址执行 RAM boot 验证

已按上一节建议在 `192.168.50.113` 上尝试历史记录中出现过的 RS 地址组合：

```bash
upgrade_tool rs 0x20000 0x20800 0x21000 uboot.img trust.img boot.img
```

本轮只执行：

- `npu_powerctrl`；
- `upgrade_tool db`；
- `upgrade_tool rs`；
- `npu_transfer_proxy devices` 与 `lsusb/dmesg/upgrade_tool LD` 状态采集。

未执行 `upgrade_tool wl`、`upgrade_tool uf`、`upgrade_tool di` 或任何 eMMC/分区写入命令。

完整日志保存到：

```text
/mnt/sdb3/LPA3399Pro/NPU_192.168.50.113_RS_0x20000_TEST_20260703_183809.log
```

---

## 17. 检查主线 6.18.33 下 NPU 运行态链路是否缺失

已按要求检查“是否是主线下链路缺失”。本轮对比了：

- 工作机 `192.168.50.129`：官方 4.4，`npu_transfer_proxy devices` 显示 `PCIE`；
- 测试机 `192.168.50.113`：主线 6.18.33，NPU 只能到 `2207:180a USB-MSC / Mode=Loader`；
- 本地 `current_dtb.dts` / `baseline_dtb.dts` 中的 NPU、PCIe、USB、clock、reset 相关节点；
- 两台机器的 live device tree、PCIe 枚举、USB controller、clock/regulator、kernel config/module、dmesg。

完整日志保存到：

```text
/mnt/sdb3/LPA3399Pro/NPU_MAINLINE_LINK_MISSING_CHECK_20260703_184215.log
```

---

## 18.1 最小化启用 PCIe host 测试中止：未找到远端启动 DTB

首次生成最小化 PCIe host DTB 成功，但在 `192.168.50.113` 上没有从 `/boot`、`armbianEnv.txt`、`extlinux.conf` 或常见启动配置中定位到当前启动 DTB，因此没有安装 DTB、没有重启，也没有改动远端启动文件。

补充排查日志：

```text
/mnt/sdb3/LPA3399Pro/NPU_PCIE_ENABLE_DTB_PATH_RECOVERY_20260703_184602.log
```
