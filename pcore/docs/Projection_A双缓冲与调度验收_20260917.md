# Projection A双缓冲与Attention调度验收

## 1. 本轮范围与取舍

依据本轮上传的建议及用户要求：先优化占比大的等待；小于总周期5%的开销，优先保留简单控制和交接余量。
不做RoPE、不做Projection到Attention物理串接，不修改其他同学的正式GCore/VPU/SFU/HBM实现。

本轮修改Projection A缓冲和调度，保留原有MXU、DEQACC算术顺序和W单Tile重排结构。
Attention执行RTL不改，只新增一个使用真实矩阵通路的55-block调度验收入口。

## 2. 前后对比

计时从Projection任务接受到`job_done_valid`有效，包含当前VPU行为模型的量化/写回过程，
不包含任务完成后的TB逐地址QOZ读回。两版使用相同输入、算术参考和行为客户端。

| 互斥周期分类 | 优化前 | 优化后 | 处理 |
| --- | ---: | ---: | --- |
| MXU有效输入发射 | 52224 | 52224 | 计算量不变 |
| 首次发射前冷启动 | 54 | 54 | 保留 |
| 后续A pair等待 | 26061 | 0 | 双Bank接收/计算重叠 |
| W就绪等待 | 0 | 0 | 无需增加W assembler |
| 非最终pair尾流水等待 | 5456 | 0 | last issue时释放A |
| 每个nt最终归约等待 | 176 | 176 | 必须等真实commit |
| VPU post阶段 | 2480 | 2480 | 单FACC串行交接，保留 |
| 其余控制 | 1022 | 1022 | 保留简单状态切换 |
| 总周期 | 87473 | 55956 | 减少31517拍，约36.03% |

有效发射占比为`52224 / 总周期`：从59.703%提高到93.330%。这是本测试任务的周期利用率，
不是DSP资源占用率，也不是已达到某个FPGA工作频率的证明。

优化后恰好满足：

```text
55956 = 52224 + 54 + 176 + 2480 + 1022
节省 = 26061 + 5456 = 31517拍
```

`pair_gap`和`tile_gap`是相邻输入发射的间隔诊断，与上表重叠，不能再加到总周期中。
正常场景中，两者都是992拍：同一pair的偶数kt到奇数kt连续；相邻pair有2拍空隙。
共有`16 × (32-1) = 496`个nt内部pair边界，故为`496 × 2 = 992`拍。
这占总周期1.773%；其余30拍属于nt之间的控制切换。
post占4.432%，最终drain占0.315%。本轮都保留，不增加FACC双份后处理流水或零间隙组合交接。
各项低于5%不代表它们相加仍低于5%；本轮总体非发射占比为6.670%，满足用户80%以上目标。

## 3. A缓冲的物理逻辑结构

`dea8_projection_xpair`内部新增第二份A pair存储，两Bank轮流拥有输入数据：

| 存储 | 组织 | 有效位数 |
| --- | --- | ---: |
| A数据 | 2 Bank × 2 K块 × 51行 × 128bit | 26112 |
| A scale | 2 Bank × 2 K块 × 51行 × 8bit | 1632 |
| 合计payload | 两份A pair | 27744bit = 3468字节 |

相对原单pair增加1734字节。另有每Bank的状态、pair/nt/epoch标签、接收计数器和同步读输出寄存器，
不包含在payload容量内。数据与scale分数组、同地址写入/读取。
目前描述的是RTL逻辑存储；本轮未对新A双Bank做综合，不能据此确定其最终BRAM/LUTRAM/FF映射。

一个XBC beat仍是256bit数据加16bit scale，对应同一行两个相邻K块。
每Bank接收51个beat，之后可供两个Tile各计算51行，共102个有效发射拍。
充分供数时`51 < 102`，下一pair的装载可以隐藏在当前pair计算中。

```text
XBC数据/scale -> RX控制器 -> Bank0 DATA / SCALE
                       -> Bank1 DATA / SCALE

匹配expected nt/pair/epoch的READY Bank
    -> 同步读数据和scale（1拍）
    -> Q_ACT_REG接收 / 对应scale、tag输入边界
    -> MXU乘法及四级树 -> Psum及匹配旁带
    -> DEQACC -> FACC
```

每Bank状态为`EMPTY -> FILL -> READY -> ACTIVE -> EMPTY`。
RX维护独立`rx_nt/rx_pair/rx_row/rx_bank`，compute使用当前`nt/kt/row`。
填充Bank与计算Bank必须不同，READY/ACTIVE Bank不允许被RX覆盖；无空位就向XBC施加背压。
compute的`PAIR_RX`现在只等“所需pair已经READY”，不再控制接收器什么时候开始装载。
RX可在当前nt仍计算或post时预取下一个nt的pair0；无断供测试覆盖15次跨nt预取。

外部XBC格式没有增加nt字段，仍根据`nt -> pair(0,2,...,62) -> row(0..50)`有序流内部推导。
**真实GCore仍需确认按nt重放16遍XHAT的契约；这次优化没有取消该要求。**

## 4. 为什么可以在issue时释放

本实现的`pair_release`条件是MXU输入握手成立、奇数kt、row50。
此时同步A读已在上一个时钟沿完成，本拍数据被Q_ACT_REG接收；后续乘法、旁带和DEQACC都不再读取原A Bank。
因此可以释放该Bank接收之后的pair，不必等11拍后的算术尾部commit。

```text
最后一行A同步读完成
    -> 下一沿：Q_ACT_REG接收，释放旧pair
    -> 两拍控制交接
    -> 下一pair首行被Q_ACT_REG接收

旧pair的MXU/DEQACC尾流水继续推进，允许与新pair前部重叠。
```

同一个FACC行地址相邻K块更新至少间隔51拍，远大于当前归约RAW保护距离。
这里释放的是A源缓冲，不是清空FACC，也不是取消旧事务。
每个nt的`kt63,row50`发射后进入`NT_DRAIN`，仍等最后真实commit，才允许VPU读取本nt的51×16结果。
只有16个nt全部完成后，QOZ才包含51×256完整输出。
建议末段的“nt63”应理解为“每个nt的kt63”，不是有64个nt。

## 5. 为什么暂时不改W和post

现有W单Tile assembler需要接收9个HBM beat，再排出16列。
这个约25拍的主要数据传输窗口小于每Tile的51拍计算窗口；状态控制开销以实测计数为准。
充分供数回归确认`w_wait=0`，故无需复制W assembler或修改PE双Weight Bank。

post串行保留单FACC所有权：完成K归约后，VPU模型从真实FACC读回并量化，
写完当前nt的51组QOZ数据/scale且确认done，再让下一nt复用FACC。
2480拍已小于本轮总周期5%，继续并行化将涉及额外存储和所有权控制，本轮不做。

## 6. 功能与压力测试

每次完整Projection仍逐项验证52224个16-lane INT32 Psum、52224个FP32归约向量、
816个最终FACC向量、816组量化结果及真实QOZ RAM读回；不是向DUT灌入golden结果。

| 模式 | 实测完整任务周期 | 验收目的 |
| --- | ---: | --- |
| default | 55956 | A/W等待均为0，利用率93.330% |
| STALL | 57672 | A/W规则插空、post延迟，利用率90.553% |
| RANDOM_STALL | 67168 | 固定种子独立扰动HBM/XBC供数，保证数值和顺序 |
| A_STARVE | 56350 | 强制长时间A断供，A等待394拍 |
| W_STARVE | 56411 | 强制长时间W断供，W等待455拍 |
| CLEAR_RESTART / CLEAR_POST / CLEAR_READY | 重启后55956 | 清空ACTIVE/FILL/READY状态，丢弃旧epoch，再完整重算 |
| REPEAT | 每次55956 | 不做硬复位连续执行两个任务 |

随机断供场景利用率77.751%，不要求达到充分供数时的80%目标；外部平均供数不足时，缓冲不能创造带宽。
所有场景仍禁止Tile内部断流，缺数时停在Tile/pair边界。
新增覆盖检查包括两种Bank填充/计算方向、跨nt预取、512次commit之前的安全pair释放及clear后双Bank为空。
保留错误XBC上下文、提前post done、错误结果上下文、错误量化输出等负向检查。

## 7. Attention独立调度验收

新增`tb_dea8_attention_schedule_signoff.sv`，使用真实Core/队列/FIFO/MXU/DEQACC和现有外部行为客户端。
测试中独立计算预期Job顺序，核对op/block/head/epoch、每Job 16 Tile、每Tile 51行、last及commit计数。

```text
QK0, QK1, PV0, QK2, PV1, ... , QK54, PV53, [尾部SCALE槽], PV54
55 QK + 55 PV = 110 Job
1760 Tile，89760个输入及89760个commit向量
```

供数充分且行为客户端按当前时序完成时：首Job完成844拍，108个普通完成间隔各828拍，
PV53到PV54完成间隔1656拍，总矩阵完成`844 + 108×828 + 1656 = 91924`拍。
此后当前行为模型AFIN完成于92799拍。这些指标本轮未优化，也没有虚构QK55。

命令：`powershell -ExecutionPolicy Bypass -File pcore/rtl/run_xsim.ps1 -Test signoff`。
它也包含在`-Test all`中。CSV逐Job记录context、issue/commit数量和完成间隔。
这属于矩阵调度及接口行为模型联调，不代表正式VPU/SFU的算术精度、综合时序或完整pi0签核。

## 8. 证据与复现

最终`run_xsim.ps1 -Test all`退出码0：82个模式通过，其中43个正常PASS、39个错误注入触发预期断言。
日志内39条Fatal均对应负向测试，没有非预期Error；Python25项测试全部通过。
回归前后90个RTL、TB、参考模型和脚本文件的SHA256全部一致。
Attention调度CSV共110项，完成间隔分布为1个844、108个828、1个1656，最后完成于91924拍。

本轮源文件变更：

| 文件 | 作用 |
| --- | --- |
| `rtl/dea8_projection_xpair.sv` | 两Bank数据/scale、独立RX计数、上下文匹配、所有权断言 |
| `rtl/dea8_projection_engine.sv` | 开放计算期预取、last issue释放、NT_DRAIN最终commit屏障 |
| `tb/tb_dea8_projection_engine.sv` | 性能分桶、重叠覆盖、随机/长断供、READY clear、全尺寸数值验收 |
| `tb/tb_dea8_attention_schedule_signoff.sv` | 独立Job次序和828/1656/91924周期判据 |
| `tb/tb_dea8_attention_core.sv` | 复用测试客户端的开关，独立日志文件，避免重复统计PASS |
| `rtl/run_xsim.ps1` | 注册新增模式及signoff入口 |

- [优化前同口径日志](evidence/20260917_projection_perf/baseline/xsim.txt)
- [优化前周期计数](evidence/20260917_projection_perf/baseline/cycles.csv)
- [优化前源码校验](evidence/20260917_projection_perf/baseline/SOURCE_SHA256.csv)
- [本轮全量XSim日志](evidence/20260917_projection_perf/xsim_all.txt)
- [Python单元测试](evidence/20260917_projection_perf/python_tests.txt)
- [本轮受测文件校验](evidence/20260917_projection_perf/SOURCE_SHA256.csv)
- [回归后源码一致性复核](evidence/20260917_projection_perf/SOURCE_VERIFIED.csv)
- [Projection正常周期与分桶](evidence/20260917_projection_perf/projection_cycles.csv)
- [Projection随机断供](evidence/20260917_projection_perf/projection_random_cycles.csv)
- [A长断供](evidence/20260917_projection_perf/projection_astarve_cycles.csv)
- [W长断供](evidence/20260917_projection_perf/projection_wstarve_cycles.csv)
- [READY和ACTIVE Bank清空重启](evidence/20260917_projection_perf/projection_clear_ready_cycles.csv)
- [Attention逐Job调度验收](evidence/20260917_projection_perf/attention_schedule_signoff.csv)
- [Attention行为客户端周期](evidence/20260917_projection_perf/attention_signoff_clients_cycles.csv)

使用Vivado2022.2；在VLA根目录执行`python -m unittest discover -s pcore/tests -v`及
`powershell -ExecutionPolicy Bypass -File pcore/rtl/run_xsim.ps1 -Test all`。
Python不在PATH时向仿真脚本传入`-PythonExecutable`。
本轮只更新主开发目录，不更新独立Git发布快照、不自动推送GitHub。
