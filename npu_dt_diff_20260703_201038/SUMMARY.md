# NPU DT diff summary: official 4.4 vs mainline 6.18.33

Time: 2026-07-03T20:12:01+08:00

## Scope

- Official working board: `192.168.50.129`, kernel 4.4.194, `npu_transfer_proxy devices` shows `PCIE`, `lspci` enumerates RK3399 root port and RK1808 endpoint.
- Mainline test board: `192.168.50.113`, kernel 6.18.33, restored stable DTB, PCIe host disabled and no NPU PCIe runtime link.

## Important runtime evidence

Official 4.4:

- live DT: `pcie@f8000000/status = okay`
- `lspci`: root port `1d87:0100` and endpoint `1d87:1808 RK1808 Neural Network Processor Card`
- root port link: 2.5GT/s, width x2
- `npu_transfer_proxy devices`: `PCIE`

Mainline 6.18:

- live DT: `pcie@f8000000/status = disabled`
- no `/sys/devices/platform/f8000000.pcie`
- no `lspci` enumeration
- `npu_transfer_proxy devices`: empty ntb list

## Key files

- `official4_4_live.dts`
- `mainline6_18_live.dts`
- `mainline_stable_boot.dts`
- `mainline_bad_pcie_boot.dts`
- `mainline_vs_official_live_pcie_npu.filtered.diff`
- `stable_vs_bad_pcie.filtered.diff`
- `official4_4_live.dts.relevant.txt`
- `mainline6_18_live.dts.relevant.txt`

## Immediate conclusion

The previous failed DTB is confirmed as a status-only change: stable vs bad diff changes only `pcie@f8000000/status` from `disabled` to `okay`. Because that DTB caused boot/network failure, PCIe enablement requires additional board-specific migration from the official 4.4 tree.

## Recommended next action

Build a separate test DTB and extlinux menu entry after manually reviewing the filtered diff. Do not overwrite the default stable DTB.
