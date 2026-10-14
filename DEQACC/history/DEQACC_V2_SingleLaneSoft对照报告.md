# DEQACC V2：Single-Lane Soft Pblock 对照

2026-10-14。**单 lane Soft 实验已完成，整体不优于 No-Pblock：WNS −0.225ns 对 −0.222ns，TNS −84.415ns 对 −61.556ns。推荐下一轮 Q1 RTL 优化继续以 No-Pblock 为物理基线。**

此结果是post-route STA，非综合net估算。功能RTL、七级、II=1、Delta4、算术/舍入、ACC、forwarding及TB均未修改。工作仅在`DEQACC/`，`DEA8/`保持冻结；没有推送GitHub。

依据：`interaction/下一步方案.docx`。原始结果：[v2_soft_single_lane_20261014](Pcore/reports/v2_soft_single_lane_20261014/)。四版摘要：[four_way_summary.csv](Pcore/reports/v2_soft_single_lane_20261014/four_way_summary.csv)。

## 1. 实验条件与区域生成

使用和前三版相同的应用Pblock前综合网表：

```text
v2_route_20261013/synthesized.dcp
SHA256 = 16c68c7223acedbc08a4148ec8bde23b8b1eb4431e1a18095e530519c85a7683
```

无重新综合。器件U50 -2-e、Vivado2022.2、4ns、BUFG、完整输出观测壳不变，指令为`opt_design → place Explore → phys_opt AggressiveExplore → route Explore`。没有降低频率、增加stage、删除critical endpoint或增加timing exception。

先读No-Pblock routed DCP，导出32 lane每级primitive位置bounding box、X/Y span和clock-region分布。以各lane自然位置中位数为区域中心，在该lane所在SLR0内扩展矩形，不把FPGA机械切成32块。

每个Soft区域包含本lane的quant、add、C寄存与lane专属scale base_adder/控制叶/forward叶/ACC掩码叶；中央RAM、control spine、共享root/branch不强行分配。初始化时检查成员互斥，最终层次展开检查没有其他lane或中央RAM/control混入。

32个区域最终全部：**IS_SOFT=1、CONTAIN_ROUTING=0、EXCLUDE_PLACEMENT=0**。没有给整个lane加DONT_TOUCH，phys_opt按正常流程执行。允许不同Soft矩形空间重叠，但成员逻辑不重叠；Soft不是独占资源配额。

### 区域余量的实际局限

生成时要求：本lane原语LUT/容量≤60%、No-Pblock位置中已有全部CLB占用≤65%、已有LUT占用≤65%。预生成自然布局CLB比例55.94%～64.89%，每个范围286～5,785个SLICE。

为降低“窗口内所有逻辑”的已有密度，26/32个窗口扩得较大，本lane自己的LUT容量比例低于20%，形成较多重叠/嵌套。因而这是一版**基于自然中心且保守留余量的Soft矩形**，不是每个窗口都恰好50%～65%的紧凑单lane区域。最终实际布局密度也超过目标，不能宣称成功满足方案的局部密度要求。

Vivado有32项FLBO-1 Pblock overlap Warning，以及3处checkpoint/XDC嵌套区域读取顺序Warning。报告展开层次后验证每个Pblock的完整lane及属性保留，未把warning隐藏；空间重叠仍可能影响placer偏好，因此结论只针对本次生成方式，不排除其它Soft方案更好。

## 2. 四版全局结果

| 指标 | 4×8 Hard | 8×4 Hard | No-Pblock | Single-Lane Soft |
| --- | ---: | ---: | ---: | ---: |
| WNS ns | −0.685 | −0.358 | **−0.222** | −0.225 |
| TNS ns | −1521.264 | −310.534 | **−61.556** | −84.415 |
| setup失败端点 | 4,824 | 2,660 | **842** | 1,051 |
| WHS / THS ns | 0 / 0 | 0.008 / 0 | 0.004 / 0 | **0.011 / 0** |
| routing errors / overlaps | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| SLR crossing | 0 | 0 | 0 | 0 |
| 核心LUT | 44,045 | 43,982 | 44,075 | 44,096 |
| 核心FF | 20,712 | 20,714 | 20,714 | 20,720 |
| 总已用CLB（含观测壳） | 6,797 | 7,673 | 8,267 | 7,264 |
| 最高clock-region CLB占用 | 100% | 73.64% | **74.17%** | **91.40%** |

四版BRAM均14 RAMB36＋2 RAMB18，1184 LUTRAM、715 SRL、1124 CARRY8、DSP=0。Soft含shell为25,099 FF，shell4,379 FF＋1个BUFG。逻辑资源近乎相同，整体实现差异来自约束和物理优化选择。

WNS只差0.003ns，单看Top1不能证明有意义的优势；Soft TNS绝对值增加37.13%，失败端点增加209（24.82%），更充分支持维持No基线。四版4ns都未通过setup，hold都无失败。

## 3. 七级真实路径

Soft七级各类最差Slack路径，单位ns；类别内起止点可变化，logic/net/total不可跨级相加。

| 级 | Logic | Route | Total | Slack | No total / Slack |
| --- | ---: | ---: | ---: | ---: | --- |
| Q0 | 0.703 | 2.948 | 3.651 | +0.417 | 3.430 / +0.415 |
| Q1 | 1.749 | 2.301 | 4.050 | **−0.225** | 4.044 / −0.222 |
| A0 | 1.414 | 2.776 | 4.190 | **−0.182** | 3.983 / −0.130 |
| A1 sideband | 1.241 | 2.924 | 4.165 | **−0.206** | 4.028 / −0.219 |
| A2 | 1.317 | 2.834 | 4.151 | **−0.216** | 4.085 / −0.099 |
| A3任意pin | 0.593 | 2.809 | 3.402 | +0.367 | 3.796 / +0.180 |
| C数据 | 0.079 | 1.211 | 1.290 | +2.549 | 1.681 / +1.979 |

A1最大类仍包含中央选择/分类到SRL sideband D，而非纯lane算术。A3 D数据pin=3.225ns、Slack+0.700ns；LZA=3.717ns/+0.188ns。ACC读→A0=3.738ns/+0.026ns，ACC输入=3.858ns/−0.032ns，reset/clear最差Slack+0.037ns。没有把小幅正Slack扩大成签核余量。

完整267类路径包括224项lane×stage：[path_delays.csv](Pcore/reports/v2_soft_single_lane_20261014/path_delays.csv)。四版七级：[seven_stage_timing.csv](Pcore/reports/v2_soft_single_lane_20261014/seven_stage_timing.csv)。列含logic、route、total、slack、logic levels、startpoint、endpoint；每级top10另有原始rpt。

## 4. 每lane worst incoming统计

口径与此前No一致：每lane每级选最差Slack输入路径，起点可以在中央ACC/control。平均/中位/范围/失败lane数如下，单位ns。

| 级/版本 | Route平均 | 中位 | 最小～最大 | Slack平均 / 中位 | Slack最小～最大 | 失败lane |
| --- | ---: | ---: | --- | --- | --- | ---: |
| Q1 No | 2.2709 | 2.2690 | 2.085～2.470 | −0.1530 / −0.1500 | −0.222～−0.044 | 32 |
| Q1 Soft | **2.3039** | 2.2925 | 2.098～2.565 | −0.1742 / −0.1825 | −0.225～−0.047 | 32 |
| A0 No | 2.6243 | 2.6230 | 2.222～3.056 | +0.0124 / +0.0020 | −0.130～+0.221 | 16 |
| A0 Soft | **2.6782** | 2.7045 | 2.347～3.093 | −0.0206 / −0.0130 | −0.182～+0.232 | 20 |
| A1 No | 2.4716 | 2.4825 | 1.759～2.803 | −0.0570 / −0.0645 | −0.219～+0.227 | 29 |
| A1 Soft | **2.6511** | 2.6635 | 2.328～3.016 | −0.1163 / −0.1260 | −0.206～+0.159 | 30 |
| A2 No | 2.4205 | 2.4105 | 1.988～2.872 | +0.1259 / +0.0925 | −0.099～+0.402 | 5 |
| A2 Soft | **2.5983** | 2.6245 | 2.067～2.878 | +0.0218 / −0.0070 | −0.216～+0.377 | 18 |

所有incoming路由均值都未下降。Q1有21个lane route增大、18个lane Slack恶化；A2有26个lane route增大，15个原本通过的lane转为失败。

例如Q1 row1 col11的Slack−0.057→−0.218ns，row0 col10为−0.044→−0.184ns；也有改善者，row0 col14为−0.213→−0.118ns、row1 col12为−0.133→−0.047ns。不隐藏退化lane，也不只选改善例。

CSV：[lane_stage_timing.csv](Pcore/reports/v2_soft_single_lane_20261014/lane_stage_timing.csv)、[statistics](Pcore/reports/v2_soft_single_lane_20261014/lane_stage_statistics.csv)、[逐lane差值](Pcore/reports/v2_soft_single_lane_20261014/lane_stage_delta.csv)。四版incoming均包含在统计中。

### 分离真正lane内部路径

另做“本lane顺序source→本lane端点”的约束查询，排除中央ACC/control起点；不是把incoming路线都称为lane-internal。

| 级 | No内部route平均 | Soft内部route平均 | No→Soft失败lane |
| --- | ---: | ---: | --- |
| Q1 | 2.2709 | 2.3039 | 32→32 |
| A0 | 2.1610 | **1.8361** | 0→0 |
| A1 | 2.2879 | **2.0615** | 0→0 |
| A2 | 2.4205 | **2.5983** | 5→18 |

因此“locality有效”只对部分A0/A1内部路线成立；Q1和A2并未因空间收紧获得路由改善。关键全输入仍受中央选择影响，不能用内部均值下降推导整体成功。内部全部256项原始数据：[lane_internal_timing.csv](Pcore/reports/v2_soft_single_lane_20261014/lane_internal_timing.csv)。

## 5. 空间收紧、密度与Soft外溢

### 实际空间跨度

每lane全部primitive bounding box：No的平均X/Y span为43.06/59.63个SLICE坐标，Soft为**20.75/32.06**；跨clock region lane数32→26。A1平均span30.91/48.25→16.44/21.44，A2为30.75/48.66→17.00/21.72。

注意Q1自身FF包围盒在No下已经较小（平均5×8.66坐标），Soft为5.56×8.50，不能以整个lane span减半证明Q0→Q1 shifter/round cone连线更短。

原始Q0/Q1/A0/A1/A2/A3/C的bbox和clock regions见`natural_lane_stage_placement.csv`与`soft_lane_stage_placement.csv`，摘要 [lane_placement_statistics.csv](Pcore/reports/v2_soft_single_lane_20261014/lane_placement_statistics.csv)。bounding box字段按名映射捕获FF/SRL，组合cell单列COMB_LEAF，并非一棵完整logic cone包围盒。

### 密度目标没有保持

No区域最高CLB占用74.17%，Soft布局后X2Y1升至**91.40%**，X2Y0为85.09%。32个Soft矩形中8个实际CLB窗口>70%，5个>90%；row0 col4窗口98.25% CLB、92.35% LUT。这些窗口统计所有落入cell，包含其它lane/中央逻辑。

不同Soft窗口重叠，不能将窗口容量或占用相加当作整机资源。大窗口可自然跨多个clock region，并不意味着固定“一个lane一个clock region”。生成前≤65%的密度不能保证重新place后仍≤65%；这版方案没有守住目标，因此不给出“密度问题已消除”的结论。

路由器仍未识别有效congestion cluster（各方向effective level=0），局部最大需求北/南/东/西约66.20%/55.92%/74.04%/73.08%。所以可以说**放置密度重新升高**，不能将它直接称为工具已证实的routing congestion。路线可能因为packing、net数量/负载、中央连接变长而退化，尚未逐因子证明。

### 实际inside/outside

总计60,703个Pblock成员primitive，**59,440 inside、1,263 outside，外溢2.081%**。不是大量放出区域，最差lane row0 col11为191/1884=10.14%。

| 级 | 区外primitive / 总数 | 区外比例 |
| --- | --- | ---: |
| Q0 | 62 / 1802 | 3.441% |
| Q1 | 7 / 1344 | 0.521% |
| A0 | 28 / 3200 | 0.875% |
| A1 | 27 / 4925 | 0.548% |
| A2 | 41 / 6816 | 0.602% |
| A3 | 1 / 1024 | 0.098% |
| C | **143 / 1024** | **13.965%** |
| 组合/本地叶 | 954 / 40568 | 2.352% |

C最容易被拆到区域外；Q0和组合leaf其次。计数包括物理优化副本，LUT为primitive数（不同于report_utilization LUT combining口径），每lane信息完整保存于 [soft_pblock_actual.csv](Pcore/reports/v2_soft_single_lane_20261014/soft_pblock_actual.csv)。包括32个属性、cell/LUT/FF、区域容量/全局占用与member自身占用。逐级内外另存CSV。

## 6. 回答方案中的八个问题

1. **比No更好吗？** 没有：WNS基本持平略差，TNS与失败端点明显更多。
2. **Q1 route明显下降吗？** 没有，均值增加0.033ns，32 lane仍全部失败。
3. **A0/A1/A2内部下降吗？** A0/A1下降，A2变差；中央输入口径A0/A1也变差，必须分开。
4. **重新产生局部拥塞吗？** 重新产生高CLB密度；router没报有效congestion hotspot，不能混同。
5. **某些lane恶化吗？** 是，Q1 18个Slack恶化，A2 23个Slack恶化，逐laneCSV可定位。
6. **Vivado大量违反Soft吗？** 总2.08%成员outside，非大量；说明Soft偏好主要被保持。
7. **哪些级最易拆开？** C约13.97%，其次Q0约3.44%，其他算术级均不到1%。
8. **下一轮baseline？** 选择No-Pblock。按照本次指令停在物理实验，不自动改Q1 RTL。

本轮只能否定这版基于median/扩展窗口的生成方法取得收益，不能普遍否定Soft Pblock。空间重叠、部分窗口过大、重布后高密度都属于该实验的实际边界，报告如实保留。

## 7. 复现与报告阶段调整

新增：`deqacc_v2_single_lane_soft.tcl`、`implement_deqacc_v2_single_lane_soft.tcl`、`run_deqacc_v2_single_lane_soft.ps1`，以及轻量report/internal/statistics脚本。

从`DEQACC/Pcore/`执行新实验：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_deqacc_v2_single_lane_soft.ps1
```

仅补报现有routed DCP（不会综合/P&R）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_deqacc_v2_single_lane_soft.ps1 -ReportOnly -Tag v2_soft_single_lane_20261014
```

工具在同一cmd先call settings64.bat再call官方bat，不手设PATH/RDI/Tcl。timeout≥300000ms，完整实验建议3600000ms。

实现已完成但首轮报告阶段超时，补报没有重复P&R。原因包括32个重叠Pblock详细utilization遍历和原语层次查询成本。现已按用户要求**默认关闭逐lane report_utilization**，保留一个全局utilization＋CSV轻量census；需要时可对异常lane传具体Pblock名生成详细报告，不再默认运行32遍。

Vivado在DCP/XDC内把quant/add成员折叠为层次根；直接`get_cells -of_objects -filter IS_PRIMITIVE`会漏掉约千余成员。最终报告显式展开这些层次、核对没有foreign lane/control/RAM混入，避免先前几十cell的错误计数。初版过程文件不作为最终census。

源码/输入DCP hash见`source_sha256.csv`、`experiment_hashes.csv`；初次实现constraint脚本hash保留，后续改动只优化census并默认关闭详细报告，未改变本轮使用的窗口或routed DCP。最终报告脚本版本由收尾hash另记。

功能RTL不变，因此本轮没有重跑算术或七Job仿真；三个前序实现报告未覆盖。所有四版仍无250MHz setup PASS，也没有八核/板级签核结果。
