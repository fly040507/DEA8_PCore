# DEQACC V3 版本说明

定义及冻结日期：2026-10-14。**V3已完成本轮重新仿真、综合布局布线，暂时冻结。**七级、II=1、Delta4保持，250MHz独立OOC post-route WNS=+0.544ns，达到现阶段0.5ns裕度要求。

## 1. 功能与约束

- 32 lane：两行×16列；每拍一笔MXU response，独立地址II=1
- 七级：Q0/Q1反量化 → A0/A1/A2/A3浮点累加 → C提交
- 相同ACC地址、相同有效parity依赖间隔≥4拍；Delta4/5由A3/C已舍入结果旁路，其余按RAM/旁路匹配
- RNE、subnormal、NaN/Inf、signed zero、INT_MIN、overflow等与冻结参考逐位一致
- 单个完整FACC-A/FACC-B/OACC，even/odd两平面，按row_valid更新；无效old=0，clear清有效状态而非data RAM
- 中央metadata流水保留；local scale/控制分发，未增加隐藏寄存级
- 保留result读、VPU写、commit_valid/meta/write/done接口；同bank在途任务反压，不同bank可并发
- 源接口没有ready；<4拍RAW由仿真断言拒绝，不新增硬件stall

外部模块继续使用现有类型/模块名（`DEQACC_V1`等），V3由本文件和freeze hash定义，不做大范围命名迁移。

## 2. V3相对原七级版本的关键变化

1. physical address在入口寄存并流水，不在A0临时生成
2. forwarding来源比较提前一个已有边界：`keys[4]/keys[0]`、`keys[5]/keys[0]`比较后寄存，下一拍用于当前A3/C取数；不转发未舍入结果
3. Q1 normal/subnormal分别并行shift-jam与有效尾数RNE，分类只选择结果；移除宽guard/sticky选择链的关键路径依赖
4. 采用No-Pblock实现，目标3.5ns驱动物理优化，最后同一网表4ns验收至少+0.5ns；不使用false-path/multicycle或修改计算标准

仍七级，九级候选未实现；A3及某些反馈route仍大于2ns，本版验收是整体时序/裕度，不声称全部A路由≤2ns。

## 3. 地址、时序与复位

当前profile：51行、26pair、每Tile16列。FACC地址为pair_idx；OACC为pair_idx×16＋nt，even深度416、odd400。row mask限制odd tail。

沿e0接受Q0，e1 Q1，e2 A0，e3 A1，e4 A2，e5 A3，e6 C输出更新；下游e7采样，接口计为7级。4ns下7拍预算28ns，不将沿后首次valid的6个完整周期误称为6级。

clear/reset同时失效pipeline、旁路选择和ACC validity；旧事务不会迟到提交。新Job遵循上游drain/flush边界，不跨未完成Job重标metadata。generation仅区分flush，不替代清RAM validity。

## 4. 本轮收尾范围

收尾仿真：212k级算术随机/定向、完整32-lane依赖流、11种动态M真实MXU、64Tile Matrix、三个RAW拒绝；不跑完整七Job/stress长回归。

收尾实现：Vivado2022.2、U50`xcu50-fsvh2104-2-e`、BUFG/全接口observability壳；synth(4ns) → opt/place/phys_opt/route(3.5ns) → 同网表恢复4nsreport。核心数据与完整commit_write均可观测，shell额外4379FF不计入核心级数。

输出：`Pcore/reports/v3_simulation/`、`Pcore/reports/v3_postroute/`。只保留每级/关键接口单条路径、总体资源、route status、DRC和DCP，不逐lane生成细节利用率。

之前通过的V2裕度结果用于定义版本；本次从当前源码重新编译和实现，实测见下节。完整PCore/八核的I/O、clock与拥塞需在集成时重新签核，独立OOC裕度不保证系统不退化。

## 5. 收尾结果与冻结

### 功能仿真：全部通过

| 用例 | 本轮结果 |
| --- | --- |
| Dequant / FPADD | 各212,166笔独立golden逐位一致，Q两级/A四级，II=1 |
| 完整32lane stream | 10,486笔commit，含5,000笔A11参考对照；七级、Delta4/5/6/7、identity/data/row mask通过 |
| 算法覆盖 | LZA correction 5,835次、exact 13,943次，round-up 81,979、round-down 115,365 |
| 状态/外部接口 | A3/C命中276/271，clear、全ACC模型、外部读写、same-bank反压通过 |
| 动态M | M=1/2/3/4/7/8/16/31/32/50/51，真实MXU逐笔正确 |
| Matrix | 64Tile，1,664 issues/commits，max issue gap=1 |
| 非法RAW负例 | 1/2/3拍依赖均只触发指定RAW拒绝 |

证据：`Pcore/reports/v3_simulation/summary.txt`和对应日志，源码版本` sources_sha256.csv`。TB模块名仍沿用V1/V2，与文件兼容名一样不代表旧波形。

### 实际综合布局布线：完成且达到裕度

首轮4ns WNS=+0.494ns，250MHz满足但少0.006ns裕度，脚本未误报通过。功能RTL不改，仅在已有routed网表上做**一次**3.45ns物理优化/route收尾，最终恢复4ns验收：

| 指标 | 冻结V3结果 |
| --- | ---: |
| 时钟周期 | 4.000ns |
| WNS / TNS | **+0.544ns / 0** |
| WHS / THS | **+0.001ns / 0** |
| setup / hold失败端点 | **0 / 0** |
| 核心LUT / FF | **49,586 / 20,743** |
| 核心Logic LUT / LUTRAM / SRL | 47,679 / 1,184 / 723 |
| RAMB36 / RAMB18 | **14 / 2** |
| DSP / URAM | 0 / 0 |
| 观测壳额外资源 | 4,379FF＋1个BUFG，整体FF=25,122 |
| 内部布线 | 全部完成，routing errors=0 |

DRC无Error，保留OOC输出无routable loads Warning；输入clock/partpin的外部OOC边界不能当作板级验收。没有降低运行时钟、multicycle/false-path或改变算术标准。

### 七级真实路径延迟（ns）

每行取本级最差Slack路径，可能来自control/RAM而非本级纯算术。数据来自完成布线的顺序路径；不可把七行最大值相加为一笔事务用时。

| 级 | Logic | Route | Total | Slack |
| --- | ---: | ---: | ---: | ---: |
| Q0 | 0.802 | 2.494 | 3.296 | +0.662 |
| Q1 | 1.245 | 2.215 | 3.460 | +0.546 |
| A0 | 1.677 | 1.518 | 3.195 | +0.550 |
| A1 | 1.818 | 1.402 | 3.220 | +0.552 |
| A2 | 1.257 | 2.085 | 3.342 | **+0.544** |
| A3 | 0.479 | 2.592 | 3.071 | +0.693 |
| C | 0.078 | 1.320 | 1.398 | +2.413 |

A1最大路径包含ACC返回→sideband SRL，A3上述路径止于同步R pin；A3数据D pin另为3.160ns/+0.736ns。完整13类路径见`stages.csv`：forward控制→A0 +0.656ns，A3/C反馈 +0.840/+0.957ns，ACC写 +0.582ns。

### 冻结交付

`Pcore/V3_FROZEN.sha256.csv`固定完整副本的RTL/TB、filelist、脚本和约束（不包括缓存、日志或可更新文字）；两条V3入口先验证hash。`Pcore/reports/v3_postroute/source_sha256.csv`是首次综合输入，报告脚本的收尾调整另外记录，不伪造初次hash。

`Pcore/reports/v3_closure.txt`记录最终验收；`v3_postroute/artifacts_sha256.csv`固定最终DCP与STA证据。暂时冻结的是已验证V3，不自动修改成九级、不继续优化、未推送或合并DEA8。

## 6. 复现与维护

从`DEQACC/Pcore/`：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_deqacc_v3.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_deqacc_v3_route.ps1
```

已有报告目录不会被静默覆盖；复现需先明确另存旧结果或选择新的route tag。默认工具路径`D:\Xilinx\Vivado\2022.2`，每次在同一cmd先call settings64.bat再call工具bat，不直接unwrapped或手工PATH/RDI/Tcl设置。短套件timeout≥300000ms，完整P&R建议3600000ms。

V3冻结后不直接修改算术、接口、tail常量、工具约束或golden。下一轮变更先定义新候选版本，保存V3 hash与证据再继续；合并DEA8/推送GitHub需要另行指令。

旧方案文字保留在`history/`，原始docx没有删除。废弃区域实验DCP、长报告、旧日志和临时波形/缓存已删除；A11、golden与test-only参考源码保留，因为它们是有效验证依赖。最终`routed.dcp`保留；本轮首轮略不足裕度的DCP也保留在同一收尾目录供核查，不作为另一个候选方案入口。
