# DEQACC V2 优化方案

**版本**：DEQACC V2 优化方案  
**状态**：2026-10-13，已改为第三种方案：独立 scale 网络、同行布局、每行固定 `1→4→16`。本轮 `-Focused` 短套件 PASS，包含 11 种 M 的真实 MXU；未跑七 Job 或独立 V1 lockstep，未执行综合/布局布线  
**适用范围**：`DEQACC/` 独立设计  
**明确不修改**：`DEA8/`、V1 历史报告和既有发布快照；V2 直接在 `DEQACC/Pcore` 的原 V1 文件名基础上原地实现，保留旧接口命名以降低迁移风险

## 1. 方案结论

当前实现：一个完整 ACC、32 个 lane、4 个同行的物理位置组；删除逻辑 cluster wrapper。独立的 scale 网络只计算一次 row_bias0/1，各经四个独立组合分支驱动四列 base 加法器。Ea/Eb/fold 随每笔 MXU response 变化，不是 Job 常量；base 和 Psum 在 Q0 同拍捕获。ACC 同步读仍由已寄存 Q0 控制驱动，在 Q1 边界返回。Full dual-path FPADD 和 USE_LZA=0 对照不变。实测范围见 [V2验证结果](Pcore/reports/v2_verification_status.md)；位置组只是布局意图，物理邻近性和时序未签核。

V2 的目标不是继续堆加流水级数，也不是一开始就拆分 ACC，而是在保持 V1 功能和时序接口的前提下，先优化反量化、FPADD、控制扇出和 ACC 外围的长距离通路。

最终采用下面的结构：

1. **32 个计算 lane**，独立接入顶层；不设逻辑 cluster 模块。
2. 四个同行位置组，每组 8 lane：row0 的 0–7/8–15 列、row1 的 0–7/8–15 列。每组接两个独立的四列 scale 分支；同行也不能改为 `1→2→16`。
3. 保留 **7 个有效流水阶段**：`Q0 -> Q1 -> A0 -> A1 -> A2 -> A3 -> C`。
4. 保留 `II=1`，保留 V1 的 `Delta=4` 前递约束，保持累加顺序和位精确结果不变。
5. scale 使用独立逐事务输入网络：全局两份 row_bias → 每行四个分支 → 每分支四个外部 base 加法器。共 32 个 base 加法器，Qlane 不接 Ea/Eb/fold。
6. Q0/Q1 使用固定宽度、固定级数的直接反量化逻辑，删除动态整数循环和运行时可变深度移位。
7. FP32 加法保留 4 个 A 阶段，但采用“FAR/CLOSE 受控双路径”，只在 CLOSE 路径使用局部 LZA，并保留精确修正。
8. **FACC/OACC 先保持为一个完整的 ACC 存储与控制模块**，不在本版方案中拆成四份，也不复制完整 ACC。
9. ACC 数据仍为 `[2][16][32]`，各 lane 直接按 row/column 静态连线读写；四个位置组各对应 256 bit，但不另设 bundle Buffer、重排网络或独立 ACC。
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

当前结构：**一个完整 ACC + 独立 scale 网络 + 32 lane**。四个同行位置组没有独立存储、接口握手或控制器；各 lane 直接接收 Psum/base 和对应 ACC 数据。只有在实测证明 ACC 本体仍无法满足时序后，才比较 ACC bank/列分区备选。

## 3. 总体数据通路

```text
MXU rsp
  +-- meta/row_valid --> central control spine (one set of keys/source compare)
  |                       +--> Q0/Q1/A0/A3/C valid and per-row use_a3/use_c
  |                       +--> complete ACC read/write bank/address/row mask
  |
  +-- Ea/fold --> two shared row_bias roots
  |                each row: 1 root -> 4 branch buffers -> 4 base adders/branch
  +-- Eb[16] ---------------------------------------------^  |
  |                                          base[2][16] + bad_scale
  +-- Psum[2][16] --> Q0/Q1 --> A0 --> A1 --> A2 --> A3 --> lane C data
                                ^                       |         |
                                +-- lane old mux <------+---------+
                                       ^
                           complete ACC old[2][16]

Physical region0: row0, col0..7    (scale branches0/1)
Physical region1: row0, col8..15   (scale branches2/3)
Physical region2: row1, col0..7    (scale branches0/1)
Physical region3: row1, col8..15   (scale branches2/3)

A3[2][16] -- fixed row/column wires --> complete ACC
C[2][16]  -- fixed row/column wires --> external commit data

Only one complete ACC: FACC_A/FACC_B/OACC, bank/parity/address/valid
```

其中：

- 计算数据 `Psum` 不经过全局 32 路大交叉开关。
- Psum 从 rsp 对应切片直达 Qlane，不经过 scale 网络或 cluster 中转存储。
- Ea/fold 只在独立 ingress 计算两个 row_bias；base 加法器归属 scale 网络，物理上应贴近对应 lane。
- FACC/OACC 的实际读写统一发生在一个完整 `acc_store_v2` 内。
- A3 数据按原 `[2][16]` 顺序接到 ACC；不能把四个位置组误认为四份 FACC/OACC。
- C 数据是各 lane 已有的本地寄存器；中心控制产生 commit valid/meta，顶层不再加全局数据寄存级。

## 4. 同行 lane 和分支映射

### 4.1 固定映射

```text
region_id = row * 2 + col / 8
local_lane = col % 8
scale_branch = col / 4
branch_column = col % 4
```

位置组与分支：

```text
region0 : row0 col0..7  <- row0 branch0/1
region1 : row0 col8..15 <- row0 branch2/3
region2 : row1 col0..7  <- row1 branch0/1
region3 : row1 col8..15 <- row1 branch2/3
```

`physical_regions[g].lanes[n]` 只是 generate 命名，不是 cluster 模块。key/valid/meta 流水和 RAW/forward 比较只有中心一套；前递数据 mux 和 C 数据寄存器留在各 lane。同行布局便于后续靠近对应 parity 的 ACC 数据，但收益须由实际布局布线确认。

### 4.2 局部 payload 宽度

每个位置组每拍处理 8 个 FP32 结果：

```text
1 row x 8 columns x 32 bit = 256 bit
```

实际顶层连线：

```text
a3_values[2][16][32] -> acc_wr_data[2][16][32]
commit_data[2][16][32] -> commit_write.data
keys[5] -> ACC write valid/bank/address/row mask
```

每个位置组等效 256 bit，但没有额外 bundle FIFO、锁存或握手。每 lane 的 C 数据供 Delta=5 前递；C valid/meta 仍来自中心，没有四份 write-back metadata。

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

1. 一份 `scale_ingress` 接收本笔 Ea[2]/Eb[16]/fold，组合计算一次 row_bias0/1。
2. 每行 row_bias 分成四个独立组合分支；每个分支驱动四个外部 base 加法器。两行共八个分支、32 个 base 加法器，始终为 `1→4→16`。
3. 每个位置组有两个相同数值但不同驱动端点的 row_bias 分支。不能将它们合并成每行两个分支。
4. `Eb[n]` 直接到两行对应列的 base 加法器；Psum 直接到 Qlane。base/bad_scale 和 Psum 在 Q0 同拍捕获。
5. Qlane 的事务输入仅为 Psum/base/bad_scale/valid；时钟、reset、clear 是控制端口。Q1 读取 Q0 的 mag/lead/base/sign/zero/bad，不能读取实时 scale。

Qlane 的事务输入格式：

```text
{ psum, base, bad_scale, valid }
```

分支端点用 `LUT1(INIT=2'b10)` 做组合 buffer，只对这些 primitive 加 `DONT_TOUCH`；row_bias root 加 `KEEP`。包括 bad_Ea 的分发，共 `2×4×(12+1)=104` 个显式 LUT1 实例，没有新增寄存器。这个数是 RTL 实例数，不是综合后的利用率。

`bad_Ea=(Ea==255)` 在 root 单独生成并随分支传递；仅从数值 row_bias 不能恢复 bad_Ea。bad_Eb 则按列生成，最终 `bad_scale=bad_Ea||bad_Eb`。本轮不做 Pblock/LOC，组合 buffer 会增加一级逻辑延迟，是否换来更低 route 必须后续实测。

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
| `Q0` | 捕获 `Psum/base/bad_scale`，计算绝对值和 leading 信息；已寄存 key 驱动 ACC 读 | `psum`、`base`、`lead`、`key`、地址、valid | 不放完整反量化和 FP 加法 |
| `Q1` | 固定宽度直接反量化，产生 FP32 deq 候选 | `mag`、`lead`、`base`、guard/sticky | 不放动态循环、不等待可变移位 |
| `A0` | FP 类别解码、大小数选择、key/forward 判断 | old、deq、A3/C key | 不做长距离全局数据选择 |
| `A1` | FAR/CLOSE 两条局部算术路径并行计算 | 对阶、右移粘滞、加减、局部 LZA | 不跨 lane 汇聚数据 |
| `A2` | 规格化、LZA 修正、舍入候选生成 | FAR/CLOSE candidates | 不写 ACC |
| `A3` | 精确 RNE 选择、指数修正、特殊值/旁路处理 | 最终 FP32 候选 | 不新增全局 mux 级 |
| `C` | 完整 ACC 写回和 commit | `[2][16]` 数据、中心 key、dest、last | 不再增加全局结果寄存器 |

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
4. 捕获独立 scale 网络形成的 `base`，不在 Qlane 内重复计算 scale 加法。
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
- CLOSE 路的 LZA 只在本 lane 内计算，不把 32 lane 的 predicate 汇聚到中心模块。
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

当前不把逻辑 ACC 拆成四个物理 ACC。`FACC/OACC`、bank、parity、valid map 和地址译码仍由一个完整 `acc_slice_v1` 管理。四个同行位置组只标识 lane 的局部位置，不改变 ACC 存储组织。

列映射只用于确定每组算术 lane 和 write-back bundle 的位置：

```text
row0 column 0..7  -> physical region0
row0 column 8..15 -> physical region1
row1 column 0..7  -> physical region2
row1 column 8..15 -> physical region3
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
- 不为位置组或 lane 各复制一套 FACC/OACC；
- 32 lane 的 old/A3/C 数据以固定 row/column 连线读写，没有中转 Buffer；
- 分布式 RAM / BRAM 的具体推断方式由综合结果决定，但 V2 不先改变 ACC 的逻辑所有权。

如果需要在完整 ACC 内部降低扇出，允许对 bank decode、地址寄存器或小宽度选择控制做**控制复制**，但这不等于复制数据 RAM，也不等于把 ACC 拆成四个模块。

### 9.3 读写路径

```text
Q0: acc_read_req from complete ACC
Q1: old_rsp[2 x 16 x 32 bit] from complete ACC
A0: central key compare + lane-local forwarding data select
A1-A3: arithmetic
C: 2 x 16 x 32 bit write-back into complete ACC / commit
```

`old` 的来源只可能是：

1. 完整 ACC 读出的旧值；
2. 同 row/column 的 A3 前递值；
3. 当前事务前序的 C 前递值；
4. `old=0` 的明确旁路。

完整 ACC 输出 `[2][16]` 的 old data，每 lane 直接使用对应切片，不增加全局重排。中心控制只发送 source select 和 key；A3/C/RAM/zero 的数据 mux 放在各 lane，不能将全宽数据汇聚到中心 control。

### 9.4 当前阶段允许的 ACC 优化

在不改变“完整 ACC”前提下，V2 允许以下优化：

1. 在 ACC 输入端寄存 bank、parity、地址和 destination，减少地址/控制长线。
2. 在 ACC 内按 bank 复制小宽度 decode 和 valid 控制，而不是复制数据 RAM。
3. 保持 `[2][16]` 的静态写回映射，不做动态全局列重排。
4. 将 RAM old、A3、C、zero 的选择编码成紧凑 source select，再由各 lane 本地完成数据 mux。
5. 仅对实测高扇出控制网使用局部复制或 `MAX_FANOUT`。

以下行为留到后续备选阶段：

- 将 FACC/OACC 按列切成四套物理存储；
- 将 valid map 按列复制成四份；
- 让每个位置组拥有独立 ACC owner。

### 9.5 前递规则

- `Delta=4` 是协议约束，V2 保留。
- A3/C key 与 A0 消费 key 只在中心 control spine 比较一次；每个 parity 各有 use_a3/use_c，32 lane 只做本地数据 mux。
- `use_a3`、`use_c` 是紧凑选择位，数据不回流中心控制。
- 同一 key 过早重用时，由 assertion 报错；不让它依赖综合后随机的 RAM 读写优先级。
- 32 lane 的 Q1/A3 valid 必须与中心 key 同拍；任何 lane 不一致均视为事务错误。

## 10. 控制和布线约束

### 10.1 中心 control spine 只传窄信号

中心控制允许传递：

- job / generation / key；
- bank、parity、地址基址；
- row_valid、zero、bad_scale、last、dest；
- 每个 parity 的 `use_a3/use_c` 和 commit valid。

Ea/Eb/fold 不由控制中心分发，独立 ingress 从本笔 rsp 直接读取；base/bad_scale 与对应 Psum 在 Q0 同拍捕获，不是作业常量。控制中心不保存或重复计算 scale。

中心控制禁止传递：

- 32 lane 全宽 `Psum` 数据；
- 32 lane 全宽 old data；
- 32 路 one-hot 读选择；
- 一个全局 1024 bit 或更宽的 ACC 数据选择器；
- 由一个中心 LUT 同时驱动全部算术 pipeline 和完整 ACC 的单一高扇出清零信号。

### 10.2 复位和清除

reset/clear 由完整 ACC 清除 valid map，由唯一 control spine 清除事务 valid；各 lane 只清除 Q/FPADD 的本地 valid，不拥有独立 key pipeline、RAW comparator 或 forwarding 控制器。scale ingress 是纯组合网络，不需要复位寄存器。真实扇出与放置效果需后续物理报告验证。

建议先用自然层次实现并测量，再针对真正的高扇出网使用局部 `MAX_FANOUT`。不使用全局 blanket `DONT_TOUCH`，也不把所有层次锁死。

AMD 文档对 `MAX_FANOUT` 的说明也是“通过复制寄存器/驱动器限制局部扇出”，并提醒全局粗暴使用可能带来反效果：  
[AMD UG901: MAX_FANOUT](https://docs.amd.com/r/2022.2-English/ug901-vivado-synthesis/MAX_FANOUT)

### 10.3 层次属性

当前不再设 cluster wrapper，四个 `physical_regions` generate 标签保留位置意图；本轮没有 LOC/Pblock。只对八个 scale 分支的组合 buffer 端点使用局部 `DONT_TOUCH`：

```systemverilog
(* DONT_TOUCH="true" *) LUT1 #(.INIT(2'b10)) branch_buffer(...);
```

不要在 V2 初版中使用 `keep_hierarchy="yes"`、全局 `DONT_TOUCH` 或未经测量的 Pblock。第一轮应比较：

1. 无物理约束的 V2；
2. 仅四个同行位置组的局部放置/扇出约束；
3. 必要时再对完整 ACC 做局部控制复制；
4. 最后才评估 ACC bank/列分区。

## 11. 推荐模块边界

V2 按下面的边界直接重构原 V1 文件；文件名暂不整体改名，避免现有仿真文件列表和上层调用入口同时发生无关变化。

```text
DEQACC_V1.sv (V2 implementation, compatibility name)
  ├─ deqacc_v1_control.sv             x1 (metadata spine + key views + RAW/forward compare)
  ├─ deqacc_v2_scale_ingress.sv       x1 (2 roots, 4 branches/row, 32 local base adders)
  ├─ physical_regions[0:3]           (generate labels only, 8 same-row lanes/region)
  │    └─ lanes[0:7]
  │         ├─ dequant_lane_v1.sv    x1 (Psum/base/bad_scale/valid only)
  │         ├─ fp32_add_lane_v1.sv   x1
  │         └─ lane old mux + C data register
  └─ acc_slice_v1.sv                 x1 (complete FACC_A/FACC_B/OACC)
```

### 11.1 `deqacc_v1_control`（中心 control spine）

负责：

- 接收 MXU response/meta/rows 和事务 valid，不新增 Job 级 scale 装载协议；
- 锁存逐事务 key/meta/rows；scale 由独立的一份 ingress 处理，不当作 Job 常量；
- 生成 `valid_pipe[0:6]`；
- 广播紧凑 key/address/control；
- 产生全 lane 共用的 write-back valid/bank/address/row mask；
- 检查 Delta、generation、row_valid 和 last。

不负责：

- 传输全宽 Psum/old data；
- 直接实现 FACC/OACC 的 RAM 数据选择；
- 实现 FP32 加法。

### 11.2 `deqacc_v2_scale_ingress`

负责：

- 一份 ingress 接收 Ea[2]/Eb[16]/fold，均来自同一笔 response；
- 组合计算两个 row_bias root；每行四个独立分支，各驱动四个外部 base 加法器；
- bad_Ea 随相同行的分支分发，bad_Eb 按列使用，共形成 32 个 base/bad_scale；
- 不单独增加 ingress 寄存级，base/bad_scale 由 Qlane 在 Q0 捕获；
- 不存 Job 常量，不复制 key/valid 流水。

### 11.3 `physical_regions`（同行位置标签）

旧 `deqacc_v2_cluster.sv` 已删除。顶层四个 generate 位置标签中的 lane 直接接线：

- 每组接收同一行八列 Psum/base/bad_scale，没有 cluster 中转寄存器；
- 每 lane 完成 Q0/Q1、FPADD 和本地 C 数据寄存；
- 每 lane 直接读取完整 ACC 对应 row/column 的 old data；
- 使用中心产生的本行 A3/C 选择位，不重复比较 key；
- A3 和 C 数据保持原 row/column 映射，不改变 ACC 或外部接口。

### 11.4 `acc_slice_v1`（完整 ACC）

这是 V2 当前唯一的完整 FACC/OACC 存储拥有者，负责：

- 全部 bank/parity/address 的译码；
- 全部 FACC/OACC RAM 的读写；
- valid map 和初始化状态；
- 向 32 lane 返回 `[2][16]` 的 old data；
- 接收静态 `[2][16]` 写回数据；中心控制和 C 数据共同完成逻辑 commit。

这里不允许再实例化四份独立 `acc_slice`。若后续 route 仍不满足，再另行评估 bank/列物理分区。

### 11.5 顶层 commit 静态拼接

负责：

- 检查各 lane 的 Q1/A3 valid 与中心 key 一致；没有四份写回 metadata；
- 将 A3 数据接入完整 ACC，将本地 C 数据接入外部 commit；
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

### 12.2 scale 网络与 lane 内部

```text
row_bias[2][12]                  // two shared roots
row_bias_branch[2][4][12]       // four independent local drivers per row
bad_ea_branch[2][4]
lane_base[2][16][12]
bad_scale[2][16]
Qlane: Psum[32] + base[12] + bad_scale + valid
old_issue / partial_values / a3_values / commit_data[2][16][32]
use_a3[2] / use_c[2]            // central per-row source select
keys[5]                        // central ACC write identity
```

### 12.3 输出

```text
result_valid
result_data / result_meta
vpu_valid / vpu_data / vpu_meta
commit_done
error_valid / error_code
```

接口必须使用同一拍的 `valid + data + meta`，不能让 SFU/VPU 或上层控制猜测数据延迟。`row_valid`、`zero`、`bad_scale`、`last` 不能因为同行重映射而丢失。

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

V2 复用冻结 golden/reference vectors。独立发布版 V1 lockstep 入口保留，但本轮按用户要求只运行 `-Focused`：单 lane 算术、32-lane stream、动态 M 和三项 RAW 负例；不运行七 Job 或独立 V1 lockstep。之前七 Job/lockstep 的 PASS 不证明当前同行源码。

完整验收时可额外运行 V1/V2 lockstep：

1. 每个 lane 比较 Q0/Q1 的中间字段；
2. 比较 dequant FP32 bit pattern；
3. 比较 A0-A3 的 class/order/rounding 结果；
4. 比较每一次 ACC read source：RAM、A3、C 或 zero bypass；
5. 比较各 row/column 的 commit data、valid、key 和 destination；
6. 检查同行布局后的逻辑结果顺序不变。

### 14.2 必测覆盖

- `M={1,2,3,4,7,8,16,31,32,50,51}`；真实 MXU、16 个 K Tile，逐行/逐列/逐 Tile 变化的 scale；
- 两行尾部只有一行有效；
- 各 bank/parity/address；
- Delta `4/5/6/7`；
- 连续 II=1 输入；
- bubbles、clear、generation 切换；
- Psum 正负、零、INT_MIN、最大值；
- scale 正常、极小、极大、bad_scale；
- FAR、CLOSE、精确相等指数；
- cancellation、全零、subnormal、overflow、underflow、NaN、Inf、signed zero；
- 八个 scale 分支的列映射与四个同行位置组，边界列 3/4、7/8、11/12；
- A3/C forwarding 与 RAM old value 的三路选择；
- 各 lane commit 同拍对齐和 last 传递；最终 ACC 包含无效/未使用行的全空间检查。

### 14.3 结构性断言

至少增加下面的 assertion：

```text
1. 每个 scale 分支对应四列，每个位置组对应同行八列，映射不越界。
2. 八个 row_bias 分支与本笔 Ea/fold 一致，bad_Ea 不丢失。
3. 32 lane 的 Q1/A3 valid 与中心 key 同拍。
4. 输入 valid 经过固定七级后才允许 commit。
5. Delta < 4 的同 key 重用必须报错。
6. row_valid/zero/bad_scale/last 与数据同拍对齐。
7. C 阶段写回的 bank/address/dest 与原 issue 一致。
8. forwarding 只能选择同 row/column 的 A3/C。
9. clear 后完整 ACC 的 valid map 和各 lane 的 pipeline valid 均为空。
10. V2 不存在 ACC 外部的全局 32-lane old-data 大 MUX，也不复制完整 ACC。
```

### 14.4 验证顺序

```text
固定宽度 dequant 单元
  -> 单 lane FPADD
  -> 32 lane + complete ACC + scale branch checks
  -> dynamic M with real MXU
  -> 连续 II=1 与 Delta 测试
  -> optional V1/V2 lockstep / seven jobs
  -> separately authorized OOC synthesis
  -> post-route timing/routing 对比
```

## 15. 综合与布局布线验收指标

下面是 V2 的**验收目标，不是已经完成的结果**：

### 必须满足

- 250 MHz：时钟周期 `4.0 ns`，post-route `WNS >= 0`；
- `II=1`；
- 核心有效流水为 7 级；
- V1/V2 位精确结果一致；
- 不因同行重映射丢失或错配 valid/meta；
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
- 固定同行位置组、每行四个 scale 分支和原 `[2][16]` 数据映射。

### 阶段二：先完成 lane 级优化

- 重写固定宽度 Q0/Q1；
- 重构四阶段 FPADD；
- 用 V1 向量逐 lane 比较；
- 先不改 ACC 物理布局。

### 阶段三：实现独立 scale 网络和同行 lane

- 保持一个完整 `acc_store_v2`；
- 只计算一次 row_bias0/1，落实每行 `1→4→16` 的组合分支和外部 base 加法器；
- 删除逻辑 cluster，32 lane 直接接 Psum/base 和原 ACC row/column 数据；
- 验证 RAM old、A3、C、zero 四种来源；
- 增加列映射、bundle 对齐和完整 ACC commit 断言。

### 阶段四：进行物理导向优化

- 运行无约束 OOC baseline；
- 读取 fanout、route delay、critical nets；
- 只对实际高扇出网做局部复制或 `MAX_FANOUT`；
- 必要时先做四个同行位置组与对应 scale 分支的局部 floorplan；不先写死 ACC 分区 Pblock。

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
| 同行重映射造成数据错位 | 保持原 `[2][16]` 顺序，逐 lane 和最终 ACC 检查；不加隐藏寄存器 |
| bank/parity 迁移出错 | 使用地址映射 checker 和全量 lockstep，不依赖肉眼波形 |
| 复制 reset/clear 造成资源上涨 | 仅针对实测高扇出边界处理，避免 lane 级独立控制器 |
| 分支被优化合并或 buffer 增加逻辑延迟 | 仅保护显式 buffer primitive；后续检查实际驱动/放置/route，不能用仿真断言物理收益 |
| 旧接口需要全宽结果 | 在边界做显式 bundle adapter，核心内部仍保持局部数据流 |
| 4 ns 满足但 3.3 ns 不满足 | 先保证 4 ns 目标，再根据真实 Top path 选择局部优化，不提前增加流水级 |

## 18. 最终冻结描述

DEQACC V2 不是“把 V1 变成更宽的中心总线”，也不是一开始就把 ACC 拆开，而是：

```text
32 logical lanes
4 same-row physical regions, no logical cluster wrapper
1 complete ACC
2 shared row-bias roots -> 4 branches/row -> 16 local base adders/row
lane-local forwarding + complete ACC
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
- AMD UG912： [DONT_TOUCH](https://docs.amd.com/r/2022.2-English/ug912-vivado-properties/DONT_TOUCH)，仅用于保护局部分支端点，不是时序保证
- LZA 精确修正的经典来源： [Schmookler and Nowka, ARITH 2001](https://doi.org/10.1109/ARITH.2001.930098)

