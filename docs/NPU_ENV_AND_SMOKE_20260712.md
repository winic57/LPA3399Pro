# NPU 环境补齐 + 完整冒烟（2026-07-12）

目标板：`root@192.168.50.17`（Armbian 6.18.33，SD）  
参考板：`neardi@192.168.50.129`（厂商 4.4.194，**无** `/opt/rknn_py39`）

## 结果总表

| 阶段 | 结果 |
|---|---|
| SD 根分区扩容 | **PASS** `2.9G → 14G`（GPT Fix + resizepart + resize2fs） |
| RKNN 用户态环境 | **PASS** 自建 `/opt/rknn_py39`（实际 Python 3.7.10） |
| USB loader / noep | **PASS** `boot_rc=0` |
| USB 枚举 `2207:0019` | **PASS** `usb_rc=0` |
| `npu_transfer_proxy` `USB_DEVICE` | **PASS** `proxy_rc=0` |
| RKNN resnet18 zeros | **PASS** `rknn_rc=0` |
| **SUMMARY** | **`boot_rc=0 usb_rc=0 proxy_rc=0 rknn_rc=0`** |

板端日志：`/var/log/npu-usb-pipeline/usb_loader_rs_rknn_20260712_222303.log`  
主机日志：`logs/npu_smoke_20260712_rknn_env/remote_console.log`

## 根分区扩容

原 GPT 未吃满 16G SD（root 仅 ~3.1GB）。在线：

```bash
printf 'Fix\n' | parted ---pretend-input-tty /dev/mmcblk1 print
parted -s /dev/mmcblk1 resizepart 2 100%
resize2fs /dev/mmcblk1p2
# df: /dev/root 14G, avail ~12G
```

## RKNN 环境来源

`.129` 登录成功（`neardi` / 用户提供密码，`sudo -s`），但厂商镜像**没有**历史 mainline 用的：

- `/opt/rknn_py39`
- `/root/npu_deep_test`

因此从本机 SDK 与 PyPI 组装（**未**生成新 `.img`）：

| 组件 | 来源 |
|---|---|
| Python | Miniconda3-py37_4.9.2-Linux-aarch64 → `/opt/rknn_py39` |
| rknn_toolkit_lite 1.7.1 | `LPA3399Pro-SDK-Linux-V3.0/external/rknn-toolkit/rknn-toolkit-lite/packages/...cp37...aarch64.whl` |
| numpy 1.21.6 | PyPI manylinux2014_aarch64 wheel |
| ruamel.yaml + clib | PyPI wheels |
| psutil 5.6.2 | 源码在板端用系统 gcc 编译（conda `compiler_compat/ld` 与 trixie glibc 不兼容，已 rename 规避） |
| `librknn_api.so` | SDK `RKNPUTools/.../Linux/lib64/` → `/usr/lib/` |
| 模型/脚本 | SDK `resnet_18.rknn` + `logs/npu_deep_test_20260705/resnet18_zeros_test.py` → `/root/npu_deep_test/` |

兼容路径：

```text
/opt/rknn_py39/bin/python -> python3.7
/opt/py39_standalone/python -> /opt/rknn_py39
```

主机暂存：`build_artifacts/rknn_runtime_stage_20260712/`

## 冒烟命令

```bash
export RUN_RKNN=1
export RKNN_CMD="/opt/rknn_py39/bin/python /root/npu_deep_test/resnet18_zeros_test.py /root/npu_deep_test/resnet_18.rknn"
/usr/local/bin/npu_usb_ntb_noep_rknn.sh
```

### RKNN 输出摘要

```text
RET load_rknn 0
RET init_runtime 0
RET outputs_len 1
RET out_shape (1, 1000) ...
DONE
RKNN_RC=0
SUMMARY boot_rc=0 usb_rc=0 proxy_rc=0 rknn_rc=0
```

USB：`2207:0019 Rockchip rk3xxx`；proxy：`USB_DEVICE`。

## 备注

1. 正式路径仍是 **USB NTB noep**；PCIe link training timeout 预期可忽略（`FORCE_USB_DEVICE=1` 会临时 hide `/dev/pcie-dev`）。
2. 新装 miniconda（py37_4.9.2）在 A53 上可用；更新的 Miniconda3 曾 `Illegal instruction`。
3. rknn-toolkit-lite 声明依赖 `numpy==1.16.3` / `ruamel.yaml==0.15.81`，实际用 1.21.6 / 0.17.21 导入与推理均通过。
4. `.129` 凭证已用于拉取对照；其上无 py39 环境可拷，后续勿再默认「从 129 rsync rknn_py39」。

## 对照历史

此前 `HW_CHECK_NPU_SMOKE_20260712.md`：`rknn_rc=127`（缺 `/opt/rknn_py39`）。  
本次补齐环境后 **全绿**。
