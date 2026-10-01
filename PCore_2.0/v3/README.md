# PCore 2.0 v3 数据面

## 2026-10-01：PCore Job入口与完整OP_GU

已同步现有G-U replay、Matrix交错累加、Pair Buffer和shared QOZ增量。本轮新增 `rtl/dea8_pcore_ctrl_v3.sv`，在统一操作入口跑通一条 `OP_GU`。最终 **24个testbench + Attention55 port-stress通过，3类错误completion拒绝检查通过**；证据为 `reports/v3_simulation_summary.txt`。本轮未运行综合/P&R。

### 两层Job契约

- 上层 `pcore_op_e`：Q/K/V/O/Down Projection、Attention、GU各自独立。`OP_GU`完成仅表示Z形成，不含Down。
- 公共 `job_header_t`：16-bit job_id、epoch、head、op；操作与各引擎completion必须返回接受时的context。
- Matrix子Job：`pcore_matrix_job_t`，mode保留MAT_PROJECTION/MAT_ATTENTION/MAT_GU，附n、k_tiles、m_rows。
- VPU/SFU使用各自payload：`POST_GU`、`GELU_GU`，不要求所有引擎解析统一大opcode。
- 当前controller只执行OP_GU，固定51行、64 K Tile、默认32 N Tile；其他操作返回 `JOB_UNSUPPORTED`。Projection/Attention继续独立回归，尚未挂到同一dispatcher。
- 所有命令/完成口在valid&&ready转移；停顿时保持payload。controller同时最多一个Operation、一个Matrix子Job、一个post tile；Matrix和上一tile后处理可重叠。

### OP_GU完成与资源边界

1. 锁存Operation，申请shared QOZ的Z region；region begin接受后启动内部GU local scheduler。
2. 发出32个MAT_GU子Job，每个由既有GU wrapper计算G/U；每n有3328次连续pair issue。
3. Pair Buffer完整后，分别发VPU和SFU Job。TB只有两个post Job均接受才读取真实G/U；SFU数学/乘法/量化为reference模型。
4. 每tile最后Z pair在QOZ写口被接受，向controller提供 `z_tile_commit`。VPU done必须在该commit之后（或同拍）；SFU done表示对应GELU生产完成。
5. 32次Matrix completion、32个post tile的VPU/SFU完成及Z commit、QOZ region complete全部满足，才置 `job_done_valid`，一直保持到ready。

协议错误（错误context、提前VPU done、非法Z提交等）置sticky `protocol_error`并进入FAULT；FAULT不发正常completion、不释放执行资源，必须对controller和相关引擎统一clear/reset。`JOB_PROTOCOL_ERROR`保存在completion payload中供诊断，但FAULT期间没有有效completion token。

QOZ begin的owner=QOZ_Z、tiles=32由当前固定GU adapter连接，epoch/head来自 `active_header`。GU结束后Z region继续保留给消费者，controller不自动release；下一Operation若需重用必须先由资源管理方消费/release。当前所有外部engine也必须随clear取消旧generation。

### 实际验证

- `tb_v3_gu_32_system` 不再直接启动GU scheduler，只发一条OP_GU（job_id=0x7319）。实际32 Matrix / 32 VPU / 32 SFU Jobs，1632行G/U、832个Z pair、832次shared QOZ回读均通过，完成context匹配。
- Z由实际RTL的G/U流计算，不再直接拷贝z_golden。TB使用tanh近似GELU、显式FP32舍入、乘法、E8M0 scale和RNE INT8量化，与独立Python生成的fixture逐项比较。这是固定刺激下的reference验证，不是正式SFU近似误差或模型精度签核。
- `tb_v3_pcore_ctrl` 覆盖不支持opcode、region/engine背压、Matrix完成后继续等待Z、QOZ complete barrier、completion保持、错误job_id隔离和clear恢复。
- 旧Matrix64 TB的job_tiles位宽修正为 `MATRIX_TILE_COUNT_BITS`，消除扩宽接口后的未知位停顿；保留1664次issue/commit、max_gap=1和数值检查。
- Projection golden通过；Attention继续body=416、steady=434、尾部867、最终tail439，未重写两条既有计算链。

### 当前仍未完成

- controller、GU wrapper、shared QOZ目前由系统TB按公开接口连接，还不是完整可综合PCore Top。Matrix完成脉冲由adapter附上接受时descriptor；正式共享Top需保留这一关联。
- A/B仍按每n供数；BFIFO无job-N标签，未启用跨n任意预取。内部GU scheduler的prefetch提示暂不消费，不能宣称跨n零启动开销。
- VPU/SFU后处理算术仍为TB reference，真实引擎未实现。没有新增250MHz硬件签核。
- 下一步先给Projection/Attention加Operation adapter并接同一dispatcher，再考虑共享资源Top和Layer/Denoise sequencer。

以下DEQACC及Attention章节保留各自baseline与接口背景；本节是当前Job集成进度。

## 当前状态：DEQACC_3.3ns

2026-09-30：Matrix 使用冻结的 `DEQACC_3_3ns`。本轮按 `interaction/AI工具意见.docx` 收尾 Attention v4 接口与验证：完整尾部 guard、描述符背压保持、延迟 PBUF 就绪、v4 独立专项、55-block 双模式和错误 completion 检查。**本轮只做 RTL 仿真，没有运行综合或 P&R。** 下文 DEQACC 时序仅属于其既有 baseline，不能外推到新 Attention scheduler/wrapper。

**当前 baseline 固定为 `DEQACC_3_3ns`**：11级、II=1，使用 `reports/DEQACC_3.3ns/final_250MHz.dcp` 作为最终 refined 物理实现证据。本阶段 DEQACC 优化到此结束，后续集成沿用此接口和数值/延迟契约。

### 改动与固定契约

- 11 级 D0..D10，输入采样到 commit 的 edge delta=10；32 lanes，每拍一个 row-pair，II=1。
- D0 abs/lead；D1 normalize/exponent；D2 partial prepare 与 ACC read；D3 partial finish 与对应 RAM response；D4 order；D5 align；D6 add/coarse LZC；D7 shift control；D8 normalize；D9 round/pack；D10 physical write/commit。
- ACC 内部读取使用 raw data + even/odd word valid，零值选择在 DEQACC lane 输入附近完成；外部 Result/VPU 接口保留 invalid→0 语义。
- arithmetic、metadata payload 和 lane result 不复位；reset/clear 清 valid、done/commit 和 RAM valid bitmap。invalid 时 payload 不保证为零。
- `add_old=0/1` 延迟一致；前者 old 输入置零且最终保留 partial 原值。保留 RAM response、lane/context 对齐和未提交同地址 RAW hazard 检查。
- FP32 算术规则与 frozen reference 一致，本轮未引入 close/far 算法或修改特殊值处理。

## 实际时序证据

Vivado 2022.2，`xcu50-fsvh2104-2-e`。输入和输出在 `DEQACC_3.3ns_timing_shell.sv` 中注册，shell 寄存器不计入正式11级延迟。先在4ns下综合、布局布线，再以更严格的3.3ns目标执行物理优化，最后在同一个 routed netlist 上恢复4ns出验收报告。

最终报告：`reports/DEQACC_3.3ns/refined_250MHz_timing.rpt`

| 指标 | 最终结果 |
| --- | ---: |
| 时钟周期 | 4.000 ns / 250 MHz |
| Setup WNS / TNS | +0.700 ns / 0 |
| Hold WHS / THS | +0.019 ns / 0 |
| 无时钟 / 内部未约束端点 / 组合环 | 0 / 0 / 0 |
| Failed / unrouted nets | 0 / 0 |

逐级 post-route Data Path Delay（logic + route）：

| 阶段 | Logic ns | Route ns | Total ns |
| --- | ---: | ---: | ---: |
| D0 abs/lead | 1.053 | 1.632 | 2.685 |
| D1 normalize/exponent | 0.802 | 2.330 | 3.132 |
| D2 partial prepare | 0.809 | 2.236 | 3.045 |
| D3 partial/RAM response | 0.266 | 2.884 | **3.150** |
| D4 order | 0.643 | 2.379 | 3.022 |
| D5 align | 0.677 | 2.209 | 2.886 |
| D6 add/coarse LZC | 0.698 | 1.590 | 2.288 |
| D7 shift control | 1.118 | 1.853 | 2.971 |
| D8 normalize | 0.397 | 2.029 | 2.426 |
| D9 round/pack | 0.726 | 1.965 | 2.691 |
| ACC storage 路径组 | 0.479 | 2.586 | 3.065 |

来源：`refined_stages.csv` 与对应 `refined_*.rpt`。路径按目的寄存器组统计，SRL 推断可能让部分路径跨逻辑字段边界；ACC storage 组包含读写控制，不等同于单独 D10 算术级。主要路径均≤3.3ns，多数≤3ns；尚不宣称全部≤3ns。

最终 refined checkpoint 资源（2026-09-30 18:42 重新打开 `final_250MHz.dcp` 执行 `report_utilization -hierarchical`）：

| 范围 | Total LUT | Logic LUT | LUTRAM | SRL | FF | RAMB36 | RAMB18 | DSP |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| DEQACC core | **33534** | 30827 | 1184 | 1523 | **20552** | 14 | 2 | 0 |
| 含 registered timing shell | **33814** | 31107 | 1184 | 1523 | **23872** | 14 | 2 | 0 |

来源：`reports/DEQACC_3.3ns/final_utilization.rpt`。以上替代首次 route 的资源数字；层次 LUT 统计直接采用 Vivado 报告，不手动相加。

同一 checkpoint 重新执行 `report_drc`：**0 Error、0 Critical Warning、1项 Warning**。唯一检查项为 `RTSTAT-10: No routable loads`，涉及 OOC shell 的1062条输出无可路由外部负载（包括 commit/result）；未豁免或隐藏。详见 `reports/DEQACC_3.3ns/final_drc.rpt`，这不是完整板级DRC签核。

**适用范围**：这是带真实 launch/capture FF 的独立模块 OOC 物理时序验证，不是整机上板验证。OOC 外部端口未绑定板级 pin，时钟源位置未指定；完整 PCore 的时钟树、外部接口及集成拥塞仍需重新实现验证。没有 false-path/multicycle 豁免内部算术路径，也没有降低目标频率。

复现（在本目录）：

```powershell
powershell -ExecutionPolicy Bypass -File .\run_DEQACC_3.3ns.ps1
powershell -ExecutionPolicy Bypass -File .\run_v3_xsim.ps1
```

`run_DEQACC_3.3ns.ps1` 串联 `DEQACC_3.3ns.tcl` 和 `DEQACC_3.3ns_refine.tcl`，新运行保存并核对源码哈希。本次实际执行为直接调用这两个 Tcl；最终 checkpoint 为 `reports/DEQACC_3.3ns/final_250MHz.dcp`。

仅重出最终checkpoint的资源/DRC，不重新实现：用Vivado batch运行 `report_DEQACC_3.3ns_final.tcl`，Tcl参数为本目录绝对路径。refine脚本也已加入最终资源与DRC报告，后续重跑保持相同输出。

## 数值与协议验证

统一入口 `run_v3_xsim.ps1`：17个正向 testbench、1次额外 Attention55 port-stress、3类错误 completion 的预期拒绝检查。最终状态以 `reports/v3_simulation_summary.txt` 为准，源码对应 `reports/v3_sources_sha256.csv`。负向测试只有命中指定 DUT context assertion 才通过，普通报错或 watchdog 不算成功。

DEQACC 上轮收尾仅删除无调用的 `normalize()`；对应专项日志为 `reports/DEQACC_3.3ns/baseline_cleanup_xsim.log`。DEQACC 最终 checkpoint 是既有 refined 网表；本轮 Attention 修改后更新的是仿真源码清单，未生成新综合/布线证据。

- lane frozen reference：1000000笔连续事务，加 clear 中断及16笔重启；共1000016笔输出检查通过。
- 32-lane：5000组连续 pair，轮换 FACC-A/FACC-B/OACC、地址、scale、符号、add_old、row mask；固定11级及metadata检查通过。
- 独立FP函数：400256次加法、76928次pack对拍。frozen reference 独立于本轮改动，但不是第三方IEEE全覆盖模型。
- Matrix64：1664次issue/commit，max_gap=1。
- Projection：`[51,1024]×[1024,256]`，完整数值、尾行及输出背压保持检查通过。
- Attention55 两种模式均逐项检查13056个最终OACC值、110个矩阵 job、55次 PBUF装载、416个QOZ A2和14080个KVB B2。
- `tb_v3_attention_scheduler` 现在实例化 **v4**。快/慢两轮各55 block，覆盖P/scale早晚就绪、随机Matrix ready、VPU/SFU长背压、命令保持、同拍完成、尾部guard、done保持及新epoch/head。实际覆盖：Matrix stalls=1644、VPU stalls=2708、SFU stalls=1531、simultaneous_done=56。
- `tb_v3_attention_matrix` 增加30拍 completion背压、pending PV先接受后装载PBUF、guard阻止launch时A预取，以及block/epoch/head错配拒绝。
- 三类负向测试分别注入Matrix epoch、VPU head、SFU epoch错误，要求相应 `completion context mismatch` assertion。断言用于仿真检测，不是硬件错误恢复接口。
- 其余检查：XBC M51/M50尾部、BFIFO连续流、pair-store region、跨bank ACC并发、PBUF身份和乱序保护。

历史命名的 `tb_fp32_acc_lane_v5`、`tb_deqacc32_v5_stream` 当前测试对象已是 `DEQACC_3_3ns`，名称保留以便对应既有回归入口。

## Attention 尾部与握手契约

- 保留 current + pending 描述符，利用当前Job末次issue后的排空时间预取下一Job的A。B预取继续由真实BFIFO背压约束。
- 删除 `TAIL_PREFETCH_CYCLES=8`。`TAIL_SCALE_SLOT_CYCLES=ATTN_NOMINAL_SLOT=433` 是完整架构时隙；PV53完成后即允许PV54描述符接受，不必等P/scale全部完成。
- 预取等待对应PBUF committed generation。新增 scheduler输出/wrapper输入 **`tail_launch_ready`**；最终PV的执行同时要求guard到期、P已提交、scale已提交。不能将该信号丢弃或在系统级固定为1。单独wrapper测试可由TB驱动。
- guard从PV53 completion握手边沿计入首拍，计数初值为 `TAIL_SCALE_SLOT_CYCLES-1`。数据按时到齐时，PV54首issue相隔PV53 commit **434拍**；源迟到会延长等待，不重新减去RAM启动补偿。
- 实测：PV54 descriptor在47734拍接受，47735拍开始预取，48166拍guard放行，48167拍首issue。即加载发生于完整guard内部，PV53→PV54保持867拍。
- `launch_valid` 不再依赖Matrix ready；`launch_fire` 才结合ready及当前completion是否已消费。完成通知被背压时，当前done/context保持，pending不得覆盖当前owner。
- VPU/SFU命令在valid且未ready期间锁存保持。Matrix completion按接受顺序和完整command校验；VPU/SFU只允许各一个in-flight，done必须原样回传完整context。
- pending描述符不变时，PBUF后续commit也必须刷新 `source_ready`；已把存储依赖展开为显式组合表达式，并通过延迟供数与慢端口模式验证。

### VPU/SFU done 定义

**done表示该命令的数据已提交、对下游可见，不是最后一个请求刚发出。** 各通道在valid&&ready时转移token；未握手保持valid和全部context。reset/clear取消当前generation，外部单元也必须取消相应in-flight，不能回送旧completion。

| 命令 | 允许发done的条件 |
| --- | --- |
| `VPU_QK_POST` | 本block供Alpha/SFU使用的score/row-state全部可见 |
| `SFU_ALPHA_EXP` | 对应alpha generation完整可见，P EXP与OACC scale可启动 |
| `SFU_P_EXP` | 本P generation生产完成、供P_POST消费的数据可见 |
| `VPU_P_POST` | 最后一个有效PBUF pair已被PCore接受且region committed |
| `VPU_OACC_SCALE` | 最后一次OACC更新已被正式accumulator接口接受并提交，后续PV可安全读取 |
| `SFU_RECIP` | reciprocal数据全部可供A_FIN消费 |
| `VPU_AFIN` | 最终输出全部提交完成，包括最后一个下游握手 |

若外部模块内部使用队列，“请求进入本地队列”不满足上述done条件；必须等待对PCore/下游可见的提交。当前accumulator写入接受边沿即物理commit。

### 两种55-block验收模式

| 指标 | Scheduling | Port-stress |
| --- | ---: | ---: |
| Matrix body | 416..416 | 416..416 |
| 首request→首issue | 8 | 8 |
| start握手→首issue | 9 | 9 |
| 末issue→最终commit | 18 | 18 |
| 普通稳态首issue间隔 | **434..434** | 434..501（不考核性能） |
| 普通handoff | **1..1** | 1..68 |
| PV53→PV54首issue间隔 | **867** | 928 |
| PV54 commit→Attention done | **439** | 449 |
| Attention job总周期 | **48620** | 52242 |
| VPU正式端口读/写 | 1430 / 0 | **24310 / 22880** |
| Matrix busy期间读/写 | 1430 / 0 | **23425 / 22048** |

Scheduling模式断言body=416、普通interval=434、尾部867及439，SFU P-exp=204、OACC scale=208、A_FIN=408拍是TB模型假设，不代表真实VPU/SFU RTL性能。Port-stress使用同一矩阵数值golden，通过真实ACC接口读写，强制检查非零读/写overlap；不限制上层慢模型的周期。两模式都不能省略数值/协议检查。

`first issue→commit=433` 是边沿差，body=416是有效issue计数（首末边沿差415）；因此commit tail为18。request/accept到commit会包含lookahead排队，已不再作为性能主指标。最终completion不再命名D4。job总周期从start握手算到Attention done握手，不含之前的QOZ装载与之后的debug核对。

报告：`reports/tb_v3_attention_55.txt`、`reports/tb_v3_attention_55_port_stress.txt`、`reports/tb_v3_attention_scheduler.txt`、`reports/tb_v3_attention_scheduler_bad_*.txt`。单独重跑慢模式：

```powershell
& "D:\Xilinx\Vivado\2022.2\bin\xsim.bat" tb_v3_attention_55_sim -runall -testplusarg PORT_STRESS
```

### 尚未执行：Attention综合/P&R

按本轮要求暂不运行。55-entry pending scan保留，是否需要pointer/FIFO替换必须由后续实际综合路径决定；没有声称已消除其潜在时序风险。新scheduler/wrapper的250MHz与资源尚无当前源码签核，不能借用DEQACC的WNS。该项是评审中唯一明确后置的验证工作。

## 数据面与接口边界

- 双行 MXU：16×16、256 DSP48E2，7级；51行转26个row-pair。
- Projection A：XBC4→2×A2→AFIFO；Attention A：QOZ/PBUF同步reader→A2→AFIFO。本地committed源使用4-entry streaming credit，外部XBC仍要求完整Tile。
- B：HBM/KVB B2→BFIFO→B1 serializer→双stationary bank；Job内锁存B源，本地模式允许Job间预取。
- QOZ：16 Tile、单head region、epoch/head一致；最后A2自动commit，全局clear后替换。Projection真实FP32→INT8量化尚未接入。
- PBUF：单Tile、双bank，slot=block_id[0]；26个顺序A2自动commit。block/epoch/head必须匹配，PV最终commit后release。错误顺序、mask、slot、active/full bank写入置sticky error。
- FACC-A/B/OACC各自独立1R1W，Matrix整个Job占用目标bank，VPU可访问其他bank。读请求valid&&ready接受，响应一拍且无响应背压；VPU写接口为`acc_write_t`。
- FACC保持LUTRAM；OACC保持14 RAMB36+2 RAMB18；AFIFO/BFIFO/PBUF/QOZ继续使用前轮BRAM结构。dbg口仅用于RTL仿真。
- Projection输出必须连接`qoz_wr_ready`，停顿时保持数据与tile/pair标记。
- 逻辑10-bit source ID与FIFO transport ID分离。实际HBM AXI/KVB寻址控制器、真实Mask/Softmax/EXP/reciprocal未在本目录完成。
- VPU/SFU算术仍为TB模型，Matrix 只依赖 `valid/ready/done`、epoch/head/block 上下文和 PBUF/scale 就绪信号；本轮 TB 按后续双 lane 方案将 SFU P-exp 建模为204拍、OACC scale为208拍、A_FIN为408拍，恒等 OACC scale 用于保持矩阵数值对拍。该模型验证的是调度与接口，不是 VPU/SFU 的 RTL 算术签核。
- Projection与Attention仍是独立wrapper；Top、G-U、VPU/SFU行级调度不属于本轮范围。
