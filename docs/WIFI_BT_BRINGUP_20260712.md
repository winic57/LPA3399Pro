# LPA3399Pro WiFi / BT bring-up (6.18.33)

## WiFi (RTL8821CS SDIO) — fixed path

Problems observed on amlogic image:

1. `uname -r` = `6.18.33` but modules live in `6.18.33-rk35xx-ophub`
2. `sdio-pwrseq` deferred: `pwrseq_simple: reset control not ready`
3. Root cause: `reset_gpio` not loaded → WiFi SDIO host `fe310000.mmc` never binds

Fix:

```bash
ln -sfn 6.18.33-rk35xx-ophub /lib/modules/$(uname -r)
depmod -a $(uname -r)
modprobe reset_gpio
# then rtw88 stack, or:
/usr/local/sbin/lpa-wifi-bt-bringup.sh
```

Expected:

- `mmc2: new UHS-I speed SDR50 SDIO card`
- `rtw88_8821cs` + firmware `rtw88/rtw8821c_fw.bin`
- `wlan0` up, `iw scan` lists APs

Packaged as:

- `/etc/modules-load.d/lpa-wifi-bt.conf`
- `/etc/modprobe.d/lpa-wifi-bt.conf`
- `/etc/systemd/system/lpa-wifi-bt-bringup.service`

## Bluetooth (RTL8821CS UART) — partial

DT node: `/serial@ff180000/bluetooth` (`realtek,rtl8821cs-bt`) was `status=disabled` on base DTB.

Kernel package note (critical):

```
CONFIG_BT_HCIUART=m
CONFIG_BT_HCIUART_SERDEV=y
# CONFIG_BT_HCIUART_RTL is not set   <-- blocks proper Realtek UART HCI
CONFIG_BT_RTL=m
```

Without `CONFIG_BT_HCIUART_RTL=y`, serdev Realtek path will not load `rtl_bt/rtl8821cs_fw.bin` correctly.

Userspace best-effort:

- install `bluez` (`bluetoothctl`, `hciattach`)
- hold BT enable/device-wake GPIOs (gpio2-28 / gpio2-26)
- `hciattach /dev/ttyS0 rtk_h5 115200 noflow` (may report unknown type depending on bluez)

Next kernel action: enable `CONFIG_BT_HCIUART_RTL=y` and ship DTB with bluetooth `status=okay`.
