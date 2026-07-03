# Fixed official 4.4 live DT export and PCIe/NPU diff

Time: 2026-07-03T20:14:05+08:00

This directory supersedes the broken official export in `npu_dt_diff_20260703_201038`. The earlier official DTS had only 4 lines because SCP from the 4.4 board was reset. This run retrieved the live DT tar via SSH cat, decompiled it locally, and regenerated focused diffs.

Key files:

- `official4_4_live.dts`
- `mainline6_18_live.dts`
- `mainline_vs_official_live_pcie_npu.filtered.diff`
- `stable_vs_bad_pcie.filtered.diff`
- `DECISIVE_SUMMARY.md`
