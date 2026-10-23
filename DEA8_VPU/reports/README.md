# 保留证据索引

2026-10-23，无代价优化后的证据索引。旧基线保留供比较，不代表当前源码。

| 证据 | 位置 | 范围 |
|---|---|---|
| 当前完整七Job | [Summary](../Pcore/reports/compute/nocost_final7/Summary.md) | 285942拍，逐Job周期不变；6299量化＋157743 FP、55 QK/55 PV |
| 当前9项模块回归 | `Pcore/reports/compute/nocost_r2_modules/` | SFU共享/背压、QK数值、DEQ格式化、P-history/P-stream、GU/M2V、OACC、共享算术、RoPE |
| 当前3项邻接回归 | `reports/layer_native/` | `tb_qk_special_rows`、`tb_mask_profile`、`tb_pcore_cancel_native` |
| 当前单PCore综合 | [Summary](resource_synth/pcore_nocost_r2/Summary.md) | 104422LUT、398DSP、71.5BRAM36等效、40URAM |
| 综合试验/消融 | `resource_synth/pcore_nocost_r1/`、`pcore_nocost_ablate_sfu/`、`pcore_nocost_ablate_acc/` | 只有面积预览；源码与最终候选不同，无七Job验收主张 |
| 优化前七Job/面积 | `Pcore/reports/compute/optimized7_banked/`、`resource_synth/pcore_banked_20261023/` | 本轮比较基线285942拍/116270LUT，旧PASS不覆盖当前RTL |
| GCore外推基线 | [Summary](resource_synth/gcore_ram_remap_20261019/Summary.md) | 2026-10-19 OOC面积，不是本轮GCore功能回归 |

PCore原始manifest和PASS保持字节不变；当前七Job与9项模块回归共用118项输入清单哈希，最终综合89项输入逐项核对。消融后已恢复到最终七Job/综合完全相同的源码字节，无须把消融结果当作新的功能通过。外部Vivado路径是运行时记录，不作为新机器的构建入口。

前一轮已删除旧产物；本轮新DCP、`ip_work`及快照暂留，未重新做发布清理。`pcore_nocost_baseline`是用户叫停的未完成基线尝试，无PASS，不作任何面积依据；基线直接采用已有报告。`nocost_modules`为首批候选定向记录，不覆盖最终版本。

历史基线数字保留在最新汇总表。当前目录不混放旧方案的PASS来推断新版本通过。
