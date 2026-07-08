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

