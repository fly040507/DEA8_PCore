# 保留证据索引

2026-10-23清理后，仅保留以下验收/测量记录。

| 证据 | 位置 | 范围 |
|---|---|---|
| 当前完整七Job | [Summary](../Pcore/reports/compute/optimized7_banked/Summary.md) | 285942拍、6299量化＋157743 FP、55 QK/55 PV |
| 当前共享SFU | `Pcore/reports/compute/banked_modules/` | GELU/Up共享算术并发、真实workspace、背压 |
| 当前单PCore综合 | [utilization](resource_synth/pcore_banked_20261023/utilization.rpt) | 398DSP、71.5BRAM36等效、40URAM；LUT仍未达标 |
| GCore外推基线 | [Summary](resource_synth/gcore_ram_remap_20261019/Summary.md) | 2026-10-19 OOC面积，不是本轮GCore功能回归 |

PCore报告中的原始manifest和PASS保持字节不变；其RTL/TB/IP配置/ROM/gold等输入在清理前后逐项核对。外部Vivado安装路径和报告中的原机器路径是运行时记录，不作为新机器的构建入口。

已删除：被替代的PCore仿真、失败/中断运行、旧RoPE初始化方案综合、旧面积预览、历史服务器目录、旧图表与旧GCore后端报告。DCP、`ip_work`、波形、仿真快照和临时日志可按[复现说明](../docs/Verification.md)重建。

历史基线数字保留在最新汇总表。当前目录不混放旧方案的PASS来推断新版本通过。
