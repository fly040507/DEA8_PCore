# PCore 2.0 v3 数据面

这一目录是按照 `AI工具意见.docx` 与 `设计方案.docx` 重构的新数据面，独立于旧版 `PCore_2.0/rtl`。本轮只做 RTL 仿真，不做综合，不修改旧版源码。

## 已实现

- `qvec16_t`：16 个 INT8 数据与 8-bit scale 绑定为一个传输原子。
- `a2_t/xbc4_t/b2_t`：数组维度采用 packed 维度前置写法，Vivado 可识别为完整 288-bit packed 接口；编译时仍检查 `$bits(a2_t)==288`、`$bits(b2_t)==288`。
- `XBC4 -> 2 x A2`：每拍输入 4 行，转换为两个 row-pair。
- `AFIFO`：64 x 288，支持 0/1/2 push 与 1 pop，完整 Tile reservation，尾行 `row_valid=01`。
- `HBM/KVB B2 -> BFIFO`：两列一个 B2，两个来源统一进入 64 x 288 BFIFO，并检查 tile/group/epoch 顺序。
- `B2 -> B1 serializer -> B Loader`：Tile 内部连续输出一列/拍，分别加载两个 stationary B bank；Tile 末列禁止跨 Tile 预取，避免破坏完整 Tile credit。
- `2-row MXU`：保留 16 x 16、256 个显式 DSP48E2、每拍两行 A、7 级 Psum 流水。
- `Pair Store`：QOZ/PBUF 使用偶数行/奇数行物理存储，data 与 scale 绑定，保留 begin/write/commit 语义。
- `DEQACC32`：32 lane、严格 D0..D4 五级流水，偶奇双物理路径，支持 FACC A/B 与 OACC；`add_old=0` 直接写 partial，`add_old=1` 读旧值并做 FP32 累加，最终 D4 commit 才产生 `done`。写回在 `valid_q[3]` 对应的 D4 边沿完成，没有额外 `sum_q4` holding stage；testbench 逐周期检查首个响应到 commit 的 edge delta 为 4（含首拍计数即 5 stage）。
- `dea8_matrix_v3`：把 XBC、A/B FIFO、B Loader、MXU 和 DEQACC 接成完整多 Tile 矩阵作业链路；逻辑 `job_a_tile_idx/job_b_tile_idx` 与 FIFO 运输 `job_a_stream_idx/job_b_stream_idx` 分开，`m_rows` 派生 pair 数与尾行 mask，支持 HBM/KVB 入口选择、显式 `job_start`、作业配置锁存、Tile 序列、bank 释放/重装、首 K Tile 清零和最终 D4 commit 后结束。B 源在 Job 接受时锁存，Job 期间不能由 live `b_source` 切换。
- `dea8_projection_v3`：Projection 控制壳，验证 `[51,1024] x [1024,256]`；每个输出 N Tile 归约 64 个 K Tile，FACC-A/B 交替写入，同时读回上一个 N Tile 的 26 个 pair。
- `dea8_attention_scheduler_v3`：按旧单 INT8 方案生成 `QK0, QK1, PV0, QK2, PV1, ...,
  QK54, PV53, PV54`；没有 QK55，并在 PV53 后保留一个完整的稳态矩阵时隙给尾部 OACC/scale。
- `dea8_attention_matrix_v3`：Attention block 适配层。QK/PV 均作为一个 16-Tile Matrix Job，
  QK 沿 K 方向展开，PV 沿 N 方向展开；PV 在一个 Job 内重放同一 PBUF bank 的 P，逐 N Tile 更新 OACC 地址。PBUF 为双 bank，按 group 顺序完成 load/commit，PV 最后一个 N Tile 完成后 release 当前 bank，下一 block 可装载另一 bank。
- `matrix_cmd_t`：算法模式只存在于控制边界；`a_id/b_id` 为 10-bit 逻辑源 ID，MXU 和 DEQACC 只接收目标 accumulator、`add_old/result_last/job_last` 等通用元数据。内部 A/B FIFO 运输编号由 Matrix/Attention 适配层单独维护。

## 仿真入口

在本目录执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\run_v3_xsim.ps1
```

脚本使用 Vivado 2022.2 XSim，检查编译、elaboration、Fatal/Error 和每个 testbench 的 PASS 标志，并生成 `reports/v3_sources_sha256.csv`。

当前回归覆盖：

| Testbench | 覆盖 |
| --- | --- |
| `tb_v3_ingress` | XBC4 到 26 个 A2，13 拍输入与尾行 mask；再验证 M=50 时 25 个 pair 和单个有效尾 A2 |
| `tb_v3_bpath` | 8 个 B2 到 16 次 B1 加载，scale/data 绑定与 BFIFO 完整度 |
| `tb_v3_bfifo_stream` | 16 Tile、128 个 B2 的连续入队/出队，覆盖 `group7` 同拍 push/pop |
| `tb_v3_pair_store` | QOZ/PBUF 行偶奇存储、scale 原子性与尾行读取 |
| `tb_v3_pair_store_regions` | Q16、Z32 及 Z32→Q16 reuse，验证 odd row 计数 `25×Tile` |
| `tb_v3_deqacc32` | 5 级流水、FACC-A/FACC-B/OACC 三种选择、OACC 读改写及 D0..D4 周期测量 |
| `tb_v3_matrix` | 单作业连续 64 Tile，A/B 并发灌入、AFIFO 边写边读、两 bank 循环复用、1664 个 pair commit；MXU issue=1664、`max_gap=1` |
| `tb_v3_projection` | 完整 Q Projection：`[51,1024] x [1024,256]`，16 个输出 Tile、每 Tile 64 个 K Tile；逐一检查 16×26×16 个输出 lane、尾行 mask 和最终输出 Tile 数 |
| `tb_v3_attention_scheduler` | 真实 55 个 block 验证 QK/PV 顺序、矩阵完成握手、VPU/SFU 独立完成握手、尾部时隙及 55+55 计数 |
| `tb_v3_attention_matrix` | 真实 `QK0,QK1,PV0,QK2,PV1` 序列；验证两个 PBUF bank、P 重放 16 个 N Tile、OACC 地址以及第二个 PV 的 `add_old` 数值 |
| `tb_v3_attention_system` | Scheduler 与真实 Attention Matrix 直接连接，2 个 KV block 跑通 QK=2 + PV=2，VPU/SFU 使用 one-cycle handshake model，检查 command/done context、A/B stream、PBUF 双 bank和协议错误 |
| `tb_v3_attention_55` | 完整 55 个 QK + 55 个 PV；TB 模拟 VPU/SFU 非矩阵延迟、PBUF 产生、HBM A/B 输入，真实运行 Scheduler、Attention Matrix、MXU、DEQACC 和 OACC；逐 Block 检查上下文/部分结果，最终逐项检查 51×256=13056 个 OACC 输出 |

## Attention 时序基线

- 双行 MXU 每个 QK/PV block 的发射量为 `26×16=416` 拍。
- 当前 v3 采用 `7` 级 MXU 流水、`5` 级 DEQACC 流水，完整数据通路排空为
  `7+5=12` 拍，矩阵交接预留 `1` 拍，因此稳态预算为
  `416+12+1=429` 拍。
- 冷启动仍单独保留首个权重装载余量，参数为 `MATRIX_COLD_BUDGET=445`；
  该参数只用于控制/性能建模，不改变 MXU 的 416 拍发射。

## 边界说明

- `b2_t` 是 PCore 的逻辑 B2 接口，不是物理 HBM AXI beat。真实 256-bit HBM AXI 的 burst/repack 由 HBM Controller/GCore 完成。
- 当前 Projection 输出是送往 VPU/QOZ 量化边界的 FP32 流；VPU 的 FP32→INT8 量化及实际 QOZ 写入尚未接入本目录。
- Attention 已完成完整 55 个 block 的矩阵级验证：`tb_v3_attention_55` 由TB模拟VPU/SFU的非矩阵处理、PBUF装载以及HBM A/B供数，真实运行 Scheduler、Attention Matrix、双行 MXU、DEQACC、PBUF/BFIFO 和 OACC，完成 QK=55、PV=55，并逐项检查最终 51×256 个有效输出。该TB的 P/Q/K/V 数值用于验证矩阵和累加地址；真实 Mask/Softmax 算术仍由后续VPU/SFU实现替换。
- `dea8_attention_matrix_v3` 的逻辑 `a_id/b_id` 不再承担 FIFO 顺序检查；每次 QK/PV command 内部使用独立的 A/B transport stream counter，避免 Q 源、PBUF 源、K/V block 地址混用。
- `dea8_acc_store_v3` 将 FACC 与 OACC 组织为 16-lane vector memories：FACC 标记为 distributed/LUTRAM 候选，OACC 标记为 block RAM 候选；DEQACC 与结果读取共享一个物理读选择器，写端为单写口。最终 BRAM/LUTRAM 数量仍需 Vivado 综合确认。
- 当前目标是先证明接口粒度、数据/scale 对齐、双行 MXU 算术、奇偶累加存储和最终 commit；综合、布局布线和 250 MHz 时序留到下一阶段。
- `tb_v3_attention_55` 实测每个 QK/PV Matrix Job 为 455 拍，其中核心双行 MXU 发射为 416 拍，其余为TB模拟的装载、Job交接和流水排空；全序列共 54860 拍。该实测值用于当前仿真基线，不能替代综合后的硬件时序。
