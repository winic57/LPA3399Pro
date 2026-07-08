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
