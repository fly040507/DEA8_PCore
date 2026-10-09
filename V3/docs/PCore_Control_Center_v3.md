# PCore 控制中心 V3

2026-10-07 实现。设计依据：`interaction/Pcore控制方案.md`。此说明描述接口与实现；验证状态以本次源码对应的控制仿真日志为准。

## 外部 Job 与完成

`dea8_pcore_control_v3` 一次接受一个 DEA8 Job，使用 Projection、Attention、G-U 三个 Engine 共享现有 Matrix。保留七种 opcode，层数和去噪步由 DEA8 处理。

| Job | 后处理 | 完成屏障 |
|---|---|---|
| K | RoPE、feature-B16 量化 | 52 个本核 KV 包已发送，内部事务退休 |
| V | token-B16 量化 | 64 个本核 KV 包已发送，内部事务退休 |
| Q | RoPE、feature-B16 量化 | QOZ_Q 16 Tile 提交 |
| Attention | 110 个矩阵子任务与 Softmax、缩放、A_FIN 量化 | QOZ_O 16 Tile 提交 |
| O | 本核 FP32 partial 外发 | 1664 个包发送，输入 QOZ_O 释放 |
| G-U | SFU GELU、VPU 乘法与量化 | QOZ_Z 32 Tile 提交 |
| Down | 本核 FP32 partial 外发 | 1664 个包发送，输入 QOZ_Z 释放 |

`job_valid/ready` 和 `done_valid/ready` 采用保持型握手。done 返回完整 `control_job_t` 与 status。输入 region 不存在或身份错误时返回 CONTROL_PRECONDITION，不无限等待被单 Job 规则阻止运行的生产者。

Job 包含 header、user_tag、core_id、position_base、data_context、rope_pair_base、layout_id。layout_id=0 为当前固定 profile；其他布局拒绝。data_context 为 16-bit 比较标识，DEA8 在数据存活期间不得复用。底层 epoch 保持原宽度，顶层附加 data_context 与 generation 检查。

`PCORE_ID` 为实例的固定核号，默认 0，可设为 0..7。DEA8 负责路由；PCore 仅检查 `job.core_id == PCORE_ID`。不匹配返回 `CONTROL_CONTEXT_ERROR`，不启动 Matrix 或 Post。completion 仍回显收到的完整 Job，便于定位错路由。

## 两个单向输出流

`kv_out_valid/ready/kv_out` 发送量化 K/V；`reduce_out_valid/ready/reduce_out` 发送 FP32 O/Down partial。各自有两项弹性缓冲，PCore 等待本核最后数据实际送出。没有 collective_cmd/done 回程，外部八核完成由 DEA8 跟踪。

packet 包含完整 Job、type、tile/index、vector_valid、token_mask、feature_base、token_base、payload、scales、tile_last、last。payload 使用统一 2×16×32 容器，量化格式仅低 8 bit 有效，FP32 使用完整 32 bit。K 的两组表示两行 feature；V 的两组表示两列各 16 token。实际有效载荷分别为 272 与 1024 bit，封装元数据另计。

## VPU SFU 命令

| 通道 | 作用 |
|---|---|
| vector_cmd、vector_done | VPU 命令与完整 command 回显 |
| function_cmd、function_done | SFU 命令与完整 command 回显 |
| vector_data | RoPE 两半、GU 的 GELU/Up 配对，或 Attention P 数据 |
| function_data | Gate 到 GELU |
| function_result | GELU 或 P_EXP 的 FP32 返回 |
| vector_result | 带量化轴、坐标、scale 的量化结果 |

两个单元各允许一个在途命令。token 为 generation + command_id；命令号最低位区分单元。所有返回在写存储/外发前检查 token、坐标、数量、mask 和 last。

`control_fp_data_t.first/second` 的含义由当前 command 决定：RoPE 是同一行的两半；V_QUANT 是两列各 16 token；GU_POST 是同一行的 GELU(G) 与 U。GU 输入 `vector_valid=01` 表示该行有效，**不能因此丢弃 second 中的 U**。GELU 返回只使用 first。量化结果 `control_quant_result_t.vector_valid` 才按双行（或 V 的双列）解释，奇数行尾包为 01。

接入单元应先握手 command，再返回 result/done。最后 result/write 已握手、读响应已消费之后才拉高 done；不支持把最后一次数据握手和 done 放在同一个接收边沿。RoPE 系数返回也必须晚于对应请求的握手。所有 valid 在背压期间保持完整内容，done 必须回显完整 command。

VPU 功能：VECTOR_ROPE_QUANT、VECTOR_V_QUANT、VECTOR_GU_POST、VECTOR_QK_POST、VECTOR_P_POST、VECTOR_OACC_SCALE、VECTOR_AFIN_QUANT。SFU 功能：FUNCTION_GELU、FUNCTION_ALPHA_EXP、FUNCTION_P_EXP、FUNCTION_RECIP。

elements 是有效标量元素数，不包含奇数行尾部填充。QK_POST/P_POST/GU_POST/V_QUANT 为 816；RoPE 配对为 1,632；SCALE/AFIN 为 13,056（16 个输出 Tile）。ALPHA/RECIP 为 51，GELU/P_EXP 为 816。TB 先核对描述符再执行，不能只按功能枚举绕过长度。RoPE 命令 tile 标识完成配对的内部 N 阶段，量化结果 tile 使用原始 feature Tile 地址。

source/destination 表示逻辑用途，不是任意可读写的统一地址空间。FACC/OACC 走 acc 接口；SBUF/统计量走 mem 接口；GELU/P 的 FP32 回包走 function_result；Q/O/Z 的量化结果走 vector_result，由 PCore 写回。单元不能凭 destination=WORK_PAIR/WORK_QOZ 直接申请对应 RAM 写端口。

ROPE_QUANT 命令明确 position_base 和 rope_frequency_base。VPU 通过 rope_req 请求系数，PCore 校验 token/row/position/frequency 后转发 rope_sfu_req；SFU 系数服务返回 16 对 FP32 cos/sin，再经 rope_out 给 VPU。系数服务可使用 ROM，不预设运行时三角函数硬件；RoPE 乘加仍由 VPU 完成。系数口最多一个在途请求，flush 也覆盖它。G-U 的 SFU 先收到 GELU 命令，VPU 先被配置为接收者；每行的 U 在 PCore 配对寄存器中保持至同一行 GELU 返回被接受。基础实现最多一行 GELU 在途，可后续按单元延迟扩充配对 credit。

## Pair BUF 与量化布局

`dea8_pcore_post_v3` 为 K/Q/V 复用两组逻辑 51×16 FP32 缓存。物理按 row%16 分 16 个 bank，每 bank 8×512 bit，两个 RoPE half 各占 4 个地址；总声明容量 65,536 bit，逻辑有效数据 52,224 bit。使用 distributed RAM 提示来表达并行 token 读取，实际 LUTRAM/寄存器映射待综合确认。K/Q 先捕获第一半并退休捕获事务，放行第二半；完整配对后 VPU 读取 51 行两半。G-U 使用已有 GU Pair BUF，Post Service 只保留当前行的 Up，不复制整块 GU 数据。

Q 的计算 Tile 顺序为 0,8,1,9,...,7,15；返回结果用原始 feature tile 地址写 QOZ。K 用 rope_pair_base 指定全局配对起点。QOZ 支持 Tile 间不同顺序，Tile 内 pair 必须严格 0..25，完整提交全部 Tile 后才 complete。

V 每个 Tile 被打包成 4 个 token group × 8 个双 feature 包。最后 token group 仅三个 token 有效，token_mask=0x0007。此 profile 本地 row0 对齐 token block，KVB/外部适配器负责与绝对 prefix/suffix 布局的衔接；不隐式对服务器 prefix 数据重新量化。

## Attention 共享存储接口

`dea8_pcore_workspace_v3` 提供一个物理共享副本：SBUF 双 bank，各 51×16FP32；m、aa、l、1/l 各 51FP32；alpha 双 bank，各 51FP32。m/l 初始化通过 valid 元数据实现，默认 m=-inf、l=0，不擦数据 RAM。

VPU 使用 vector_mem_req/ready 与 vector_mem_out_valid/ready；SFU 使用对应 function_mem_*。请求含 token、buffer_id、bank、index、write、mask、16FP32 data。每个读口有保持型响应寄存器。

- SBUF 以 index 表示行，读写完整 16 列；写 mask 必须全有效。
- 统计量以 index 表示首行，可一次访问连续最多 16 行；写 mask 只选择合法行。
- 单 bank 状态 bank=0；SBUF/alpha bank 必须匹配当前 block 奇偶。
- VPU QK_POST 读写 m、写 aa 和 SBUF；P_POST 读 alpha、读写 l；SCALE 读 alpha；A_FIN 读 1/l。
- SFU ALPHA_EXP 读 aa、写 alpha；P_EXP 读 SBUF/m；RECIP 读 l、写 1/l。

控制器记录每条命令的写入行位图，拒绝重复写，并要求 QK_POST 的 S/m/aa、P_POST 的 l、ALPHA_EXP 的 alpha、RECIP 的 1/l 全部写完后才允许 done。

FACC/OACC 使用单独 acc_rd/acc_data/acc_wr 接口，请求带 acc_token。读返回有四项容量预约，允许多个顺序读在途并保持下游背压数据。QK_POST 只读对应 FACC；SCALE 读写 OACC；A_FIN 只读 OACC。SCALE 写回按地址顺序完成全部 416 项才能 done。

VPU 的 OACC 接口使用逻辑地址 `tile*26+pair`，控制接口边界转换为现有矩阵通路的 `pair*16+tile`。偶数行物理 bank 有 416 项；奇数行有 400 项，每个 Tile 的 pair25 奇数行无效、读回零。保留原 DEQACC 地址路径，不在矩阵关键流水内增加地址转换。

## Attention 启动与生命周期

矩阵子序列保留 QK0,QK1,PV0,...,QK54,PV53,尾部时隙,PV54。STREAM_P_POST 模式先配置 VPU P_POST，再让 SFU P_EXP 流式发送；OACC_SCALE(b) 等待 PV(b-1) 提交。下一代 QK_POST 等前代 P_EXP 完成读取 m/aa；alpha bank 复用还等待旧代 P_POST 与 SCALE 都完成。

QK54 提交且 QOZ 读响应排空后释放 Q 并申请 O。RECIP 后 VPU AFIN_QUANT 产生 O，写入 Manager；Attention 等 O region_complete 才 done。O/Down 当前保守地在矩阵结束且读取排空后释放输入 region。

## 故障和取消

非法返回在产生副作用前被拦截。运行中错误返回 CONTROL_UNIT_ERROR/CONTROL_EARLY_DONE，保持 FAULT，直到 clear。clear 通知 flush_valid；VPU/SFU 独立 flush_ack 都到齐才恢复 job_ready。reset 为各模块同步复位契约。普通 Job 完成不清掉给后续消费者使用的 QOZ。

completion 一旦有效，内容保持至接收。若这期间收到迟到的非法返回，保留原 completion、置 `protocol_error` 并保持 FAULT，禁止新 Job；不改写已提供的 status，也不补发第二份 completion。DEA8 收到原 completion 后仍须按故障/clear/flush 合约恢复。

XBC/HBM/KVB 只在活动 Job 接受。外部 QOZ fixture 写口只允许在无活动 Job 时准备数据，写入仍通过 Manager。DEA8 必须协调输入源的取消，不能在 flush 结束后继续发送旧 Job 数据。

## 验证与适用范围

入口：`run_control_v3.ps1`。数值 TB `tb_v3_pcore_control_v3` 连续运行七 Job，用真实共享 Matrix 和 DSP 模型，TB 实现 RoPE、GELU、Softmax、alpha 缩放、倒数与量化。Q/Attention/O 及 GU/Down 直接连接真实 QOZ 结果。TB 的串行存储访问耗时不代表目标 SFU/VPU 硬件吞吐。

协议 TB 验证前置条件、非法 opcode、错误结果拦截、done 保持、FAULT 与独立 flush ack。控制回归另包含 QOZ、Job dispatch、原矩阵 scheduler 相邻检查。

### 本次结果

2026-10-07 的历史记录：完整七 Job 数值仿真 PASS。另六项回归为控制协议、QOZ Manager、QOZ Store、Job dispatch、原 Attention scheduler、ACC 并行访问；当时对应 73 份 RTL/TB 哈希复核无变化。旧日志不作为本轮签核附件，当前证据以本页末尾的时间戳目录为准。

| Job | 接受到 done 可见的 TB 周期 | 矩阵发射次数 | 本核外发包数 |
|---|---:|---:|---:|
| K | 3,719 | 3,328 | 52 |
| V | 3,558 | 3,328 | 64 |
| Q | 27,281 | 26,624 | 0 |
| Attention | 273,292 | 45,760 | 0 |
| O | 28,249 | 26,624 | 1,664 |
| G-U | 107,357 | 106,496 | 0 |
| Down | 54,873 | 53,248 | 1,664 |

总矩阵发射 265,408 次；Attention 110 个子任务。七 Job 在同一实例运行，中间没有 clear；Q/Attention/O 和 GU/Down 使用真实 QOZ 结果。以上是串行存储访问的 TB 模型周期，不是实际 FPGA 性能，也不能套用旧 434 拍稳态估算。

以上为 2026-10-07 的历史确定性基线，不作为新增 stress/fault 测试的结果。2026-10-08 至 10-09 的控制收尾回归另见下节；本轮确定性基线已重新运行，七 Job 的周期、发射与外发包数均与上表一致。

数值 TB 还包含全 Mask 行：m 保持 -inf，aa 用零表达无旧贡献变化，P/l/O 为零；RECIP 对 l=0 返回零，不执行无保护的 -inf-(-inf) 或 1/0。这是 SFU/VPU 接入时需要遵守并验证的边界约定，不代表其算术 RTL 已经实现。

Mask 是 TB 的受控用例，不等于真实 pi0 的完整掩码配置。TB 使用 tanh 近似 GELU 和标量 FP32 参考运算顺序；实际 SFU/VPU 的近似误差、归约顺序和吞吐，需在替换 TB 模型后另行验证。

本阶段保留底层 Matrix 的三种 mode 分支及现有 DEQACC 数值/流水。描述符化底层策略是后续内部整理，不改变本次外部七 Job 合约。SFU/VPU 算术 RTL、真实 KVB/HBM、跨核网络及整体去噪循环不属于本次实现。未运行新的综合或布局布线。

## 控制收尾回归入口

完整入口仍为 `run_control_v3.ps1`，调用 `run_control_signoff_v3.ps1`。默认依次运行：确定性七 Job、基础协议、异常、阶段取消、16 个 stress seed、五项邻接回归。

```powershell
.\run_control_v3.ps1 -Workers 4
.\run_control_v3.ps1 -ProtocolOnly
```

`ProtocolOnly` 只作快速协议检查，不能替代完整签核。`-StressSeeds` 可用于调试；最终签核要求不少于 16 个。

- `+STRESS +SEED=n`：只改变时序，不改变输入数值或 golden。XBC/HBM 初始供数先后交替，KVB 有初始与 block 间停顿；单元接受、结果、done、存储消费和输出均加入延迟。
- `+CORNERS`：卡住 K/V/O/Down 最后一包、Q/Z/O 最后量化结果、PV54 最后权重输入、RECIP 与 A_FIN 启动，检查不得提前完成。
- Attention 只读监视器：统计 22,880 次 Q 响应消费、一次 Q release、一次 O acquire、一次 PV54 commit；检查 release 前读排空、O acquire 在 release 后、RECIP 在 PV54 commit 后。
- QOZ Manager 定向测试：最终 Q 读响应保持 32 拍，同时请求 release；响应消费前不得释放。此处是存储边界的直接测试，不是强改完整 PCore 的内部 ready。
- 异常 TB：由真实输入和 Matrix 到达被测阶段，再注入 token/generation、坐标、mask、last、数量、done echo/error、RAM/ACC 权限及 RoPE 异常。
- 取消 TB：覆盖 Matrix、RoPE、QK、P_EXP、SCALE、A_FIN、GU GELU、KV/reduce 输出；flush 期间发送旧返回，独立确认两边 ack；恢复后跑完整数值 V Job。

结果以 `reports/control_v3_signoff_latest.txt` 指向的时间戳目录为准。目录保存 `summary.txt`、`results.csv`、各测试日志、`coverage_summary.txt` 和前后两份 SHA256。只有全部测试 PASS 且源码哈希不变，才写完整 PASS；中断、Fatal/Error、缺 PASS、源码变更均写 FAILED。波形与并行工作目录放 `.tmp/`，不上传。

注意：随机测试是有限样本验证，不是对无限延迟的形式证明。固定时序 RAM 不改成随机延迟，仅随机下游消费。当前 XBC/HBM/KVB 没有 generation，DEA8/GCore/HBM 必须在 flush 后撤销旧输入；PCore 不能单独辨别这些通道上的迟到旧包。

## 收尾验收：2026-10-09

**PCore Control V3 仿真签核通过。** 25 项测试全部 PASS：确定性基线、协议、异常、取消恢复、16 个完整七 Job stress seed、5 项邻接回归。

证据目录：[`reports/control_signoff_20261008_210425`](../reports/control_signoff_20261008_210425)。入口状态见 [`summary.txt`](../reports/control_signoff_20261008_210425/summary.txt)，逐项结果见 [`results.csv`](../reports/control_signoff_20261008_210425/results.csv)，计数见 [`coverage_summary.txt`](../reports/control_signoff_20261008_210425/coverage_summary.txt)。

| 验收项 | 结果与证据 |
|---|---|
| C0 七 Job 正常链 | 基线及 16 seed 均在同一实例无 clear 完成 K→V→Q→Attention→O→G-U→Down；每链 265,408 次发射 |
| C1 核身份 | 固定 PCORE_ID 检查；协议 TB 拒绝 7 个错误核号，数值 TB 使用 core 2 |
| C2 输入停顿 | 16 seed 的 XBC/HBM/KVB 延迟和气泡覆盖计数均非零；数值、数量、顺序通过 |
| C3 单元停顿 | command/result/done 可变延迟均实际触发；阻塞命令保持检查通过 |
| C4 存储背压 | ACC/workspace 保持与排空通过；ACC credit=4 的满队列、停收、同拍出入通过 |
| C5 外发边界 | K/V/O/Down 最后一包停顿检查通过；包数分别 52/64/1,664/1,664 |
| C6 QOZ 提交 | 每个 seed 均执行 Q、Z、O 最后量化结果延迟用例；完整提交前不完成 |
| C7 Attention 生命周期 | 每链 110 子任务，Q 响应消费 22,880 次，Q release/O acquire/PV54 commit 各 1 次；Manager 最后 Q 响应阻塞 32 拍时不得释放 |
| C8 错误返回 | 56 个故障用例通过，覆盖身份、数量、done、访存权限、ACC、RoPE 等 |
| C9 clear/flush | 9 类阶段取消通过，独立 flush ack 与旧返回隔离通过；6 个完整数值 V 恢复 Job 通过 |
| C10 completion | 内容保持、上下文回显、下一 Job 等待、迟到故障不改写已提供 completion 均通过 |
| C11 随机回归 | seed 1～16 全通过；逐组复核 seed 编号、7 个 Job、110 子任务及所有要求的非零覆盖计数 |
| C12 证据一致性 | 25 项 PASS；续跑前后 77 项 SHA256 一致，结束后再次对照当前文件，无变化 |

16 个 seed 共验证 112 个完整 Job、4,246,528 次矩阵发射；另有确定性基线和异常/恢复用例。七种 Job 在每个 seed 都有 completion corner 覆盖。SFU/VPU 的非矩阵算术仍为 TB 模型；没有新增其算术 RTL，没有新综合或 P&R，不能据此声称八核集成或 250 MHz 签核完成。

### 本轮续跑记录

最初压力启动失败于 Windows PowerShell 后台调用：`SEED=n` 被拆分，XSIM 报参数错误，未进入 HDL 仿真。改用每 worker 独立的 `stress.options` 文件后，16 组均正常运行。

续跑前核对原 manifest：74 份 RTL/TB 和 `v3_all.f` 均未变；仅 `run_control_signoff_v3.ps1` 因启动修复与安全续跑入口发生变化。因此保留本轮已实际通过的 baseline/protocol/faults/cancel 日志，继续执行全部 stress 和邻接回归，不借用其他日期的历史日志。

- `sources_sha256.csv`：最初冻结清单
- `sources_sha256_resume.csv` / `sources_sha256_after.csv`：续跑前后清单，77 项完全一致
- `summary_before_resume_*.txt`：保留最初启动失败记录
- `.tmp/control_signoff_20261008_210425/seed_*/launcher.log`：各 worker 原始启动输出；不上传波形和缓存

仅在 RTL/TB/编译列表未变化且前四项 PASS 证据齐全时，可以使用安全续跑：

```powershell
.\run_control_signoff_v3.ps1 -ResumeReport .\reports\control_signoff_20261008_210425 -StressSeeds 16 -Workers 8
```

此命令重跑全部 stress 和邻接回归，不把缺失测试直接标为通过。源码变更后必须重新运行完整入口。下一阶段优先接入真实 SFU/VPU，复核数值近似、数据布局与 flush 合约，再推进八核及 DEA8 总控集成。
