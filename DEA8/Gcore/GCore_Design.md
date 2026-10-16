# GCore 详细设计方案

> 历史方案：118 DSP、独立Reduce及双路rsqrt已被替代。当前实现/接口以 [GCore_Reduce_Plan.md](GCore_Reduce_Plan.md)、[README](README.md) 和 `gcore_rtl.f` 为准。下文保留旧设计推导，不作为新接口合同。

日期：2026-10-16。范围：`DEA8/`，固定 `M=51`。

**本文是架构与接口合同，不是全芯片单层推理通过的报告。** 实际范围见[README](README.md)。本次按118 DSP预算落实GCore专用add/mul与本地双通道rsqrt；外部rsqrt模式保留用于故障注入。不修改PCore、Reduce、HBM或总控RTL，不引入动态M，不增加工程版本名称。

## 1. 设计依据与边界

### 1.1 依据优先级

1. 用户本轮要求：在 `DEA8/Gcore` 搭建固定 51 行的 GCore；动态 M 后续单独设计。
2. 当前固定版接口：`../Pcore/rtl/pcore_pkg.sv`、`pcore_control_pkg.sv`、`dea8_tile_link_pkg.sv`、`dea8_pcore_control.sv`、`dea8_pcore_output.sv`。
3. 当前接收方：`../reduce/rtl/dea8_reduce_top.sv`。
4. 当前供数顺序参考：`../Pcore/tb/tb_pcore_control.sv` 的 `feed_projection`、`feed_gu`、`feed_attention`。
5. `../../VLA_Arch_Spec_v1.pdf`：第 6.6 节 GCore、第 8.1 节 RMS、第 8.6/8.8 节残差及归一化、第 8.11 节 gamma 折叠。旧接口和旧周期不覆盖现有 RTL。

`../../DEA8_dynamic/` 不作为本轮接口依据。当前 PCore 是四行 XBC、两列 KVB，不是三行 XBC、512-bit KVB。

### 1.2 固定参数

| 参数 | 本轮值 | 说明 |
|---|---:|---|
| PCore 数量 | 8 | 每核一个 Query head |
| suffix 行数 | 51 | state 1 行、action 50 行 |
| hidden width | 1024 | RMSNorm 的完整归约维度 |
| FFN width | 4096 | 每核 512 列 |
| Query / KV head | 8 / 1 | 共享一份 K/V |
| head width | 256 | 每 head 16 个 feature Tile |
| prefix 物理槽 | 816 | 51 个 key block |
| suffix 物理槽 | 64 | 51 有效、13 padding |
| Attention key block | 55 | prefix 51、suffix 4 |
| 量化块 | 16 | data 128 bit、scale 8 bit |
| 目标时钟 | 250 MHz | 设计目标，尚无 GCore 物理签核 |

### 1.3 三层控制分工

| 控制层 | 负责 | 不负责 |
|---|---|---|
| DEA8 control | 10 步、18 层、八核七 Job、跨模块屏障、权重/上下文选择 | 每拍 RAM 地址和算术流水 |
| GCore control | 共享对象、Norm/Residual、KV 接收与供数服务、真实完成与故障 | 自行展开 18 层或给 PCore 擅自发七 Job |
| PCore control | 一个完整私有 Job、矩阵及局部 VPU/SFU 后处理 | 全 hidden RMSNorm、全局残差、跨核 Reduce |

Reduce 仍是 GCore 外部的独立模块。GCore 接收归约结果，不再执行第二次八核求和。K/V 由八个 PCore 直接传入 GCore，不重建 Collective。

2026-10-16用户确认采用方案一：DEA8总控是唯一PCore Job发布者，GCore与PCore各有局部控制。GCore今后可以承接步间算术，但不因此兼任全局调度或服务器协议主控；本轮未实现步间EHU。

### 1.4 本轮完成目标与非目标

目标：形成可实施的固定 51 行单层数据/控制链，最终可由 TB 提供外部配置、HBM 和 VPU/SFU 服务，接通七种 Job。

本轮方案不实现：动态行选择、全局 AXI 地址分配、真实 HBM IP、PCore VPU/SFU 内部算术、步边界 EHU、最终 action output projection。后四项需要接口边界，但不能据此声称完整十步去噪已经覆盖。

最新阶段约束：本轮先搭建GCore主体，不要求当轮完成真实八核单层；DEA8主控用TB模拟，X和本层prefix K/V默认已在RAM中。因此删除本轮prefix接收/loader任务，使用预置对象登记，不把“已预置”误写成“已实现接收”。后文涉及未来prefix换层装载的内容仅为生命周期约定。

## 2. 单层流程与张量归属

令 `R` 为入口残差，`Y_O`、`Y_D` 为八核 Reduce 后的 FP32 全量结果。

```text
R[51,1024] BF16
   |
   +-- RMS_a / feature-B16 quant --> X_A INT8 + scale
   |                                 |
   |                                 +-- XBC --> K / V / Q projection
   |                                               |
   |                                K/V sender --> suffix KV
   |                                prefix + suffix --> KVB --> Attention
   |                                Q/O/Z 留在 PCore QOZ
   |
   +-- add Y_O --> R_mid BF16 --> RMS_f / quant --> X_F --> XBC --> G-U
                     |
                     +-- add Y_D --> R_next BF16 --> 下一层
```

| 阶段 | GCore 动作 | 完成谓词 |
|---|---|---|
| 入口 | 保有已预置R与本层prefix K/V，登记对象 | 上层保证RAM内容完整，GCore核对context/版本 |
| RMS_a | 求平方和、rsqrt、归一化、量化，产生 X_A | 3264 个量化块实际写入 |
| K | 重放 X_A；八路接收 K 的两个 Tile/核 | 全局 16 个 K Tile 写入且 commit 返回被接受 |
| V | 重放同一 X_A；八路接收 V 的两个 Tile/核 | 全局 16 个 V Tile 写入且 commit 返回被接受 |
| Q | 重放同一 X_A | 该 XBC 会话全部 beat 被八核接受；Q ready 另由 DEA8 收集 |
| Attention | 按现有 QK/PV 顺序读取共享 K/V 并广播 | 14080 个逻辑 KVB beat 被八核接受 |
| O | 接收 Reduce Tile，读 R、残差相加、BF16 写回并累积平方和 | 64 个 NTile 更新、统计量及 commit 全结清 |
| RMS_f | 使用 R_mid 及其平方和，产生 X_F | 3264 个量化块实际写入 |
| G-U | 重放 X_F，响应八核 n+1 预取许可 | 所有供数被接受；Z 完整由 PCore 负责 |
| Down | 接收 Reduce Tile，加 R_mid，得到 R_next 并收集平方和 | 64 个 NTile 更新、统计量及 commit 全结清 |

GCore 不接收 Q、Attention 输出或 Z 的完整副本。O/Down 的矩阵输入已经在各核 QOZ，不能再绕到 GCore 做一次全量搬运。

## 3. 顶层结构与建议文件

```text
dea8_gcore
  +-- gcore_control / context / object scoreboard
  +-- residual_store
  +-- residual_norm_engine
  |     +-- FP32 residual add / BF16 RNE
  |     +-- square / fixed sum tree / synchronous row-square RAM
  |     +-- native rsqrt pair + credit/RAM result queue / inverse RAM
  |     +-- FP32 normalize / max16 / MXINT8 quant
  +-- activation_store: four row banks
  +-- xbc_source: replay sequencer + multicast holding
  +-- kv_rx[8]: header / word / write / commit
  +-- kv_store: prefix window + suffix K / V
  +-- preloaded object registration (no prefix loader)
  +-- kvb_source: QK/PV sequencer + paired reads + multicast
  +-- reduce_sink: header / two-beat holding / residual pipeline
```

目标文件划分如下；**实际已创建与通过验证的范围以本目录README为准**：

| 文件 | 职责 |
|---|---|
| `rtl/gcore_pkg.sv` | GCore 自有 command、context、对象和状态类型 |
| `rtl/dea8_gcore.sv` | 结构顶层，不堆放各服务内部计数器 |
| `rtl/dea8_gcore_control.sv` | 命令分派、资源互斥、completion、cancel/fault |
| `rtl/dea8_gcore_residual_store.sv` | BF16 残差同步读写 |
| `rtl/dea8_gcore_norm.sv` | Residual、统计、RMS apply、量化调度 |
| `rtl/dea8_gcore_activation_store.sv` | 四 bank XHAT/data/scale |
| `rtl/dea8_gcore_xbc.sv` | Projection/G-U 供数及八核握手 |
| `rtl/dea8_gcore_kv_receive.sv` | 八路独立接收端、每路两word holding及提交屏障 |
| `rtl/dea8_gcore_kv_store.sv` | K/V 物理 bank 和地址映射 |
| 预置对象登记 | descriptor握手，不实现prefix payload接收 |
| `rtl/dea8_gcore_kvb.sv` | 共享 K/V 到现有 B2 格式 |
| `rtl/dea8_gcore_reduce_sink.sv` | Reduce 接收、提交与残差流水对接 |

不要直接实例化完整PCore VPU作为GCore运算器。GCore具有独立共享算术资源；默认本地真实rsqrt，外部服务仅为兼容和协议测试模式，不能混写验证范围。

### 3.1 顶层接口清单

valid/ready 均不计入下表数据宽度；多路接口每路独立握手。所谓“广播”是同一逻辑内容服务8个端点，不意味着FPGA中只存在一根无分支物理导线。

| 端口组 | GCore方向 | 数据/描述符宽度 | 状态 |
|---|---|---|---|
| cmd / done | 入 / 出 | 192 / 128 bit | 新增，字段见11.2 |
| context配置/提交 | 入 / 出 | typed context或CSR适配；语义见11.3 | 新增，不套用PCore Job类型 |
| residual import | 入 | BF256 + index12 + last1 + token32 = 301 bit | 新增，完整对象导入 |
| preloaded登记/状态 | 入 / 出 | descriptor96 / status4，另有完成握手 | 登记已存在的X/prefix，无payload |
| xbc[0:7] | 出 | 每路xbc4_t，563 bit | 对接现有PCore |
| gu_prefetch[0:7] | 入 | 每路n6 | 对接现有PCore，ready由GCore返回 |
| kv_header[0:7] | 入 | 每路128 bit | 对接现有PCore |
| kv_data[0:7] | 入 | 每路136 bit + last1 | 对接现有PCore |
| kv_commit[0:7] | 出 | 每路64 bit | 对接现有PCore |
| kvb[0:7] | 出 | 每路b2_t，288 bit | 对接现有PCore |
| reduce_header / data | 入 | 128 / 512 bit，另有last | 对接现有Reduce |
| reduce_commit | 出 | 64 bit | 对接现有Reduce |
| rsqrt_req / response | 出 / 入 | 各110 bit | 外部兼容模式；默认部署使用本地双IP |
| cancel / flush / ack / fault | 双向 | 独立控制及context身份 | 新增，见第13节 |

residual import的index按 `nt*51+row` 从0到3263递增，last只在3263；数据已是BF16，不再次量化。其token为generation+command_id，不是PCore局部VPU token。

本轮没有prefix import端口。`gcore_preloaded_t`为context_id、generation、residual_object/version、prefix_object/version共6×16=96bit；先config，再登记。仅允许无有效对象、无活动任务及无KV引用时登记，且prefix版本必须匹配context；成功后RESID/PREFIX标COMPLETE。RAM装入是调用方的前置保证，当前仿真用层次预置；不是GCore检测或执行了DMA。旧`prefix_import_t`仅保留类型定义，不接到结构顶层。

`rsqrt_req/response`建议共用 `{token32,row0_6,row1_6,mask2,fp32_data64}`，合计110bit。请求按相邻两行发送，最后mask=01；响应带同一token/row/mask，拒绝重复或越界行。允许多个有限在途请求，inv写入按行有效位确认；若实现的credit或算术吞吐不足2行/拍，周期预算必须随之更新。

context的最终线性寄存器地址不是本方案强制项，但其字段、提交与不可变规则是接口合同；控制/CSR负责人可在不改变语义的前提下选择typed总线或CSR窗口。

## 4. 精度合同

### 4.1 残差与平方和

```text
r32[i]    = BF16_to_FP32(RESID[row, nt, i])
s32[i]    = FP32_ADD_RNE(r32[i], reduce_data[i])
r16[i]    = FP32_to_BF16_RNE(s32[i])
stored[i] = BF16_to_FP32(r16[i])
square[i] = FP32_MUL_RNE(stored[i], stored[i])
partial   = SUM16_FIXED_TREE(square[0:15])
sq[row]   = FP32_ADD_RNE(sq[row], partial)  // nt=0..63 顺序
```

- 加法后先写 BF16 精度边界，再从同一 BF16 值求平方；不能用未舍入的 `s32` 代替 `stored`。
- SUM16 固定四层树：相邻两项求和，再逐层配对；每个节点 FP32 RNE。
- 行平方和按 nt 递增累加，不能随核到达顺序或停顿改变顺序。
- 原位更新只允许 Tile 按 nt=0..63、Tile 内 row=0..50；入口先检查，不允许重复 Tile 二次加残差。
- 默认 NaN/Inf 输入或统计溢出进入 FAULT；不把无穷值静默量化成正常数据。

### 4.2 RMS 两遍处理

```text
u[row]     = FP32_ADD_RNE(sq[row] * 2^-10, epsilon)
inv[row]   = RSQRT_FP32(u[row])
norm[i]    = FP32_MUL_RNE(BF16_to_FP32(RESID[row,nt,i]), inv[row])
XHAT[row,nt] = ENCODE_MX_B16(norm[0:15])
```

`epsilon` 是命令参数；建议默认 FP32 `1e-6`，编码 `32'h358637bd`，但导出的模型清单可以覆盖。不能把 epsilon 藏在某个算术子模块中。

gamma 按旧方案离线折入 W_Q/W_K/W_V 或 W_G/W_U。实施前核验打包清单：必须说明已折叠及对应 norm/层；不满足时返回配置错误，不能既省掉硬件 gamma，又使用未折叠权重。

rsqrt 服务合同：FP32 正有限输入，FP32 输出、带 row/context 标签；吞吐目标 2 行/拍，延迟独立参数化。功能参考使用明确的 FP32 舍入口径，实际近似核必须另提供算法版本和位精确模型；不能把 TB 的实数函数当作 FPGA 算术验收。

### 4.3 量化与老 PDF 的差异

当前 PCore TB 的 `quant()` 选取最小可覆盖块最大值的 E，而 PDF 第 4.4 节固定采用 floor 型指数，两者并非总是相同。**本方案拟采用当前 TB 兼容口径，命名为 `Q_COVER127_RNE`，不直接抄旧 PDF 编码器。**

```text
decode(q,E) = signed(q) * 2^(E-133)
amax        = max(abs(norm[0:15]))
E           = min { e in [0,254] : amax <= 127 * 2^(e-133) }
q[i]        = clamp(RNE(norm[i] * 2^(133-E)), -128, 127)
all_zero    -> E=0, q[0:15]=0
```

若集合为空则 E=254 并按显式有限溢出策略饱和；NaN/Inf 走故障，不产生 E=255。正常覆盖范围内不会依靠饱和掩盖选错指数。指数选择用 FP32 指数/尾数比较实现，不要求硬件 log2。

例如amax=1.999时，floor口径会保留E=127并触发上端饱和，当前TB覆盖口径选E=128。该差异足以改变q/scale和后续矩阵结果，因此必须进入量化profile和golden，不能只当作注释差异。

后续如负责人决定采用 PDF 的 floor/对称 ±127 profile，必须同步修改/校准参考模型和数据包格式清单，不能在 GCore 一侧静默切换。本轮只记录该兼容性差异，不修改现有 TB。

### 4.4 packed 顺序

- KV 线路 word 固定 `{scale[7:0], data[127:0]}`，scale 在 bit135:128。
- 当前 `qvec16_t` 声明为 `{data,scale}`，不能把 136-bit RAM word 直接 cast 成该 struct。
- XBC/KVB 用 `.row[r].data/.scale`、`.col[c].data/.scale` 赋值；字节 i 固定 `data[8*i +: 8]`。
- 不假设 packed 数组下标 0 在整条总线最低位；直接使用现有类型，避免 `[0:3]` 带来的序位反转。

## 5. 残差、激活与统计存储

### 5.1 RESID

| 项目 | 方案 |
|---|---|
| 有效尺寸 | 51×1024 BF16 |
| word | 16 BF16，256 bit |
| 深度 | 64×51=3264 word |
| 地址 | `addr = nt*51 + row` |
| 端口 | 同步 1R1W；读/写返回有有效与上下文标签 |
| 容量 | 104448 B = 102 KiB |

只保留一份完整 RESID：R 原位变为 R_mid，再变为 R_next。每个 word 必须先完成旧值读取再写新值；同一 residual object 不允许导入、Norm 和残差更新并发抢端口。

对象状态：`INVALID -> IMPORTING/UPDATING -> COMPLETE`。原位写一旦开始，旧版本不再对外可读；cancel 后标记整个目标 INVALID，不能把已更新和未更新的混合矩阵当成旧 R 恢复。

### 5.2 XHAT + scale

按 `row%4` 分四 bank；每 bank 保存 13 个 row group ×64 feature Tile：

```text
bank = row % 4
addr = nt*13 + floor(row/4)
word = {scale[7:0], data[127:0]}  // 136 bit
```

| 项目 | 数量 |
|---|---:|
| 逻辑有效块 | 51×64=3264 |
| 逻辑容量 | 55488 B = 54.1875 KiB |
| 物理声明 | 4×832×136 bit |
| 物理 payload 容量 | 56576 B = 55.25 KiB |

四 bank 同步读取同一 `(nt,group)`，生成一个 XBC4 beat。最后 group12 只有 row48/49/50 有效，第四 lane 必须输出零，`row_valid=4'b0111`。

不单独分配 X_A 和 X_F 两套 RAM。覆盖为 X_F 前，X_A 的所有 XBC 引用与在途读取必须释放；Norm 写与 XBC 读同一活动版本在第一版互斥。

### 5.3 统计量和防止漏行

`sq[51]`、`inv[51]` 各为 FP32，合计 408 B；另有 row-valid、每行 tile 完成计数和对象版本。`sq` 表示未乘 gamma 的 BF16 残差平方和，与 norm epsilon 无关；`inv` 必须同时匹配 residual version 和 norm epsilon/config。

已有 sq 可用于下一次 RMS 的条件：全部 51 行已经完成 64 次 nt 更新，版本与源 RESID 完全一致。首层若导入过程没有收集 sq，NORM 必须显式执行一次扫描，不能假设 sq 初始化为正确值。

### 5.4 FP32 累加依赖

初始扫描和残差接收统一使用 `nt-major, row-minor` 顺序。相同行的两次 sq 更新至少相隔 51 个向量，避免按 row-major 连续处理时每拍访问同一 FP32 累加器的 RAW 相关。

sq 加法延迟应满足小于 51 个推进机会；若实际流水更长，必须增加 busy/前递或降低发射速率，不能用一次时钟内 FP32 加法的假设绕过依赖。背压时有效、标签、计数和 RAM 写入共同停止或由弹性 FIFO 保持。

## 6. Residual/Norm 算术结构

### 6.1 共享 16-lane 运算资源

采用16个FP32残差加lane、16个共享FP32乘lane、固定SUM16树、MAX16树和同步行统计RAM。34个物理加法器各2DSP、16个物理乘法器各2DSP、两个rsqrt IP各9DSP，合计118；固定树与逐nt求和顺序不变。

- 收 O/Down 时，乘 lane 用于残差值平方。
- RMS Pass B 时，同一组乘 lane 用于 `RESID * inv`。
- 两阶段本来互斥，第一版不为平方和归一化复制两套乘法器。
- Reduce 已经完成八核求和，GCore 不再配置八输入归约树。
- 实际流水级由 FP32 单元时序决定，不复用旧 PDF 的六拍 PRU 作为物理延迟承诺。

### 6.2 Residual 流水与提交

```text
接收 FP512 + row/nt/context，预留完整返回空间
  -> 同步读 RESID BF256
  -> BF16 转 FP32
  -> 16-lane FP32 add
  -> BF16 RNE / RESID 写回
  -> 同一 BF16 值转 FP32、平方、SUM16
  -> row sq FP32 累加
  -> 当前 row 的 residual + statistic commit
```

前端仅保留两个 FP512 word 的弹性容量，不额外复制完整 `[51,16]` 输出 Tile。同步读返回、算术中间结果和标签有各自必要寄存器，不能把这两个 word 当成整条流水全部存储。

`last` 仅是 Tile 输入计数检查。收到 last 后仍须等待该 Tile 的 51 个残差写和 51 个 sq 更新真正完成，之后才产生 Tile commit。

### 6.3 Norm 启动与结束

NORM 的资源前置条件：完整源残差、无在途更新、XHAT 可覆盖、gamma 配置确认、epsilon 为合法正有限值。

执行顺序：`CHECK -> SCAN_SQ(可选) -> RSQRT -> APPLY_QUANT -> DRAIN -> COMPLETE`。第一版等 51 个 inv 都已返回再进入 Pass B，避免引入逐行波前调度；额外等待相对 3264 个块很小。

Pass B 处理 3264 个向量，所有 XHAT data/scale 写入同沿提交。最后一次 RAM 写后才发布目标 XHAT COMPLETE，不以最后一次读请求或 quant 输入发射作为完成。

### 6.4 当前RTL流水与rsqrt边界

`dea8_gcore_vector`按统一推进条件暂停，元数据与数据同停。输入寄存器记为第0沿：残差FP32加法第1..4沿，BF16舍入第5沿，共享乘法第6..8沿；四层SUM16分别在12/16/20/24沿出结果，行sq加法在25..28沿完成。归一化分支使用9..11沿的三级MAX/量化，再延迟到统一输出点。第28个推进间隔后valid，最早下一沿写回；不是无条件28个自然周期。

rsqrt准备先同步读取两行sq，再做除1024和加epsilon，正常II=1。110-bit服务合同保留，末包mask=01、row1=51无效；一个Norm共26包。默认原生IP配置32拍、两通道，输入精确正规化至[1,4)后计算并调整输出指数，避免输入非正规数被FTZ。32包信用覆盖在途与结果，输出用同步RAM FIFO，实际响应还含入队/握手边界。外部兼容模式仍可使用8拍TB服务。误差按1ULP合同单独验收，不修改原有add/mul、XHAT与Residual的严格检查；Fmax仍未签核。

`dea8_gcore_shared_compute`复用向量引擎处理NORM/RESIDUAL，和Reduce sink共同形成作业完成屏障。不能用Norm引擎的最后一次算术完成替代最终Tile commit被接受。

## 7. XBC 供数与八核广播

### 7.1 当前物理格式

`xbc4_t` 的 payload 为 4×136=544 bit；另含 row_valid4、group_idx4、tile_idx6、slot1、reserved4，完整 struct 为 **563 bit**，每核另有 valid/ready。

GCore 用独立运输计数器解释 N/K/重放次数。现有 struct 不含 job_id、epoch 或 N，所以这些信息不能靠单个 XBC beat 自证；必须由 GCore 活动会话和 DEA8 的阶段/flush 协议绑定。

### 7.2 重放顺序与长度

```text
for n in 当前阶段的 NTile:
  for k in 0..63:
    for group in 0..12:
      读取 XHAT[k, group]，广播四行
```

| 会话 | NTile | 逻辑 XBC beat | 行/块内容 |
|---|---:|---:|---|
| K | 2 | 1664 | 同一 X_A |
| V | 2 | 1664 | 同一 X_A |
| Q | 16 | 13312 | 同一 X_A；不按 Q 输出 RoPE 顺序改写输入 feature |
| G-U | 32 | 26624 | 同一 X_F；Gate/Up 的 A 重放已在 PCore 内完成 |

每个 A Tile 需要 13 beat，而 MXU 双行处理需要 26 个 pair。该比例是原始供数余量，不是总线停顿后仍能维持满速的保证。

`tile_idx=k`，`group_idx=group`，第一版 `slot=0`、reserved=0，与当前主 TB 供数相容。数据源选择 X_A/X_F 来自会话配置，不从实时 Job 引脚猜测。

### 7.3 广播不能让快核重复接收

使用一个 holding beat、一个预读 holding 和 8-bit `pending_mask`：

```text
load holding: pending_mask = core_mask
valid[i]    = holding_valid && pending_mask[i]
fire[i]     = valid[i] && ready[i]
pending_new = pending_mask & ~fire
pending_new == 0 -> 当前逻辑 beat 完成，可以推进源计数
```

已接受的核将 valid[i] 拉低，直到进入下一 beat。数据、scale、mask、tag 在任何未接受核处保持不变。禁止简单向全部核持续广播同一个 valid，而只用 AND-ready 决定源计数，这会使快核重复消费。

RAM 返回空间按完整 beat 预约。read issued 不代表读引用释放；holding 被全部目标接受后才减少 outstanding。

### 7.4 G-U 的 n+1 许可

- n=0 在 XBC_RUN 会话启用且八核 G-U Job 接受后可开始。
- 对 n+1，收集八核 `gu_prefetch_valid/gu_prefetch_n`；n 必须一致，握手后记住许可。
- 可以逐核接受许可，但只有所选八核全部授权后才发送该 n 的数据。
- 只允许一个 n 前瞻，不无限累计未来分片，不等当前 n 的 GELU/Z 后处理全部结束才供下一 n。
- 最后一片无需额外许可；任一核错序、重复/不一致许可是协议错误。

## 8. KV 接收、格式与存储

### 8.1 八路独立入口

每路：128-bit header、136-bit data、last、valid/ready；返回 64-bit commit 和 valid/ready。每核只增加两个 word 接收 holding，不复制已有 PCore `64×136` Tile sender。

每核状态：`WAIT_HEADER -> RECEIVE -> DRAIN_WRITE -> SEND_COMMIT -> WAIT_HEADER`。接收 header 时先完成检查，数据只能在后续 RECEIVE 接受；第一版不做 header/data 同沿旁路。

共同检查：source_id 等于物理端口号，rows=51、columns=16、reserved=0、kind/layout 正确，transfer/context 已预绑定，Tile 未提交过，word 个数和 last 精确匹配。

接收有限量化profile时scale不得为255。线路里的signed INT8按完整二补码搬运，不能在接收端把-128擅自改成-127；量化范围由生产者profile约束，接收端不做有损修正。

### 8.2 K 的地址

核 i 的两块 K 列采用 canonical 映射：`16*i`、`128+16*i`。DEA8 必须配置 `rope_pair_base=16*i`；接收端同时检查 header 与配置映射，不按到达顺序拼接。

一个 K Tile 的第 j 个 word：

```text
row = j, j=0..50
feature_tile = header.column_base / 16
word.data[i] = K_suffix[row, header.column_base+i]
word.scale   = 对该 row 的连续16个 feature 共用的 E_K
```

全局 16 个 feature Tile，共 816 个 136-bit word。

### 8.3 V 的地址

核 i 的两块 V 列为 `32*i`、`32*i+16`。V Tile 的 j=0..63：

```text
token_group  = j / 16       // 0..3
local_feature= j % 16
feature      = header.column_base + local_feature
word.data[t] = V_suffix[16*token_group+t, feature], t=0..15
word.scale   = 该 feature 沿连续16个 token 的 E_V
```

最后 token_group3 仅 lane0..2 对应 token48..50，lane3..15 必须为零。当前 PCore sender 已做该清零，GCore 验收仍应检查，不重新生成 scale 或二次量化。全局 V 共 1024 个 word。

### 8.4 物理 bank：直接服务 B2，不建大转置缓冲

K、V 各用 `16个feature_tile × 2个parity` 的逻辑 bank，每个 word 136 bit：

| 对象 | bank | bank 内地址 | B2 一拍读什么 |
|---|---|---|---|
| K | `(feature/16, token%2)` | `token/2` | 相邻两个 key 的16-feature向量 |
| V | `(feature/16, feature%2)` | `token_group*8 + (feature%16)/2` | 相邻两个 feature 的16-token向量 |

每bank使用一片136×440同步RAM，prefix地址0..407，suffix地址408..439；对象/版本仍独立。写路由固定：K核c只写feature Tile c或c+8，V核c只写2c或2c+1；存储入口再次检查归属，不建每bank八选一写数据网。suffix K仍按64 token声明，padding读取强制规范零。

八核同拍写不同 feature_tile bank，符合当前 K/V 分片映射，不增加一个单路串行 gather 总线。读口只在该对象完整后用于 KVB；本轮不支持同一 KV 版本边生产边 Attention。

| 存储 | 物理声明 | payload |
|---|---|---:|
| Prefix K 单窗口 | 32×408×136 bit | 216.75 KiB |
| Prefix V 单窗口 | 32×408×136 bit | 216.75 KiB |
| Suffix K | 32×32×136 bit | 17 KiB |
| Suffix V | 32×32×136 bit | 17 KiB |

bank 是逻辑端口组织，不等于每个 bank 必须独占一块 BRAM。实际 BRAM/URAM 分片、宽深补齐和分布式 RAM 选择要在实现时预算；本文的字节数不是器件占用报告。

### 8.5 prefix 生命周期

首轮固定单 prefix window，先把单层正确性跑通；另保留 `PREFIX_WINDOWS` 参数可扩至2。单窗口不承诺隐藏下一层 prefix 装载，双窗口只有在资源预算和实测带宽允许后开启。

每层 prefix K/V 在十步之间逻辑不变，但单窗口不能把18层全缓存；切换层仍可能需要 HBM 装载。suffix 每层每步重新生成，不能把十步的 suffix 不断追加。

本轮prefix已预置。未来需要换层装载时，再由HBM适配器提供解码后的136-bit word；K/V各13056 word，K为`feature_tile -> token0..815`，V为`feature_tile -> token_group0..50 -> local_feature0..15`。本轮不实现该接收器，也不把现有PCore `hbm_entry`当成prefix DMA。

## 9. KVB：现有 Attention 供数合同

### 9.1 现有 B2 接口

`b2_t` 是两列 `qvec16_t` 加 tile_idx6、group_idx3、epoch4、reserved3，完整宽度 **288 bit**；有效 data/scale 为272 bit。当前每 Tile8个beat，PCore 内再序列化为16次驻留列装载。

现有顶层没有 KVB 的 block/role 显式端口。因此 GCore 必须通过活动 Attention 会话、完整子任务序号和固定供数顺序恢复，不能只观察 tile_idx 回绕判断 K 或 V。

### 9.2 110 子任务顺序

```text
j=0:   QK(0)
j=109: PV(54)
其余奇数j: QK((j+1)/2)
其余偶数j: PV(j/2-1)

QK0,QK1,PV0,QK2,PV1,...,QK54,PV53,PV54
```

每个 j：`t=0..15`，每个 t：`g=0..7`。线路 `tile_idx=(j*16+t)%64`，`group_idx=g`，epoch 使用该会话匹配的 PCore Job epoch，reserved=0。

完整 Attention 为 `110×16×8=14080` 个逻辑 B2 beat，八核使用同一数据。不额外补一个 QK55；PV53→PV54 的空时隙由现有 PCore 调度控制，GCore 可以合法预取，但不能靠定时器越过 ready。

### 9.3 QK 与 PV 的读地址

对 block b，b<51 从 prefix 读；b>=51 从 suffix 的 block `b-51` 读：

| 运算 | t 的含义 | g 对应的两个 B 列 | 每列16个元素 |
|---|---|---|---|
| QK | 归约 feature_tile | key=`16*b+2*g`、`+1` | 对应 key 的 feature16*t..16*t+15 |
| PV | 输出 feature_tile | feature=`16*t+2*g`、`+1` | 当前16个 key位置上的 V |

K 的 scale 随 key、feature_tile 取出；V 的 scale 随 token_group、feature 取出。二者经 typed `.col[]` 封装，不再量化。该 bank 布局让 K 的逻辑转置由读地址实现，不复制整个 K 或设置完整转置 RAM。

padding K 行返回全零块；padding V 元素为零。padding 的 score 仍必须在 PCore VPU 掩码为负无穷，零 K 不能代替 mask。

### 9.4 广播、预读和释放

KVB 使用与 XBC 相同的 pending-mask 广播原则，另外保留两项配对读返回信用。一次读必须预约两个136-bit结果和其共同 tag 的容量；data和scale不得分别推进。

第一版八个 PCore Job 的 epoch 必须统一，head 可不同；不假设各核局部 VPU command token 相同。若后续允许核间 epoch 不同，需要各分支重标 tag，不能直接广播一个 epoch。

`KVB_RUN done` 只表示供数结束，不表示110子任务算术已完成；KV对象释放由 DEA8 在 Attention 全局完成后下达。先保留这一保守引用边界，不用最后发数握手提前复用 KV 窗口。

## 10. Reduce 接收和 Tile commit

### 10.1 接收规则

使用现有单路128-bit header、512-bit data、last、64-bit commit，不新增第二套外发协议。接受 header 前校验已配置的 O/Down 目标、transfer key、source_id=8、rows=51、columns=16、layout=FP_ROWS、reserved=0。

`column_base=16*tile_seq`，tile_seq须为当前预期 nt，范围0..63。Tile内第j个beat对应row=j；恢复地址 `RESID[nt*51+j]`。不从FP32数值或到达间隔猜行号。

### 10.2 接收与更新重叠

Reduce发当前Tile时，GCore一边接收一边残差更新/收集平方和；PCore可以计算后续NTile。GCore不等整份 `[51,1024]` 收齐才开始加残差。

当前Reduce本身已经有 `51×512` 结果RAM，且在发送和等待commit期间不收下一Tile，因此GCore不再加一个完整Tile副本。

Tile输入最后一拍后，等待本Tile residual和sq更新提交数都等于51、所有读返回和写请求结清，再持有 `commit_valid`。commit只允许在最终数据握手之后产生，直到Reduce接受为止。

### 10.3 四种完成不能混为一个

| 事件 | 真正含义 |
|---|---|
| PCore O/Down done | 该核partial已经送给Reduce |
| Reduce out_last握手 | 当前归约Tile已经交给GCore流水 |
| GCore Tile commit | 对应残差及统计已经更新，可释放Reduce结果Tile |
| GCore RESIDUAL_APPLY done | 64个Tile和返回commit全部完成，新残差完整可读 |

若在原位更新中途fault/取消，整份目标残差INVALID；恢复必须重新导入或从合法checkpoint重放，不能让上层继续使用半更新结果。

## 11. 上层命令与上下文

以下为GCore自有接口合同，不应与已有PCore端口混淆。结构顶层已接入命令/context/完成控制、Residual/Norm/XBC、suffix接收、KV存储和KVB。DEA8全局调度不在GCore内部实现。

### 11.1 命令粒度

| opcode | 单次命令覆盖 | 不包含 |
|---|---|---|
| `IMPORT_RESID` | 完整51×1024 BF16对象 | 服务器/PCIe协议 |
| `PREFIX_LOAD`（保留编码） | 当前结构顶层返回INVALID_CMD，无接收实现 | 使用预置登记代替，不假造完成 |
| `NORM` | 指定residual版本到一个完整XHAT版本 | 重复执行每个PCore的Norm |
| `XBC_RUN` | K、V、Q或G-U的一整个供数会话 | 发布PCore七Job |
| `KV_RX` | 本阶段八核K或V的16个Tile接收/commit | 再次RoPE或量化 |
| `KVB_RUN` | 一次Attention的110子任务供数 | Softmax与OACC算术 |
| `RESIDUAL_APPLY` | O或Down的64个归约Tile更新 | 八核求和本身 |

不要让DEA8逐行逐Tile发命令。上层给阶段/对象，GCore内部展开。KV_RX、XBC/KVB为独立服务；Norm、IMPORT、Residual因共享RESID和乘法资源互斥。预置登记在普通服务之外，只描述启动前已经存在的对象。

### 11.2 command/response建议字段

`cmd_valid/ready`与`done_valid/ready`均保持型握手。下面的192/128bit是GCore自有接口建议值，不改现有PCore header：

| `gcore_cmd_t` 字段 | bit | 解释 |
|---|---:|---|
| opcode | 4 | 七类服务 |
| command_id / generation / context_id | 各16 | 命令身份、取消代、绑定配置 |
| src_object / src_version | 各16 | 源对象及版本 |
| dst_object / dst_version | 各16 | 目标对象及版本 |
| pcore_op | 3 | K/V/Q/Attention/O/G-U/Down配置选择 |
| core_mask | 8 | 本轮正常层执行必须8'hff |
| epsilon_fp32 | 32 | NORM使用；其它opcode固定0 |
| flags / reserved | 8 / 25 | 明确允许位，reserved必须0 |

合计192bit。completion建议128bit：opcode4、status4、command_id16、generation16、context_id16、dst_object16、dst_version16、completed_items16、reserved24。

completed_items按opcode解释：NORM/Residual为3264向量块，KV_RX为16个Tile，KVB_RUN为14080个B2 beat，XBC_RUN按第7节计数。它不是FP32标量数。

### 11.3 context配置和transfer绑定

DEA8配置只读活动context，至少包含：

- 51行/1024维模型profile、norm参数与gamma折叠清单版本；
- PCore Job epoch、共享输入data_context、八核固定列映射；
- prefix window、prefix版本/有效位、suffix版本、position_base；
- K、V、O、Down各自的transfer_id/transfer_epoch/destination_id/token_origin；
- 预期输出kind/layout、允许的source_id、当前阶段与源/目标对象；
- quant profile、mask规则和RoPE位置/系数版本。

活动context被服务或持久对象引用时不可改写。第一版只需一个活动层context，不做多层乱序context cache；下一层预取需要另一个window/context时再扩展。

同一context不能给K/V/O/Down复用完全相同的transfer key：现有commit只含transfer_id/epoch、tile_seq、source_id，不含kind/列坐标。应给四阶段分配不同key，防止迟到K commit被新V事务误接受。

### 11.4 对象状态与命令接受

对象最少记录 `(object_id,version,kind,state,refcount)`。RESID、XHAT、prefix、suffix K、suffix V独立有效；不能用一个gcore_done代表所有对象。

- 缺少源对象且当前命令不能自己产生：返回PRECONDITION，不无限等待。
- 源存在、服务资源忙：ready=0保持命令，已有服务继续推进。
- 合法源数据气泡/下游背压：等待，不按固定拍数伪造完成。
- 新命令不清持久数据；只有生产覆盖或显式invalidate改变对象版本。

每个服务最多一个active命令，完成在该服务本地保持；共享completion仲裁器公平返回。因外部done背压而未退休的服务不能被第二条同类命令覆盖。资源占用和对象有效不同：保存有效RESID/XHAT不意味着GCore永远busy。

### 11.5 单层发令建议

1. TB模拟DEA8配置context；登记已预置R/prefix；NORM产生X_A。
2. 先arm `KV_RX(K)`，再发布八核K Job与 `XBC_RUN(K)`。
3. 等K供数/接收及八核Job完成；同样执行V。第一版不让不同opcode核间混跑。
4. 发布八核Q Job与 `XBC_RUN(Q)`；保持X_A直到所有读取排空。
5. 八核Q完成且prefix/suffix均完整后，发布八核Attention Job与 `KVB_RUN`。
6. 先arm `RESIDUAL_APPLY(O)`，再发布八核O Job；归约与残差更新流水进行。
7. 全局R_mid完成后NORM产生X_F；发布八核G-U及 `XBC_RUN(G-U)`。
8. 八核Z完成；先arm `RESIDUAL_APPLY(Down)`，再发布八核Down。
9. R_next完成后结束本层。下一层RMS_a可复用正确版本sq，不重复做两次相同Norm。

arm接收服务只表示目的资源已准备，不要求PCore结果已存在；这样不会出现发送方等ready、GCore又等PCore done的循环等待。

## 12. Mask、RoPE与步边界

### 12.1 Mask和位置

固定物理KV宽880，逻辑prefix816+suffix51；slot867..879永久无效。基线prefix全有效；若以后引入prefix padding，必须传递有效位语义，不能只在GCore把数据置零。

固定pi0 suffix规则建议由VPU mask服务配置：state query只允许suffix state key，action query允许整个51行suffix；所有query按prefix有效位访问prefix。不能误改成逐token三角因果mask。

mask仍在PCore VPU的QK_POST执行。当前顶层没有独立mask request端口，所以本轮只定义上层配置合同：DEA8/VPU集成侧必须在Job启动前绑定同一context。若要增加运行时mask服务，需要另行补正式接口，不宣称现有RTL已经具备。

K/Q RoPE在PCore VPU执行；GCore不重复旋转。当前`rope_sfu_req/out`可接独立系数ROM/服务；是否把ROM物理放在GCore共享侧由接口负责人确定，不属于本轮必要数据路径。

### 12.2 EHU不混进单层

state/action embedding、time MLP、final RMSNorm、action_out_proj、Euler更新是步边界工作，不是这七种层内Job自动覆盖的内容。DEA8最终十步目标仍需为它们制定执行归属和精度合同；本轮保留residual导入/导出与context边界，不创建一个只有名字却宣称完成的EHU。

## 13. 背压、取消与错误

所有通道仅在valid&&ready时计数。数据、scale、header、last、context一起保持；同步RAM读前先预约返回空间，不能靠最终ready临时阻挡已经返回的数据。

本轮不照搬旧PDF的全局pipe_en冻结所有核。GCore各服务、每核端口和Reduce用ready/valid解耦；广播通过pending_mask保证不丢不重。

建议错误分类：INVALID_CMD、PRECONDITION、BAD_CONTEXT、BAD_HEADER、BAD_LENGTH、DUPLICATE_TILE、NUMERIC_FAULT、SOURCE_PROTOCOL。错误必须先拦截再写RAM；无法撤销的在途原位写会让目标对象INVALID。

cancel/clear流程：停止新命令和新RAM读，阻断新数据副作用，撤销本代valid/预约；与DEA8协调PCore、Reduce、HBM/供数源排空；全部ack后才复用transfer key、context或输出holding。

特别注意：XBC没有epoch字段、KVB只有4-bit epoch、commit是独立16-bit transfer_epoch。三者不能视为同一个generation。外部旧数据仍可能到达时，仅清GCore计数器不足以安全重启。

已经向上层提供的completion在背压期间不可改写。迟到非法数据只锁存fault、阻止新命令，不补发相同命令第二份completion。

当前GCore control用`service_fault[6:0]`接收服务异步故障。Norm服务对已退休后的非法rsqrt响应只置protocol_error，不补completion；总控经原cancel/flush/ack流程恢复。不得仅清GCore本地valid就复用仍可能有迟到响应的token。

## 14. 容量与周期预算

### 14.1 固定payload预算

| 单元 | 首轮声明payload |
|---|---:|
| RESID | 102 KiB |
| 四bank XHAT+scale | 55.25 KiB |
| sq+inv | 0.3984375 KiB |
| Prefix K/V，单window | 433.5 KiB |
| Suffix K/V，均按64槽声明 | 34 KiB |
| 合计 | 625.1484375 KiB |
| 若增加第二prefix window | 合计1058.6484375 KiB |

以上未包含接收FIFO、header/commit、valid计数、context、流水寄存器、RoPE ROM、ECC和FPGA RAM宽深补齐。不能拿payload直接宣称U50资源足够；先整合8核PCore/Reduce的真实预算，再决定prefix双窗。

### 14.2 理想服务量，不是仿真结果

| 工作 | 无停顿payload量/时间 |
|---|---|
| 全量sq扫描 | 3264向量，16-lane目标II=1 |
| rsqrt | 51行；2-lane输入至少26拍，另加流水尾部 |
| Norm apply/quant | 3264向量，目标II=1 |
| 每个K接收阶段 | 全局16Tile，816个136-bit word |
| 每个V接收阶段 | 全局16Tile，1024个136-bit word |
| 每个O/Down接收阶段 | 64Tile，3264个512-bit word |
| O单NTile矩阵主体 | 16×26=416个issue机会，不含加载/交接 |
| Down单NTile矩阵主体 | 32×26=832个issue机会，不含加载/交接 |

单个Reduce Tile至少51个data握手，GCore residual 16-lane处理51向量再加尾部。它有机会隐藏在下一NTile矩阵计算中，但仍要计入Reduce收集/树尾/header/commit、核间差异和实际背压，不能只比较51与416。

Norm Pass B必须等整行统计量可用。第一版完整物化后才开始XBC，不声称把3264拍全部隐藏。初始sq扫描可与IMPORT融合，O/Down的sq与写回融合；这些是有条件的重叠，不删除真实依赖。

## 15. 实施与验收顺序

实施以官方Vivado 2022.2、当前`interaction/仿真说明.docx`为运行约定；保持独立新snapshot、涉及DSP时使用真实DSP模型，并检查明确PASS，不以返回码0替代检查。

| 阶段 | 实施内容 | 必须观察的结果 |
|---|---|---|
| A | 公共类型、context、RESID、activation store、广播holding | 精确位宽、bank地址、背压稳定、无重复接收 |
| B | Reduce sink和Residual/Norm，TB先提供rsqrt等未实现服务 | R_mid/R_next BF16、sq/inv、XHAT及scale逐项参考比较 |
| C | 八路K/V接收、bank写入、header/commit | K/V坐标无错位，816/1024 word及32个Tile完全正确 |
| D | prefix预置登记、KVB读地址和110子任务 | 每个B2列、scale、运输tile_idx与独立golden一致，无prefix接收器 |
| E | 一个真实PCore+GCore共享侧，外部Reduce其余贡献由TB提供 | 七Job来源/后处理/输出链不断开，不注入golden Psum |
| F | 八个真实PCore+现有Reduce+GCore单层 | R_next正确，全部真实提交屏障完成，无死锁 |

阶段B可按算术负责人进度先用有限吞吐/有限在途的TB服务，但报告必须区分“GCore控制/存储RTL”与“TB算术”。不能把无限吞吐实数函数测得的周期当成硬件指标。

### 15.1 数值golden

- BF16导入、FP32残差加、BF16 RNE边界、square、SUM16树、nt顺序和量化profile均独立建模。
- Reduce golden严格遵循现有固定8输入树；不以Python串行sum替代FP32树顺序。
- 使用非均匀矩阵数据和各不相同的scale；不能只有全1场景。
- Norm测试包含全零、正负混合、BF16舍入临界、量化阈值、极小/极大有限值及NaN/Inf故障。

### 15.2 必须覆盖的协议场景

1. XBC13个group、尾部0111、四行packed顺序、连续N重放和G-U32片许可。
2. 每次广播8个核不同背压，逐核计数无少收、重收，快核提前接受不覆盖holding。
3. K上下半列映射、V最后token group补零、两种scale轴、prefix/suffix交界。
4. K/V八核乱序到达、重复Tile、错误列基址/source/last/commit，故障前不写非法RAM。
5. Reduce连续64Tile，最后data已到但sq未提交时不能提前commit；首尾Tile都检查。
6. 上层completion背压、commit背压、GU许可错序、cancel时同步读返回在途。
7. 同一reset内完整单层，再运行第二层/第二会话，证明旧valid、sq或transfer不被误用。
8. prefix不足、XHAT版本错误、源对象不存在和gamma标志错误明确拒绝，不以watchdog兜底。

### 15.3 验收边界

阶段F通过才可称“固定51行单层真实共享链路跑通”。若VPU/SFU仍由TB提供，应写“八核矩阵+GCore/Reduce控制存储链路通过，非矩阵算术由TB服务”，不能称完整FPGA模型推理通过。

250MHz、资源、路由、18层十步、服务器接口和整模型量化精度均是后续独立验收。本方案没有提供或冒用这些结果。

## 16. 需要接入前核实的事项

以下不是延期设计的借口，而是数据产物/负责人必须提供的输入：

| 项目 | 当前方案采用 | 接入前动作 |
|---|---|---|
| gamma | 已折叠权重 | 核验权重导出/打包清单 |
| 量化 | 当前TB兼容Q_COVER127_RNE | 与VPU/SFU负责人确认并形成共享golden |
| rsqrt | FP32服务、2行/拍目标 | 确认具体算法、延迟、误差与位精确模型 |
| prefix KV | 已按本项目K/V不同量化轴打包 | 服务器/HBM提供格式、版本和有效位 |
| mask/RoPE | VPU/SFU负责算术，DEA8绑定context | 确认现有接口以外的配置入口 |
| prefix window | 首轮单窗 | 全芯片资源/带宽验证后再决定双窗 |
| 阶段取消 | DEA8协调所有源/目标 | 明确PCore/Reduce/HBM撤销和ack边界 |

当前已搭建A-D的RTL及GCore结构顶层，且已接入真实Reduce；测试范围以README和最新日志为准。下一阶段接入真实PCore，保持其矩阵/控制主链，不提前重构动态M或步边界算子。

## 17. 方案阶段文档核对记录

2026-10-16已做只读源码核对及Python静态/地址模型检查：

- XBC563、KVB288、command192、completion128、导入301/184和rsqrt110位宽算式通过。
- prefix/suffix、RESID、XHAT容量复算通过；Markdown代码围栏和入口链接检查通过。
- 模拟8核K/V接收地址：K816个word、V1024个word无地址重叠；suffix全部4个block的KVB双列读取与接收映射一致。
- 110子任务序列检查通过：QK/PV各覆盖0..54一次，尾部为PV53、PV54，没有QK55。

以上是最初方案阶段的一致性检查，不是RTL仿真、资源估计或时序签核；当时只创建方案及README。后续RTL和本轮真实验证结果以本目录README及当前源码校验对应的reports为准。
