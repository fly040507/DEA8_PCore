# DEQACC V2：8个硬区域、每组4 lane对照

2026-10-14。**8×4 Hard布局布线完成：WNS=−0.358ns，比原4×8 Hard改善，但不如No-Pblock的−0.222ns。八组CLB占用降至38.33%～73.64%，4ns仍未通过。**

原始报告：[v2_hard8x4_20261014](Pcore/reports/v2_hard8x4_20261014/)。[三版汇总](Pcore/reports/v2_hard8x4_20261014/three_way_summary.csv)、[七级汇总](Pcore/reports/v2_hard8x4_20261014/seven_stage_comparison.csv)。

## 1. 实验设置

同一个应用Pblock前的`v2_route_20261013/synthesized.dcp`，SHA256：`16c68c7223acedbc08a4148ec8bde23b8b1eb4431e1a18095e530519c85a7683`。

没有重新综合、修改RTL/七级/II/forwarding、降频或改变实现指令：4ns、Vivado2022.2、U50 -2-e、BUFG、完整接口观测壳；`opt → place Explore → phys_opt AggressiveExplore → route Explore`。

新的区域方案：同一SLR相邻4×2 clock-region矩形。row0/row1各四组，同行四列连续分组；每组一个硬Pblock（IS_SOFT=false），EXCLUDE_PLACEMENT=false、CONTAIN_ROUTING=false。

- 包含四lane完整Q/A/C、对应scale/forward/ACC读mask branch与本地控制叶
- ACC RAM和中央control spine自由放置
- 原common-control的八lane根branch由两个四lane组共享，16个LUT1根节点不分配Pblock，避免强塞一侧；这是8×4约束分组的一部分，不新增/删除buffer RTL
- 实现前检查成员非空、互不重叠、ACC RAM不混入；具体成员见`locality_members.csv`

本轮是在一个固定4×2区域摆放上做单次实验，不等于穷尽所有8×4位置/形状选择。

## 2. 全局三版结果

| 指标 | 4×8 Hard | 8×4 Hard | No-Pblock |
| --- | ---: | ---: | ---: |
| WNS | −0.685ns | **−0.358ns** | **−0.222ns** |
| TNS | −1521.264ns | **−310.534ns** | **−61.556ns** |
| setup失败端点 | 4,824 | **2,660** | **842** |
| WHS / THS | 0.000 / 0.000 | 0.008 / 0.000 | 0.004 / 0.000 |
| 最高region CLB占用 | 100.00% | **73.64%** | **74.17%** |
| 内部路由错误/overlaps | 0 / 0 | 0 / 0 | 0 / 0 |
| SLR crossing | 0 | 0 | 0 |
| 总占用CLB（含shell） | 6,797 | 7,673 | 8,267 |

8×4比4×8 WNS改善0.327ns；比No-Pblock仍差0.136ns，且TNS/失败端点明显更多。三轮内部网络全部布通，hold无失败，均未setup签核250MHz。

DRC没有Error，仅同样OOC输出无routable loads Warning；HD.CLK_SRC/PARTPIN边界提示仍在。这里比较内部已route顺序路径，不宣称板级I/O或真实八核签核。

## 3. 每区域实际占用

下面包括所有落入该区域的逻辑，不仅Pblock成员；EXCLUDE_PLACEMENT=false允许ACC/中央/观测逻辑进入。CLB占用不是“所有内部LUT都占满”。

| 组 | 同行列 | clock region | CLB | CLB占比 | LUT/容量 | LUT占比 |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| G0 | row0 col0～3 | X2Y1 | 878/2280 | 38.51% | 5017/18240 | 27.51% |
| G1 | row0 col4～7 | X3Y1 | 972/1320 | **73.64%** | 5550/10560 | 52.56% |
| G2 | row0 col8～11 | X4Y1 | 1178/1740 | 67.70% | 6598/13920 | 47.40% |
| G3 | row0 col12～15 | X5Y1 | 834/1800 | 46.33% | 4800/14400 | 33.33% |
| G4 | row1 col0～3 | X2Y2 | 874/2280 | 38.33% | 5023/18240 | 27.54% |
| G5 | row1 col4～7 | X3Y2 | 957/1320 | 72.50% | 5499/10560 | 52.07% |
| G6 | row1 col8～11 | X4Y2 | 1191/1740 | 68.45% | 6734/13920 | 48.38% |
| G7 | row1 col12～15 | X5Y2 | 783/1800 | 43.50% | 4750/14400 | 32.99% |

原99.85%/100%密度问题已消除，但这并不自动保证整体最优。8×4固定矩形的东西跨度大于原2×2，中央ACC/控制还要服务两行16列；局部packing放松与中央广播距离之间存在权衡。

## 4. 七级post-route路径

各类别最差Slack路径，单位ns，具体起止点可能不同；不能相加当作事务延迟。

| 级 | 4×8 total | 8×4 total | 8×4 logic / route | 8×4 Slack | No total / Slack |
| --- | ---: | ---: | --- | ---: | --- |
| Q0 | 3.588 | 3.578 | 0.651 / 2.927 | +0.297 | 3.430 / +0.415 |
| Q1 | 4.713 | **4.254** | 1.533 / 2.721 | **−0.353** | 4.044 / −0.222 |
| A0 | 4.917 | **4.191** | 1.204 / 2.987 | **−0.358** | 3.983 / −0.130 |
| A1 sideband | 4.774 | **4.233** | 1.294 / 2.939 | **−0.358** | 4.028 / −0.219 |
| A2 | 4.582 | **4.080** | 1.403 / 2.677 | **−0.160** | 4.085 / −0.099 |
| A3任意pin | 3.595 | **3.321** | 0.466 / 2.855 | +0.468 | 3.796 / +0.180 |
| C数据 | 2.165 | **1.707** | 0.078 / 1.629 | +2.199 | 1.681 / +1.979 |

A1最大值仍是中央forward分类到sideband SRL D，不代表纯A1算术；8×4 LZA=3.618ns/+0.228ns，FAR=3.138ns/+0.739ns。A3 D数据pin=3.161ns/+0.673ns。

其他路径：

| 类别 | 8×4 total / Slack | No total / Slack |
| --- | --- | --- |
| 中央forward控制→A0 | 4.191 / **−0.358** | 3.983 / −0.130 |
| ACC读选择→A0 | 3.834 / **−0.190** | 3.943 / −0.003 |
| ACC写/读控制incoming | 3.785 / **−0.300** | 3.662 / −0.004 |
| A3数据反馈→A0 | 3.156 / +0.806 | 3.005 / +0.600 |
| C数据反馈→A0 | **2.680 / +1.257** | 2.899 / +0.728 |
| reset/clear→core | 3.538 / **−0.127** | 3.173 / +0.378 |
| 外部读→capture | 3.190 / +0.443 | 2.955 / +0.937 |

total小不必然Slack更好，源/目的clock skew、setup/uncertainty和端点不同。这里A2 total几乎一致，No的Slack仍更好；应按完整STA判断。

### 原关键起止点复查

同4×8基线的固定pin仍能比较者：forward地址→A0 distance[7]为3.775ns/+0.152ns（原4.917/−0.685）；CLOSE exponent→A2 exp1[5]为3.540ns/+0.383ns（原4.582/−0.677）；C数据→A0 distance[5]为1.778ns/+2.162ns（原3.574/+0.682）。

这些原点路径显著改善，且部分优于No；不能因此忽略另一lane/另一控制源成为新关键链。全部固定endpoint/exact_pair状态和clock skew见`matched_paths.csv`；phys_opt副本不存在者标MISSING_PIN，不用相近名称伪造匹配。

## 5. 失败端点与资源

| 类别 | 4×8失败 | 8×4失败 | No失败 | 8×4最差Slack |
| --- | ---: | ---: | ---: | ---: |
| Q1 | 992 | 937 | 634 | −0.353 |
| A0 | 2614 | 1204 | 153 | −0.358 |
| A1 sideband | 67 | 46 | 29 | −0.358 |
| A2 | 270 | 48 | 10 | −0.160 |
| ACC | 810 | 425 | 16 | −0.300 |
| 外部capture | 71 | 0 | 0 | — |

8×4核心：43,982 LUT、20,714 FF、1184 LUTRAM、715 SRL、14 RAMB36＋2 RAMB18、1124 CARRY8、0 DSP。观测壳额外4379FF＋1 BUFG。三版逻辑资源非常接近，收益/退化主要来自物理实现选择，不是RTL功能量变化。

## 6. 判断与后续建议

1. 8×4有效缓解容量问题，比4×8更合理；但本次仍不如No-Pblock整体时序
2. “density解除”是必要改进之一，不充分说明硬Pblock能取得最佳时序；固定矩形会影响中央ACC/forward接口距离，这是本轮结果支持的解释，未单独测线长因果
3. 局部LZA/A3与C反馈有优势，可保留8×4作为有可控布局需求的候选；当前单核时序基线仍建议No-Pblock
4. 下一轮若继续探索物理约束，可单独试soft/更紧凑的区域形状；若改RTL，则以No基线针对Q1与控制链优化，保留四拍反馈验证

本轮没有自动再扫其它位置、改RTL、合并DEA8或推送。报告完整保存三版对照，三版都没有4ns setup PASS。

## 7. 复现

从`DEQACC/Pcore/`执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_deqacc_v2_nopblock.ps1 -FourLane -Baseline v2_route_20261013
```

历史入口名保留，`-FourLane`选择8×4 Hard；不带该参数仍是No-Pblock。工具通过同一cmd先call settings64.bat再call官方Vivado bat，timeout建议3600000ms。需要相同本地pre-Pblock综合DCP；filelist/功能RTL不变。

本轮constraint脚本：`deqacc_v2_locality4lane.tcl`。区域清单/成员、八个Pblock利用率、267项路径/32-lane数据、同端点对照、各clock-region密度和routed checkpoint均位于报告目录。
