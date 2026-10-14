# DEQACC V2 A-only locality：快速结果

2026-10-14。**布局布线和七级/逐lane时序已完成。A0/A1/A3内部路由改善，A2和Q1退化；当前版本不采用为默认物理基线。**按用户要求停止长统计，仅汇总已完成结果，不重跑综合/P&R。

## 实验做了什么

- 输入仍为同一个pre-Pblock综合DCP：`v2_route_20261013/synthesized.dcp`，没有改RTL、算法、级数、时钟或实现指令
- 32个互不重叠的硬A区域，包含本lane FPADD、C寄存和对应forward/控制/old mask叶；量化Q、完整RAM、中央控制自由放置
- `IS_SOFT=false`、`EXCLUDE_PLACEMENT=true`、`CONTAIN_ROUTING=false`，禁止其它逻辑进入A区以留余量；与No-Pblock的差异包含该资源预留，不能只归因于lane局部化
- 每区17×23=391个CLB站点，共预留12,512；根据No自然布局A逻辑足迹计算的预算占用39.64%～57.80%，不是最终实际占用
- 原综合网表内的old mux可能已吸收到FPADD组合逻辑；本轮不移动或重写RTL，不宣称所有中央选择链均已收进A区

工具：Vivado2022.2，U50 -2-e、4ns、BUFG/全接口观测壳；opt → place Explore → phys_opt AggressiveExplore → route Explore，均经cmd/settings64官方入口。

## 总体结果

| 指标 | No-Pblock | A-only Hard |
| --- | ---: | ---: |
| WNS | −0.222ns | **−0.442ns** |
| TNS | −61.556ns | **−398.074ns** |
| setup失败端点 | 842 | **2,224** |
| WHS / THS | 0.004 / 0ns | 0.011 / 0ns |
| 布线错误/overlaps | 0 / 0 | 0 / 0 |

本轮内部网络全部布通、hold无失败，但4ns setup失败；OOC外部接口未作板级签核。流程成功不等于timing PASS。

## 是否达到A路由接近2ns

下表从本lane顺序元件到本lane阶段端点取最差Slack路径，统计32lane路由均值/最大值。A0可含本laneQ1或feedback输入，已排除中央ACC/control起点；不称为固定同pin路线比较。

| 级 | No route均值 | A-only route均值 | No最大 | A-only最大 | A-only ≤2.1ns lane数 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Q1 | 2.2709 | **2.5755** | 2.470 | 2.788 | 0/32 |
| A0 | 2.1610 | **1.9698** | 2.633 | 2.694 | 23/32 |
| A1 | 2.2879 | **2.0947** | 2.821 | 3.022 | 18/32 |
| A2 | 2.4205 | **2.5229** | 2.872 | 3.045 | 0/32 |
| A3 | 2.6115 | **2.3183** | 3.379 | 2.843 | 9/32 |
| C | 1.0823 | **0.8052** | 1.610 | 1.215 | 32/32 |

A2内部失败lane从5增至11。只A0/A1均值接近2ns，不满足A0～A3整体目标；不能用均值遮盖最差lane。

## 边界连接仍然偏重

各类最差Slack路径的route列（起止点可变化）：

| 路径 | No route | A-only route | A-only total / slack |
| --- | ---: | ---: | --- |
| Q1数据→A0 | 2.409 | **2.694** | 3.442 / +0.184 |
| 中央forward控制→A0 | 3.056 | 3.029 | **4.303 / −0.433** |
| ACC读/选择→A0 | 2.549 | **3.248** | **4.229 / −0.365** |
| A3反馈→A0 | 2.507 | **2.153** | 3.053 / +0.735 |
| C反馈→A0 | 2.330 | **1.998** | 2.773 / +0.937 |
| A3数据→ACC写口 | 2.203 | **3.038** | 3.273 / +0.333 |

局部反馈环缩短，但RAM连接、Q1及中央控制链没有得到同等改善。硬区域和资源预留限制Q/ACC靠近A区，是合理解释之一；本轮尚未完成最终位置/密度census，不能把推测称为已证实因果。

## 已有文件与未完成项

结果：[Pcore/reports/v2_aonly_20261014/](Pcore/reports/v2_aonly_20261014/)

- `routed.dcp`、`timing_summary_postroute.rpt`：实现与总时序
- `path_delays.csv`、各类top10：全部七级、顺向、feedback、ACC及32lane数据
- `lane_internal_timing.csv`、`quick_internal_comparison.csv`：No/A-only逐lane对照与快速汇总
- `A_region_plan.csv`、`natural_A_resources.csv`：32区规划和No基线资源/位置
- `source_sha256.csv`、`experiment_hashes.csv`：功能源码与输入DCP版本

实际区域密度/成员位置报告`A_region_actual.csv`尚未完成（空文件），长报告调用已中止；原规划百分比不能替代实际值。本轮按用户最新指令不再补耗时census，没有对32lane调用详细utilization。七级route与内部统计为已完成独立报告，可用于上述结论。

本轮只增加`deqacc_v2_aonly_locality.tcl`、`implement_deqacc_v2_aonly.tcl`、`report_deqacc_v2_aonly.tcl`及报告；逐lane内部报告脚本补A3/C观测。功能RTL/TB、DEA8和已有基线未改，不合并、不推送。

## 下一步建议

保留No-Pblock为整体基线，A-only保留为局部反馈缩短的证据。**不继续盲目加紧32个硬岛。**若仍优先物理改进，下一版应减少区域预留对Q/ACC的隔离、只约束重的FPADD子块，或优化控制复制与SRL映射；若改算法，A2的CLOSE normalize/候选链需单独处理。A0/A1到2ns附近已经有部分证据，A2并非仅靠整个FPADD放近就能解决。
