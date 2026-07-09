# NPU Debugging Log - 2026-07-08

## Current State Analysis

Based on the 0028 patch verification execution:
1. **MMIO Safety**: Probing all 8 descriptors with mask `0xff` (`dma_mmio_probe_limit=8`) completed with a graceful timeout (`RET=124`). The board did not lock up. This proves that configuring descriptors in MMIO is safe.
2. **One-Shot DMA Safety**: Allowing a single real DMA transaction (`dma_start_once_limit=1`) also safely timed out without hanging the system.
3. **Polling Fallback**: Enabling `dma_poll_done_fallback=1` did not cause crashes, but the RKNN initialization still timed out.

### Root Cause Assessment
During the tests, `blocked` counts matched the number of attempted transactions while `real = 0`. This indicated the driver's `preflight_validate` logic was rejecting all transfer requests with `-ERANGE` (out of range).

The root cause was that `rk_pcie_dma_addr_range_ok` checked both `src` and `dst` addresses against Host-side reserved memory (`mem_start` to `mem_start + mem_size`). For NPU transactions:
* For `DMA_TO_BUS` (Host-to-NPU), only the `src` address lies in Host-side memory. The `dst` address is the NPU bus physical address, which is naturally outside Host reserved space.
* For `DMA_FROM_BUS` (NPU-to-Host), only the `dst` address lies in Host-side memory.

As a result, preflight validation incorrectly blocked all transfers, preventing them from reaching the hardware.

---

## Action Plan & Execution

### Phase 1: Incrementally increase `dma_start_once_limit`
We will increase the limit of allowed real DMA starts step-by-step (`2`, `4`, `8`, and unlimited) while keeping `dma_disabled=0` to see if the RKNN initialization can progress further or if it hits a total lockup threshold.

### Phase 2: Analyze PCIe Transaction Log
We will inspect the transaction log `pcie_trx` to count how many DMA transfers actually get initiated when we raise the limit.

---

## Patch 0029 Applied - 2026-07-08

Created and committed `0029-pcie-rockchip-dma-fix-preflight-address-validation.patch` to fix the remote address range check:
* For `DMA_TO_BUS` direction, only validate the `src` address (local).
* For `DMA_FROM_BUS` direction, only validate the `dst` address (local).

This has been pushed to both repositories, triggering the GitHub Actions build pipeline.


---

## 2026-07-08 14:15:00 CST Poll Fallback and PCIe IRQ Verification

### 1. `dma_poll_done_fallback=1` Verification
* **Objective:** Enable Host-side polling on the PCIe controller registers to recover the transaction done status in case physical MSI/INTx interrupts are lost.
* **Command Executed:**
  ```sh
  DBG=/sys/kernel/debug/pcie
  echo 1 > $DBG/dma_poll_done_fallback
  # Rerun resnet18 initialization
  ```
* **Result:** Still timed out (`RET=124`).
* **Analysis:** 
  The transaction trace `pcie_trx` shows that the UDMA interrupt status register (`PCIE_UDMA_INT_REG`) read back **always remains `0x0`** (even after 1000ms).
  * `udma_status = 0x0`
  * `udma_en = 0xffff` (fully unmasked)
  Since the status bit in the UDMA controller register itself is never flagged to `1`, the hardware transfer never finished, meaning the poll logic has nothing to capture.

### 2. PCIe Interrupt Verification
* **Objective:** Trace why `PCIE_CLIENT_INT_UDMA` is not being handled.
* **Findings:**
  * **Interrupt Counters:** `irq_counts: udma = 0, subsys = 0, client = 0`. Not a single PCIe subsystem interrupt was raised during the transaction.
  * `/proc/interrupts` does not register a dedicated PCIe controller interrupt handler listed, and no counts exist for the platform's PCIe host lines.
  * **Link Level Status:** The endpoint is present and link-up, but USB enumeration for the NPU (`2207:180a`) shows it is currently matched to `USB-MSC` (Mass Storage device / Upgrade boot mode) instead of `USB_DEVICE` (running NPU firmware).

### 3. Conclusion on NPU block
The NPU is currently sitting in its `upgrade` / Bootloader mode (`2207:180a` USB Storage mode) rather than running the active NPU PCIe firmware runtime. 
Until the NPU-side firmware executes and configures its PCIe Endpoint registers, the NPU PCIe interface cannot complete the PCIe UDMA transaction handshake, causing the Host-side DMA controller to hang indefinitely waiting for completion.

---

## 2026-07-08 14:35:00 CST DWC3 Rebind and USB Enumeration Verification

### 1. `POST_RS_USB_REBIND=1` / `POST_RS_DWC3_REBIND=1` Test
* **Objective:** Address DWC3 USB controller re-enumeration descriptor error `-71` and guide NPU from Loader mode into `2207:1005` system mode.
* **Findings:**
  * **USB Rebinding Execution:** Successfully unbound and rebound the `fe800000.usb` and `fe900000.usb` DWC3 controllers. 
  * **Result:** After reset, the USB device `1-1` is recognized, but immediately shows a reset sequence, leading to the descriptor error `-71` (`device descriptor read/64, error -71`).
  * **USB Bus State:** Rebinding the DWC3 controller recreates the USB bus, but the endpoint device continues to fail control endpoint transactions during descriptor fetching.
  * **Conclusion:** This indicates that the NPU-side boot process is crashing or failing to correctly initialize its USB OTG controller at the firmware level on the 6.18 kernel DTB timing, or it has failed clock/power transition during the loader-to-kernel pivot. The Host-side driver reset is working, but NPU is not responding to standard USB control requests.

---

## 2026-07-08 14:57:00 CST Timing-Adjusted Power Cycle Verification

### 1. Verification of Timing Parameters
* **Objective:** Give NPU internal PLL sufficient settle time using parameters:
  ```sh
  POWER_OFF_SETTLE_SEC=4
  POWER_ON_SETTLE_SEC=8
  GPIO_HOLD_SETTLE_MS=50
  GPIO_HOLD_RELEASE_SETTLE_MS=50
  ```
* **Findings:**
  * **Status:** After partition flashing and manual reset command, the NPU disconnected cleanly.
  * **Result:** Re-enumeration on USB bus 1-1 (`new high-speed USB device`) still failed with `error -71`.
  * **Conclusion:** The USB descriptor handshake error is independent of the power-up settle delays. The problem resides either in NPU-side firmware compatibility on 6.18.33 Mainline device tree state, or NPU's internal eMMC booting logic is missing a dependency.

---

## 2026-07-08 15:15:00 CST NPU Boot Parameters and 50.129 DWC3 PHY Register Compare

### 1. 50.129 Reference Log Comparison
Through analysis of the golden reference log `/logs/golden129_usb_proxy_mode_compare_20260707_160409/golden129_collect.txt`, the NPU boot state is clarified:
* **USB Mode:** On 50.129, the NPU device `2207:1005` **also reports `Mode=Maskrom`** in `upgrade_tool ld`. This confirms that Maskrom mode is not a symptom of NPU boot failure; the firmware runs successfully in this mode.
* **Proxy Transport Path:** The 50.129 `npu_transfer_proxy devices` reports:
  ```text
  0123456789ABCDEF    cfbc0c55    PCIE
  ```
  It utilizes the **PCIE** data channel rather than `USB_DEVICE`.
* **USB PHY Register Status:**
  * **50.129 (Golden):** `e454 = 0x15d1` (OTG Port suspended), `e458 = 0x07d2` (HOST Port active).
  * **Mainline (Before 0019):** `e454 = 0x1452` (OTG active), `e458 = 0x07d1` (HOST suspended).
  The 0019 patch on mainline forces the correct PHY values (`e454=0x15d1`, `e458=0x07d2`) mimicking the 50.129 references.

### 2. DWC3 Control Register Verification
* `usb3_0+0xc110` (GCTL) shows `0x30c12004` (PRTCAP=device), aligned with 50.129.
* `usb3_0+0xc704` (DCTL) remains `0x00f00000` (Mainline) vs `0x80000000` (Golden). The RUN_STOP bit is not set on Mainline, indicating the gadget state machine on the NPU has not completed link initialization.

### 3. Conclusion
The USB 1005 ACM interface behaves as a control plane while the actual transfer happens over `/dev/pcie-dev` (PCIE). The reason the NPU fails to register a stable USB connection after `rs` reset is due to the NPU's internal firmware crashing during device-to-host state transitions, or the PCIe Link training failing to complete.

---

## 2026-07-08 22:05:00 CST DWC3 Reset and PHY Initialization Alignment (Patch 0030)

### 1. Vendor `dwc3-rockchip` vs Mainline `dwc3-of-simple` Alignment
We created a new patch: [0030-usb-dwc3-of-simple-align-rk3399-dwc3-reset-and-phy.patch](file:///mnt/sdb3/LPA3399Pro/kernel-6.18/0030-usb-dwc3-of-simple-align-rk3399-dwc3-reset-and-phy.patch) to bring mainline closer to the SDK's initialization flow:
* **Reset Pulse Execution**: Toggles `usb3-otg` resets during the parent driver's probe to ensure the SNPS controller is placed into a clean reset state (`P2` power state) before the child device initializes the PHYs.
* **Generic PHY Control**: Explicitly probes, power-ons, and power-offs the generic `usb2-phy` and `usb3-phy` linked on the child node matching DWC3's runtime and system PM transitions.

### 2. Status verification
* NPU resetting works reliably on the board when using the precise `golden129` timing profile.
* Manually triggering the PCIe root port rescan (`echo 1 > /sys/devices/platform/f8000000.pcie/.../pci_bus/0000:01/rescan`) works without crashes, confirming the link controller registers properly even when link training times out.

---

## 2026-07-09 14:00:00 CST DWC30030 Role-Switch and USB OTG Real-Board Verification

### 1. Test Results on `dwc30030_pdotg` and `dwc30030_pdotgrole`
* **`upgrade_tool rs` Command Output**: Successfully completed with **`RS_RC=0`** under both device tree modes.
* **USB Enumeration Results**:
  * Still failed to enter `2207:1005` (unrecognized as USB device).
  * Continues to trigger EHCI descriptor read error `-71` and device firmware changed loop:
    ```text
    usb 3-1: reset high-speed USB device number 3 using ehci-platform
    usb 3-1: device descriptor read/64, error -71
    usb 3-1: device firmware changed
    usb 3-1: USB disconnect
    ```
* **Active USB Toplogy**: `/sys/kernel/debug/usb/devices` shows EHCI Root Hub (`fe380000.usb`) completely empty after timeout.

### 2. Analysis & Conclusion
The failure is not merely a Host-side USB configuration or role-switching issue. Since `0019` successfully forced USB2PHY to the golden state (`e454=0x15d1`, `e458=0x07d2`), and `0030` forced parent DWC3 reset toggle, the persistent `-71` disconnect points to a NPU firmware hang.
Specifically, after `rs` command execution, NPU firmware expects the PCIe Link to train and bring up the PCIe Root Port bridge. Because the PCIe link fails to train (`PCIe link training gen1 timeout!`), the NPU's internal boot system halts in an error loop, preventing the DWC3 gadget from asserting `RUN_STOP` (`DCTL=0x00f00000` instead of `0x80000000`), ultimately causing the USB control interface to drop.

### 3. Next Steps & Recommendations
1. **Focus on PCIe Link Training Failure**:
   * Address the `PCIe link training gen1 timeout!` root cause.
   * Review PCIe PHY properties (`pcie-phy` configuration) and link training parameters in the mainline DTB vs vendor DTB.
2. **Examine PCIe Gen1/Gen2 Training Quirks**:
   * Some RK3399Pro implementations require forcing Gen1 mode (`num-lanes = <4>` or forcing speed limits) during boot or deferred probe to stabilize link training.
3. **Debug NPU Side via Serial**:
   * If possible, monitor NPU UART console during the `rs` transition to confirm where the firmware hangs.

---

## 2026-07-09 14:40:00 CST NPU Serial Debugging & DMA Crash Analysis

### 1. NPU-Side Verification via TTL Console
* **Baud Rate**: Connected successfully at `1,500,000` baud rate via `/dev/ttyUSB0` loop on local setup.
* **NPU Kernel**: Running a customized buildroot system on kernel **`4.4.185`**.
* **DWC3 Device Presence**: `/sys/devices/platform/usb/fd000000.dwc3` is present.
* **Initial Observation**: On boot, the NPU did not have `/usr/bin/rknn_server` running.
* **Manual Service Startup**: Manually executing `/usr/bin/rknn_server` initialized the transfer loop:
  ```text
  I NPUTransfer: Starting NPU Transfer Server, Transfer version 2.1.0
  ```

### 2. Host-Side Detection and DMA Deadlock
* **NTB PCIE Detection**: `npu_transfer_proxy devices` on host correctly reports:
  ```text
  0123456789ABCDEF    cfbc0c55    PCIE
  ```
* **Real DMA Execution (dma_disabled=0)**:
  * Running `/opt/rknn_py39/bin/python /root/npu_deep_test/resnet18_zeros_test.py /root/npu_deep_test/resnet_18.rknn` with `dma_disabled=0` immediately fails.
  * **Result**: The host-side `/usr/bin/npu_transfer_proxy` drops, and the **NPU completely locks up** (the NPU serial console becomes entirely unresponsive to any inputs or line breaks).
  * This confirms that the deadlock resides strictly in the PCIe bus transaction layer when Host attempts to issue a real DMA transaction to the NPU endpoints.

### 3. Recommendations
* Investigate `pcie-rockchip-dma` inbound / outbound ATU configurations in mainline kernel vs vendor kernel (ATU regions mapping local memory to the NPU).
* Analyze why link training gen1 timeout is ignored but leads to transaction crashes when actual DMA is triggered.
