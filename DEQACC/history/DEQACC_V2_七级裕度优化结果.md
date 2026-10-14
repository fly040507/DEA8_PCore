# DEQACC V2：七级保留与250MHz裕度优化

2026-10-14。**保留七级/II=1/Delta4，当前OOC post-route在4ns下WNS=+0.500ns、TNS=0、hold无失败。无需转为九级。**

工作仅在DEQACC副本；DEA8冻结，未推送GitHub。本轮简化验证和报告，未执行完整七Job/八核联调。

## 1. 修改与真实结果

| 小工作 | 修改 | 4ns post-route WNS | 判断 |
| --- | --- | ---: | --- |
| 第1项 | physical address入口捕获并流水；A3/C来源比较前移，选择寄存在Q0→Q1边界 | −0.270ns | forward链缩短，但其它路径仍失败 |
| 第2项 | Q1 normal/subnormal并行；统一35-bit shift-jam、24-bit RNE候选 | +0.079ns | 七级首次满足250MHz，裕度不足 |
| 第3项 | 同一功能RTL，以3.5ns约束进行place/phys_opt/route；同一routed网表恢复4ns报告 | **+0.500ns** | 达到工具报告精度下0.5ns裕度 |

第3项没有降低运行频率、增加stage、使用false-path/multicycle或放松setup/hold；只是更紧的物理优化目标。综合仍以原4ns约束执行，3.5ns在综合网表上设置并用于实现，最终4ns验收。一个初始脚本在open design前create_clock失败，未进入实现；修正后使用独立`margin7b`目录保存完整结果。

最终数据：[Pcore/reports/v2_margin7b_20261014/](Pcore/reports/v2_margin7b_20261014/)。前两项目录为`v2_preselect7_20261014`、`v2_parallelQ7_20261014`，按对应源码hash记录，不混用。

## 2. 结构说明

### forwarding选择前移，但数据仍在A0沿取已舍入结果

原来同拍做`keys[5] vs keys[1]`、`keys[6] vs keys[1]`比较，并串入A0数据mux/浮点解码。本轮先计算`keys[4] vs keys[0]`、`keys[5] vs keys[0]`，下一沿得到与当前A3/C对应的来源标志。

两parity独立，A3优先，clear清来源标志；physical address在输入边界捕获并推进，完整metadata仍保留。没有把未舍入结果用于feedback，也没有新增数据流水。

### Q1并行计算

分别用`lead−23`和`−(base+149)`计算normal/subnormal候选，classification不再位于barrel/round之前。统一shift-jam保持GRS；RNE增量仅覆盖25-bit有效结果，而非原宽数据加法。最终按exponent选择一次舍入结果，保留bad-scale、signed zero、shift32 tie、subnormal/min-normal及overflow语义。

旧辅助函数仍保留为源码上下文，未被使用的逻辑由综合消除；本轮不为了代码清理改变已经验证并布线的源码版本。

## 3. 短功能验证

两次RTL小修改后分别运行`run_deqacc_v1.ps1 -Focused`，最终记录源码与routed manifest一致：

- Dequant/FPADD各212,166笔，独立冻结golden逐位一致，Q2级/A4级、II=1
- 完整32-lane stream 10,486笔，含5,000笔A11对照；七级commit/metadata/row mask/data一致
- Delta4/5/6/7反馈、A3命中276/C命中271、外部访问、clear、完整ACC检查通过
- 11种动态M真实MXU仿真通过
- 三种非法RAW负例精确拒绝

日志与hash：`Pcore/reports/v2_same_row_simulation_summary.txt`、`v2_same_row_sources_sha256.csv`。没有改TB/golden降低标准。当前完整七Job和八核使用此新RTL尚未重新验证。

## 4. 七级真实延迟

单位ns，来自完成route的资源位置/net拓扑，不是综合估算。每级取最差Slack路径；可能不是最大纯data delay，不能七行相加作为事务延迟。

| 级 | Logic | Route | Total | Slack |
| --- | ---: | ---: | ---: | ---: |
| Q0 | 0.739 | 2.507 | 3.246 | +0.694 |
| Q1 | 1.153 | 2.227 | 3.380 | **+0.502** |
| A0 | 1.390 | 1.711 | 3.101 | **+0.500** |
| A1 | 1.878 | 1.444 | 3.322 | **+0.504** |
| A2 | 1.307 | 2.071 | 3.378 | **+0.506** |
| A3 | 0.612 | 2.589 | 3.201 | +0.694 |
| C | 0.078 | 1.351 | 1.429 | +2.266 |

A0/A1当前最差源为BRAM read output；A1还包括sideband SRL输入归属问题，不将其1.444ns当作全部A1 lane内net的最大值。A3此轮最差为D数据pin，A0/A3等其他轮次可能止于R/S同步pin，需按原始路径比较。

附加关键链：forward控制→A0 total3.364/route2.466/Slack+0.640；A3数据反馈total2.859/route2.384/Slack+0.862；C反馈total2.753/route2.303/Slack+0.976；ACC写入total3.020/route2.505/Slack+0.554。

**A路由全部≤2ns的目标尚未达到**：A3仍2.589ns，forward数据路线也有2.3～2.5ns。当前达到的是全局250MHz+0.5ns的工程验收，不把“均值/部分路径约2ns”误写为所有路由约2ns。

七级仍为目标时钟下7拍=28ns协议预算（输入接受e0，C沿后e6可见，下游e7采样）。本结果是带BUFG、全接口launch/capture壳的OOC STA；完整PCore/八核会改变布局/clock关系，不据此保证集成后仍+0.5ns。

## 5. 全局时序与资源

- 4ns：WNS +0.500ns、TNS=0、setup失败0/48,083
- hold：WHS +0.006ns、THS=0，失败0
- 63,527个内部可布线net全部route，routing errors=0
- 3.5ns实现目标的报告WNS=0.000ns、TNS=0；恢复4ns后原始SLACK属性=0.500，`margin_exact.txt`记录pass=1
- 无Pblock/密度census，仅保存一个总体resource和简短core层次resource

| 核心资源 | 原No-Pblock | 本轮最终 |
| --- | ---: | ---: |
| Total LUT | 44,075 | **49,578** |
| FF | 20,714 | **20,738** |
| LUTRAM / SRL | 1,184 / 715 | **1,184 / 723** |
| RAMB36 / RAMB18 | 14 / 2 | 14 / 2 |
| DSP / URAM | 0 / 0 | 0 / 0 |

LUT增加5,503（12.49%），主要与并行normal/subnormal数据通路及实现优化相关，未做逐cone资源分摊；不是无成本提高频率。观测壳额外4,379FF＋1BUFG，整体FF=25,117。

DRC保留OOC输出无routable loads警告；输入clock/partpin的顶层OOC边界未作板级签核。本报告使用内部已route顺序路径，没隐藏外部边界限制。

## 6. 执行耗时与复现

最后一轮：综合3分15秒、place6分06秒、phys_opt1分15秒、route6分23秒。只报13类path，没有224lane遍历、区域利用率/位置扫描，报告阶段约几十秒；原始Slack核对另约1分钟。

从`DEQACC/Pcore/`，在加载settings64.bat的同一cmd中调用：

```text
vivado.bat -mode batch -source implement_deqacc_compact.tcl -tclargs <Pcore绝对路径> <新的报告tag> 3.500
```

4ns最终报告、`stages.csv`、13个path rpt、route status/global resource/DCP/hash存入新目录，不覆盖基线。工具timeout≥300000ms，完整实现建议3600000ms；源码修改后先跑Focused短套件。

本轮目标已达到工具精度下的下限，不宣称超过0.5ns大余量。九级候选暂不实现；后续先核对完整PCore连接、资源预算和集成STA，再决定是否需要九级。不能用本OOC壳独立结果代替真实八核拥塞和时序。
