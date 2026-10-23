# 当前资源口径

更新：2026-10-23。仅统计完整GCore及单个完整PCore的OOC综合；器件为U50 `xcu50-fsvh2104-2-e`。

## 完整模块与八核外推

| 资源 | 当前PCore | GCore基线 | GCore＋8×PCore | U50容量 | 占比 |
|---|---:|---:|---:|---:|---:|
| LUT | 104422 | 29782 | 865158 | 871680 | 99.25% |
| FF | 142551 | 33198 | 1173606 | 1743360 | 67.32% |
| DSP | 398 | 109 | 3293 | 5952 | 55.33% |
| BRAM36等效 | 71.5 | 79 | 651 | 1344 | 48.44% |
| URAM | 40 | 24 | 344 | 640 | 53.75% |

- PCore：2026-10-23实测；61 RAMB36＋21 RAMB18，blackbox=0
- GCore：2026-10-19 RAM映射基线；77 RAMB36＋4 RAMB18，blackbox=0
- 本轮无代价优化：116270→104422 LUT，净降11848（10.19%）；FF减少222，DSP/BRAM/URAM不变；七Job总周期及逐Job周期不变
- 本轮不强求系统LUT降至70%；当前外推距该目标仍差254982 LUT，后续另行决定资源交换或架构措施
- 外推不含平台shell、HBM/PCIe物理控制器及跨核互连开销；不等于八核联合综合或可布通结论

原始证据：[PCore](../reports/resource_synth/pcore_nocost_r2/utilization.rpt)、[层次表](../reports/resource_synth/pcore_nocost_r2/utilization_hier.rpt)、[RAM表](../reports/resource_synth/pcore_nocost_r2/ram.rpt)、[试验对比](../reports/resource_synth/pcore_nocost_r2/Summary.md)、[GCore基线](../reports/resource_synth/gcore_ram_remap_20261019/Summary.md)。GCore生产清单37项与优化前字节一致，沿用面积基线，没有重新测GCore。

## 算术与存储核对

| 项目 | 当前实测/实现 |
|---|---|
| Matrix | 320 DSP：MXU256、DEQACC64 |
| 非矩阵 | 78 DSP：MUL16/ADD16、QK SUB1、EXP4、RECIP1 |
| M2V | 16个RAMB18＝8 BRAM36等效；16-bank 256×32 SDP |
| KV sender | 2 BRAM36；128×144，双Tile填充/发送 |
| scaled OACC | 16 URAM；26pair×16tile，两行奇偶银行 |
| raw OACC | 16 URAM；双page，各page独立行奇偶 |
| RoPE | 4 URAM；外部显式预载、双端口读 |
| 其他全核存储 | 61.5 BRAM36等效＋4 URAM，含FACC/QOZ/PBUF/算术表等 |

主要专用存储的10 BRAM36等效＋36 URAM不是整个PCore的RAM总数。α×l复用MUL16，QK差值保留独立SUB；EXP/RECIP资源按综合网表统计，不能都按普通MUL的2DSP计。

## 测量与清理边界

- 只执行`synth_design -mode out_of_context`；4ns为测量约束，不是250MHz签核
- `resource_preview=true`、`simulation_gate_passed=false`表示综合没有执行完整八核仿真准入，不否定另行完成的单核七Job
- 保留原始报告、PASS、输入哈希和日志；本轮DCP和`ip_work`暂留用于归因，属于可重建产物
- 层次LUT包含跨模块共享/吸收，不能把父子节点混加，也不能把`ctrl`层次缩小当作单独可兑现收益；以完整PCore总表为准
