# Attention 连续矩阵调度实现（2026-09-17）

更新：PV53与PV54之间新增独立828拍SCALE时隙，并已完成带Softmax行为模型的联调。
见 [完整联调与尾部时隙](Attention_完整联调与尾部时隙_20260917.md)。
下文91096/91097仅指不计该时隙的纯矩阵基准；含尾部缩放时隙的矩阵实测/预算为91924/91925。

## 1. 本次依据与边界

本次 Attention 矩阵侧以用户 2026-09-17 提供的“一个 Top Job、连续 KVB、跨 Job 预加载”方案为准。
它替代旧文档中的 Attention `expect_job` 逐块请求、`tile_columns` 二次暂存和每个 Block 固定重新加载 16 拍。
HBM 私有权重路径、XBC、VPU/SFU 算术及其他同学的实现不在本次修改范围。

新时序数字仅对应一个 head/epoch 的 110 次矩阵运算，并假设 A 数据、累加器及启动依赖已就绪。
不能把矩阵测试的总周期当作真实 Softmax、OACC 缩放、A_FIN 全部完成的 Attention 周期。

## 2. 实际接线

```text
上层：一次 start_valid && start_ready，携带 head / epoch
  |                         |
  | 通知 GCore              +--> PCore 的两项 Block Job 队列
  v                                  | current / next
GCore 连续 KVB                       v
  |                         Attention Matrix / Sequencer
  v                                  | bank/column/activate
KVFIFO：256 项、完整事务              |
  | B 列数据 + scale                 |
  +---------------------------> MXU 双 PE Bank + E_STAT Bank
                                      |
QOZ(Q) / PBUF(P) --> 同步读 --> Q_ACT_REG --> 乘法/四级树
                                      |              |
                  E_stream/E_stat/tag/dest 旁带 ------+
                                                     v
                                                  DEQACC
                                                     |
                                   QK --> FACC_A/B；PV --> OACC
                                                     |
                                   最后写入 --> commit --> Job done
```

Top Job 的上层扇出是系统集成契约；本次实现 PCore 接收端及连续流测试生产者，不修改正式 GCore RTL。
`dea8_attention_core.start_valid/ready` 是本工程的 Top Job 入口。

## 3. 模块职责

| 文件 | 当前职责 |
| --- | --- |
| `dea8_job_pkg.sv` | 固定 110 个 Job 的顺序；队列描述符只存 op、block、head、epoch |
| `dea8_block_job_queue.sv` | 两项队列 current/next，当前任务完成被接受后才出队并补充 |
| `dea8_kvb_stream.sv` | 连续 KVB、256 项 FIFO、上下文及顺序检查、每 Block 的有效 key mask |
| `dea8_attention_matrix.sv` | 队列与矩阵引擎连接；区分内部下一任务与外部依赖启动许可 |
| `dea8_matrix_sequencer.sv` | PE Bank 状态唯一所有者、列加载、A 同步读、跨 Job 预加载、完成屏障 |
| `dea8_matrix_engine.sv` | 连接 Sequencer、列加载模式 MXU、DEQACC |
| `dea8_mxu.sv` | Attention 采用 COLUMN_LOAD=1，HBM 原路径仍为默认行加载模式 |
| `dea8_attention_core.sv` | 接入新矩阵路径，保留已有 VPU/SFU、PBUF、alpha/OACC 依赖调度 |

固定顺序：`QK0, QK1, PV0, QK2, PV1, ..., QK54, PV53, PV54`。
GCore 的数据必须按同一顺序到达；不再等待 110 次单独的 Block 请求。
`facc_bank=pbuf_bank=block_id[0]`；只有 PV0 设置 `init_oacc`。

## 4. KVB 格式与物理存储

每项 `q[8*k+:8]=B[k,n]`，k=0..15；`e` 是该列的共享 scale。
QK：tile 是 K 维 feature 分块，column 是本 KV Block 内 key。
PV：tile 是输出 feature 分块，column 是该分块内输出 feature，16 个数据沿 key 维排列。
端口名沿用 `kvb_feat_blk` 与 `kvb_key_lane`，但在新协议中分别表示 tile 与 column；PV 不能再按名字把后者当成 key 序号。

| 存储 | 实际容量/含义 |
| --- | --- |
| KVFIFO | 256 × 172 bit；128 数据 + 8 scale + 36 metadata，共 5504 byte，不含控制寄存器 |
| PE 权重 A/B | 256 个 PE，每个两份 INT8 权重，共 512 byte |
| E_STAT_BANK A/B | 每 Bank 16 × 8 bit，共 32 byte；在 PE 外 |
| Q_ACT_REG | 16 × INT8，共 128 bit；每拍广播到 256 个乘法器 |
| Job 队列 | 两份 14-bit 简化描述符，加生成索引和有效计数 |

KVFIFO 的 metadata 包括 kind、block、tile、column、mask、last、epoch。
FIFO 可混存相邻 Job，数据与 scale 作为同一事务推进，不会独立错位。
满队列若本拍 pop，仍允许本拍 push；总接收数限制为 `110*16*16=28160`，不会在尾块计算期间继续吞入额外数据。
`kvb_last` 表示每个 Matrix Block 的第 256 项，不是整个 Top Job 仅一次 last。

一个有效 KVB entry 直接写 `PE[k][column]` 的 16 个权重，并写 `E_STAT_BANK[column]`。
16 个 entry 即完成一个 Bank，没有另外 16 拍的列转行复制。
历史 `dea8_tile_columns` 和旧 Adapter 文件保留供旧回归使用，但不在当前 Attention Core 的执行路径中。

注意：Attention 列协议的 scale 随每列写入，区别于 HBM 路径“16 个 scale 在首加载拍一起写”的原合同。两种源不能混用加载格式。

## 5. Bank 与激活控制

Bank 状态：`NULL -> LOAD -> READY -> ACTIVE -> NULL`。
加载只写空闲 Bank，计算只读 ACTIVE Bank；Bank 记录对应 Job 与 tile。
计算 tile0..14 时装下一 tile；计算 tile15 时装 next Job 的 tile0。
下一 Job 预加载完成也不能提前计算，必须等待当前 Job 的全部 816 个向量提交，且依赖启动许可有效。

A 侧合同是同步一拍读，不是带任意延迟的总线。`a_read_job` 与地址一起指出该次读取对应哪个 Job。
这尤其用于旧 Job 完成与下一 Job 接受同拍时，避免使用旧 op 误读 QOZ/PBUF。
行 0 可以在权重加载期间预取，读响应保持到 Bank 完整；等待过程中禁止后续读取覆盖它。
一次 tile 发射开始后，上游必须保证连续 51 行以及 DEQACC 写入容量，不支持 tile 内任意暂停。

最后一列加载与首行写入 Q_ACT_REG 可同沿发生。此时新 scale 的最后一项直接旁路到 E_STAT_ACTIVE_REG，避免采到旧值。
下一拍才使用 PE 中已经写好的权重做乘法；并非在寄存器写入沿之前就使用新权重。
MXU 六阶段仍是：Q_ACT_REG、乘法、树1、树2、树3、树4直接写 Psum_out_reg。
Tag、scale、目的信息始终在 PE 外，旁带末级与 Psum 对齐进入 DEQACC。

## 6. DEQACC 与交接

DEQACC 算术和五级合同没有改变：L0-L2 反量化准备及转换，L3 FP32 加法，L4 RAM 写入。
QK 沿 K 维归约，tile0 清旧值，后续 tile 读回同一行 FACC；反量化折入 `exp_fold=-4`。
PV 沿 N 维分块，读 PBUF[row]，写 OACC[row*16+tile]；只有 PV0 清旧 OACC。
后续 PV 的旧 OACC 必须由 VPU 按正确代际的 alpha 缩放完成。

RAM 写入、寄存的 commit_valid 被控制器采样、Job done 握手是不同事件。
current_job 在最终 commit 以前不会被 next_job 覆盖，禁止两代计算上下文同时在流水中。
Done 若被背压，描述符及已预加载的 Bank 保持；不能因为权重已 ready 就越过完成握手。

## 7. 周期预算与计数口径

默认参数：51 行 × 16 tile = 816 次连续乘法发射；MXU 六阶段，DEQACC 五阶段。
方案预算：冷启动 845，预加载稳态 828，无预加载兜底 844，110 Job 为 91097。
预算通过 `PIPE_DRAIN=MXU_LAT+DEQACC_LAT` 派生，不另外手写第二个 11。

下面的 T0 是测试采到 Top Job 的上升沿；记录值是相对 T0 的上升沿编号。

| 事件 | 首个 QK0 |
| --- | ---: |
| 第一项 KVB 接收 | T1 |
| 第一列到最后一列 PE 加载 | T2..T17 |
| 第一行进入 Q_ACT_REG | T17 |
| 实际乘法发射 | T18..T833，共 816 拍 |
| 最后向量写入 RAM，L4 | T842 |
| 最后 commit 被 Sequencer 采样 | T843 |
| QK0 Done 被接受，同时可接受 QK1 | T844 |
| QK1 第一行进入 Q_ACT_REG | T845 |
| QK1 第一行乘法 | T846 |
| QK1 Done | T1672 |

因此默认矩阵测试实测：冷启动 Done=T844，稳态 Done 间隔 828，无预加载间隔 843。
110 次矩阵最终 Done=T91096，最后 RAM 写入=T91094；均不超过对应预算。
较预算少的一拍来自寄存边界的计数及 A 预取重叠，不通过人为插入空拍凑预算。
首乘法到末乘法是 816 个发射沿，但两个沿编号相减是 815，不能混淆。
每两个相邻 Job 的最后乘法至下一首乘法相差 13 个沿，中间是 12 个无乘法周期。

这些数字来自 AUTO_LAUNCH=1 的矩阵侧测试。正式 Attention Core 使用 AUTO_LAUNCH=0，等待 Scheduler 的许可；最新Scheduler支持完成与下一命令同沿握手，正常依赖已就绪时普通Block仍为828拍，依赖未就绪则增加等待。
尤其 PV53 后的 alpha54 × OACC 仍要执行，没有 QK55 帮它隐藏，不能宣称真实尾部也无条件只有 828 拍。
本次保留 850 拍测试阈值，未新增硬件 watchdog 输出接口；外部断供和完成背压单独验证，不能归为固定计算时间。

## 8. 验证与复现

`tb_dea8_attention_matrix.sv` 使用独立整数 oracle，再精确转换 FP32。
它不调用 DUT 的浮点加法/反量化函数生成预期值；覆盖带符号的数据、逐行/逐列 scale、QK 跨 K 累加和 PV 旧值累加。
每次全流程检查 110 个 Job、28160 次列加载、89760 个 512-bit 向量，即 1436160 个 FP32 lane。
它只验证矩阵和反量化累加，不验证真实 EXP/Softmax 精度。

模式：default、STARVE、DEPENDENCY_WAIT、DONE_BACKPRESSURE、RESET_JOB、NO_PREFETCH。
错误模式 BAD_COLUMN/BAD_EPOCH/BAD_ORDER 必须触发协议断言，不能把这些预期 Fatal 当作正常路径失败。
STARVE 分别在首 tile 最后一列、跨 Job 半个 tile、内部 tile 边界注入断供。
RESET_JOB 检查复位期间与释放后无残留提交；不是完整掉电恢复或重新装载系统测试。

```powershell
# 在 VLA 目录运行；PythonExecutable 可替换为本机 Python 路径。
powershell -ExecutionPolicy Bypass -File pcore/rtl/run_xsim.ps1 -Test all -PythonExecutable python
python -m unittest discover -s pcore/tests -v
```

周期明细输出到 `pcore/rtl/attention_matrix*_cycles.csv`，记录 first_mul、final_ram_write、final_commit、block_done。
结果见 [本次验证记录](Attention_连续矩阵验证_20260917.md)。当前结论是 RTL 功能仿真，不是目标 FPGA 的频率、资源、布线或真实 VPU/SFU 数值签核。
