# PCore 2.0 v3 数据面

这一目录是独立于 `PCore_2.0/rtl` 的 v3 数据面。2026-09-29 按 `interaction/AI工具意见.docx` 接通本地 A 数据源、拆分 accumulator 端口，并完成 XSim 回归与 Vivado OOC 综合。

**当前状态：14 项 XSim PASS；OACC 已推断为 BRAM；OOC 暴露 FP32 加法路径组合环和负时序裕量，尚未达到 250 MHz。**

## 已实现

- `qvec16_t`：16 个 INT8 数据与 8-bit scale 绑定为一个传输原子。
- `a2_t/xbc4_t/b2_t`：数组维度采用 packed 维度前置写法，Vivado 可识别为完整 288-bit packed 接口；编译时仍检查 `$bits(a2_t)==288`、`$bits(b2_t)==288`。
- `XBC4 -> 2 x A2`：每拍输入 4 行，转换为两个 row-pair。
- `AFIFO`：64 x 288，支持 0/1/2 push 与 1 pop，完整 Tile reservation，尾行 `row_valid=01`。
- `HBM/KVB B2 -> BFIFO`：两列一个 B2，两个来源统一进入 64 x 288 BFIFO，并检查 tile/group/epoch 顺序。
- `B2 -> B1 serializer -> B Loader`：Tile 内部连续输出一列/拍，分别加载两个 stationary B bank；Tile 末列禁止跨 Tile 预取，避免破坏完整 Tile credit。
- `2-row MXU`：保留 16 x 16、256 个显式 DSP48E2、每拍两行 A、7 级 Psum 流水。
- `dea8_pair_store_v3`：保留独立的 begin/write/commit、Q16/Z32 region 测试。Attention 使用下面的顺序流式 local store，不把两个接口混用。
- `dea8_local_a_store_v3`：偶奇行分开存储；A2 顺序写入、完整 region 自动 commit、同步弹性读口。Attention 实例化 QOZ（16 Tile、1 bank）与 PBUF（1 Tile、2 bank），替换旧 XBC4 `replay_mem`。
- `DEQACC32`：32 lane、严格 D0..D4 五级流水，偶奇双物理路径，支持 FACC A/B 与 OACC；`add_old=0` 直接写 partial，`add_old=1` 读旧值并做 FP32 累加，最终 D4 commit 才产生 `done`。写回在 `valid_q[3]` 对应的 D4 边沿完成，没有额外 `sum_q4` holding stage；testbench 逐周期检查首个响应到 commit 的 edge delta 为 4（含首拍计数即 5 stage）。
- `dea8_matrix_v3`：把 XBC、A/B FIFO、B Loader、MXU 和 DEQACC 接成完整多 Tile 矩阵作业链路；逻辑 `job_a_tile_idx/job_b_tile_idx` 与 FIFO 运输 `job_a_stream_idx/job_b_stream_idx` 分开，`m_rows` 派生 pair 数与尾行 mask，支持 HBM/KVB 入口选择、显式 `job_start`、作业配置锁存、Tile 序列、bank 释放/重装、首 K Tile 清零和最终 D4 commit 后结束。B 源在 Job 接受时锁存，Job 期间不能由 live `b_source` 切换。
- `dea8_projection_v3`：Projection 控制壳，验证 `[51,1024] x [1024,256]`；每个输出 N Tile 归约 64 个 K Tile，FACC-A/B 交替写入，同时读回上一个 N Tile 的 26 个 pair。
- `dea8_acc_store_v3`：FACC-A、FACC-B、OACC 各自独立 1R1W，进一步分 even/odd RAM。Matrix 与 VPU 可同时访问不同 bank；同 bank 通过 `result_rd_ready/vpu_wr_ready` 背压。Matrix 从 Job 接受至最终 commit 完成独占目标 bank，包含中途无读写的空拍。
- `dea8_attention_scheduler_v3`：按旧单 INT8 方案生成 `QK0, QK1, PV0, QK2, PV1, ...,
  QK54, PV53, PV54`；没有 QK55，并在 PV53 后保留一个完整的稳态矩阵时隙给尾部 OACC/scale。
- `dea8_attention_matrix_v3`：Attention block 适配层。QK/PV 均作为一个 16-Tile Matrix Job，
  QK 从 QOZ 读 16 个 Tile 并沿 K 归约；PV 从 PBUF 同步重放同一个 Tile，沿 16 个 N Tile 更新 OACC。A2 source selector 在 AFIFO 前选择 QOZ/PBUF；Projection 的 Matrix 实例仍选择 XBC4 adapter。
- `matrix_cmd_t`：算法模式只存在于控制边界；`a_id/b_id` 为 10-bit 逻辑源 ID。MXU 和 DEQACC 接收 accumulator、`add_old`、上下文及完成标记，不按 QK/PV 选择算术。底层完成字段仍为 `final_k/last`，见接口契约。

## 本轮接口契约

- **QOZ 写入**：`qoz_load_*` 输入 A2；`tile_idx=0..15`，每 Tile 的 `pair_idx=0..25`；末 pair 的 `row_valid=01`。最后一次握手自动置完整标志。`epoch/head` 在整个 region 内保持一致。
- **QOZ 生命周期**：当前固定 51 行、单 head region，装载一次供全部 QK 重用；下一 head/epoch 使用全局 `clear` 后重新装载。尚未实现 Q/Z region 复用或独立 QOZ replace 命令。
- **PBUF 写入**：`replay_load_entry` 由 XBC4 改为 A2，`tile_idx=0`，26 次顺序写入；另带 `replay_load_block/epoch/head`。`slot=block_id[0]`；完整写入自动 commit，PV 最终 D4 完成后 release。
- **PBUF 检查**：乱序 pair、错误 mask/slot、reserved 非零、写满 bank、写 active bank、半途更改身份均置 sticky `protocol_error`；`clear/reset` 清除。尚未完整时等待数据；已完整但 block/epoch/head 不匹配的 PV 命令拒绝并报错。
- **本地 A 读口**：同步请求/响应；下游不 ready 时保持 A2 数据、scale 和 tag。QK/PV 命令固定 `m_rows=51`，其他值明确拒绝；通用 Matrix 的动态 M 接口保留。
- **Source 选择**：`dea8_matrix_v3.LOCAL_A` 是实例级选择；Attention 内部按已接受命令动态选择 QOZ/PBUF。Projection 与 Attention 仍是不同 Matrix 实例，尚未合成一个共享 PCore Top。
- **VPU accumulator 端口**：读请求只有 `valid && ready` 才接受，响应延迟一拍；响应端无 ready，消费者必须接收。`acc_write_t` 绑定目标、地址、row mask 和两行 FP32 vector。跨 bank 可以并行，同 bank 请求保持到 ready；同地址同步读写按旧值读取语义使用。
- **容量**：FACC 每 bank 为 even 26 / odd 25 个 512-bit vector；OACC 为 even 416 / odd 400。尾部无效奇行读零。异步 `dbg_*` 只用于 RTL 仿真，综合输出常零，不产生额外 RAM 读口。
- **逻辑 ID**：Attention 保留完整 10-bit command，QK `a_id=0`，PV `a_id=block_id`；不再截断逻辑 ID 传进 Matrix。K/V 仍由外部按逻辑窗口供流，内部仅检查运输编号；尚无自主 KVB 地址请求器。
- **待统一的元数据**：底层仍保留 `final_k/last` 字段及 `job_final_k` 端口。当前把 `cmd.result_last` 传入旧 `final_k`；底层 `last` 表示本次 Matrix Job 最后 pair，scheduler 的 `cmd.job_last` 表示整段 Attention 最后 Job，不能机械互换。

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
| `tb_v3_acc_overlap` | 442 次跨 bank 并发读、442 次并发写；同 bank 冲突和保持重试；odd 深度与 clear |
| `tb_v3_local_a_protocol` | 7 种错误写入；sticky error；同步读背压保持；尾奇行；bank 复用与 clear |
| `tb_v3_deqacc32` | 5 级流水、FACC-A/FACC-B/OACC 三种选择、OACC 读改写及 D0..D4 周期测量 |
| `tb_v3_matrix` | 单作业连续 64 Tile，A/B 并发灌入、AFIFO 边写边读、两 bank 循环复用、1664 个 pair commit；MXU issue=1664、`max_gap=1` |
| `tb_v3_projection` | 完整 Q Projection：`[51,1024] x [1024,256]`，16 个输出 Tile、每 Tile 64 个 K Tile；逐一检查 16×26×16 个输出 lane、尾行 mask 和最终输出 Tile 数 |
| `tb_v3_attention_scheduler` | 真实 55 个 block 验证 QK/PV 顺序、矩阵完成握手、VPU/SFU 独立完成握手、尾部时隙及 55+55 计数 |
| `tb_v3_attention_matrix` | 真实 `QK0,QK1,PV0,QK2,PV1`；本地 QOZ/PBUF、OACC `add_old` 数值；3 种已满 PBUF 的 block/epoch/head 错配拒绝 |
| `tb_v3_attention_system` | Scheduler 与真实 Attention Matrix 直接连接，2 个 KV block 跑通 QK=2 + PV=2，VPU/SFU 使用 one-cycle handshake model，检查 command/done context、A/B stream、PBUF 双 bank和协议错误 |
| `tb_v3_attention_55` | 55 QK + 55 PV；QOZ 一次装载后重用、双 PBUF、本地 A2 reader、KVB B2；VPU 模型通过正式端口读 FACC、读写 OACC；最终检查 13056 个值 |

2026-09-29 回归：`reports/v3_simulation_summary.txt`，对应源码清单 `reports/v3_sources_sha256.csv`。

55-block 覆盖计数：QOZ 装载 416 A2、KVB 输入 14080 B2；VPU 读 24310 / 写 22880 次，其中 Matrix busy 期间接受读 9431 / 写 8056 次。这里的 OACC scale 使用恒等回写模型，验证真实存储并行而非 Softmax 数学。

## Attention 时序基线

- 双行 MXU 每个 QK/PV block 的发射量为 `26×16=416` 拍。
- 当前 v3 采用 `7` 级 MXU 流水、`5` 级 DEQACC 流水，完整数据通路排空为
  `7+5=12` 拍，矩阵交接预留 `1` 拍，因此稳态预算为
  `416+12+1=429` 拍。
- 冷启动仍单独保留首个权重装载余量，参数为 `MATRIX_COLD_BUDGET=445`；
  该参数只用于控制/性能建模，不改变 MXU 的 416 拍发射。

## 边界说明

- `b2_t` 是 PCore 的逻辑 B2 接口，不是物理 HBM AXI beat。真实 256-bit HBM AXI 的 burst/repack 由 HBM Controller/GCore 完成。
- Projection 输出仍为 FP32 流，尚未接真实 VPU FP32→INT8。Attention 的 QOZ/PBUF 存储与 reader 已接通，但量化 Q/P 的生产者仍为 TB，Projection→量化→QOZ 尚未闭环。
- 55-block 测试真实运行本地存储、Matrix、MXU、DEQACC、OACC 和正式 VPU 存储端口。Mask/Softmax/EXP/reciprocal 仍为模型；部分 golden 复用 RTL 浮点函数，不是独立浮点算术签核。
- `dea8_attention_matrix_v3` 的逻辑 `a_id/b_id` 不再承担 FIFO 顺序检查；每次 QK/PV command 内部使用独立的 A/B transport stream counter，避免 Q 源、PBUF 源、K/V block 地址混用。
- 当前每个 QK/PV Matrix Job 最大 458 拍，核心发射量仍为 416；全 TB 为 100833 拍，包含 QOZ 预装载、逐 vector VPU 读/校验/恒等回写和最终 debug 检查。VPU 模型未流水化，不能与旧 delay-only 模型的 54860 拍直接比较吞吐。

## OOC 综合：资源已核对，时序未通过

Vivado 2022.2，`xcu50-fsvh2104-2-e`，4 ns。复现入口：

```powershell
powershell -ExecutionPolicy Bypass -File .\run_v3_ooc.ps1 -Top dea8_deqacc32_v3
powershell -ExecutionPolicy Bypass -File .\run_v3_ooc.ps1 -Top dea8_attention_matrix_v3
```

| 2026-09-29 OOC top | Total LUT | FF | DSP | RAMB36 / RAMB18 | 报告 WNS |
| --- | ---: | ---: | ---: | ---: | ---: |
| `dea8_deqacc32_v3` | 72086 | 9585 | 0 | 14 / 2 | −6.071 ns |
| `dea8_attention_matrix_v3` | 91777 | 65427 | 256 | 18 / 2 | −6.472 ns |

- 报告：`reports/ooc_dea8_deqacc32_v3/`、`reports/ooc_dea8_attention_matrix_v3/`。Attention OOC 另保存 `sources_sha256.csv` 和 `status.txt`；DEQACC 本次直接使用 Tcl 执行，其日志为 `reports/ooc_deqacc_run.log`。
- OACC：even/odd 各 7 RAMB36 + 1 RAMB18，合计等效 15 BRAM36。FACC 四个 parity RAM 合计 1184 LUTRAM；Attention QOZ 另用 4 RAMB36。
- **阻塞项**：综合日志在现有 `dea8_fp32_v3_pkg.sv` 加法路径报告 timing loop。DEQACC `check_timing` 有 2 个组合环；Attention 有 4 个。最差路径为 `old_q2 → sum_q3`。Vivado 自动切断部分 timing arc，以上 WNS 仅作问题定位，不能作为有效时序签核。
- 次要资源问题：Attention OOC 的 AFIFO 使用 18384 FF，双 PBUF 模块使用 14483 FF，尚未得到期望的小容量 RAM 映射。资源表不是 8 核系统预算。
- 未执行布局布线、上板或完整 I/O 时序约束；下一步先定位 FP32 综合组合环，再评估 D3 加法路径的流水/结构方案。不能通过关闭检查或降低数值验证标准解决。
