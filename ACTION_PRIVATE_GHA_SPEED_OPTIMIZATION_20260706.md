# private 仓库 GitHub Action 编译变慢原因与优化建议

日期：2026-07-06

## 结论

`winic57/LPA3399Pro-private` 的 Action 比之前 public 仓库 `winic57/LPA3399Pro` 慢，核心原因是 GitHub-hosted runner 规格不同：

| 仓库 / run | runner 资源 | 总耗时 | 核心 build step |
|---|---:|---:|---:|
| `winic57/LPA3399Pro` #22 `28739624260` | `nproc=4`, RAM 15GiB | `40m45s` | `40m20s` |
| `winic57/LPA3399Pro-private` old `28743338777` | `nproc=2`, RAM 7.8GiB | `1h18m08s` | `1h17m49s` |
| `winic57/LPA3399Pro-private` deeper `28757045692` | `nproc=2`, RAM 7.8GiB | `1h02m49s` | `1h02m27s` |

当前 workflow/脚本使用：

```bash
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) Image
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) modules
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) dtbs
```

因此 public 仓库实际为 `-j4`，private 仓库实际为 `-j2`。慢点主要集中在 `Run build in Ubuntu 22.04 container`，不是 checkout、artifact、release 或 webhook。

## 优化建议

1. **使用 larger runner 或 self-hosted runner**
   - 最直接恢复 public #22 约 40 分钟级别的完整内核构建耗时。
   - 如果本地有稳定 x86_64 机器，可注册 self-hosted runner，并给 private repo 单独使用。

2. **增加 ccache/cache**
   - 对反复修改 patch / DTS 的增量编译有效。
   - 首轮完整编译收益有限，但后续迭代能减少大量重复编译时间。

3. **拆分 DTB-only 快速 workflow**
   - DTS/DTB 调试阶段无需每次完整编译 `Image + modules`。
   - 可新增 `ophub_6.18_dtb_only.yml`：下载/解压同版本内核、应用 patch、只执行 `make dtbs`、上传 `dtbs.tar.gz`。

4. **拆分 quick object/driver build workflow**
   - 对 `pcie-rockchip-host.c` / `pcie-rockchip-dma.c` 这类 patch，可先做对象级编译验证。
   - 通过后再触发完整 release build。

5. **精简 kernel config / modules 范围**
   - 当前 config 会编译大量与 RK3399Pro 无关的模块，例如 nouveau、多个非 Rockchip 平台驱动等。
   - 长期可维护一个 `config-6.18-lpa3399pro-minimal`，减少 modules 阶段耗时。

6. **避免无效触发完整构建**
   - 当前 6.18 workflow 已限制 path，但后续可进一步区分：
     - `kernel-6.18/*.dts` -> dtb-only
     - `kernel-6.18/*.patch` / `config-6.18` -> full build

## 推荐执行顺序

短期：

1. 保持当前完整 build workflow 不变，作为 release 构建。
2. 新增 DTB-only workflow，用于 PCIe/NPU DTB A/B 快速验证。
3. 在脚本中加入 ccache 缓存，减少重复构建耗时。

中期：

1. 准备 self-hosted runner 或 larger runner。
2. 维护 minimal config，减少 modules 编译量。
