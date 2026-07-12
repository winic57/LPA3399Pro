# LPA3399Pro 硬件全面检查 + NPU 冒烟（2026-07-12）

目标：`root@192.168.50.17`  
系统：Armbian 6.18.33（SD 启动，`maxcpus=4`，`root=PARTUUID=c5c5cac8-...`）  
systemd：`running`

原始流水线日志：`/var/log/npu-usb-pipeline/usb_loader_rs_rknn_20260712_162231.log`

## 总表

| 子系统 | 结果 | 证据 / 说明 |
|---|---|---|
| 有线网卡 eth0 | **PASS** | YT8521 RGMII，Link Up 100Mbps/Full，ping 网关 0% loss，IP `192.168.50.17/24` |
| USB host | **PASS** | xHCI/EHCI/OHCI 多总线正常；外接 hub + UDisk `abcd:1234` 枚举成功 |
| WiFi | **FAIL** | 无 wlan；`nl80211 not found`；modules 路径/布局异常（见下） |
| 蓝牙 | **FAIL** | 无 `bluetooth.service` / `bluetoothctl`；BT 内核模块未按 uname 路径加载 |
| 4G 模块 | **FAIL / 未见设备** | `n4-pwren=hi`，`vcc-gnss=lo`；无 modem USB/tty/wwan；无 ModemManager |
| PCIe RC | **部分** | Root Port 存在，`/dev/pcie-dev` 有；link training gen1 timeout（noep 路径预期可不依赖 EP link） |
| NPU USB 冒烟 | **部分 PASS** | `boot_rc=0 usb_rc=0 proxy_rc=0`，出现 `2207:0019` + `USB_DEVICE`；**RKNN 失败 127**（缺 runtime） |

## 1. 有线网卡

- 驱动：`rk_gmac-dwmac` + PHY `YT8521 Gigabit Ethernet`
- `ethtool`: Link detected yes，Speed 100Mb/s Full
- `ping 192.168.50.1`: 3/3 成功（~2–3ms）
- dmesg：`Link is Up - 100Mbps/Full`

## 2. USB

`lsusb` 可见：
- 多个 root hub（USB2/USB3）
- Genesys hub `05e3:0610`
- 外接 U 盘 `abcd:1234`
- NPU 冒烟后：`2207:0019 Rockchip rk3xxx`（USB NPU 设备）

## 3. WiFi

现象：
- 无 `wlan*`
- `iw dev` → `nl80211 not found`
- 无 `/dev/rfkill`（检查时）
- dmesg：`platform sdio-pwrseq: deferred probe pending: pwrseq_simple: reset control not ready`

根因（模块树）：
- `uname -r` = **`6.18.33`**
- 模块目录 = **`/lib/modules/6.18.33-rk35xx-ophub`**（名称不匹配）
- 约 1434 个 `.ko` 全在 `extra/` 扁平目录，缺标准 `modules.dep` 布局时 `modprobe` 按 uname 路径失败

临时尝试：`ln -sfn 6.18.33-rk35xx-ophub /lib/modules/6.18.33` 后 `cfg80211/rfkill` 可加载，但 WiFi 驱动/SDIO pwrseq 仍未完成 bring-up。

## 4. 蓝牙

- 仅有 `libbluetooth3`，无完整 bluez 用户态（无 `bluetoothctl` / `bluetooth.service`）
- `modprobe bluetooth/hci_uart/btrtl` 因 modules 路径失败
- UART 节点存在：`/dev/ttyS0..S3`（硬件口在，软件栈未起）

## 5. 4G

- GPIO：`n4-pwren` out **hi**；`vcc-gnss` out **lo**
- 无 `ttyUSB*` / `cdc-wdm*` / `wwan*`
- `lsusb` 无 modem 类设备
- 无 `mmcli`

结论：电源脚有配置迹象，但模块未枚举（未上电完整链路 / 无驱动 / 硬件未插入-激活需再查）。

## 6. NPU 冒烟（`npu_usb_ntb_noep_rknn.sh`）

### 通过阶段

```text
SUMMARY boot_rc=0 usb_rc=0 proxy_rc=0 rknn_rc=127
proxy criterion met: USB_DEVICE
lsusb: 2207:0019 Rockchip rk3xxx
npu_transfer_proxy 进程在跑
```

即：**USB loader / noep 固件 / transfer proxy USB_DEVICE 路径成功**。

### 失败阶段（RKNN）

```text
RUN RKNN ... /opt/rknn_py39/bin/python /root/npu_deep_test/resnet18_zeros_test.py ...
bash: /opt/rknn_py39/bin/python: No such file or directory
RKNN_RC=127
```

镜像含 min NPU runtime（fw + upgrade_tool + proxy + 脚本），**未打包** golden 上的：
- `/opt/rknn_py39`
- `/root/npu_deep_test/*.rknn` 测试用例

因此不能把 rknn_rc=127 判为 NPU 硬件失败，而是 **用户态推理环境缺失**。

### PCIe 备注

PCIe link training 超时、link down；当前正式冒烟走 **USB NTB noep**，不依赖 PCIe EP 链路上来。

## 7. 优先修复建议

1. **modules 安装路径对齐**  
   - 安装到 `/lib/modules/$(uname -r)/` 或保证 `uname -r` 与目录名一致  
   - 生成完整 `modules.dep`（不要只丢 `extra/*.ko`）
2. **WiFi/BT**：路径修好后加载 `rtw88`/SDIO + bluez；处理 `sdio-pwrseq` deferred
3. **4G**：确认模组供电时序（`n4-pwren`/`vcc-gnss`）、USB/PCIe/UART 枚举与驱动
4. **NPU RKNN**：从 golden SD 同步 `/opt/rknn_py39` + `/root/npu_deep_test` 后再跑同一脚本

## 8. 本次命令入口

```bash
ssh root@192.168.50.17   # password 1234
/usr/local/bin/npu_usb_ntb_noep_rknn.sh
```


## 9. 2026-07-12 续：modules 修复并拉起 WiFi

### 已做

1. `ln -sfn 6.18.33-rk35xx-ophub /lib/modules/6.18.33`
2. `depmod -a 6.18.33`（生成/刷新 modules.dep）
3. 加载：`rfkill cfg80211 mac80211 rtw88_*`
4. 关键阻塞：`sdio-pwrseq` deferred = `reset control not ready`
5. 加载 **`reset_gpio`** 后：
   - `sdio-pwrseq` 绑定 `pwrseq_simple`
   - `fe310000.mmc` 绑定 `dwmmc_rockchip` → **mmc2**
   - SDIO 卡：`mmc2: new UHS-I speed SDR50 SDIO card`
   - 驱动：`rtw88_8821cs`，firmware 24.11.0
   - 出现 **`wlan0`**（MAC `60:fb:00:7e:d2:34`）

### WiFi 验证

- `rfkill`: phy0 Soft/Hard blocked = no
- `iw dev wlan0 scan` 可见周边 AP（2.4G/5G），例如：
  - `ChinaNet-3002-2` CH1 ~ -62 dBm
  - `ChinaNet-3002-5` CH40
  - `ChinaNet-3002-5G` CH40
- `nmcli`: wlan0 = wifi disconnected（未主动连 AP，属预期）

### 开机持久化（已写入 rootfs）

- `/etc/modules-load.d/lpa-wifi.conf`：`reset_gpio` + rtw88 栈
- `/etc/modprobe.d/lpa-wifi.conf`：`softdep` 保证 `reset_gpio` 先于 rtw88
- modules 软链：`/lib/modules/6.18.33 -> 6.18.33-rk35xx-ophub`

### 仍存问题

- 探测时有 `sdio read32/write8 failed (-110)`，但随后固件加载成功且可 scan
- 镜像侧应把 modules 安装到匹配 `uname -r` 的路径，并保证 `reset_gpio` 早期加载（或修 DT/依赖）
- 蓝牙/4G 未在本步处理

## 10. WiFi 修复入库 + 蓝牙处理（2026-07-12）

### WiFi
- 已验证：`reset_gpio` + modules 软链/depmod → `wlan0` + scan PASS
- 已打包到 amlogic `different-files/lpa3399pro`：
  - `etc/modules-load.d/lpa-wifi-bt.conf`
  - `etc/modprobe.d/lpa-wifi-bt.conf`
  - `usr/local/sbin/lpa-wifi-bt-bringup.sh`
  - `etc/systemd/system/lpa-wifi-bt-bringup.service`（enable）

### 蓝牙
- 已安装 bluez 5.82（主机 deb 侧载）
- 已加载 `bluetooth/btrtl/hci_uart`，`hci0` 可创建但 **init timeout**
- 根因：内核 **`# CONFIG_BT_HCIUART_RTL is not set`**，且 base DTB bluetooth 原为 disabled
- 板上 DTB 已改 bluetooth `status=okay`（需重启；仍缺 HCIUART_RTL）
- 下一步内核：打开 `CONFIG_BT_HCIUART_RTL=y` 后重编 6.18.33 包


## 2026-07-12 晚更新：NPU 环境已补齐并冒烟全绿

见 `docs/NPU_ENV_AND_SMOKE_20260712.md`。
`SUMMARY boot_rc=0 usb_rc=0 proxy_rc=0 rknn_rc=0`。
