# DEQACC V2 七级综合时序与资源基线

后续已完成真实布局布线：请优先使用 [DEQACC_V2_布局布线报告.md](DEQACC_V2_布局布线报告.md)。本文保留未布局综合估算历史，不能替代post-route。

日期：2026-10-13。**当前同行V2源码综合成功；4ns综合估算未满足，最坏Q1路径4.969ns、WNS=−0.988ns。未运行布局布线。**

报告目录：[Pcore/reports/v2_synth_20261013/](Pcore/reports/v2_synth_20261013/)。本轮保持功能RTL不变，增加完整接口观测壳、综合/报告脚本和本文；正式`DEA8/`保持冻结。

## 1. 对应设计与流程

当前V2是32个独立lane、四个同行位置组：row0列0～7/8～15、row1列0～7/8～15；一个完整ACC。Scale/forward每行1→4→16，common control 1→4→32，ACC读掩码分层分发。FPADD默认USE_LZA=1，完整FAR/CLOSE和A2并行舍入候选已实现。

最新行为证据是 [Focused短套件](Pcore/reports/v2_same_row_simulation_summary.txt)：算术212,166笔、stream10,486笔、11种动态M、三种非法RAW拒绝通过。本轮综合源文件hash与这些证据对应；没有重跑仿真、七Job或V1 lockstep，不沿用早先混合行结构的七Job结果证明当前设计。

| 配置 | 当前值 |
| --- | --- |
| 工具/器件 | Vivado 2022.2；`xcu50-fsvh2104-2-e` |
| 流程 | `synth_design -mode out_of_context -flatten_hierarchy rebuilt` |
| 时钟 | 4.000ns，250MHz目标 |
| 综合顶层 | `deqacc_v2_timing_shell`，实例`core`为当前`DEQACC_V1`兼容名 |
| 接口观测 | 全输入launch FF；全输出capture FF，含1024-bit commit_write与metadata |
| 延迟边界 | shell FF不计入核心七级；不更改算法/反馈寄存边界 |
| 物理实现 | 没有opt_design、place_design、phys_opt_design、route_design |
| Pblock | 在综合后匹配当前网表并写入第二个DCP；尚未放置 |

综合0 errors、0 critical warnings；综合DRC 0 violations。4ns估算WNS=−0.988ns、TNS=−822.029ns，1,120个setup失败端点；WHS=+0.073ns、THS=0。内部端点无未约束、无组合loop。外部ports无I/O delay，这是独立launch/capture观测壳，不是板级I/O约束。

OOC时钟未设置HD.CLK_SRC，时钟位置/skew尚未获得真实物理值。表中的`estimated_net_ns`是Vivado未放置网表的net delay估算，即报告中标为`route`的列，**不是实测routing**。不能用本报告签核250MHz，也不能直接与R11 routed数据判断routing改进百分比。

## 2. “七级完整用时”的两个口径

### 固定流水延迟

`Q0 → Q1 → A0 → A1 → A2 → A3 → C`，核心七个边界；Q占2级、A占4级、C占1级，II=1，依赖间隔Delta≥4。

- 沿e0接受输入并捕获Q0；沿e6后C输出有效，下游沿e7采样
- 按七级接口计数、目标4ns：**7拍预算=28ns**
- 若计“输入采样沿e0到C沿后首次有效”，为6个整周期=24ns＋C clock-to-Q；不能将这个观察口径误报为六级
- Q/A/C的级数预算为8ns/16ns/4ns；依赖输入四拍间隔预算16ns

这些是目标时钟下的协议/周期换算，不是已经实现的物理运行时间。4ns估算未通过，所以目前不能声称真实FPGA可每28ns完成一笔延迟。

### 各级组合关键路径

每级只须在自己的寄存周期内完成。**以下七个最大值不能相加当作一笔事务真实延迟**：它们可能来自不同lane、不同控制/数据起点，还有feedback和SRL端点；STA也不会把跨七个寄存级当一条组合路径。

| 目标级 | 工作 | Logic ns | 估算net ns | Total ns | Slack ns | 最坏来源 |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| Q0 | magnitude/lead/base捕获 | 0.662 | 1.108 | **1.770** | +2.211 | 输入psum→lead |
| Q1 | 直接移位/RNE/pack | 1.487 | 3.482 | **4.969** | **−0.988** | lead→partial mantissa |
| A0 | old选择、解码/排序、diff | 1.136 | 3.030 | **4.166** | **−0.185** | producer地址→source compare→old mux→diff |
| A1（综合命名端点） | raw/LZA及SRL sideband | 1.174 | 3.388 | **4.562** | **−0.687** | control→old mux→A0分类→close_path SRL D |
| A2 | normalize、round候选 | 1.149 | 2.599 | **3.748** | +0.233 | CLOSE exp1候选 |
| A3（任意pin） | path/round/special选择 | 0.344 | 1.211 | **1.555** | +2.327 | close_path→result FF同步R pin |
| C（数据） | 结果输出寄存 | 0.077 | 0.203 | **0.280** | +3.701 | A3 FF→C FF |

A3仅D数据pin的独立路径为1.536ns（logic0.432＋net1.104），Slack+2.445ns；任意pin最大值与D pin值不同，均已单独记录。C数据pin0.280ns不含并行ACC写口及metadata控制，不能当作整个C写回的唯一时间。

32个lane逐级数据都在 [path_delays.csv](Pcore/reports/v2_synth_20261013/path_delays.csv)，包含224项per-lane统计和stage/field/feedback分类；当前未布局时同构lane多项估算相同，不据此认为实际位置完全对称。

## 3. 纯顺向、反馈和ACC路径

| 路径 | Logic ns | 估算net ns | Total ns | Slack ns |
| --- | ---: | ---: | ---: | ---: |
| Q1数据→A0 | 0.703 | 1.562 | 2.265 | +1.716 |
| A0→A1（到LZA shift） | 0.789 | 1.678 | 2.467 | +1.514 |
| A1→A2 | 1.149 | 2.599 | 3.748 | +0.233 |
| A2→A3（D pin） | 0.432 | 1.104 | 1.536 | +2.445 |
| A3结果→A0 | 0.759 | 1.776 | 2.535 | +1.446 |
| C结果→A0 | 0.784 | 1.814 | 2.598 | +1.383 |
| ACC读输出→A0 | 1.517 | 2.088 | 3.605 | +0.330 |
| producer控制spine→A0 | 1.136 | 3.030 | **4.166** | **−0.185** |
| ACC任意输入（最差WE） | 0.489 | 1.556 | 2.045 | +1.710 |
| A3数据→ACC写口 | 0.189 | 0.310 | 0.499 | +3.170 |
| 控制spine incoming | 0.115 | 0.437 | 0.552 | +3.330 |
| 输出capture（最差外部读） | 0.943 | 0.285 | 1.228 | +2.707 |
| reset/clear→core | 0.411 | 1.316 | 1.727 | +2.028 |

当前A3/C结果数据feedback本身不是最慢路径，中心地址/key compare→forward select→old mux→分类才是A0更重的输入。ACC数据读本身也接近4ns余量边界。

## 4. 算术内部细分

| 组合部分/寄存字段 | Total ns | Logic ns | 估算net ns | 逻辑级数 |
| --- | ---: | ---: | ---: | ---: |
| Q0 abs/magnitude | 0.940 | 0.492 | 0.448 | 6 |
| Q0 lead | 1.770 | 0.662 | 1.108 | 7 |
| Q0 scale/base | 1.522 | 0.486 | 1.036 | 6 |
| Q1 mantissa / exponent最长路径 | 4.969 | 1.487 | 3.482 | 23 |
| A1 FAR align/add/sub | 1.492 | 0.827 | 0.665 | 7 |
| A1 CLOSE subtract | 0.693 | 0.464 | 0.229 | 4 |
| A1 CLOSE LZA→shift | 2.467 | 0.789 | 1.678 | 9 |
| A2 FAR（含exp1） | 2.069 | 0.674 | 1.395 | 9 |
| A2 CLOSE（含exp1） | 3.748 | 1.149 | 2.599 | 14 |
| A2 FAR mantissa+0 | 0.953 | 0.324 | 0.629 | 3 |
| A2 FAR mantissa+1 | 1.646 | 0.672 | 0.974 | 7 |
| A2 CLOSE mantissa+0 | 2.673 | 0.893 | 1.780 | 8 |
| A2 CLOSE mantissa+1 | 3.362 | 1.189 | 2.173 | 12 |
| A2 round predicate（最差CLOSE） | 2.894 | 0.869 | 2.025 | 9 |
| A3 D pin选择/pack | 1.536 | 0.432 | 1.104 | 6 |

每项是从真实顺序元件起点到字段捕获的完整路径，不是彼此互斥、可相加的小段延迟。例如CLOSE mantissa+1包含前面的normalize，它和mantissa+0重叠。

### SRL重映射为什么影响级名

综合把32 lane中37-bit/lane的旁路、partial、special/close等顺移sideband映射为1,184个SRL16E。`arithmetic_q_reg[close_path]_srl2/D`实际接收A0分类结果，却命名在A1端点集合内。

因此A1表中的4.562ns包含中心forward控制与A0解码，**不是FAR/CLOSE arithmetic在A1里算了4.562ns**。A1实际算术最差LZA为2.467ns。未来切流水时同时检查FF/SRL边界，不能只按变量名归因。

[register_mapping.csv](Pcore/reports/v2_synth_20261013/register_mapping.csv)：Q0 FF1664、Q1 FF1024、A0 FF3104、A1 FF3168＋SRL1184、A2 FF6560、A3 FF1024、C FF1024。资源映射中的`other_primitives`是名称带该寄存字段的组合cell，不是新增寄存级。

## 5. 资源

### 整体：核心与观测壳分开

| 资源 | DEQACC核心 | 含观测壳 | 说明 |
| --- | ---: | ---: | --- |
| Total LUT | **44,945** | **44,945** | LUT combining口径 |
| Logic LUT | 42,534 | 42,534 | 包含568个保护的LUT1端点 |
| Distributed RAM LUT | 1,184 | 1,184 | 浅FACC |
| SRL LUT | 1,227 | 1,227 | FPADD1184、metadata43 |
| FF | **20,633** | **25,012** | shell额外4,379 FF |
| RAMB36 / RAMB18 | **14 / 2** | **14 / 2** | 相当于15个36K Tile，不是16个36K |
| CARRY8 | 1,124 | 1,124 | Dequant/FPADD/base等 |
| DSP / URAM / latch / blackbox | 0 | 0 | 本次DEQACC独立范围，不含MXU |

资源不是完整PCore，也不是八核总资源；synthesis后尚未opt/place/route，最终利用率可能变化。

### 层次资源：综合重建后的归属

| 部分 | Total LUT | Logic LUT | SRL/LUTRAM | FF |
| --- | ---: | ---: | --- | ---: |
| 32×Dequant | 13,728 | 13,728 | 0 / 0 | 2,688 |
| 32×FPADD | 22,688 | 21,504 | 1,184 / 0 | 13,856 |
| 完整ACC | 4,218 | 3,034 | 0 / 1,184 | 2,976 |
| control spine | 3,031 | 2,988 | 43 / 0 | 74 |
| scale ingress | 448 | 448 | 0 / 0 | 0 |
| forward分发 | 80 | 80 | 0 / 0 | 0 |
| common分发 | 144 | 144 | 0 / 0 | 0 |
| core顶层其他 | 608 | 608 | 0 / 0 | 1,039 |

单lane综合归属：Dequant429 LUT、84 FF；FPADD709 LUT（含37 SRL）、433 FF。C寄存1024 FF归在core顶层其他中；ACC mask分发240 LUT1已经包含在ACC资源内，不能重复相加。

`flatten_hierarchy rebuilt`可能跨边界移动或合并逻辑，control表的3031 LUT不等于纯身份流水逻辑成本。层次值用于对比相同流程，不替代逻辑cone逐门归属。

### 存储推断

- OACC even：416×512；odd：400×512；各7 RAMB36＋1 RAMB18
- FACC-A/B even/odd：逻辑26/25深度，物理映射32×512 distributed RAM；共1,184 LUTRAM
- 未使用额外BRAM output register；Vivado明确提示可能影响时序。增加寄存必须重新设计ACC返回/forwarding边界，不能只改RAM属性而保留原延迟标签
- RAM总线宽512是parity row，不是另一套完整ACC副本

## 6. 分发树、高扇出与Pblock

568个显式LUT1均在网表中保留：scale104、forward80、common144、ACC masks240。它们不是新增stage，但每条相应组合路径确实包含LUT1延迟。

综合后仍存在：最大592-load的FACC写使能/控制网，512-load的读/选择控制，304/288-load地址译码；forward单lane叶还可驱动约32个数据mux输入。树把广播分层，但未自动消除本地数据mux和RAM decode扇出；后续需结合放置/route再判断。

当前四个硬Pblock已非空匹配、组间无重叠、排除ACC RAM，并写入 [synthesized_with_locality.dcp](Pcore/reports/v2_synth_20261013/synthesized_with_locality.dcp)。网表约束预算：

| 位置组 | clock region | LUT预算 | 区域LUT容量 | 占比 | FF |
| --- | --- | ---: | ---: | ---: | ---: |
| row0 col0～7 | X3Y1 | 9,432 | 10,560 | 89.32% | 4,392 |
| row0 col8～15 | X4Y1 | 9,494 | 13,920 | 68.20% | 4,392 |
| row1 col0～7 | X3Y2 | 9,384 | 10,560 | 88.86% | 4,392 |
| row1 col8～15 | X4Y2 | 9,574 | 13,920 | 68.78% | 4,392 |

这里只证明综合网表成员与静态容量预算，不证明已放置成功。左侧两个区域近89% LUT占用，局部routing与SLICE packing余量偏紧；增加stage/控制副本时要重新核对。现有Pblock `EXCLUDE_PLACEMENT=false`，其他未约束cell仍可能进入区域，不能把预算百分比当最终拥塞。

## 7. 后续调整流水的优先依据

1. **Q1最先处理**：23级组合、4.969ns，lead→exponent/classify→shift/guard/sticky→increment/pack串行。Q0的1.770ns相对宽裕，可先研究把部分指数/移位分类移到Q0，或重构Q1并行舍入；本轮不实施改动。
2. **控制compare→A0单独优化**：Q1/A3/C数据到A0为2.265/2.535/2.598ns，但producer key控制到A0为4.166ns。不要把问题误归因于FPADD数据feedback本身；检查地址表达式、中央compare和选择信号何时产生，保持Delta4时序。
3. **先厘清SRL，再决定A0/A1边界**：A1名下4.562ns是sideband SRL输入路径。可做选择性禁止相关sideband SRL的小实验，量化FF增长与路径变化，不能全局禁止或改级数掩盖。
4. **CLOSE A2余量小**：exp1 3.748ns、mantissa+1 3.362ns；LZA correction→normalize→候选增量链是重点。A3 D pin1.536ns较轻，可评估重新分配候选运算；但必须重新验证A3→A0四拍反馈，不能只看顺向时间。
5. **暂不按ACC最慢假设拆存储**：当前综合ACC写入2.045ns、ACC→A0读3.605ns；未获得routing实测。先针对当前实测瓶颈设计实验，并在物理验证后再决定bank/列分区。

4.988ns≈4ns−WNS只可作为本次约束下的粗略周期需求指示，不是签核Fmax，也不作为可直接运行的频率。

## 8. 报告文件与复现

| 文件 | 后续用途 |
| --- | --- |
| `path_delays.csv`、`*_top10.rpt` | 七级、纯顺向、feedback、ACC、字段级与全部lane路径 |
| `timing_summary_synth.rpt`、`check_timing.rpt` | setup/hold、约束覆盖与内部loop |
| `utilization.rpt`、`utilization_hierarchical.rpt` | 核心/shell及部分资源 |
| `register_mapping.csv`、`endpoint_coverage.csv` | FF/SRL与七级端点保留 |
| `buffer_tree_counts.csv`、`fanout.rpt` | 分发树实际保留、高扇出负载 |
| `pblocks.csv`、`deqacc_v2_core_region*_utilization.rpt` | 当前网表区域成员与容量预算 |
| `primitive_cells.csv` | 原语名称、类型；辅助重建报告查询 |
| `source_sha256.csv`、`report_script_sha256.txt` | 综合输入版本与最终报告脚本版本 |
| `synthesized.dcp`、`synthesized_with_locality.dcp` | 同一综合网表，无/有局部约束；均未放置布线 |

初次报告收尾因hierarchical查询规则失败，随后在同一DCP上补报，不重复综合。`source_sha256.csv`保留初次综合时脚本hash，脚本后续改动仅修复报告匹配；最终报告脚本hash单独记录，不修改旧hash冒充同一版本。

从`DEQACC/Pcore/`执行下一次新基线：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_deqacc_v2_synth.ps1
```

脚本自动生成新的时间戳目录，不覆盖本基线；使用同一cmd先call settings64.bat再call Vivado官方bat。终端timeout至少300000ms，完整报告建议3600000ms。

已有DCP仅补报：

```text
vivado.bat -mode batch -source synth_deqacc_v2.tcl -tclargs <Pcore绝对路径> v2_synth_20261013 report_only
vivado.bat -mode batch -source report_deqacc_v2_census.tcl -tclargs <Pcore绝对路径> v2_synth_20261013
```

这两条也须在加载settings64的同一cmd内调用。此基线用于下一轮对照：先提出寄存边界/算术或控制修改，再跑数值/feedback回归和同流程综合；最终以授权后的post-route验证真实250MHz。
