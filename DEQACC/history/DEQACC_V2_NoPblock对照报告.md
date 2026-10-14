# DEQACC V2：Hard-Pblock / No-Pblock 同网表对照

2026-10-14。**去掉四个硬Pblock后，WNS由−0.685ns改善至−0.222ns，TNS减少95.95%，最高clock-region CLB占用由100%降至74.17%。**

结论：本轮同网表结果强支持“单clock region硬塞8-lane约束过紧”的判断。No-Pblock明显更好，但仍未满足4ns；接下来的流水/算术优化应参考自由布局基线，不能继续把原−0.685ns全部归因于RTL逻辑。

原始报告：[No-Pblock目录](Pcore/reports/v2_nopblock_20261014/)。Hard基线：[v2_route_20261013](Pcore/reports/v2_route_20261013/)。本轮不修改任何RTL、Pblock源码默认设置或冻结DEA8，不运行新仿真、不推送GitHub。

## 1. 控制实验条件

两轮起点是**同一个应用Pblock前的synthesized.dcp**，没有重新综合；只在No-Pblock轮省略`deqacc_v2_locality::apply core`。

```text
Input: Pcore/reports/v2_route_20261013/synthesized.dcp
SHA256: 16c68c7223acedbc08a4148ec8bde23b8b1eb4431e1a18095e530519c85a7683
```

保持：Vivado2022.2、U50 -2-e、4ns、BUFG、输入/输出观测壳、RTL层次/keep/dont_touch/LUT1分发树、无false-path/multicycle例外。

实现顺序相同：`opt_design → place_design Explore → phys_opt_design AggressiveExplore → route_design Explore`。没有指定新seed、额外SLR约束、改变器件或降频；两轮最终物理优化可能选择不同副本/布局，这是取消约束后产生的结果，而不是相同最终物理网表。

脚本检查输入DCP中无Pblock、无固定cell LOC，实施前核对当前RTL/时钟hash与Hard基线相同。运行文件记录：[experiment.txt](Pcore/reports/v2_nopblock_20261014/experiment.txt)、[input_constraints.xdc](Pcore/reports/v2_nopblock_20261014/input_constraints.xdc)。

## 2. 全局结果

| 指标 | Hard-Pblock | No-Pblock |
| --- | ---: | ---: |
| WNS | −0.685ns | **−0.222ns** |
| TNS | −1521.264ns | **−61.556ns** |
| setup失败端点 | 4,824 | **842** |
| setup总端点 | 48,048 | 48,040 |
| WHS / THS | 0.000 / 0.000ns | 0.004 / 0.000ns |
| routing errors / overlaps | 0 / 0 | 0 / 0 |
| 最高实际clock-region CLB占用 | 100.00% | **74.17%** |
| SLR crossing | 0 | **0** |
| 所有逻辑所在SLR | SLR0 | SLR0 |

WNS改善0.463ns；TNS绝对值减少95.95%；失败端点减少82.55%。不是仅Top1换了位置：多个算术/控制/ACC类的失败数量同时下降。总端点差8来自物理优化映射变化，应看绝对数量与各类证据，不要求route后网表计数完全相同。

No-Pblock DRC仍只有OOC输出无routable loads警告；内部可布线网全部route。外部边界无HD.PARTPIN_LOCS/HD.CLK_SRC的OOC警告两轮相同，比较对象是已route内部顺序路径，不是上板或完整PCore时序签核。

## 3. 七级/关键类对照

各行是同一端点类别的最差Slack路径，起止点可不同。这里的route是post-route真实拓扑延迟，非综合估算。不能将各级最大值相加计算事务延迟。

| 类别 | Hard total | No total | Hard route | No route | Hard slack | No slack |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Q0 | 3.588 | 3.430 | 2.634 | 2.770 | +0.181 | +0.415 |
| Q1 | 4.713 | **4.044** | 2.758 | **2.119** | −0.685 | −0.222 |
| A0 | 4.917 | **3.983** | 3.576 | **3.056** | −0.685 | −0.130 |
| A1命名端点 | 4.774 | **4.028** | 3.077 | **2.619** | −0.682 | −0.219 |
| A2 | 4.582 | **4.085** | 3.235 | **2.872** | −0.677 | −0.099 |
| A3任意pin | 3.595 | 3.796 | 2.973 | 3.379 | +0.242 | +0.180 |
| C数据 | 2.165 | **1.681** | 2.086 | **1.603** | +1.687 | +1.979 |
| ACC读/选择→A0 | 4.644 | **3.943** | 3.819 | **2.549** | −0.684 | −0.003 |
| ACC写控制incoming | 4.008 | 3.662 | 3.164 | 3.175 | −0.368 | −0.004 |
| 外部读→capture | 4.230 | **2.955** | 3.783 | **2.333** | −0.395 | +0.937 |

单位ns。No-Pblock并不是所有路径都更短：A3最差类略退化、仍有正Slack；Q0最差起点从psum/lead变为fold/base，route列不可直接当作同一net变化。应同时看下表固定端点与每lane分布。

A1最大值仍是分类sideband SRL输入，不等于纯A1算术；纯LZA路径由3.916ns/−0.067ns变成3.803ns/+0.304ns，纯FAR由3.360ns/+0.539ns变为3.537ns/+0.473ns。

### 32 lane中段路由平均与失败分布

统计每lane每级的最差Slack路径，不是全部nets平均。

| 级 | Hard route均值 | No route均值 | Hard失败lane数 | No失败lane数 |
| --- | ---: | ---: | ---: | ---: |
| Q1 | 2.749ns | **2.271ns** | 32 | 32 |
| A0 | 3.128ns | **2.624ns** | 32 | 16 |
| A1 | 3.140ns | **2.472ns** | 32 | 29 |
| A2 | 2.772ns | **2.421ns** | 28 | 5 |

同类path与224项lane结果：[path_delays.csv](Pcore/reports/v2_nopblock_20261014/path_delays.csv)，摘要：[seven_stage_comparison.csv](Pcore/reports/v2_nopblock_20261014/seven_stage_comparison.csv)。

## 4. 原关键起止点对照

对Hard的43类关键路径分别复查固定endpoint和固定start/endpoint。40/43个原endpoint仍存在；缺少的Q0副本和部分Q1/ACC读selector副本因phys_opt变化标为MISSING_PIN，没有用近似名称伪装同端点。

| 相同起止点路径 | Hard logic/route/total | No logic/route/total | Hard→No slack |
| --- | --- | --- | --- |
| forward地址→A0 distance[7] | 1.341 / 3.576 / 4.917 | **1.202 / 2.418 / 3.620** | −0.685 → **+0.339** |
| forward地址→close_path SRL D | 1.697 / 3.077 / 4.774 | **1.492 / 2.332 / 3.824** | −0.682 → **+0.143** |
| CLOSE exponent→A2 exp1[5] | 1.347 / 3.235 / 4.582 | **1.341 / 2.525 / 3.866** | −0.677 → **+0.093** |
| A3数据→A0 distance[4] | 0.836 / 2.542 / 3.378 | **0.716 / 1.526 / 2.242** | +0.534 → +1.667 |
| C数据→A0 distance[5] | 0.602 / 2.972 / 3.574 | **0.687 / 1.352 / 2.039** | +0.682 → +1.745 |
| Q1 lead→partial exponent[30] | 1.859 / 2.697 / 4.556 | **1.782 / 2.131 / 3.913** | −0.682 → −0.031 |

Q1原最差base副本在No中不存在，但相同partial_value[0] endpoint仍在：最差输入变为lead，total3.995ns、Slack−0.093ns；不能声称同源base路径改善。固定点的clock skew、级数和具体pin均记录于 [matched_paths.csv](Pcore/reports/v2_nopblock_20261014/matched_paths.csv) 和 `matched_*.rpt`。

固定点结果显示route显著减少，但logic delay与skew也有变化。结论是取消硬Pblock改善整体实现，不把全部WNS收益都算作route长度减少，也不将单次结果推广到所有器件/布局策略。

## 5. 放置密度与资源

Hard原四区域实际CLB占用：X3Y1=99.85%、X4Y1=94.14%、X3Y2=100%、X4Y2=88.10%。No-Pblock自由布局最高X1Y0=74.17%，其次X3Y0=70.30%、X3Y1=69.70%、X2Y0=66.18%；所有使用区域都低于75%。

整个设计两轮均使用13个clock region（计包含shell/ACC的少量外围cell），但No分布改变且没有一个区域被占满。逻辑group允许跨region分布，不再等同于一组一个clock region；具体每lane分布见 `*_lane_regions.csv`。资源总计已用CLB从6,797变为8,267，说明整体占用足迹变大、packing更松，时序因此改善不等于面积压缩。

| 核心资源 | Hard | No |
| --- | ---: | ---: |
| Total LUT | 44,045 | 44,075 |
| FF | 20,712 | 20,714 |
| LUTRAM / SRL | 1,184 / 715 | 1,184 / 715 |
| RAMB36 / RAMB18 | 14 / 2 | 14 / 2 |
| CARRY8 / DSP | 1,124 / 0 | 1,124 / 0 |

观测壳仍4,379FF、1个BUFG；core LUT只增30、FF只增2，并非用显著逻辑膨胀换取性能。不同物理优化选择解释少量资源差异。

## 6. 剩余问题与推荐下一步

| 失败端点类别 | Hard | No | No最差Slack |
| --- | ---: | ---: | ---: |
| Q1 | 992 | **634** | −0.222ns |
| A0 | 2,614 | **153** | −0.130ns |
| A1 sideband | 67 | **29** | −0.219ns |
| A2 | 270 | **10** | −0.099ns |
| ACC | 810 | **16** | −0.004ns |
| 外部输出capture | 71 | **0** | — |

634/842≈75.3%的剩余失败端点在Q1，而且32个lane均仍有Q1负Slack。建议：

1. 将No-Pblock结果用作后续物理对比基线；保留Hard脚本与历史结果，不把差实验删除
2. 当前无需立即增加流水级，先研究Q1移位/round/pack结构，并检查A0→sideband SRL选择链
3. 对A2只有少数lane的小幅失败和ACC−0.004ns保持验收，不将它们误报为已通过
4. 如需八核可控布局，再单独试更宽区域/soft或单SLR分区；不要把本轮自由布局PASS程度推成八核集成保证

本轮单次确定性A/B结果足以改变优化优先级，但不证明所有剩余WNS来自Pblock。No版本仍未250MHz签核，没有通过调低时钟或改stage计数制造PASS。

## 7. 复现与交付

新增入口：`Pcore/implement_deqacc_v2_nopblock.tcl`、`compare_deqacc_v2_placement.tcl`、`run_deqacc_v2_nopblock.ps1`。报告函数支持无Pblock的routed DCP，仅变更工具脚本与文档，不改功能源码。

从`DEQACC/Pcore/`执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_deqacc_v2_nopblock.ps1 -Baseline v2_route_20261013
```

timeout建议3600000ms，所有工具经同一cmd先call settings64.bat再call Vivado官方bat。需要本地基线` synthesized.dcp`（GitHub按既有规则不上传DCP）；缺失时应先按Hard入口重建同网表基线，而非任意使用不同源码的DCP。

最终证据：route完成、setup/hold摘要、完整267项timing分类、原43类路径固定pin对照、两个版本的region密度/每lane位置/失败端点统计、资源以及routed checkpoint。所有路径数据都是post-route STA，仍有相同OOC外部端口约束边界，不是硅片实测。
