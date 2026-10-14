# 动态 M Attention 调度方案 V1

状态：方案制定，2026-10-13。本文只新增设计文档，没有修改 RTL，也没有执行新调度的仿真或综合。V1 是本文版本，不是把工程重新命名为 V4。

## 1. 目标与冻结项

单核 Attention 接收一个总 Job，内部产生 55 个 QK 和 55 个 PV 矩阵子 Job。保持原顺序：

```text
QK0 -> QK1 -> PV0 -> QK2 -> PV1 -> ...
    -> QK54 -> PV53 -> 空出一个 Block slot -> PV54 -> RECIP -> A_FIN/量化 -> QOZ_O complete
```

- `M=0..51`，一次 Attention 内固定；只认识 compact row `0..M-1`
- QK：`[M,256] × [256,16]`，沿 K 拆成 16 个 Tile
- PV：`[M,16] × [16,256]`，沿 N 拆成 16 个 Tile；同一 P Tile 重放 16 次
- 每个微 Tile 为 `[M,16] × [16,16]`，两行/拍，B 四列/拍、四拍加载
- QK/PV 的矩阵次序不变；稳态 Softmax(b) 隐藏在 PV(b-1)，OACC_SCALE(b) 隐藏在 QK(b+1)；Softmax0 是 QK1 内的启动特例
- VPU/SFU 仅定义接口与时间合同，不实现内部算术；仿真分别采用 VPU32、SFU4 行为模型
- 七级 MXU、七级 DEQACC、一套 FACC-A/FACC-B/OACC 保持；不为 Attention 新增第二个 MXU/OACC
- K/V block 数仍为 55；M 缩短的是 query/output 行，不是 K/V token 列或 head dimension
- `M=0` 直接完成空任务，不发 110 个空矩阵 Job、不运行尾部计数器

## 2. 已检查的旧实现

### 2.1 真正使用的控制路径

```text
dea8_pcore_control
  -> dea8_pcore_exec
  -> dea8_attention_job_adapter
  -> dea8_attention_scheduler_v4
  -> dea8_attention_matrix
  -> 共享 dea8_matrix / MXU / DEQACC_3_3ns
```

旧目录的 `dea8_attention_scheduler.sv` 是早期 FSM；当前 adapter 实例化的是带 active/pending descriptor 的 `dea8_attention_scheduler_v4.sv`。新方案参考其功能，不沿用文件名中的版本后缀。

| 旧实现 | 可复用 / 需要改进 |
|---|---|
| [Job adapter](C:/Users/fly04/Desktop/VLA/DEA8/Pcore/rtl/dea8_attention_job_adapter.sv:44) | Q 区域获取/释放、O 区域获取、整 Job 完成；增加固定 M/context |
| [scheduler](C:/Users/fly04/Desktop/VLA/DEA8/Pcore/rtl/dea8_attention_scheduler_v4.sv:71) | 110 Job 次序、block_id、P/α 两代、真实 done 检查 |
| [matrix frontend](C:/Users/fly04/Desktop/VLA/DEA8/Pcore/rtl/dea8_attention_matrix.sv:97) | active/pending、Q/P 源切换；旧 A 预取等到 issue_done 才开始，动态版应更早 |
| [matrix owner](C:/Users/fly04/Desktop/VLA/DEA8/Pcore/rtl/dea8_matrix.sv:253) | 整个 PV 期间独占 OACC 的规则保留；最终 C 边沿转移 owner，不再串行等多个 busy 清除 |
| [PCore unit bridge](C:/Users/fly04/Desktop/VLA/DEA8/Pcore/rtl/dea8_pcore_control.sv:190) | token、结果计数、通道排空检查保留；数据 fence 与完整 unit done 分离 |
| [workspace](C:/Users/fly04/Desktop/VLA/DEA8/Pcore/rtl/dea8_pcore_workspace.sv:29) | m/aa/l 一代、α 两代、SBUF 两代；现有统计读取已支持连续行 span，可用于 SFU4 |

### 2.2 OACC_SCALE 为什么额外暴露

旧 scheduler 在 `STREAM_P_POST=1` 时，SCALE(b) 的命令选择要求 `pv_committed[b-1]`；同时 VPU 必须从 busy 状态退出。之后还经过 PCore 命令接受、TB/实际单元准备、ACC 读返回和最终 done 链路。来源见 [SCALE 选择](C:/Users/fly04/Desktop/VLA/DEA8/Pcore/rtl/dea8_attention_scheduler_v4.sv:127)、[VPU busy](C:/Users/fly04/Desktop/VLA/DEA8/Pcore/rtl/dea8_attention_scheduler_v4.sv:140)、[SCALE ready 更新](C:/Users/fly04/Desktop/VLA/DEA8/Pcore/rtl/dea8_attention_scheduler_v4.sv:229)。

旧控制层又把 `scale_ready` 间接绑定到完整 unit done：要求所有 ACC 写入、读返回、workspace 等相关通道均完成，然后接收 VPU done，再由 scheduler 寄存 ready。安全性有价值，但命令准备、α 读取、通用 done 运输不应全部挤到 QK 窗口之后。

因此问题不是“FP32 乘法比矩阵慢”，而是：

1. 等 PV 最终提交后才发 SCALE 命令，准备时间没有提前吸收。
2. 同时依赖矩阵整 Job done、busy 释放、VPU busy 清除等注册信号，交接可能串行。
3. PV 启动等待通用 VPU done，而不是该 SCALE 的全部 RAM 写入已经提交这一数据事实。
4. 旧 TB 的 Scale 按 NTile-major 重复读取 α；每个 row pair 的两个 α 被重复使用 16 次，却未利用复用关系。

历史 [control 日志](C:/Users/fly04/Desktop/VLA/DEA8/Pcore/reports/pcore_control_after_migration.log:27) 记录：matrix body 416，稳态最大 440 / 平均 438，scale_cycles 425，α/RECIP 各 108。这是历史结果，不是当前动态方案的验证。425 是 TB stage 的统计区间，不能直接把 `434-425=9` 当作真正的隐藏余量；起始偏移和 done 返回仍需逐事件测量。

还要区别两种 TB：

- `tb_pcore_control.sv` 的性能模型使用真实 ACC/workspace 交互与数值检查，但 α/RECIP 的循环仍按单行请求，108 拍不能当成 SFU4 的算术下界。
- [tb_attention_55 FAST 分支](C:/Users/fly04/Desktop/VLA/DEA8/Pcore/tb/tb_attention_55.sv:278) 将 SCALE 抽象为 208 拍等待，没有真实 Scale RAM 写回；它能支持部分调度/矩阵检查，不能证明 VPU32 的完整 OACC_SCALE 被隐藏。新 TB 不采用这个假设。

### 2.3 当前 dynamic 计算核的边界

已完成的 [动态计算链路](C:/Users/fly04/Desktop/VLA/DEA8_dynamic/Pcore/README.md) 验证了所有 M 的 Tile 内吞吐、四拍加载、Δ4/5/6/7 前递及真实累加。它尚未实现跨 Block 调度。

加载接口遵守已确定的 [A 侧 V1](C:/Users/fly04/Desktop/VLA/DEA8_dynamic/Pcore/A侧矩阵加载方案_V1.md) 与 [B 侧 V1](C:/Users/fly04/Desktop/VLA/DEA8_dynamic/Pcore/B侧矩阵加载方案_V1.md)，本文不重新定义其 packet 和物理存储布局。

当前 `dea8_compute_core` 在 DRAIN 收到注册 deq_done 后才回到 IDLE；新 Job 接受时会清 bank ready，并只在 RUN 接收 B。把 110 个现有独立计算 Job 直接串起来，会反复暴露加载和交接，达不到本方案目标。后续必须增加 pending/prepared Block、保留合法的预加载 bank，并分离发射结束与退休结束。

## 3. 严格定义周期，避免漏算 MXU 尾部

对 `M>0`：

```text
P = ceil(M/2) = (M+1)>>1
R = max(4, P)
T = 16*R                       // Block 的 16 个 Tile 预约时间
X = 6                          // 最后 S0 -> MXU response 的边沿差
D = 7                          // response -> DEQACC C 的边沿差
S_target = T + D + 5 = T + 12  // 相邻 Block 首 S0 之间的目标间隔
```

本文按用户目标的严格口径使用 D=7，不把额外的 MXU 六拍偷偷并入 D，也不把目标改成 `T+X+D+5`。

若一个 Block 首 S0 位于 s，Tile i 首 S0 位于 `s+i*R`，最后一对 S0 和最终 C 分别为：

```text
last_S0 = s + 15*R + P - 1
last_C  = s + 15*R + P + 12
S_target - (last_C-s) = R-P
```

注意：T 是预约时间；M≤6 时最后 Tile 仍只发 P 拍，不能把最后未发射的 `R-P` 拍算作真实计算。

| M | P | R | T | 首 S0→最终 C | S_target | C 后可用交接拍 |
|---:|---:|---:|---:|---:|---:|---:|
| 1..2 | 1 | 4 | 64 | 73 | 76 | 3 |
| 3..4 | 2 | 4 | 64 | 74 | 76 | 2 |
| 5..6 | 3 | 4 | 64 | 75 | 76 | 1 |
| 7..8 | 4 | 4 | 64 | 76 | 76 | 0 |
| 9 | 5 | 5 | 80 | 92 | 92 | 0 |
| 11 | 6 | 6 | 96 | 108 | 108 | 0 |
| 20 | 10 | 10 | 160 | 172 | 172 | 0 |
| 32 | 16 | 16 | 256 | 268 | 268 | 0 |
| 50 | 25 | 25 | 400 | 412 | 412 | 0 |
| 51 | 26 | 26 | 416 | 428 | 428 | 0 |

结论：M≥7 时，严格目标要求下一 Block 首 S0 与上一 Block 最终 C 同沿。这里的“+5”不是 C 之后另有五拍交接预算；六拍 MXU 尾部和时钟边沿计数已经消耗这部分额度。

首 QK0 允许冷启动。若第一版调度只能做到再多 1..2 拍，记录为 `S=T+13/T+14` 的未达目标项，不能修改统计口径掩盖。

## 4. 矩阵调度：active + prepared，同 C 交接

### 4.1 四个不同的事件

| 事件 | 定义 / 用途 |
|---|---|
| `descriptor_accept` | 保留下一 Job 的 context、source/slot；不代表可以计算 |
| `source_read_closed` | 当前 Block 最后 A Tile 已完整复制到 A queue，旧源读返回全部结清；可切 Reader 预取下一 Block |
| `issue_closed` | 当前 Block 最后一对 A 已进入 S0；权重仍需等最后 S1 后才可重写 |
| `retire_C` | 当前 Block 最后一笔真实 ACC RAM 写入；输出旧 Job 完成 token，可同沿发下一 Job 的首 S0 |

一个 active descriptor 加一个 prepared descriptor 足够。旧结果由流水 metadata / completion snapshot 识别，不从已经切到下一 Job 的 live context 重新标注。

`retire_C` 的同沿放行依据：DEQACC A3 注册候选中的 last/key/generation，确定它在当前 C 边沿真实写入；clear/fault 具有最高优先级。不要等 C 后的 `done_valid -> done_ready -> busy=0 -> START` 注册链再启动。

这不是提前宣称旧结果完成：新 A 只进入 S0，新的 Psum 在六拍后出现；旧最终写入仍在该 C 沿执行。FACC/OACC 的后处理读取最早放在 C 的下一沿，避免 read-first 同址碰撞。

### 4.2 第一对 A 和 B 必须提前准备

旧 A frontend 等到 `matrix_issue_done` 才从下一源预取。新方案改为：当前最后 A Tile 完整进入 queue、旧 Reader 返回结清后，即开始 next Block 的 A 首 Tile 读取，不必等 PE 算完。

- A 三行/拍填入 3-slot queue；完整首 Tile 准备需要 `ceil(M/3)` 个数据 beat，加真实 RAM/holding 延迟
- M=51 的数据填充就有 17 拍，不能只指望最后 13 拍算术排空窗口
- 利用当前最后 Tile 的计算期间填好下一首 Tile，再预取 pair0 到 holding register
- next 是 PV：只能从对应已 COMMITTED 的 PBUF 代取数；未完成时可接受 descriptor，不能读取半成品
- next 是 QK：QOZ 的 Q region 保持绑定，切回 feature tile 0
- 已预取但未执行的 slot/region 仍有 read reference，不能被生产者复用

B loader 持续运行，当前最后 Tile 使用 bank B 时，可在已释放的 bank A 装下一 Block 的第一个 B Tile。当前最后一次 S1 后，另一个 bank 也可预装 next Tile1。

Block 边界不清 W bank、B queue、A queue 或 DEQACC；只转移匹配 descriptor 的 owner。K/V role 由 B descriptor 区分，物理 source 在整个 Attention 内保持 KVB。完整 head/Job 结束或 cancel 才执行相应释放/flush。

### 4.3 下一 Block S0 的放行条件

```text
slot_due && prepared_context_match
&& first_A_tile_READY && first_A_pair_held
&& first_B_bank_READY && scales_READY
&& previous_Block_retire_C_or_already_retired
&& DEQACC_address_reservation_ok
&& operation_dependency_ok
&& !clear && !fault
```

PV 的 operation dependency 是 PBUF generation 完成，以及对应 OACC scale 的真实写回完成；PV0 无 Scale 依赖，直接覆盖旧 OACC。QK 则需要目标 FACC 和 workspace generation 可用。

同沿的数据 fence 也要显式定义：若 SCALE 的最后一次写回就在目标 PV 首 S0 边沿，只有该边沿前已确定 `write_valid && write_ready`、写入身份/计数全部正确、无 fault，才可用 `scale_will_commit` 放行 S0。否则等待已注册的 fence。这样只是重叠 S0 与真实写入，不允许未被 RAM 接受的结果先行；新的 OACC 读取仍发生在其后。不能把先注册 fence 再 START 的一拍开销漏出周期表。

保持 Tile 内 Δ≥4、已启动 Tile 连续双行发射。跨 Block 的 bank/地址身份加入 `(major Job token, subjob_seq, QK/PV, block_id)`；不能只用低六位运输序号或 parity 判数据属于哪一 Block。不要借用 GU 的 `gu_n` 字段表示 Attention block_id。

## 5. 稳态工作表与在线 Softmax 版本

沿用原公式；O 是未除 l 的分子：

```text
m_b = max(m_(b-1), row_max(masked S_b))
aa_b = m_(b-1) - m_b
alpha_b = exp(aa_b)
P_b = exp(masked S_b - m_b)
l_b = alpha_b*l_(b-1) + row_sum(P_b)
O_b = alpha_b*O_(b-1) + P_b*V_b
A_FIN = O_54 / l_54
```

| 矩阵 slot | VPU 工作 | SFU 工作 |
|---|---|---|
| QK0 | 初始化/准备，不缩放旧 OACC | 准备 |
| QK1 | QK_POST0、流式 P_POST0 | α0、P_EXP0 |
| PV0 | QK_POST1、流式 P_POST1；准备 SCALE1 | α1、P_EXP1 |
| QK2 | SCALE1：α1×O0 | 下一阶段准备 |
| PV1 | QK_POST2、流式 P_POST2；准备 SCALE2 | α2、P_EXP2 |
| … | … | … |
| QK54 | SCALE53：α53×O52 | 下一阶段准备 |
| PV53 | QK_POST54、P_POST54；准备 SCALE54 | α54、P_EXP54 |
| 空出的 slot | SCALE54：α54×O53 | 无 QK55 / P55 |
| PV54 | 矩阵完成 O54 | 准备 RECIP |
| 最终尾部 | A_FIN、B16 量化、写 QOZ_O | RECIP(l54) |

L 可以比 OACC 领先一代，不能要求 live m/l 的 block_id 与正在计算的 PV 相同。PBUF、α、OACC 的版本必须独立识别。

OACC 的小型版本状态：

- `has_value`、`last_pv_block`、`basis_block`
- PV0 C：`last_pv=0, basis=0`
- SCALE(b) 全写回：旧 `last_pv=b-1` 不变，`basis=b`
- PV(b) C：`last_pv=b, basis=b`
- SCALE(b) 要求前一 PV 已提交，且 OACC 基准仍为 b-1；不允许重复缩放
- PV(b>0) 要求 `last_pv=b-1 && basis=b && PBUF_generation=b`

α 两代继续使用。α_b 在 L_b 更新完成、SCALE_b 完成且读引用归零后才释放；α0 无 SCALE0。SBUF/m 的更新还要等待前代 P_EXP 读完。PBUF 按对应 PV 退休及读引用归零释放，不仅凭 bank 翻转释放。

## 6. OACC_SCALE 的隐藏方案

### 6.1 PREPARE 与 EXECUTE 分开

在 PV(b-1) 期间，P_POST(b) 完成或即将完成后，提前接受/预解码 SCALE(b) descriptor、绑定 α_b、准备首对系数与 ACC 请求信用。此时可以准备，不能读写尚由 PV 独占的 OACC。

PV(b-1) 最终 C 与 QK(b+1) 首 S0 同沿时：

1. 确认旧 PV 的真实退休，OACC owner 转移给已 armed 的 SCALE(b)。
2. 下一沿开始 OACC read；QK 只使用 FACC，两个存储没有冲突。
3. 每拍读取一个双行×16 FP32 bundle，乘 α 后流水写回。
4. 全部真实写入完成立即形成 `oacc_scale_committed(b)`；通用 done 可再做 token/通道核对，但不能平白给矩阵再增加固定等待。

数据 fence 不等于销毁旧 command：保留 completion token，关闭该 command 的后续写权限，直到其 done/flush 完整结清。迟到 done 不阻挡已经满足数据依赖的 PV；错误、重复写或迟到错误仍使整个 Attention fault，不能在存在未结清命令时宣布整体成功。若 VPU 仍因旧 done 处理不能接下一个 QK_POST，其延迟也计入下一 Softmax deadline，不假定它免费消失。

不采用“只等估计拍数就宣布缩放完成”，也不采用 PV 与 SCALE 同时写同一 OACC 的地址级交错技巧。PV 必须等全 bank Scale fence；控制简单、错误容易定位。

### 6.2 推荐 pair-major 扫描，避免重复 α 和动态除法

OACC 本来就是 `addr=pair*16+nt`。Scale 推荐：

```text
for pair=0..P-1:
    bind alpha_b[2*pair], alpha_b[2*pair+1]
    for nt=0..15:
        read OACC[pair*16+nt]
        multiply 32 FP32 lanes
        write same physical address, with the dynamic row mask
```

两路 α 连续复用 16 拍。可用当前/下一对系数 hold（总计 128 bit）预取，系数引用随 RAM response tag 对齐；不用在 PCore 新建整套 51-row α 副本。具体乘法流水与系数 hold 由 VPU 负责人实现。

接口保留 `(pair,nt)` 或直接使用 physical pair-major address。不要把旧 `linear % PAIRS` 改成运行时 `%P`、`/P` 放到 250 MHz 组合交接路径。`addr={pair,nt}` 可直接拼接，序号只用于计数/重复写检查。

AFIN 可继续按 NTile-major 输出，便于原 QOZ 接入；其 reciprocal 预取/广播也必须流水化。Scale 与 AFIN 不需要强行同一种外部扫描顺序，command 中明确 `scan_order`。

### 6.3 周期预算

32 lane 的保守物理遍历拍数：

```text
W_scale = 16*P
```

不能只用 `ceil(256*M/32)`：奇数 M 时，每个 NTile 的最后一个 pair 只有一行有效，even parity RAM 仍每拍最多读一个 16-FP32 word。M=51 因而是 416 个 pair beat，不是 408，更不是 208。

设 QK 首 S0 为 q，Scale 首 RAM 读取在 `q+delta`，L_rmw 是从 RAM 请求接受到对应 RAM 写入提交的固定流水延迟。则：

```text
last_scale_write <= q + delta + (W_scale-1) + L_rmw
必须满足 delta-1 + L_rmw <= T-W_scale+12
```

推荐 `delta<=1`。M≥7 时 `T=W_scale`，因此 `L_rmw<=12` 就能在下一个 PV 首 S0 前全写完。α、命令解码的准备费用必须已吸收，不再计入 delta。

`L_rmw=12` 用满预算时，最后写回与 PV 首 S0 同沿，必须采用上述 `scale_will_commit`。如果只允许 PV 读取已注册 fence，保守合同改为 `L_rmw<=11`。两种边沿口径不能混用。

若用“RAM读1 + FP32乘法4 + 写入1”的接口示例，`L_rmw=6`，约有六拍余量；这是拟定合同示例，不是已实现 VPU 的时序结果。实际延迟由负责人给出并由 TB 参数复现。

M≤6 时，矩阵被四拍 B loader 下界限制，Scale 的有效遍历更短，余量反而更大。

## 7. 非矩阵接口合同

### 7.1 命令接受不等于启动

保留原 QK_POST、ALPHA_EXP、P_EXP、P_POST、OACC_SCALE、RECIP、AFIN 操作语义。建议控制边界使用：

| 接口 / 事件 | 语义 |
|---|---|
| `cmd_valid/ready + context` | 接受不可变 descriptor，允许在数据 fence 前准备 |
| `armed_valid/ready + token` | 解码、合法可预取的系数/首请求地址和返回容量已准备；不要求提前读取尚未授权的 RAM |
| `go_valid/ready + token` | 数据/owner 依赖满足，允许实际执行 |
| `data_valid/ready + tag` | 接收/发送真实数据；反压时整包保持 |
| `commit_fence + token` | 指定输出已完整提交，由 PCore 的真实读写/行计数确认 |
| `done_valid/ready + context` | 单元整体完成；未结清事务或错误 token 不能被接受 |
| `flush/ack` | 取消 active/prepared 工作；旧 generation 返回不得污染新 Job |

不强制 VPU/SFU 同时执行两个算术任务。每单元最多一个 active 加一个 prepared descriptor，prepared 可提前解码；明确区分两个 token，不能让旧单元的单个 busy 位阻止所有准备。单位内部队列/流水由负责人适配，PCore 负责 grant、访问合法性与计数。

可优先只给 SCALE 增加提前 armed 路径；其余提前准备程度以非矩阵 deadline 为准。不要无理由增加多任务算术并发。

### 7.2 必须携带的 context

`major Job token/generation, head/context, profile/version, M, block_id, operation, input/output bank generation`。数据再带 compact row/pair、nt/column group、mask、last、请求身份。

profile 只用于验证全 Job 相同，不把 original row list 复制进每条数据。Attention mask 若依赖 original position，应由上游按 compact profile 提供；矩阵和指数流水不猜原始位置。

### 7.3 数据与访存宽度

| 路径 | payload / 条件 |
|---|---|
| FACC/OACC→VPU | 两行×16 FP32，1024 bit；valid rows + pair/nt/tag；同步读、足够信用时 II=1 |
| VPU Scale→OACC | 同样 1024 bit，读写并行，原地址返回；每拍最多一个 bundle |
| VPU→SBUF | 目标两行×16 FP32；可用 1024 bit 或两路独立 512 bit。若仍一个512-bit单行写口，QK_POST 时间必须按至少 M 写拍计，不能按 P 宣称32-lane写入 |
| AA/α/L/RECIP↔SFU | 连续4行 FP32，128 bit + mask/tag；或利用现有512-bit span只选有效4项；不得每拍只用一个scalar却声称SFU4 |
| SBUF→SFU P_EXP | 每拍4个 Score FP32，128 bit；同一row的 m 广播，column group0..3 |
| SFU→VPU P_POST | 每拍4个 P FP32，128 bit + row/group/tag；也可组装32值bundle后每8拍交付，必须记录真实4-lane产出率 |
| VPU→PBUF/QOZ | 每pair两行INT8+scale，272 bit + mask/行索引；接A方案三row-bank写端，不额外增加ZBUF |

所有统计/Score/量化写入只提交前 M 行。三个 row bank 的写冲突、返回容量和每任务 written bitmap 仍按 A 方案校验。VPU/SFU 是独立单元，可并行；同一 VPU 的两个工作没有被假定为同时占用32 lane。

### 7.4 Softmax 隐藏的可检验预算

QK_POST→ALPHA_EXP→P_EXP 的阶段依赖维持原串行语义；P_POST 在 P_EXP 前 armed，随着 P 流到达做行和、L 更新、量化、PBUF 写回，不等整个 P_EXP 后再串行处理。

```text
alpha_input_cycles = ceil(M/4)
P_exp_input_cycles = 4*M
QK_POST_data_cycles >= P        // 若真正32值/拍路径
                     >= M      // 若SBUF仍只有单行写口
```

各数只表示输入/遍历吞吐，不包含指数 pipeline、行最大值/量化尾部、统计端口仲裁和命令交接。若 α 读与写共用一条请求口，其服务拍数也要实算；不能用 SFU4 掩盖存储瓶颈。

性能合同：PBUF(b+1)、L(b+1) 的真实提交，以及 SCALE(b+1) 的准备应在 PV(b) 的隐藏窗口结束前完成；否则报告超时并延长下一 QK，不强行启动。Bootstrap 的 P0 需在 QK1 窗口内完成。

理想32值 QK_POST路径下，基础串行输入占用为 `P+ceil(M/4)+4M`。M=8 时为38拍，S=76，尚有38拍用于其它真实延迟，是重要压力点；M=51 时为243拍，尚有185拍。若 QK_POST按单行写，M=8余量34拍、M=51余量160拍。

只给出 VPU32/SFU4 不足以自动保证这个合同。负责人要明确 cmd/armed/go、RAM、EXP、行和、量化 pipeline 延迟，TB 必须把它们参数化并验证最差 M，而不是只验证 M=51。

保持全掩码行的原语义：相等的 -inf 最大值不生成 NaN aa；masked P=0；l=0 时 reciprocal/output 采用约定的0结果。

## 8. 尾部：严格空出一个 slot

令 PV53 的首 S0 为 s53，正常间隔为 S：

```text
虚拟空 slot 开始 = s53 + S
PV54 最早首 S0  = s53 + 2*S
```

空 slot 不产生 QK55，只允许 SCALE54、A/B预取和必要控制。PV54 必须同时满足这个时间条件、PBUF54 committed、SCALE54 RAM全写入、A/B ready。

从首 S0 的时间戳定义尾部，不在 PV53 C 后再次机械等待“一个完整矩阵 + 一套额外交接”，防止同一尾部重复计费。若资源超时，延长并单独记录。

PV54 最终 C 后执行 RECIP，再 AFIN/量化。RECIP、AFIN descriptor 可以提前准备，但本方案不把 reciprocal 的执行移到 PV54 前，以保持原尾部算法顺序。

```text
RECIP_input = ceil(M/4)
AFIN_data   = 16*P              // 保守的双parity访存/32-lane遍历
F_tail = RECIP_input + L_recip + AFIN_data + L_afin_quant + H_tail
```

M=51 是 `13+416=429` 拍数据工作，加实际流水和交接，尾部仍为四百多拍；不能把429直接当成已测的完整尾部。

QK54 完成且所有 Q read reference 归零后释放 QOZ_Q，提前获取 QOZ_O，利用 PV53/空slot/PV54准备区间完成 owner 交接。整体 Attention done 必须等 l54 reciprocal、AFIN输出、QOZ_O 的全部有效行/scale提交及所有单元 completion 结清，不能只等 PV54。

## 9. KVB 与初始预取的供数条件

现有 B V1 packet 为两 Tile/9个512-bit beat：16 Tile 的一个矩阵 Block需要72个beat，而内部权重写口只需64个data beat。

- R=4 时每 Block 目标间隔76拍，72拍总线服务在长期平均上可容纳，余量只有4拍
- 开始 Block 时推荐可用库存至少4个匹配 Tile，库存包括驻留bank和queue READY；8-slot queue吸收packet相位、header与RAM读取
- 库存阈值4是待验证的工程初值，不是对任意外部气泡的保证；packet grant、queue读延迟若更大需按实测调整
- 8核 packet grant 必须提前/流水化，不能每个packet额外停等几拍；若8个packet每个多两拍，总服务88拍，就不可能满足76拍目标
- 允许在旧 Block drain/下一descriptor准备期间继续接收K/V，role由packet识别；保持整Attention的KVB source lock
- KVB、B queue、holding到loader必须支持稳态连续四拍写；同步读产生的首拍在预取中吸收

首 QK0 的 cold_start 单独计。它不仅有四拍 weight write，还可能包含首A Tile的 `ceil(M/3)`、B packet接收、同步读和命令准备。TB 若预填源存储，要同时说明哪些工作已经在计时开始前完成。

## 10. 总 Attention Job 时间的计算口径

测量起点为外部 Attention `job_valid&&job_ready`；终点为首次整体 `done_valid`。另报 done_ready 反压造成的完成接收等待，不算成算术时间。

令 C0 为接收总 Job 到 QK0 首 S0 的实测冷启动，理想/无反压条件下所有正常首S0间隔按 S执行，且 PV53→PV54 为2S：

```text
最后 PV54 首 S0 - QK0 首 S0 = 110*S
T_job = C0 + 110*S + (15*R+P+12) + F_tail
```

109个相邻Job间隔中，108个正常间隔、一个双slot尾部间隔，所以是110S；不是把110个矩阵再额外加110次尾部。

| M | S目标 | QK0首S0→PV54最终C（解析值） |
|---:|---:|---:|
| 1 | 76 | 8,433 |
| 7..8 | 76 | 8,436 |
| 11 | 108 | 11,988 |
| 20 | 172 | 19,092 |
| 32 | 268 | 29,748 |
| 50 | 412 | 45,732 |
| 51 | 428 | 47,508 |

上表未加 C0/F_tail，也不是仿真结果。实际任务总时间由110个真实矩阵Job、真实数据fence和TB服务时序累积，不能直接把表中常数写进done计数器。

## 11. 后续 RTL 实施边界

本轮不执行以下修改；它们是将方案落地时的顺序：

1. 在 dynamic 建立 Attention scheduler/adapter，锁存 M/context，生成原110个Job；由首S0计时维护slot target。
2. 计算核/Block frontend增加active+prepared、source_read_closed、issue_closed、retire_C；保留预装bank，先证明同C换Job的metadata与RAM写回不被下一context覆盖。
3. 接A三行加载/3-slot和B512接收/queue；在最后A Tile已入queue后提前预取next，而不是等最后S0。
4. 将旧非矩阵命令接入prepare/armed/go、token与真实commit fence。优先修SCALE冷启动及末次写回放行，保留full done/flush安全检查。
5. 明确Scale pair-major `(pair,nt)`访存与动态计数；统计span适配SFU4；P_POST仍流式跟随P_EXP。
6. 用真实MXU/DEQACC/存储运行完整Attention；非矩阵单位由TB并行模型替代。Projection/G-U已有计算合同和回归不能退化。

继续只在 `DEA8_dynamic/Pcore` 修改；旧 `DEA8` 和独立 `DEQACC` 只读，不综合，不上传GitHub。

## 12. 仿真验收：不只检查总数

运行环境沿用 [当前仿真入口](C:/Users/fly04/Desktop/VLA/DEA8_dynamic/Pcore/run_compute_xsim.ps1) 的 Vivado 2022.2 标准调用方法，先读 [仿真说明](C:/Users/fly04/Desktop/VLA/interaction/仿真说明.docx)。具体 Attention TB/入口尚未创建，不伪造可运行命令。

| 验证项 | 必须观察的证据 |
|---|---|
| 真实矩阵 | 55 QK+55 PV，每Job16 Tile、每Tile P pair；累计 `110*16*P` 个Psum/ACC commit；Psum和有序FP32累加golden |
| M范围 | 全M=0..51，尤其1..8、11、奇偶M、51；M0无110 Job，行尾无写入 |
| 调度次序 | 完全符合冻结次序；无QK55，PV53→PV54首S0间隔2S |
| 跨Block准备 | source_read_closed、首A_READY、B0/B1预加载、lastS1释放、首S0时间戳与context |
| 稳态性能 | 无人为断供/反压时，各实际间隔≤`16R+7+5`；最大值、平均值及超预算分解。Bootstrap另报，不拿冷启动或尾部冒充稳态失败 |
| OACC_SCALE | 非单位α、真实1024-bit RAM读/写、W个写入、正确mask/address；记录command/armed/go/首读/末写/PV首S0；正margin必须来自这些时间戳 |
| VPU/SFU模型 | 两个独立并行agent；单个VPU算术不被假定多任务并发；VPU32/SFU4固定吞吐+非零可配置流水，真实valid/ready和存储返回 |
| Softmax | Mask、m/aa/α、P、l实际更新；两代α/PBUF正确；全mask行、SFU/VPU数据气泡与迟done |
| 尾部 | RECIP读l54，AFIN读取真正O54，量化/写QOZ_O，全region提交后才done |
| 协议安全 | prepared≠启动；clear时旧返回失效；最后RAM写未accept就done、错generation、重复Scale、错误block/role均明确拒绝 |

性能测试不采用“SCALE等待208拍”的旧FAST stub，也不把M51有效元素除以32的408拍替代实际416个ACC pair beat。模型需在吞吐上真实限速，在访存上真实交互；不向RTL注入预期Psum或OACC结果。

另运行压力模式：合法数据气泡、随机ready、VPU/SFU晚armed/晚done、KVB packet grant延迟。在压力模式允许间隔延长，必须归因并保持数值/所有权正确，不能降低检查来满足目标。

本轮证据仅为源码路径核查与周期公式校验。新调度的功能、隐藏余量、完整Job时间及250MHz物理时序，均待后续实现验证。
