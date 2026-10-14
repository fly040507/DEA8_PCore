# DEQACC V2 七级布局布线基线

后续物理对照：2026-10-14，同网表No-Pblock WNS改善至−0.222ns，最高CLB区域占用74.17%。见 [No-Pblock对照报告](DEQACC_V2_NoPblock对照报告.md)。本文保留Hard-Pblock实验记录，不能作为取消约束后的结果。

2026-10-13。**综合、布局、物理优化、布线已完成，内部57,274个可布线网络全部完成。4ns setup未通过：WNS=−0.685ns、TNS=−1521.264ns。**

本文使用完成布线后的器件时序分析。报告中的route delay来自实际布线拓扑，不使用上一轮的综合net估算；这是post-route STA，不是上板硅片测量。

主要入口：[完整报告目录](Pcore/reports/v2_route_20261013/)、[七级CSV](Pcore/reports/v2_route_20261013/seven_stage_summary.csv)、[各部分与32-lane路径CSV](Pcore/reports/v2_route_20261013/path_delays.csv)。

## 1. 当前源码与实现设置

- 32个独立lane、四个同行硬Pblock、一个完整ACC；七级与Delta≥4不变
- 当前功能RTL和Focused仿真记录hash保持一致；没有修改算术或流水边界
- 新观测壳捕获全部输出，含commit_write；加入实际BUFG，时钟网络也完成route
- Vivado 2022.2；器件`xcu50-fsvh2104-2-e`；4.000ns
- `synth_design OOC → opt_design → place_design Explore → phys_opt_design AggressiveExplore → route_design Explore`
- 使用既有四个同行硬Pblock，不添加false path或multicycle例外
- shell输入launch和输出capture不计入核心七级延迟

输出DCP：[routed.dcp](Pcore/reports/v2_route_20261013/routed.dcp)。源码、观测壳和约束版本：[source_sha256.csv](Pcore/reports/v2_route_20261013/source_sha256.csv)。

## 2. 布线完成与时序结论

| 指标 | Post-route结果 |
| --- | ---: |
| WNS | **−0.685ns** |
| TNS | **−1521.264ns** |
| setup失败端点 | 4,824 / 48,048 |
| WHS / THS | 0.000ns / 0.000ns（显示精度，无hold失败） |
| hold失败端点 | 0 |
| Fully routed内部网络 | 57,274 / 57,274 |
| Routing errors / overlaps | 0 / 0 |
| DRC | 无Error；1项RTSTAT-10输出OOC warning |
| 时钟 | 1个全局时钟buffer、时钟网已route |

证据：[timing summary](Pcore/reports/v2_route_20261013/timing_summary_postroute.rpt)、[route status](Pcore/reports/v2_route_20261013/route_status.rpt)、[DRC](Pcore/reports/v2_route_20261013/drc.rpt)、[clock](Pcore/reports/v2_route_20261013/clock_utilization.rpt)。

OOC边界未指定HD.PARTPIN_LOCS，外部输入端口→launch FF和capture FF→输出端口不作板级时序签核；输出因此有No routable loads警告。本文使用**已放置布线的内部顺序元件到顺序元件**路径，报告有具体SLICE/BRAM位置及`net (..., routed)`。这不影响核心内部路径来源，但仍不能代替完整PCore/八核顶层的物理签核。

本轮只建当前结构基线。路由命令返回0表示流程完成，不等于setup通过；没有为了消除负Slack改变时钟或测试标准。

## 3. 七级真实路由路径

单位ns。各行是该组**最差Slack路径**，不是该组所有路径中最大纯数据delay；实际clock skew、setup和uncertainty不同，所以A0总delay比Q1更长，两者Slack仍接近。

| 级 | Logic | Routed net | Total | Slack | 路径含义 |
| --- | ---: | ---: | ---: | ---: | --- |
| Q0 | 0.954 | 2.634 | **3.588** | +0.181 | 输入psum→abs/lead |
| Q1 | 1.955 | 2.758 | **4.713** | **−0.685** | base→shift/RNE/pack |
| A0 | 1.341 | 3.576 | **4.917** | **−0.685** | 中央key/地址→forward选择→old mux→decode/diff |
| A1命名端点 | 1.697 | 3.077 | **4.774** | **−0.682** | A0分类sideband进入SRL，不等于纯A1算术 |
| A2 | 1.347 | 3.235 | **4.582** | **−0.677** | CLOSE normalize→round exp1 |
| A3任意输入pin | 0.622 | 2.973 | **3.595** | +0.242 | close_path→result FF同步R pin |
| C数据寄存 | 0.079 | 2.086 | **2.165** | +1.687 | A3结果FF→C FF |

A3数据D pin为**3.403ns**（logic0.690＋route2.713），Slack+0.543ns。C表只表示结果寄存，ACC写口和commit控制是同时发生的其他路径。

七级协议仍为7拍：沿e0接受Q0，e6沿后C有效，下游e7采样。4ns目标对应7拍预算28ns，但当前setup失败，**28ns不能称为已经实现的安全运行延迟**。不将七个路径最大值相加冒充端到端延迟，也不从4ns−WNS推出未经重新约束确认的Fmax。

## 4. 纯算术、反馈、ACC等路径

| 部分 | Logic ns | Route ns | Total ns | Slack ns |
| --- | ---: | ---: | ---: | ---: |
| Q0 magnitude | 0.534 | 2.223 | 2.757 | +1.028 |
| Q0 base | 0.901 | 2.426 | 3.327 | +0.443 |
| Q1 mantissa | 1.955 | 2.758 | 4.713 | −0.685 |
| Q1 exponent | 1.859 | 2.697 | 4.556 | −0.682 |
| Q1数据→A0 | 0.828 | 2.465 | 3.293 | +0.487 |
| A3数据反馈→A0 | 0.836 | 2.542 | 3.378 | +0.534 |
| C数据反馈→A0 | 0.602 | 2.972 | 3.574 | +0.682 |
| ACC读/选择控制→A0 | 0.825 | 3.819 | **4.644** | **−0.684** |
| 中央forward控制→A0 | 1.341 | 3.576 | **4.917** | **−0.685** |
| A1 FAR align/add/sub | 0.649 | 2.711 | 3.360 | +0.539 |
| A1 CLOSE subtract | 0.300 | 1.962 | 2.262 | +1.650 |
| A1 CLOSE LZA | 1.083 | 2.833 | **3.916** | **−0.067** |
| A2 FAR候选 | 0.885 | 2.861 | 3.746 | +0.210 |
| A2 CLOSE候选exp1 | 1.347 | 3.235 | **4.582** | **−0.677** |
| A2 CLOSE mantissa+0 | 1.046 | 2.319 | 3.365 | +0.532 |
| A2 CLOSE mantissa+1 | 1.319 | 2.963 | **4.282** | **−0.415** |
| A2 round predicate | 1.068 | 2.212 | 3.280 | +0.571 |
| A3数据D pin | 0.690 | 2.713 | 3.403 | +0.543 |
| ACC写控制incoming | 0.844 | 3.164 | **4.008** | **−0.368** |
| A3数据→ACC写口 | 0.246 | 2.558 | 2.804 | +0.530 |
| 控制spine incoming | 0.130 | 1.842 | 1.972 | +1.859 |
| 外部读→观测capture | 0.447 | 3.783 | **4.230** | **−0.395** |
| reset/clear→core | 0.373 | 2.918 | 3.291 | +0.786 |

`ACC_read_to_A0`按memory起点分组，最差源是`read_sel_q`，因此本轮突出的是ACC读bank选择/掩码控制，并非只表示BRAM数据输出延迟。中央forward控制源是`oacc_addr_return`，说明地址/key→match→source select→old decode仍是跨单元关键链。

各字段路径共享normalize/round逻辑，不可彼此相加。32 lane全部七级的224项逐lane时序均在CSV，原始top10包含资源位置和每条net实际delay。

## 5. Post-route资源

| 项目 | 核心 | 核心＋观测壳 |
| --- | ---: | ---: |
| LUT总数 | **44,045** | 44,045 |
| Logic LUT | 42,146 | 42,146 |
| Distributed RAM LUT | 1,184 | 1,184 |
| SRL LUT | 715 | 715 |
| FF | **20,712** | **25,091** |
| RAMB36 / RAMB18 | **14 / 2** | 14 / 2 |
| CARRY8 | 1,124 | 1,124 |
| DSP / URAM | 0 / 0 | 0 / 0 |
| 全局clock buffer | — | 1 |

观测壳增加4,379 FF以及1个clock buffer。资源为DEQACC独立实现，不包括MXU、完整PCore或八核系统。

完整ACC最终归属4,270 LUT、2,981 FF及全部BRAM；control重建层次2,899 LUT、98 FF。其余lane和scale/树资源逐实例见 [层次资源](Pcore/reports/v2_route_20261013/utilization_hierarchical.rpt)。

物理优化将部分SRL转为FF/改变映射，并做复制与重放置；综合版本的固定层次资源和端点计数不能直接用于本轮。在route报告中重新导出primitive、register mapping、fanout、Pblock成员和physical LOC证据。

路由器记录四个方向没有识别出congested regions，但局部最大拥塞北向84.507%、南向71.09%、东向75.9615%、西向65.3846%。这不表示每条网络短，也不表示扩展到八核仍有相同余量。

## 6. 据此调整流水的优先级

1. **Q1与forward→A0同时处理**：两个最差Slack接近；只修Q1不会自动解决4ns。Q1约21逻辑级，仍可研究Q0/Q1运算再分配；Q0路由后只剩+0.181ns，不能沿用综合时“Q0很空”的结论直接搬计算。
2. **中央compare、ACC read mask与数据选择分开测**：A3/C纯数据反馈通过，但中央forward和ACC read控制路径失败。优先保持四拍反馈语义重构选择生成/局部化，不能直接加一拍寄存解决然后继续宣称Delta4。
3. **CLOSE A2候选链偏重**：exp1和mantissa+1失败，A3只有+0.543ns数据Slack，不能凭综合1.536ns认为A3大幅空闲。改normalize/候选划分需要用本轮post-route做对照。
4. **LZA与sideband SRL单独考虑**：LZA只小幅负Slack；A1的4.774ns主要是A0分类到SRL输入。按原始pin路径决定是否禁止某些SRL，不按stage名盲目拆加法。
5. **保留ACC写/外部读验收**：它们也有负Slack，不能只优化算术然后忽略result端口或WE控制。拆ACC属于另一个结构选择，本轮不自动实施。

本轮记录当前设计实际物理基线，没有试图通过改流水或多轮约束搜索取得PASS。后续修改应针对多条接近−0.68ns的关键链，而不是仅一条Top1。

## 7. 复现

从`DEQACC/Pcore/`执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_deqacc_v2_route.ps1
```

终端timeout建议3600000ms；脚本同一cmd加载settings64，再调用官方Vivado launcher。新运行采用独立时间戳目录；实现完成后再提取报告/census。失败Slack不当作工具流程失败，必须另看WNS/TNS/WHS/THS。

已有route DCP补报：`synth_deqacc_v2.tcl <root> v2_route_20261013 report_route`、`report_deqacc_v2_census.tcl <root> v2_route_20261013 routed`，均通过支持的Vivado batch入口运行。旧 [综合报告](DEQACC_V2_综合报告.md) 保留为历史，后续决策优先引用本文post-route数据。
