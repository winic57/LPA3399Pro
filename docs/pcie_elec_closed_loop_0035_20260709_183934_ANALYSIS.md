# 0035 PCIe PHY/LTSSM closed-loop sampling attempt

Time: 2026-07-09 CST
Target: 192.168.50.254, kernel 0035 (`74a42c6`)

## What was attempted

1. Rebooted `.254` to clean deferred PCIe state.
2. Confirmed after reboot:
   - `hw_started=0 probed=0`
   - `link_up=0 status1=0 debug0=0`
3. Started local TTL capture on `/dev/ttyUSB0 @ 1500000`.
4. Started a remote closed-loop script intended to collect:
   - PERST GPIO0_C4 state
   - RK3399 GRF PCIe PHY status (`GRF + 0xe2a4`)
   - PCIe APB LTSSM/status registers
   - clk_summary refclk state
   - golden129 USB loader -> rs -> deferred PCIe timing

## Result

The board became unreachable during the first `00_initial_after_host_reboot` snapshot, before golden129 NPU boot started.

Observed locally:
- `.254` ping/SSH lost and did not recover.
- ARP became incomplete on wired path.
- TTL capture stayed empty.

Most likely cause:
- The first snapshot used `/usr/local/bin/pcie_elec_sampler`, which read PCIe APB registers at `0xfd000000+` while `pcie_hw_started=0`.
- This appears unsafe on RK3399 mainline when the PCIe block is still deferred/uninitialized and can hang the host bus.

Important safety conclusion:
- Do **not** use raw `/dev/mem` reads of PCIe APB/core registers before the host driver marks the PCIe block started.
- Pre-deferred sampling must be limited to always-on domains such as GPIO0 and GRF/PMUGRF, or use kernel-side guarded sysfs/debugfs access.
- For LTSSM, use existing guarded `/sys/devices/platform/f8000000.pcie/pcie_link_state` or add a kernel-side trace buffer rather than user-space APB devmem.

## Current state

`.254` needs an external reboot/power-cycle before continuing.

## Safer next run design

- Before `pcie_deferred=1`: sample only
  - GPIO0 DR/DDR/EXT for PERST (`GPIO0_C4`, line 12)
  - GRF PCIe PHY status/laneoff/conf (`0xff77e214`, `0xff77e220`, `0xff77e2a4`)
  - clk_summary text for `clk_pciephy_ref`, `clk_wifi_pmu`
- During and after `pcie_deferred=1`:
  - sample `/sys/devices/platform/f8000000.pcie/pcie_link_state` for guarded LTSSM/status
  - optionally read APB via devmem only after `hw_started=1`, but prefer sysfs.
- Add kernel-side 0036 trace if higher resolution LTSSM sampling is required.
