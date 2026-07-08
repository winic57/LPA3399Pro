# NPU Debugging Log - 2026-07-08

## Current State Analysis

Based on the 0028 patch verification execution:
1. **MMIO Safety**: Probing all 8 descriptors with mask `0xff` (`dma_mmio_probe_limit=8`) completed with a graceful timeout (`RET=124`). The board did not lock up. This proves that configuring descriptors in MMIO is safe.
2. **One-Shot DMA Safety**: Allowing a single real DMA transaction (`dma_start_once_limit=1`) also safely timed out without hanging the system.
3. **Polling Fallback**: Enabling `dma_poll_done_fallback=1` did not cause crashes, but the RKNN initialization still timed out.

### Root Cause Assessment
Since single-transaction DMA is safe, the NPU/PCIe host does not crash on the first transaction. The timeout indicates that either:
* The NPU requires multiple sequential DMA transfers to finish handshake initialization.
* The physical IRQ is not triggering, and the poll done logic needs more attempts or does not catch the specific status.

---

## Action Plan & Execution

### Phase 1: Incrementally increase `dma_start_once_limit`
We will increase the limit of allowed real DMA starts step-by-step (`2`, `4`, `8`, and unlimited) while keeping `dma_disabled=0` to see if the RKNN initialization can progress further or if it hits a total lockup threshold.

### Phase 2: Analyze PCIe Transaction Log
We will inspect the transaction log `pcie_trx` to count how many DMA transfers actually get initiated when we raise the limit.
