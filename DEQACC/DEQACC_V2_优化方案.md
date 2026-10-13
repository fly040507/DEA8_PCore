# DEQACC V2 优化方案

**版本**：DEQACC V2 优化方案  
**状态**：2026-10-13，scale ingress、中心前递控制和 Full dual-path FPADD 已实现；本轮短套件、独立 V1/V2 同拍对照和完整七 Job 均 PASS。未执行综合/布局布线  
**适用范围**：`DEQACC/` 独立设计  
**明确不修改**：`DEA8/`、V1 历史报告和既有发布快照；V2 直接在 `DEQACC/Pcore` 的原 V1 文件名基础上原地实现，保留旧接口命名以降低迁移风险

## 1. 方案结论

当前实现：一个完整 ACC、32 个逻辑 lane、4 个仅含数据通路的 physical cluster。Ea/Eb/fold 随每笔 MXU response 变化，不是 Job 常量；每笔在 Q0 边界捕获本地 base。ACC 同步读仍由已寄存 Q0 控制驱动，在 Q1 边界返回。Full dual-path FPADD 包含 operand-only LZA、精确一位修正和并行舍入候选，并提供 USE_LZA=0 对照。实测功能范围见 [V2验证结果](Pcore/reports/v2_verification_status.md)；物理时序和真实放置邻近性未签核。

V2 的目标不是继续堆加流水级数，也不是一开始就拆分 ACC，而是在保持 V1 功能和时序接口的前提下，先优化反量化、FPADD、控制扇出和 ACC 外围的长距离通路。

最终采用下面的结构：

1. **32 个逻辑计算 lane**，物理组织为 **4 个 arithmetic cluster**。
2. 每个 arithmetic cluster 包含 **8 个 lane**，对应两行、四列：
   `cluster[c] -> row[0:1] x col[4c:4c+3]`。
3. 保留 **7 个有效流水阶段**：`Q0 -> Q1 -> A0 -> A1 -> A2 -> A3 -> C`。
4. 保留 `II=1`，保留 V1 的 `Delta=4` 前递约束，保持累加顺序和位精确结果不变。
5. scale 使用逐事务分层输入：`rsp` 的 Ea/fold 只送四个 cluster；每个 cluster 生成两份 row_bias，各自供四列形成 base。Qlane 不接 Ea/Eb/fold。
6. Q0/Q1 使用固定宽度、固定级数的直接反量化逻辑，删除动态整数循环和运行时可变深度移位。
7. FP32 加法保留 4 个 A 阶段，但采用“FAR/CLOSE 受控双路径”，只在 CLOSE 路径使用局部 LZA，并保留精确修正。
8. **FACC/OACC 先保持为一个完整的 ACC 存储与控制模块**，不在本版方案中拆成四份，也不复制完整 ACC。
9. 32 lane 算术结果以 4 个 256 bit write-back bundle 返回完整 ACC；ACC 读响应也按 4 个窄 bundle 回送 arithmetic cluster。这个划分只用于接口和布线，不代表物理上存在四个 ACC。
10. 只有在 V2 完成综合和布局布线后，证明完整 ACC 仍是主要 routing 瓶颈，才启动“ACC bank/列分区”备选方案；该备选不属于当前冻结结构。

一句话概括：

> **ACC 先保持完整，算术和控制外围先局部化；流水级数不增加，是否拆 ACC 由后续物理结果决定。**

## 2. V2 对 ACC 的处理原则

本轮不能根据旧 routing 报告直接把 ACC 切成四块。V1 的 routing 证据只能说明“ACC 周围的某些读选择和控制通路有风险”，不能单独证明“拆 ACC”一定是最优方案。V2 先保留一个完整 `acc_store_v2`，对它的外围通路、控制扇出和选择器进行优化：

| 现象 | 已有证据 | 对 V2 的含义 |
|---|---|---|
| 关键路径主要由布线构成 | `routing_R11/timing_3p3.rpt` 中最差路径约 `3.186 ns`，logic 约 `0.079 ns`，route 约 `3.107 ns` | 不能只优化加法器逻辑，必须缩短数据和控制的物理距离 |
| 高扇出/集中选择器问题明显 | 典型路径中出现 `fo=233`，并经过多级 MUX | 先复制小宽度控制、压缩选择编码、缩短 ACC 外围通路，不直接拆数据存储 |
| ACC 存储本身占用较大 | 旧报告中 `acc_store` 约占 `9854 LUT`，含 `1280 LUTRAM` 和 `16 RAMB36` | 不应为了“中心化”再复制一份完整 ACC |

因此当前 V2 不采用以下两种极端方案：

- **全局中心大 MUX**：所有 32 lane 先汇聚到一个超宽数据选择器，再选择 FACC/OACC。
- **32 路完全条带化 ACC**：每个 lane 单独建一套存储和控制，资源、valid、地址和调试复杂度都会明显增加。

当前 V2 的确定结构是：**一个完整 ACC + 四个算术 cluster**。四个 cluster 只负责本地 lane 的 Q0/Q1、FPADD 和前递选择；它们通过 4 个 256 bit 的窄接口与完整 ACC 交互。后续只有在实测证明 ACC 本体仍无法满足时序，才比较“按 bank 或列分区的 ACC”与其他方案。

## 3. 总体数据通路

```text
MXU rsp
  +-- meta/row_valid --> central control spine (one set of keys/source compare)
  |                       +--> Q0/Q1/A0/A3/C valid and use_a3/use_c to clusters
  |                       +--> complete ACC read/write bank/address/row mask
  |
  +-- Psum/Ea/Eb/fold --> four physical clusters (fixed column mapping)
                            cluster0: col 0..3,   rows 0/1
                            cluster1: col 4..7,   rows 0/1
                            cluster2: col 8..11,  rows 0/1
                            cluster3: col 12..15, rows 0/1

Per cluster:
  Ea/fold --> two row_bias --> + local Eb --> eight base/bad_scale
  Psum + base/bad_scale --> Q0/Q1 --> A0 --> A1 --> A2 --> A3 --> local C data
                                 ^                       |         |
                                 +-- local old mux <-----+---------+
                                        ^
                              256-bit ACC old bundle

Four A3 256-bit write bundles -- static concatenation --> complete ACC
Four local C data bundles     -- static concatenation --> external commit data

Only one complete ACC: FACC_A/FACC_B/OACC, bank/parity/address/valid
```

其中：

- 计算数据 `Psum` 不经过全局 32 路大交叉开关。
- arithmetic cluster 只接收本地四列 Psum/Eb、两行 Ea/fold 和中心 valid/forward 选择位，不存元数据或 key pipeline。
- Ea/fold 来自每笔 rsp，base 在本地 Q0 捕获；key 比较由中心唯一一套 spine 完成。
- FACC/OACC 的实际读写统一发生在一个完整 `acc_store_v2` 内。
- 4 个 cluster 的 write-back bundle 进入完整 ACC；不能把它们误认为 4 份独立 FACC/OACC。
- 若上层仍需要逻辑结果总线，commit 由完整 ACC 统一产生，顶层不增加额外的全局数据寄存器级。

## 4. lane、cluster 和列映射

### 4.1 固定映射

```text
cluster_id = col / 4
local_col  = col % 4
lane_id    = row * 4 + local_col
```

每个 cluster 有 8 个逻辑 lane：

```text
lane 0..3 : row 0, col local 0..3
lane 4..7 : row 1, col local 0..3
```

四个 cluster 使用相同数据通路结构，由顶层静态切片确定列归属；它们不是四套逻辑控制 group。key/valid/meta 流水及 RAW/forward 比较只存在于中心 control spine。这样有利于：

- 生成四个相同的算术时序岛；
- 让综合器在 arithmetic cluster 内优化，避免算术逻辑全部跨越到控制中心；
- 用同一套 lane 级参考模型检查四个 cluster 的列置换；
- 在布局布线时观察四个算术区域与完整 ACC 的相对位置；本版不预先承诺四个 ACC 区域。

### 4.2 局部 payload 宽度

每个 cluster 每拍处理 8 个 FP32 结果：

```text
2 rows x 4 columns x 32 bit = 256 bit
```

因此 V2 的 arithmetic-to-ACC write-back 接口建议为：

```text
cluster_commit_data[4][255:0]
central_write_valid
central_write_key
```

四个 bundle 只有数据，写回 valid/bank/address/row_valid 由中心 keys[5] 统一提供；不再复制四套 write-back metadata。每个 cluster 本地保存 C 数据供 Delta=5 前递，C valid/meta 仍来自中心；没有额外全局数据流水级。

## 5. scale 输入和 base 生成

### 5.1 逻辑公式

沿用 V2 草案定义：

```text
base[r][n] = Ea[r] + Eb[n] + fold - 266
```

其中：

- `Ea[r]`：两行的行级 scale 指数；
- `Eb[n]`：16 列的列级 scale 指数；
- `fold`：本笔 MXU response 的有符号折叠/偏置项，不得假设整个 Job 恒定；
- `base`：送入反量化 lane 的有效基指数。

RTL 中 `base` 和 `row_bias` 使用 signed 12 bit，保持原 Q0 内部精度；当前合法 base 范围为 -298 到 273。`bad_scale` 为 Ea/Eb 任一等于 255，仍随本笔事务传递。

### 5.2 物理分发

scale 不采用“所有信号广播给 32 lane”的方式：

1. 每笔 `rsp_valid` 的 Ea[0:1]/fold 扇入四个 physical cluster，不增加 ingress 流水级。
2. 各 cluster 的 `scale_ingress` 组合生成两份 `row_bias[r]=Ea[r]+fold-266`，每份只供本地四列。
3. `Eb[n]` 只送到拥有该列的 cluster，在 cluster 内供两行 lane 使用。
4. `base[r][n]=row_bias[r]+Eb[n]` 和 bad_scale 在 Q0 边界由对应 Qlane 捕获，与 Psum 同拍。
5. Qlane 的事务输入仅为 Psum/base/bad_scale/valid；时钟、reset、clear 是控制端口。Q1 读取 Q0 的 mag/lead/base/sign/zero/bad，不能读取实时 scale。

这使得 Q1 的输入变成固定格式：

```text
{ psum, base, bad_scale, valid }
```

### 5.3 是否需要额外 scale 流水级

**不增加。** Ea/Eb/fold 与每笔 Psum 同属一个 response；base 在 Q0 前组合形成并同拍捕获。不能复用前一笔或按 Job 保存不变 scale。这样仍保持：

```text
Q0 -> Q1 -> A0 -> A1 -> A2 -> A3 -> C
```

只有在综合后证明 Q0 的 base 形成成为新的最差路径时，才允许启用参数化的 8 级 fallback。fallback 必须明确标注为 V2-8S，不能把 8 级设计伪装成 7 级设计。V2 的首选目标仍是 7 级。

## 6. 七级流水定义

### 6.1 阶段总表

| 阶段 | 主要工作 | 数据/控制 | 不能放入的内容 |
|---|---|---|---|
| `Q0` | 捕获 `Psum`，计算绝对值和 leading 信息，形成本地 `base`，发起 ACC 读 | `psum`、`base`、`lead`、`key`、地址、valid | 不放完整反量化和 FP 加法 |
| `Q1` | 固定宽度直接反量化，产生 FP32 deq 候选 | `mag`、`lead`、`base`、guard/sticky | 不放动态循环、不等待可变移位 |
| `A0` | FP 类别解码、大小数选择、key/forward 判断 | old、deq、A3/C key | 不做长距离全局数据选择 |
| `A1` | FAR/CLOSE 两条局部算术路径并行计算 | 对阶、右移粘滞、加减、局部 LZA | 不跨 cluster 汇聚数据 |
| `A2` | 规格化、LZA 修正、舍入候选生成 | FAR/CLOSE candidates | 不写 ACC |
| `A3` | 精确 RNE 选择、指数修正、特殊值/旁路处理 | 最终 FP32 候选 | 不新增全局 mux 级 |
| `C` | 完整 ACC 写回和 commit | 4 个 write-back bundle、key、dest、last | 不再增加全局结果寄存器 |

### 6.2 延迟与吞吐

- 输入在 `Q0` 被接受；在 `C` 完成一次写回/提交。
- 总有效延迟为 7 个阶段，具体端口时序以 `valid_pipe[0:6]` 为准。
- 每拍可接受一个 32-lane 逻辑事务，即 `II=1`。
- 同一 ACC key 的新事务必须遵守 `Delta=4`；V2 不改变该协议。
- 不允许依赖“仿真恰好没有冲突”来隐藏违反 Delta 的输入。控制器和 assertion 都要明确拒绝或标记非法事务。

## 7. Q0/Q1 反量化优化

### 7.1 Q0：固定宽度预处理

Q0 对每个 lane 做：

1. 读取有符号 `Psum`。
2. 处理 `INT_MIN` 的绝对值，不能用有符号取负后再截断。
3. 产生固定宽度 `mag` 和 `lead`。
4. 读取或形成 `base`。
5. Qlane 锁存 zero/bad_scale；中心 control spine 锁存 row_valid/key，不把 tag 或 key 放进 Qlane。
6. 已寄存 Q0 key 驱动完整 ACC 同步读，在 Q1 边界返回。不能改为输入接受沿提前读取。

Q0 不保存任意精度的动态整数，也不使用仿真专用的 `integer` 作为硬件数据通路。

### 7.2 Q1：固定移位、guard/sticky 和 RNE

V2 删除 V1 中动态 `for` 循环式的舍入实现，采用固定级数 barrel/jam 结构：

```text
32/16/8/4/2/1
```

每一级同时维护：

- 截断后的主数据；
- guard bit；
- sticky bit；
- 当前保留结果的最低位。

最终 RNE 条件保持：

```text
round_up = guard && (sticky || lsb)
```

需要单独验证的边界包括：

- `Psum=0`；
- `Psum=INT_MIN`；
- shift 等于 0、1、32 和大于 32；
- normal/subnormal 边界；
- `bad_scale`；
- signed zero；
- 进位导致的指数加一。

建议固定内部宽度：

| 字段 | 建议宽度 | 说明 |
|---|---:|---|
| `mag` | 32 bit | 覆盖 32 bit Psum 的无符号幅值 |
| `lead` | 5 bit | 0 到 31 的前导信息 |
| `base` | signed 12 bit | 当前 RTL 精度，保存 scale 合成后的基指数 |
| `exponent` | signed 10/11 bit | 预留 normal/subnormal 和进位余量 |
| `shift` | 6 bit | 普通 barrel shift；大于 32 单独归类 |
| `sub_shift` | 9 bit | 仅用于 subnormal 分类/边界，不直接驱动大循环 |

这些宽度是 V2 的硬件建议，最终以位精确参考模型和 scale 范围证明共同冻结。

## 8. FP32 加法器优化

### 8.1 目标

FPADD 的目标是降低 routing，而不是牺牲 IEEE 特殊值和 V1 的累加顺序。V2 保持 4 个 A 阶段，不强行改成 6 级，也不把整个加法器复制成两套完全独立的大路径。

### 8.2 受控双路径

每个 lane 的 A 阶段采用以下结构：

```text
A0: 解码、比较指数、判断 FAR/CLOSE
 |
A1: FAR 右移粘滞加法  ||  CLOSE 对阶减法 + 局部 LZA
 |
A2: FAR 规格化        ||  CLOSE LZA 修正 + 规格化
 |
A3: 精确 RNE 选择、指数修正、特殊值和 bypass、打包
```

注意事项：

- FAR 路不经过 CLOSE 的 LZA 逻辑。
- CLOSE 路的 LZA 只能在本 cluster/lane 内计算，不把 32 lane 的 predicate 汇聚到中心模块。
- LZA 结果必须经过精确修正，允许 `-1/0/+1` 的边界校正。
- 若 LZA 的综合面积或布线不如预期，保留 `USE_LZA=0` 参数，切换到精确 leading-zero detector；功能结果必须一致。
- A3 再统一处理 rounding、指数溢出/下溢、NaN、Inf、signed zero 和 `old=0` bypass。

### 8.3 当前 Full dual-path 实现

FAR/CLOSE 在 A1 保存独立 raw result，在 A2 保存独立 rounding candidate；仅在 A3 选择路径。共享 A0 解码和最终特殊值处理，不把完整 ACC 或顶层总线复制两份。

- FAR：right-jam 后加/减，A2 只允许 carry-right、原位或左移一位规格化
- CLOSE：0/1 对阶后按大小顺序执行 X-Y，LZA 与减法器并行，不读取 raw subtract 结果
- LZA：`T=X XOR NOT(Y)`，`Z=NOT(X OR NOT(Y))`；数值位索引下 indicator 为 `{1,T[27:1]} XOR NOT(Z)`。预测 leading position 为 indicator leading position + 1
- 精确修正：预测位置等于真实位置或高一位。A2 先按预测左移，若 bit26 仍为 0 且指数允许，再左移一位；先限制到 exponent-1，保留 gradual underflow
- `USE_LZA=0`：用精确 LZD 产生位移，数值和延迟与 LZA 模式一致；默认 USE_LZA=1
- 并行舍入：A2 独立产生 mantissa+0/mantissa+1 及各自指数，同时产生 RNE predicate；A3 只选已寄存候选，不再串接 `+round_up` 加法器
- wanted/amount 使用固定 5 bit，指数使用 9 bit；FPADD 硬件数据通路无 integer

预测方法参考 [Schmookler/Nowka, Leading Zero Anticipation and Detection](https://www.acsel-lab.com/arithmetic/arith15/papers/ARITH15_Schmookler.pdf)。具体位序、边界和修正规则由本项目 directed/random、LZA/LZD 同拍对照和 V1 参考验证，不能用论文代替当前 RTL 验证。

## 9. 完整 ACC 组织

### 9.1 当前冻结结构

逻辑上仍然提供 V1 语义：

```text
logical_acc = {bank, parity, address, destination}
```

当前不把逻辑 ACC 拆成四个物理 ACC。`FACC/OACC`、bank、parity、valid map 和地址译码仍由一个完整的 `acc_store_v2` 管理。四个 arithmetic cluster 只是把 32 lane 算术路径分成四组，便于接口收发和后续观察布线。

列映射只用于确定每组算术 lane 和 write-back bundle 的位置：

```text
logical column 0..3   -> arithmetic0 bundle[0]
logical column 4..7   -> arithmetic1 bundle[1]
logical column 8..11  -> arithmetic2 bundle[2]
logical column 12..15 -> arithmetic3 bundle[3]
```

这不是 ACC 的物理分割，也不引入四份 valid map。完整 ACC 统一完成：

- bank/parity/address 译码；
- FACC/OACC 的读写；
- valid map 更新；
- A3/C/RAM old 的选择协调；
- 逻辑结果 commit。

### 9.2 存储结构

V2 继续沿用 V1 已验证的 bank/parity 语义和深度参数：

- bank 数、parity 数、地址深度由 package 参数统一定义；
- 只存在一套完整 FACC/OACC 存储；
- 不为 arithmetic cluster 各复制一套 FACC/OACC；
- 32 lane 的读响应和 4 个 write-back bundle 通过明确的边界接口传递；
- 分布式 RAM / BRAM 的具体推断方式由综合结果决定，但 V2 不先改变 ACC 的逻辑所有权。

如果需要在完整 ACC 内部降低扇出，允许对 bank decode、地址寄存器或小宽度选择控制做**控制复制**，但这不等于复制数据 RAM，也不等于把 ACC 拆成四个模块。

### 9.3 读写路径

```text
Q0: acc_read_req from complete ACC
Q1: old_rsp[4 x 256 bit] from complete ACC
A0: central key compare + cluster-local forwarding data select
A1-A3: arithmetic
C: 4 x 256 bit write-back into complete ACC / commit
```

`old` 的来源只可能是：

1. 完整 ACC 读出的旧值；
2. 对应 arithmetic cluster 的 A3 前递值；
3. 当前事务前序的 C 前递值；
4. `old=0` 的明确旁路。

完整 ACC 输出 4 个有固定列归属的 old bundle，避免在 ACC 外部再增加一次 32 lane 的全局重排。中心控制只发送 source select 和 key；A3/C 的数据选择在 arithmetic cluster 内完成，避免把 `mem_reg`、A3、C 和全局结果再次拉到一个中心大 MUX。

### 9.4 当前阶段允许的 ACC 优化

在不改变“完整 ACC”前提下，V2 允许以下优化：

1. 在 ACC 输入端寄存 bank、parity、地址和 destination，减少地址/控制长线。
2. 在 ACC 内按 bank 复制小宽度 decode 和 valid 控制，而不是复制数据 RAM。
3. 把 4 个 256 bit write-back bundle 作为固定列范围的输入，去掉动态全局列重排。
4. 将 RAM old、A3、C、zero 的选择编码成紧凑 source select，再由 arithmetic cluster 本地完成数据 mux。
5. 仅对实测高扇出控制网使用局部复制或 `MAX_FANOUT`。

以下行为留到后续备选阶段：

- 将 FACC/OACC 按列切成四套物理存储；
- 将 valid map 按列复制成四份；
- 让每个 arithmetic cluster 拥有独立 ACC owner。

### 9.5 前递规则

- `Delta=4` 是协议约束，V2 保留。
- A3/C key 与 A0 消费 key 只在中心 control spine 比较一次；每个 parity 各有 use_a3/use_c，四个 cluster 只做本地数据 mux。
- `use_a3`、`use_c` 是紧凑选择位，数据不回流中心控制。
- 同一 key 过早重用时，由 assertion 报错；不让它依赖综合后随机的 RAM 读写优先级。
- 四个 write-back bundle 对同一事务必须在同一 C 周期有效；任何 bundle 缺失都视为事务错误。

## 10. 控制和布线约束

### 10.1 中心 control spine 只传窄信号

中心控制允许传递：

- job / generation / key；
- bank、parity、地址基址；
- Ea/fold 为逐事务 scale，由 ingress 送至四个 cluster，并与对应 Psum 在 Q0 同拍捕获；不是作业常量；
- row_valid、zero、bad_scale、last、dest；
- 每个 cluster 的 `use_a3/use_c` 和 commit valid。

中心控制禁止传递：

- 32 lane 全宽 `Psum` 数据；
- 32 lane 全宽 old data；
- 32 路 one-hot 读选择；
- 一个全局 1024 bit 或更宽的 ACC 数据选择器；
- 由一个中心 LUT 同时驱动全部算术 pipeline 和完整 ACC 的单一高扇出清零信号。

### 10.2 复位和清除

reset/clear 由完整 ACC 清除 valid map，由唯一 control spine 清除事务 valid；cluster 仅清除 Q/FPADD 的本地 valid，不拥有独立 key pipeline、RAW comparator 或 forwarding 控制器。真实扇出与放置效果需后续物理报告验证，不能仅凭层次名断言已解决 routing。

建议先用自然层次实现并测量，再针对真正的高扇出网使用局部 `MAX_FANOUT`。不使用全局 blanket `DONT_TOUCH`，也不把所有层次锁死。

AMD 文档对 `MAX_FANOUT` 的说明也是“通过复制寄存器/驱动器限制局部扇出”，并提醒全局粗暴使用可能带来反效果：  
[AMD UG901: MAX_FANOUT](https://docs.amd.com/r/2022.2-English/ug901-vivado-synthesis/MAX_FANOUT)

### 10.3 层次属性

arithmetic cluster wrapper 可使用软层次约束，便于工具保留四个算术区域：

```systemverilog
(* keep_hierarchy = "soft" *) module deqacc_v2_arith_cluster ...
```

不要在 V2 初版中使用 `keep_hierarchy="yes"`、全局 `DONT_TOUCH` 或未经测量的 Pblock。第一轮应比较：

1. 无物理约束的 V2；
2. 仅 arithmetic cluster 局部层次/扇出约束的 V2；
3. 必要时再对完整 ACC 做局部控制复制；
4. 最后才评估 ACC bank/列分区。

## 11. 推荐模块边界

V2 按下面的边界直接重构原 V1 文件；文件名暂不整体改名，避免现有仿真文件列表和上层调用入口同时发生无关变化。

```text
DEQACC_V1.sv (V2 implementation, compatibility name)
  ├─ deqacc_v1_control.sv             x1 (metadata spine + key views + RAW/forward compare)
  ├─ deqacc_v2_cluster.sv             x4 (physical hierarchy, no logical group controller)
  │    ├─ deqacc_v2_scale_ingress.sv  x1 per cluster
  │    ├─ dequant_lane_v1.sv          x8 per cluster
  │    ├─ fp32_add_lane_v1.sv         x8 per cluster
  │    └─ local old mux + C data register
  └─ acc_slice_v1.sv                 x1 (complete FACC_A/FACC_B/OACC)
```

### 11.1 `deqacc_v1_control`（中心 control spine）

负责：

- 接收 MXU response/meta/rows 和事务 valid，不新增 Job 级 scale 装载协议；
- 锁存逐事务 key/meta/rows；scale 由四个 ingress 局部处理，不当作 Job 常量；
- 生成 `valid_pipe[0:6]`；
- 广播紧凑 key/address/control；
- 汇总四个 arithmetic cluster 的 aligned write-back；
- 检查 Delta、generation、row_valid 和 last。

不负责：

- 传输全宽 Psum/old data；
- 直接实现 FACC/OACC 的 RAM 数据选择；
- 实现 FP32 加法。

### 11.2 `deqacc_v2_scale_ingress`

负责：

- 每个 cluster 接收 Ea[2]/Eb[4]/fold，均来自同一笔 response；
- 组合生成两份 row_bias，形成八份 base/bad_scale；
- 不单独增加 ingress 寄存级，base/bad_scale 由 Qlane 在 Q0 捕获；
- 不存 Job 常量，不复制 key/valid 流水。

### 11.3 `deqacc_v2_cluster`（物理数据通路层次）

负责本 arithmetic cluster 的算术闭环，但不拥有独立 ACC：

- 接收本地四列 Psum；
- 生成两行四列 dequant；
- 完成 8 lane 的 FPADD；
- 接收完整 ACC 返回的 256 bit old bundle；
- 接收中心产生的 A3/C 选择位，完成本 cluster 的局部数据选择，不重复比较 key；
- 输出 256 bit write-back bundle。

### 11.4 `acc_slice_v1`（完整 ACC）

这是 V2 当前唯一的完整 FACC/OACC 存储拥有者，负责：

- 全部 bank/parity/address 的译码；
- 全部 FACC/OACC RAM 的读写；
- valid map 和初始化状态；
- 向四个 arithmetic cluster 返回固定列归属的 old bundle；
- 接收四个 write-back bundle 并完成逻辑 commit。

这里不允许再实例化四份独立 `acc_slice`。若后续 route 仍不满足，再另行评估 bank/列物理分区。

### 11.5 顶层 commit 静态拼接

负责：

- 检查各 lane 的 Q1/A3 valid 与中心 key 一致；四 bundle 不再各自维护写回 metadata；
- 将四个 bundle 送入完整 ACC，或在完整 ACC 完成后分发逻辑结果；
- 保持 V1 外部结果接口的顺序；
- 输出 `result_valid`、`result_meta`、`vpu_valid` 等边带。

不增加全局 data register。若兼容旧接口必须寄存，只能把它作为接口适配层的显式可选延迟，并同步修改 valid/meta，不计入默认 7 级核心流水。

## 12. 端口语义建议

V2 端口名称可以按现有项目风格调整，但语义必须固定。

### 12.1 输入

```text
rsp_valid
rsp.psum[2][16]
rsp.e_stream[2]
rsp.e_stat[16]
rsp.row_valid[2]
rsp.meta.exp_fold
rsp.meta.acc_sel / pair_idx / nt / add_old / last / identity
```

上述字段均属同笔事务。保留 V1 外部接口；没有新增 DEQACC Job 输入，也不从实时上层 Job 状态推断 scale。

### 12.2 arithmetic cluster 内部

```text
cluster_psum[2][4]
cluster_eb[4]
cluster_ea[2]
cluster_base[2][4]
cluster_old[2][4]       // complete ACC 返回的固定列归属 old
cluster_use_a3 / cluster_use_c
cluster_wb_data[255:0]
cluster_wb_valid
cluster_wb_meta
```

### 12.3 输出

```text
result_valid
result_data / result_meta
vpu_valid / vpu_data / vpu_meta
commit_done
error_valid / error_code
```

接口必须使用同一拍的 `valid + data + meta`，不能让 SFU/VPU 或上层控制猜测数据延迟。`row_valid`、`zero`、`bad_scale`、`last` 不能因为 cluster 化而丢失。

## 13. V1 到 V2 的迁移规则

### 13.1 保持不变

- Psum 的解释和 sign-extension；
- dequant 的数学定义；
- FP32 累加顺序；
- special value、RNE、signed zero 语义；
- job/key/destination 的外部协议；
- `II=1` 和 `Delta=4`；
- 7 级有效流水和 commit 对齐语义。

### 13.2 必须重做

- `dequant_lane_v1` 的动态移位/动态循环实现；
- ACC 外部的全局大宽 read-data mux；
- `acc_store` 中未经测量的跨组动态选择器；
- 32 lane old data 在控制中心的二次汇聚；
- 过度集中的 reset/clear 和 valid fanout；
- 依赖 `keep_hierarchy="yes"` 强行保留的旧层级。

### 13.3 不应做的“伪优化”

- 不在本轮拆分完整 ACC 仅为绕开一个 timing path；
- 不把 32 lane 拆成 32 套独立控制器；
- 不为了降低一条路径而打乱 V1 的 FP32 累加顺序；
- 不把新增的 8 级或 9 级设计继续叫 7 级；
- 不用 `$clog2`、`integer` 或动态循环掩盖硬件真实宽度；
- 不以功能仿真通过代替综合/布局布线结论。

## 14. 验证方案

### 14.1 位精确功能验证

V2 必须复用 V1 的 golden/reference vectors，并做 V1/V2 lockstep：

1. 每个 lane 比较 Q0/Q1 的中间字段；
2. 比较 dequant FP32 bit pattern；
3. 比较 A0-A3 的 class/order/rounding 结果；
4. 比较每一次 ACC read source：RAM、A3、C 或 zero bypass；
5. 比较每个 cluster 的 commit data、valid、key 和 destination；
6. 比较四 cluster 拼接后的逻辑结果顺序。

### 14.2 必测覆盖

- `M={1,2,3,7,16,31,51}`；
- 两行尾部只有一行有效；
- 各 bank/parity/address；
- Delta `4/5/6/7`；
- 连续 II=1 输入；
- bubbles、clear、generation 切换；
- Psum 正负、零、INT_MIN、最大值；
- scale 正常、极小、极大、bad_scale；
- FAR、CLOSE、精确相等指数；
- cancellation、全零、subnormal、overflow、underflow、NaN、Inf、signed zero；
- 四个 arithmetic cluster 的列置换和边界列 3/4、7/8、11/12；
- A3/C forwarding 与 RAM old value 的三路选择；
- cluster commit 同拍对齐和 last 传递。

### 14.3 结构性断言

至少增加下面的 assertion：

```text
1. 同一 cluster 的四列映射不越界。
2. 四个 arithmetic cluster 对同一 issue 的 key/generation 一致。
3. 四个 write-back valid 必须同拍，或明确报告缺失 bundle。
4. 输入 valid 经过固定七级后才允许 commit。
5. Delta < 4 的同 key 重用必须报错。
6. row_valid/zero/bad_scale/last 与数据同拍对齐。
7. C 阶段写回的 bank/address/dest 与原 issue 一致。
8. forwarding 只能选择对应 arithmetic cluster 的 A3/C。
9. clear 后完整 ACC 的 valid map 和各 arithmetic cluster 的 pipeline valid 均为空。
10. V2 不存在 ACC 外部的全局 32-lane old-data 大 MUX，也不复制完整 ACC。
```

### 14.4 验证顺序

```text
固定宽度 dequant 单元
  -> 单 lane FPADD
  -> 单 arithmetic cluster 8 lane
  -> 四 arithmetic cluster + complete ACC
  -> V1/V2 lockstep stream
  -> 连续 II=1 与 Delta 测试
  -> OOC synthesis
  -> post-route timing/routing 对比
```

## 15. 综合与布局布线验收指标

下面是 V2 的**验收目标，不是已经完成的结果**：

### 必须满足

- 250 MHz：时钟周期 `4.0 ns`，post-route `WNS >= 0`；
- `II=1`；
- 核心有效流水为 7 级；
- V1/V2 位精确结果一致；
- 不因 arithmetic cluster 化丢失或错配 valid/meta；
- 不出现 ACC 外部的中心 1024 bit 级数据选择器；
- 只存在一套完整 ACC 数据存储。

### 优先目标

- 关键路径 route 占比降到约 75% 或更低；
- `3.3 ns` 约束下获得非负 WNS，目标留有至少 `0.2 ns` 裕量；
- 关键路径的 route delay 低于旧 R11 基线；
- ACC 不拆分、不新增完整存储副本；
- reset/clear 和 key/forward 高扇出不再成为 Top critical path。

route 占比和 WNS 只有在 V2 完成综合、route 后才能填写。不能用 V1 的仿真周期或旧报告代替 V2 的物理结果。

## 16. 实施顺序

### 阶段一：冻结接口和参考模型

- 把 V1 的输入、输出、job/key、scale 语义写成 V2 package；
- 建立 V1/V2 共同的位精确 Python/SystemVerilog reference；
- 固定 cluster 列映射和 commit bundle 格式。

### 阶段二：先完成 lane 级优化

- 重写固定宽度 Q0/Q1；
- 重构四阶段 FPADD；
- 用 V1 向量逐 lane 比较；
- 先不改 ACC 物理布局。

### 阶段三：实现完整 ACC 与 arithmetic cluster 的边界

- 保持一个完整 `acc_store_v2`；
- 将 32 lane 的读响应固定分成 4 个 256 bit old bundle；
- 将四个 arithmetic cluster 的 write-back 接回同一个 ACC；
- 验证 RAM old、A3、C、zero 四种来源；
- 增加列映射、bundle 对齐和完整 ACC commit 断言。

### 阶段四：进行物理导向优化

- 运行无约束 OOC baseline；
- 读取 fanout、route delay、critical nets；
- 只对实际高扇出网做局部复制或 `MAX_FANOUT`；
- 必要时先做 arithmetic cluster 局部 floorplan；不先写死 ACC 分区 Pblock。

### 阶段五：冻结 V2 结果

- 功能仿真通过；
- OOC synthesis 通过；
- post-route 记录 WNS、TNS、route ratio、LUT/LUTRAM/BRAM/FF；
- 将 V2 的真实结果写入独立报告；
- V1 和 `DEA8` 保持原样。

## 17. 风险和处理策略

| 风险 | 处理 |
|---|---|
| Q0 的 base 形成导致新关键路径 | 先做本地小宽度逻辑；只有实测不满足才启用显式 8 级 fallback |
| LZA 反而增加 route | 保留 `USE_LZA` 参数，切换精确 LZD，结果必须一致 |
| cluster commit 拼接造成边界延迟 | 顶层只做静态拼接，valid/meta 同步；不加隐藏寄存器 |
| bank/parity 迁移出错 | 使用地址映射 checker 和全量 lockstep，不依赖肉眼波形 |
| 复制 reset/clear 造成资源上涨 | 只复制 arithmetic cluster 和 ACC bank/decode 边界的控制，避免 lane 级独立控制器 |
| 旧接口需要全宽结果 | 在边界做显式 bundle adapter，核心内部仍保持局部数据流 |
| 4 ns 满足但 3.3 ns 不满足 | 先保证 4 ns 目标，再根据真实 Top path 选择局部优化，不提前增加流水级 |

## 18. 最终冻结描述

DEQACC V2 不是“把 V1 变成更宽的中心总线”，也不是一开始就把 ACC 拆开，而是：

```text
32 logical lanes
4 arithmetic clusters
1 complete ACC
local scale/base
cluster-local forwarding + complete ACC
compact central control
7 stages / II=1 / Delta=4
bit-exact with V1
```

本方案允许后续 RTL 在 `DEQACC/` 内独立重构，允许新增 V2 文件和测试，但本阶段不修改 `DEA8/`。在没有完成 V2 synthesis/post-route 前，任何关于“已经解决 4 ns routing”或“流水可以减少到某一级”的结论都只能作为目标，不能作为验证结果。只有当完整 ACC 在实测中仍然是主要瓶颈，才单独启动 ACC 分区方案评审，不自动并入 V2。

## 参考依据

- `DEQACC/DEQACC_V1_优化方案.md`
- `DEQACC/DEQACC_V1_优化方案.report.md`
- `DEQACC/DEQACC_V2.docx`
- `DEQACC/Pcore/reports/routing_R11/`
- AMD UG901： [MAX_FANOUT](https://docs.amd.com/r/2022.2-English/ug901-vivado-synthesis/MAX_FANOUT)
- LZA 精确修正的经典来源： [Schmookler and Nowka, ARITH 2001](https://doi.org/10.1109/ARITH.2001.930098)
