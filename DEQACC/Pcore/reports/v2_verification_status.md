# DEQACC V2 验证结果

更新时间：2026-10-13。**当前V2剩余功能仿真已完成：短套件、发布V1/V2 lockstep和完整七Job均PASS。综合、布局布线未执行，250MHz物理时序未验证。**

V2沿用V1模块/文件名，日志中的`tb_deqacc_v1_*`是当前V2源码编译的测试，不能仅按名称判断版本。最终结果：[v2_simulation_summary.txt](v2_simulation_summary.txt)，对应源码/TB：[v2_sources_sha256.csv](v2_sources_sha256.csv)。

## 1. 本次修复

### 标准工具入口

`run_deqacc_v1.ps1`移除shadow数据根、手工RDI/TEMP设置和直接unwrapped调用。每次调用均在一个cmd内先call Vivado 2022.2 settings64.bat，再call工具bat。此前记录的系统DLL阻塞在该入口下未复现，没有安装新工具或修改Vivado安装。

双库config绑定的lockstep尝试仍触发XSim内部展开异常，O0/O2都失败；最终改为测试目录中的仅模块名改动V1副本，同库直接实例化，成功运行。这个异常不作为RTL功能失败，也不作为未完成验证的借口。

### ACC读取提前导致Delta=6错误

- 首次stream在commit序号5241失败：`got=7fc00000 expected=bee07c8f`
- V2把同步ACC读从Q0寄存后移到事务输入接受沿，Delta=6时会与前序C写回同沿读取，read-first返回旧值
- 两拍后的A0已错过该前序A3/C旁路窗口，不能修复旧RAM数据
- 恢复为已寄存Q0的valid/bank/address驱动读，在Q1返回，与A0消费对齐；没有加stage、没有拆ACC
- Delta=4/5/6/7及完整七Job重新通过

### shift=32的sticky边界

- 扩大scale范围后定向例：psum=INT_MIN，Ea=42、Eb=43、fold=0，期望`0x80000000`，实际`0x80000001`
- 原case没有distance=32专项，default的`|value`把guard位31也计入sticky，破坏RNE tie-to-even
- 补`distance=32: sticky=|value[30:0]`；guard仍取bit31
- 新测试包含shift32/33、全部合法base范围−298…273；冻结golden未改

## 2. 最终验证

最后一次执行：`run_deqacc_v1.ps1 -SevenJobs`；修正后的RTL重新编译、展开、运行，退出码0。普通用例无Fatal/Error；三个RAW负例仅有预期RAW Fatal，脚本明确验证其消息和数量。

| 测试 | 最终结果 | 日志 |
| --- | --- | --- |
| Dequant/FPADD | 各211,978笔逐位匹配；Q=2级、A=4级、II=1；CLOSE27,134、FAR异号90,731、bypass5,959 | [算术](v2_tb_deqacc_v1_arithmetic.log) |
| 32-lane stream | 10,486笔commit，七级、II=1；含5,000笔A11对照；A3命中276、C命中271；全ACC模型、parity、clear、外部read-first与反压通过 | [stream](v2_tb_deqacc_v1_stream.log) |
| 动态M/真实MXU | M=1/2/3/7/16/31/51；逐笔累加正确；最小复用间隔17/26拍 | [动态M](v2_tb_deqacc_v1_dynamic_matrix.log) |
| Matrix | 64 Tile、1,664 issues/commits、max issue gap=1 | [Matrix](v2_tb_matrix.log) |
| RAW负例 | 依赖间隔1、2、3分别触发指定拒绝 | [Δ1](v2_BAD_RAW.log)、[Δ2](v2_BAD_RAW_2.log)、[Δ3](v2_BAD_RAW_3.log) |
| V1/V2 dequant lockstep | 211,978笔；Q0 magnitude/lead/base/sign/zero/bad字段及Q1位模式一致 | [Dequant lockstep](v2_lockstep_tb_deqacc_v1_arithmetic.log) |
| V1/V2完整lockstep | 10,486笔；七级key/valid、Q1/A3/C、有效parity old选择、A3/C source、metadata/data、外部响应和全ACC一致 | [完整lockstep](v2_lockstep_tb_deqacc_v1_stream.log) |
| 完整七Job | K/V/Q/Attention/O/G-U/Down全部完成；265,408issues、55QK+55PV；数值、Q/O/Z、输出数量检查通过 | [七Job](v2_tb_pcore_control.log) |

V1/V2对照不是两轮统计相同：两个RTL同时接收输入并逐拍比较。参考来自已发布提交`af6263595efe13b200101d3774bc1df604f288fb`。四个变化模块的副本位于`tb/reference/`，逐文本核对仅标识符替换；共享package、FPADD、控制与bank模块hash和发布版相同，并由脚本检查固定hash。

FPADD没有被V2修改，因此当前A0/A1/A2结构与发布V1文本一致；stream比较A3数值和七级key/valid，未宣称独立验证了尚不存在的LZA中间状态。随机/定向覆盖不等于全域形式等价证明。

## 3. 七Job周期

模式：FUNCTIONAL，TB周期4ns。与V1发布记录逐Job相同；并未新增PERFORMANCE或八核系统结果。

| Job | V2周期 | matrix issues | 全Job矩阵占比 |
| --- | ---: | ---: | ---: |
| K | 3,783 | 3,328 | 87.97% |
| V | 3,651 | 3,328 | 91.15% |
| Q | 27,079 | 26,624 | 98.31% |
| Attention | 49,025 | 45,760 | 93.34% |
| O | 28,021 | 26,624 | 95.01% |
| G-U | 107,320 | 106,496 | 99.23% |
| Down | 54,645 | 53,248 | 97.44% |
| 合计 | 273,524 | 265,408 | — |

合计仅为Job周期相加，不含Job间握手等待。矩阵占比为issues/Job周期，不是逐PE有效MAC比例。FUNCTIONAL含人工背压与K/V发送/commit尾部；不会因为K的87.97%修改测试模型或隐藏收尾。

## 4. 复现入口与参考

从`DEQACC/Pcore/`执行：

```powershell
# 包含lane、stream、动态M、Matrix、RAW负例及V1/V2同拍对照
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_deqacc_v1.ps1
# 加完整七Job FUNCTIONAL；本次最终验证使用此入口
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_deqacc_v1.ps1 -SevenJobs
```

短套件外部timeout≥300000ms；完整套件建议3600000ms。脚本、filelist、snapshot和日志都使用支持的Vivado launcher；没有直接启动unwrapped工具。

- 活动RTL/filelist仍沿用V1名称，避免无关迁移
- `v2_lockstep.f`只用于测试；发布参考副本不会进入正常PCore或综合清单
- `tb/reference/v1_shared_sha256.csv`固定共享依赖；后续FPADD/公共模块改动时需独立冻结参考，不允许盲目更新pin使检查通过
- 出版V1参考副本与原版标识符对应、已核对共享依赖清单见`tb/reference/README.md`

## 5. 当前设计边界与后续

已完成当前RTL的剩余功能仿真，没有行为验证阻塞。`DEA8/`、V1历史报告和GitHub同步仓库未修改；本轮未推送。

尚未实现/验证的方案项目：

- FPADD仍为精确LZD，没有USE_LZA或LZA预测/修正；不能声称完成局部LZA优化
- scale仍逐事务由MXU response捕获，Ea/Eb可随pair/tile变化；不能按Job固定上下文替换
- stage固定七级，Delta<4是仿真协议断言，不是新增硬件stall；真实上游需遵守约束
- 本轮无综合/P&R、资源统计或250MHz签核；单个完整ACC外围routing收益仍待测

下一步可单独推进LZA与scale结构优化，或在获得物理验证指令后测当前完整ACC/四cluster的真实时序。每次RTL变更均以本次边界用例与V1对照回归，不能使用旧V2日志当作新源码证据。
