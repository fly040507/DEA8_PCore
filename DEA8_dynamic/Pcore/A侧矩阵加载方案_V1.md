# DEA8_dynamic Pcore A 侧矩阵加载方案 V1

版本：V1，2026-10-12。状态：方案评审与接口定义，未实现、未仿真、未综合。

依据：本目录 `A侧矩阵加载方案.docx`、用户要求“PBUF 设计与 QOZ 保持一致”，以及 `B侧矩阵加载方案_V1.md` 的 B 侧输入约束。只新增本文，不修改现有 RTL 和 `DEA8`。

## 1. 本版确定什么

| 项目 | V1 决定 |
|---|---|
| 基本矩阵 | `A[M,16] × B[16,16]`，MXU 每拍处理两行 A |
| 行语义 | 数据面统一 compact row `0..M-1`；原始行号由控制面保存 |
| 各 job 的 M | K/V projection 固定 51；Q、Attention、O、G-U、Down 使用动态 M |
| XBC | 每个 accepted beat 3 行，384-bit INT8 + 24-bit scale |
| 本地源 | QOZ/PBUF 都每拍读 3 行，进入同一个 A queue |
| A queue | 3 个顺序 slot；完整收满 M 行才 READY；直接为 MXU 供数 |
| RAM 布局 | A queue、QOZ、PBUF 都按 `compact_row % 3` 分成 3 个 row bank |
| 行记录 | 每行 `{scale[7:0], data[127:0]}`，136 bit 原子读写 |
| PBUF 与 QOZ | 共用同一种存储原语、地址规则和读写协议；容量和生命周期不同 |
| PBUF 两代 | 保留 ping-pong，避免生产 `P(b+1)` 覆盖正在用于 PV 的 `P(b)` |
| A tile 复用 | G/U 相邻计算复用一个 A slot；PV 的各输出 tile 复用同一个 P slot |
| M=0 | 动态 job 空操作成功完成，不收 A、不加载 B、不 issue、不访问结果 RAM |
| 保留的约束 | A/B 身份匹配、完整 tile 下游接收保证、generation 和存储所有权检查 |

**数据面去掉的是 original row ID，不是 local pair index、有效位和目的地址。** 后者仍然要与 Psum、scale 同步，用于本地写回。

## 2. 总体结构和职责

```text
DEA8 job / row-context configuration
                    |
            Pcore Control
       m / profile / source / use-plan
          |                     |
          |                     +--> VPU/SFU command interfaces
          |                          row-map / position / mask context
          v
XBC 3-row --> XBC Adapter -----+
                               |
QOZ: 3 row banks --+           +--> source arbiter --> 3-slot A queue
                   +--> Local Loader                         |
PBUF: 2 generations           |                         Pair Reader
      each 3 row banks -------+                              |
                                                      Q_ACT_REG
                                                     2 x 16 INT8
                                                           |
B-side READY + ACC reservation --> Matrix issue control --> MXU

A scales + active B scales + local tag --> MXU sideband pipeline
```

职责划分：

- DEA8/Gcore：准备正确的完整/压紧激活数据，维护跨核一致的 token 选择，响应 XBC tile replay。
- Pcore Control：锁定 job、M、row profile 和本地存储版本，生成矩阵 micro-operation 顺序。
- XBC Adapter：检查运输身份、beat 顺序和尾拍，不重新挑选 token。
- Local Loader：按 compact 地址读取 QOZ/PBUF，并将同步读返回转换成三行接口。
- A queue：完成 tile 原子提交、短期缓冲和必要的 tile replay。
- Pair Reader：将三 bank 存储转换成连续双行输入，提前发起 RAM 读取。
- Matrix issue control：将 A 逻辑切片、B tile、ACC 目的地址绑定起来；不是看到两个 READY 就启动。
- VPU/SFU：由外部同学实现运算；通过本文规定的事务、存储提交及上下文接口接入。

## 3. compact row 与 job 上下文

### 3.1 行选择只做一次

例：本次选择原始行 `{1,4,7,12,20,31}`，数据源必须按约定顺序发送六行：

```text
local row       0  1  2   3   4   5
original row    1  4  7  12  20  31
```

XBC、A queue、QOZ、PBUF、FACC/OACC 和 DEQACC 使用 local row。返回 Gcore 时携带 profile/context 身份，由约定的接收方恢复原始行位置；不能悄悄把 compact row 当成完整 51 行的原始地址。

同一动态 profile 跨 18 层保持不变，但每个 job 仍引用其 ID/version。Pcore 不自行计数 18 层，也不自行选择去噪步。

### 3.2 控制存储

| 内容 | 建议物理存储 | 说明 |
|---|---|---|
| `row_order[0:50]` | 51×6-bit 寄存器/小 RAM | 原始行索引 0..50，共 306 bit |
| `profile_id/version` | 上下文寄存器 | 防止不同 token 集合但 M 相同的数据混用 |
| `dynamic_m` | 6 bit | 0..51，其余编码非法 |
| `position_base` | 参数化，建议沿用现有 16 bit | RoPE 模型位置基址，不属于 6-bit 行索引 |
| `position_mode` | 小枚举 | 固定 identity、基址加映射；必要时扩展显式位置表 |
| `job_token` | generation + command_id | 与 VPU/SFU 返回、输入流共同识别事务 |

profile 配置提交时检查行数、行号范围和重复行；V1 不支持重复 token。允许非升序映射，但所有生产者、消费者和返回方必须使用同一个顺序。

REUSE 只引用已提交的 profile，不能在引用仍存活时修改它。profile 更新必须等待相关 job、VPU/SFU 返回、buffer 和外发事务解除引用。306 bit 仅是行号表，不包括上述控制字段。

### 3.3 K/V 固定 51 与 M=0

- K/V projection 的 effective M 固定为 51，使用完整源数据和 identity 行顺序。
- 动态 profile 的 M=0 不等于取消 K/V。如果总控仍发布 K/V job，它们仍按 51 行执行。
- Q/Attention/O/G-U/Down 的 M=0：完成 command 握手后返回 `EMPTY/OK`，不等待任何 A/B 数据，也不等待不存在的 VPU输出。
- M=1..51 的尾行用局部 valid mask 处理；M>51 为命令错误。

系统前提：Gcore 必须能提供 K/V 所需的完整 51 行激活，包括未被本步其它动态 job 更新的行。那些行取缓存值、预测值还是重新生成，属于 DEA8/模型优化方案；本 A loader 不定义，也不据此宣称与全量推理等价。

## 4. RoPE、Mask 和输出行位置

原方案的 `position=row_order[i]` 只在位置基址为零且原始行号就是模型位置时成立。V1 采用：

```text
Q_position(i) = position_base + row_order[i]
K_position(i) = position_base + i              // K 固定完整顺序
```

若模型使用不同的位置规则，由总控给显式 position context；不能在 loader 内猜测。RoPE 配对的特征列映射继续属于权重/布局约定，不与 token 行压紧混为一谈。

原始行上下文不只可能用于 RoPE，还可能用于 Attention mask 的 query 行选择和结果回填。V1 要求 VPU mask 命令引用相同 profile 及 key context；这里只定义接口，不擅自把 mask 改成基于 compact row 的三角矩阵。

QOZ/PBUF 内不散写回原始行号。例如 `local row3` 对应 original row12，仍存本地 row3，后续计算继续使用 row3。

## 5. 三行输入格式与握手

### 5.1 行格式

```text
row_entry[135:0] = {scale[7:0], data[127:0]}
data[8*j +: 8]  = 第 j 个有符号 INT8，j=0..15
```

scale 是 8-bit 编码，加载路径只搬运，不自行解释为 signed exponent 或重新量化；其编码、舍入和特殊值沿用矩阵数值接口约定。

第 b 个三行 beat 对应 `row=3*b+lane`。lane0 放 payload 最低 136 bit，lane1 放中间 136 bit，lane2 放最高 136 bit。

内部公共接口：

| 信号 | 宽度 | 用途 |
|---|---:|---|
| `a_wr_data` | 3×128=384 bit | 三行 INT8 |
| `a_wr_scale` | 3×8=24 bit | 三行 scale |
| `a_wr_lane_valid` | 3 bit | Adapter 根据 M 和 beat_idx 生成 |
| `a_wr_valid / a_wr_ready` | 各 1 bit | 整个 beat 原子握手 |
| `a_wr_ctx` | 参数化 sideband | token、slot、tile occurrence、beat_idx |

`fire=valid && ready` 时，data、scale、metadata、mask 一起接收。停顿时全部保持，不能只锁 data 而让 scale/counter 继续变化。

### 5.2 XBC 运输身份

V1 建议每拍携带以下运输字段；宽度参数化：

| 字段 | V1 默认宽度 |
|---|---:|
| generation | 16 |
| command_id | 16 |
| a_occurrence_seq | 16 |
| beat_idx | 5 |
| 合计 | 53 bit |

因此 XBC 默认 payload+transport 为 `408+53=461 bit`，另有 valid/ready 各 1 bit。它不是 AXI/HBM 的 512-bit 链路，不必补成 512 bit。

M、profile、逻辑 k_tile、source、layout 在该 occurrence 的 tile descriptor 中锁存，不用每拍重复。外部不必传 row_valid；Adapter 生成并校验三行尾拍 mask：

```text
lane_valid[lane] = (3*beat_idx + lane < m_snapshot)
expected_beats  = ceil(m_snapshot/3)
```

`a_occurrence_seq` 区分跨 NTile 的同一个 K slice 重放；它不是 `k_tile` 的别名。16-bit 默认需在发出 job 前检查最大 occurrence 数；不能在尚有未排空数据时回绕重用。

局部源不从 RAM 读取这 53 bit，而是在发读请求时捕获同等身份并随返回流水传递。身份不占 payload RAM，不等于不需要身份。

### 5.3 分配 slot

控制器先提交 tile descriptor，成功预留一个 FREE slot 后，才接收该 occurrence 的 beat0。不额外强制插入 header payload 拍；descriptor 可提前握手并排队。

预留保证这一 tile 不因 slot 容量不足而中途拒收，但不强迫数据源每拍 valid。只在 accepted beat 上推进 beat counter。

如果 XBC 本身是多核广播，发送端还须提供全目标接收原子性或独立接收缓冲；不能让快核重复接收、慢核漏拍。该规则与 B/KVB 广播类似，不能靠三 slot 自动解决。

## 6. 3-slot A queue 的物理组织

每个 slot 保存一个最大 `[51,16]` A tile：

```text
单 slot：51 × 136 bit = 6936 bit = 867 B
三个 slot：2601 B，约 2.54 KiB
```

物理上使用三个 row bank，而不是每个 slot 复制一整套读写电路：

```text
ROW_GROUPS = ceil(51/3) = 17
bank       = compact_row % 3
addr       = slot_id * ROW_GROUPS + floor(compact_row/3)

A_ROW_BANK[0..2]：每 bank 51 × 136 bit
```

每个 bank 一个写端口、一个同步读端口，即 1W1R。三行写分别进入三个 bank；双行读访问两个不同 bank。读写可以同时发生在不同 slot，不依赖 RAM 同址读写行为。

slot 状态：

```text
FREE -> FILL -> READY -> READING/REPLAY -> FREE
```

- 分配：严格按 wptr 轮转 0→1→2→0，预留即占用；used_count 包括 FILL/READY/READING。
- 提交：最后一个有效 beat 的 data 和 scale 真正写入后，slot 才 READY。
- 消费：只读 rptr 的 slot；重复使用仍停留在这个 slot，不另分配一个副本。
- 释放：最后一次使用的最后一对数据已被 `Q_ACT_REG` 接收，且该 slot 没有未返回 RAM 读请求，才能 FREE。
- 同周期 reserve/free 正确净更新计数；不要求 RAM 大范围清零。
- 超出 M 的旧行保持无效，不读、不写、不参与后续写回。

slot descriptor 包含 token、profile/version、M、source、内容版本、逻辑 A slice、occurrence、预计复用计划。不复制 row_order，不用 slot_id 充当全局事务身份。

## 7. 三 bank 如何实现双行输出

第 p 个 pair 的本地行是 `2p` 和 `2p+1`：

| p 示例 | 两行 | bank 与行组 |
|---:|---|---|
| 0 | 0,1 | bank0/group0，bank1/group0 |
| 1 | 2,3 | bank2/group0，bank0/group1 |
| 2 | 4,5 | bank1/group1，bank2/group1 |
| 3 | 6,7 | bank0/group2，bank1/group2 |

**两个 bank 的 group 地址不一定相同。** 不能对三个 bank 广播一个 group 地址然后只做输出 MUX，否则 row2/row3 会读错。

Pair Reader 为两个目标 bank 分别产生地址，再通过 lane steering 把读返回放入 row lane0/1。选路、pair_idx、valid 和 slot/token 必须与 RAM 返回延迟一致。

```text
pair_count = ceil(M/2)
lane0_valid = 2*p < M
lane1_valid = 2*p+1 < M
```

M 为奇数时最后一对为 `01`；无效 lane 的 data/scale 输出确定值且 valid=0，不产生 ACC/后处理写入。

## 8. 同步读、Q_ACT_REG 和无额外复制

A queue 就是 MXU 的 A tile 存储，不增加第二个整 tile array。仅保留同步 RAM 输出级及小型 holding/skid 级；`Q_ACT_REG` 是 MXU 唯一的双行激活输入寄存器。

V1 目标 RAM 读到可被 Q_ACT_REG 捕获的延迟为 1 拍，实际若映射增加输出寄存器则使用参数 `A_READ_LATENCY` 调整。

```text
边沿 t：   RAM 接受 pair p 的读请求，捕获 bank steering/context
t 之后：   RAM 输出寄存器出现 pair p
边沿 t+1： Q_ACT_REG 接收 pair p；E_stream/active E_STAT/tag 进入 sideband[0]
边沿 t+2： DSP 对 Q_ACT_REG 的 pair p 做乘法
```

上表将 RAM 的输出寄存器作为读返回级；若另加 skid 必须同时加元数据延迟，不能把两个寄存器层级都叫 Q_ACT_REG。

无 MXU 乘法/拆包/加法树改动时，不因 A 源改造而擅自改变后续 sideband 深度。起点仍是 data 写 Q_ACT_REG 与 scale/tag 写 sideband[0] 的同一边沿。

### 连续 issue 的启动条件

```text
slot READY 且 context/M 匹配
AND 首 pair 的读返回已可用
AND 对应 B bank 已提交，或满足明确定义的最终写入 look-ahead
AND 已预留整个 pair_count 对应的下游接收能力
AND 所有目的地址 RAW/WAW 条件满足
```

tile 开始后连续发射 `pair_count` 拍。不能只检查启动时一拍的 `deq_ready`，也不能在 tile 中途用 A FIFO 停顿掩盖没有预留的下游容量。

### 相邻 tile 不因同步读插泡

在当前 tile 最后一对进入 Q_ACT_REG 的前后，Reader 提前检查下一条 micro-operation，并按读延迟预取下一 tile 的 pair0。读请求流水不需要返回 IDLE；正常情况每拍仍只有一次 pair 读请求。

下一 tile 的读返回可以在 holding 级等待 B/ACC 条件，不允许提前执行乘法。预取会引用下一 slot，slot 释放/clear 必须计入这个引用。

本节保证的是具备就绪条件时不人为加 A 控制气泡。B 缺数据、ACC hazard 等合法等待必须保留。

## 9. QOZ 与 PBUF 使用同一种存储结构

### 9.1 统一存储原语

建议后续抽取参数化 `row3_store`，QOZ 和 PBUF 共用实现：

```text
bank = compact_row % 3
addr = ((storage_set * TILES_PER_SET + physical_tile) * 17)
       + floor(compact_row/3)

每个 bank entry = 136 bit
每个 bank = 一个写端口 + 一个同步读端口
```

差异只在容量参数、逻辑 tile 到物理 tile 的映射、所有权控制，不在 data/scale 格式和读写握手。

| 存储 | storage sets | 每 set 的物理 tile 数 | 每 row bank 深度 | 总 payload |
|---|---:|---:|---:|---:|
| A queue | 1 | 3 | 51 | 2601 B |
| QOZ | 1 | 32 | 544 | 27744 B，约 27.09 KiB |
| PBUF | 2 | 1 | 34 | 1734 B，约 1.69 KiB |

PBUF 的两代可以在同样三个 row bank 的不同地址区，也可在物理上分开实现；V1 不要求为每代额外复制读写端口。读取旧代和写入新代可通过各 bank 的 1R1W 并行。

容量是有效 payload，不是综合后的 BRAM/URAM 数量。地址深度是否补齐、RAM 宽度拼接和端口映射留待 RTL 综合确认，本文不承诺资源利用率。

### 9.2 QOZ 的区域语义

保留当前 Q/O/Z 复用边界，避免这轮额外引入 ZBUF：

| owner | 逻辑形状 | 逻辑 tile | 物理 tile |
|---|---|---|---|
| Q | `[M,256]` | 0..15 | 0..15 |
| O | `[M,256]` | 0..15 | 16..31 |
| Z | `[M,512]` | 0..31 | 0..31 |

V1 采用单 owner 生命周期；Q 完成所有 QK 读取后可释放，再允许 O 获得所有权。O 被 O projection 使用完后释放，Z 才能覆盖整个区域。

保留两组地址并不表示承诺 Q 和 O 任意并发读写；增加并发 owner 必须另定义引用和冲突协议。本版不新增此复杂度。

### 9.3 PBUF 的两代语义

每代保存一个 Attention key block 的 `P[M,16]`，含每 compact row 一个 B16 scale。PBUF 存的是量化 P，不是 FP32 S，也不是完整 `[M,880]` 的注意力概率矩阵。

```text
generation bank 0: P(block b)
generation bank 1: P(block b+1)
```

`block_id % 2` 只用于选候选位置，不能证明数据可用。每代 descriptor 必须匹配 job token、profile、head/context、block_id、M 和内容版本。

两代独立遵循 `FREE -> FILL -> COMMITTED -> IN_USE -> FREE`。消费者用显式 acquire/release，生产者不能仅看到 bank 翻转就覆盖旧代。

V1 保守规定：对应 PV block 的所有矩阵结果完成且不再有读引用后释放该 PBUF 代。提前拷贝到 A queue 后即释放可以后续优化，本版不依赖它。

## 10. QOZ/PBUF 的写入、提交和读取协议

### 10.1 面向 VPU 的统一写接口

存储支持每拍最多三个 row 写 lane，每 bank 最多一写：

```text
wr_valid / wr_ready
wr_token, wr_owner, wr_set, wr_content_version
wr_tile
wr_row[3]          // compact row，每项 6 bit
wr_lane_valid[3]
wr_entry[3]        // 每项 136 bit
```

规则：一个 beat 写同一个逻辑 tile；有效行不得重复，行号必须小于 M，且有效写 lane 的 `row % 3` 必须互异。对任何违反规则的 beat 整体拒收并报告错误，不能只写成功的一部分。

这样 VPU 可以使用一行、两行或三行连续 compact row 的输出，不必被迫实现固定三行计算核心。它产生的更多并行行由负责人在输出适配器分拍，不能假定一个 bank 有多个写端口。

VPU 输出的是量化完成的 INT8+scale。FP32 O/Z 或尚未生成 scale 的行不能直接标记为有效。

### 10.2 防止读到部分结果

每个 storage tile 配置 51-bit written bitmap，成功写入才置位。V1 拒绝同一内容版本下重复写同一行；未写区域不能靠 RAM 旧值补齐。

提交条件：当前 M 对应的有效位全部写入，且 data/scale 写入已完成。尾部无效行不要求清零或写入。

QOZ 建议先采用整 region complete 后开放后继 job 的读取；PBUF 每一代 `[M,16]` 完成后即可供对应 PV。G-U 可边计算边向 QOZ_Z 写入，Down 等 Z region complete 后再启动。

M、profile 或 owner 改变时使旧的 valid/commit 位失效，不清 payload RAM。小 M 完成后再变大 M，新增行必须重新写入，不能把上轮数据当作已完成。

### 10.3 Local Loader 的同步读与返回容量

读取第 k 个特征 tile、第 b 个 row group：

```text
bank0: row 3b，   tile k
bank1: row 3b+1， tile k
bank2: row 3b+2， tile k
```

同一三行请求的有效 bank 由 M 决定。读请求、返回的 context、三行 mask 必须同延迟。

Local Loader 使用返回 FIFO/elastic stage 吸收 queue backpressure。发请求前检查：

```text
response_occupancy + outstanding_reads < response_capacity
```

不能只因本周期 FIFO 没满就继续发不可取消的同步读。默认一拍 RAM 读时建议两条 408-bit 返回 entry，允许连续请求且有一条在途；若增加 RAM 读延迟或停止传播延迟，相应增加 credit 深度。

queue slot 的 READY 发生在最后一拍读返回被 queue 接受之后，不是最后一个 RAM 读请求发出时。

## 11. A tile 复用与七种 job

3-slot queue 不能保存完整 `[M,1024]` 的 64 个切片。跨 NTile 的长距离重放由数据源完成；短距离、同一切片连续使用则保留当前 slot，不重复搬运。

| job/子运算 | A source | 逻辑 A slice | slot 使用计划 |
|---|---|---|---|
| K/V/Q projection | XBC | X 的第 k 个 16 特征切片 | 每个输出 NTile 按 K 顺序重放；通常每 slot 使用 1 次 |
| Attention QK(b) | QOZ_Q | Q 的第 k 个 16 特征切片 | 每 block 读取 16 个 Q tile，分别使用 1 次 |
| Attention PV(b) | PBUF 的 block b | `P(b)[M,16]` | 保留 1 个 A slot，对 16 个 V 输出 tile 重复使用 |
| O projection | QOZ_O | O 的第 k 个 16 特征切片 | 16 个 A tile 按每个输出 NTile 重放 |
| G-U | XBC | X 的第 k 个 16 特征切片 | 同一 slot 先 G(k,n) 再 U(k,n)，共 2 次；下一 n 重放 X |
| Down projection | QOZ_Z | Z 的第 k 个 16 特征切片 | 32 个 A tile 按每个输出 NTile 重放 |

这是本版选定的调度合同，G-U 采用相同 `(k,n)` 的 Gate/Up 相邻发射，与 B 的 G/U 交错顺序对应。若未来改为先全部 Gate 再全部 Up，必须改变 use-plan/重放协议，不能继续使用“同 slot 两次”而乱配 B。

PV 的 A 逻辑 slice 不随 V 的输出 n 改变。每次 replay 把 pair counter 归零，读取同一个 slot，使用新的 B descriptor 和目的地址；不复制 P 到额外大 buffer。

use-plan 不由数据源任意声称，而是由 Pcore 调度器产生。slot 保存 `use_total/uses_remaining` 和内容身份；issue 微操作携带本次 role、n、k、ACC 目的地址，逐次检查。

slot 在最后一次使用完成之前保持占用。其它两个 slot 可预填后继 A，但严格顺序不能绕过当前仍需复用的 slot。

## 12. A/B 匹配不能只比较一个 tile_seq

区分三类编号：

1. `content_key`：这份 A 数值是什么，如 X/Q/O/Z 的 feature slice，或者 P 的 block。
2. `occurrence_seq`：本次从源搬入 A queue 的运输事件编号，重放后可以改变。
3. `micro_op`：这一次矩阵乘法的 B role、k、n、block 和 ACC 目的地址。

launch 对照调度器期望检查：

| 运算 | 关键匹配 |
|---|---|
| Projection | A feature k 对应 B reduction k；B n 对应当前输出 NTile |
| QK | A 是当前 Q feature k；B 是当前 block 的 K 转置 tile，reduction k 相同 |
| PV | A 是 P(block b)；B 是 V(block b, output n)，不能要求 A tile index 等于 n |
| G-U | A feature k 不变；B role 为本次 G 或 U，k/n 与 use-plan 相符 |

同时检查 token、profile、M、head/data context、layout、存储版本。不简单要求 A/B 所有字段逐位相等：例如共享 KV head 与本地 query head 本来就可能不同。

发生身份不匹配时停止 launch 并报错，不尝试扫描 queue 寻找“看起来能配”的 slot，也不通过丢弃队头掩盖错误。

## 13. 性能模型及边界

理想有效 beat 数：

```text
F(M) = ceil(M/3)    // 一个 A tile 的三行接收 beat 数
P(M) = ceil(M/2)    // 一次矩阵微操作的双行 issue 拍数
```

| M | F(M) | P(M) | P-F |
|---:|---:|---:|---:|
| 0 | 0 | 0 | 0 |
| 1 | 1 | 1 | 0 |
| 2 | 1 | 1 | 0 |
| 3 | 1 | 2 | 1 |
| 4 | 2 | 2 | 0 |
| 6 | 2 | 3 | 1 |
| 8 | 3 | 4 | 1 |
| 9 | 3 | 5 | 2 |
| 20 | 7 | 10 | 3 |
| 32 | 11 | 16 | 5 |
| 51 | 17 | 26 | 9 |

对 0..51，`F<=P` 成立，但它只证明无气泡且每拍三行的生产能力不低于每拍两行的消费能力。不能据此断言真实 A 路径永不阻塞。

实际准备时间还包括：source 调度、同步 RAM 首读、返回握手、slot commit、首 pair 预读。前后 tile 的请求若可流水，这些不一定成为每 tile 开销；若 FSM 每次回 IDLE、等待所有返回再启动下一请求，它们就可能变成固定气泡。

保留 B 侧的理想稳态下界用于比较：

```text
HBM B： max(P(M), 4.25) cycles / matrix tile
KVB B： max(P(M), 4.50) cycles / matrix tile
```

成立前提：连续源服务、B loader/bank 切换满足供给、A 已预取、没有 ACC 冲突和额外控制等待。4.25/4.5 是长期平均供给间隔，不是每一个 tile 都可以使用小数拍。

Projection/QK 在小 M 时可能再次访问尚未写回的 ACC 地址。必须等待 DEQACC scoreboard，或者以后另行设计 forwarding。A 方案不能通过承诺“NTile 内绝不许 bubble”取消这项数据依赖。

三 slot 能吸收有限 source jitter，不能隐藏无限断供。首 tile 可预填 1～2 slot，首读和末尾 drain 均计入 job 总时间。M=0 单独走空任务路径，不套用上面的 B 吞吐公式。

## 14. 错误、清空和接口寿命

协议检查至少包括：错误 token/occurrence/beat、M 不一致、profile 不一致、越界行/切片、重复写、提前 commit、覆写在用存储、错误 A/B 组合。

- valid 暂停不是错误；只在 fire 上推进计数。
- 非法包或命令置 sticky error，停止新的 reserve/issue，当前 job 返回失败。
- 已 issue 的乘法无法撤销；失败 job 的结果不得当作有效任务输出继续提交。
- clear 清控制状态和 valid，不要求清所有 RAM。
- clear 后旧的同步 RAM 返回、XBC 和 VPU 返回必须通过 generation 被丢弃或 drain；不能写入新分配的 slot。
- storage release 必须等待 outstanding reads 和返回缓存引用清零。单纯看到生产者 done 或最后一个读请求发出都不够。
- generation/command_id 回绕前必须确认旧事务排空，不能只依赖固定位宽碰巧够用。

## 15. 与原方案及 B 侧 V1 的差异

| 原表述/潜在歧义 | 本版处理 |
|---|---|
| A 永远不是瓶颈 | 限定为理想持续三行服务；单列首读、控制、源停顿和 ACC hazard |
| Q RoPE 直接用 row_order | 增加 position_base/position context，同时保留 mask 和结果回填的映射引用 |
| Slot 最后读请求后即可释放 | 最后一次使用的数据已捕获且无读在途，才释放 |
| BUF 内部不需 tag | payload RAM 不存 tag，但发读时锁存并流水传播 context |
| PBUF 未具体展开 | 与 QOZ 同一三 bank 136-bit 原语，保留两个 block generation |
| 所有 A/B 的 tile_seq 相等 | 分 content、occurrence、micro-op；PV 和 G-U 通过运算专属规则匹配 |
| 每次矩阵都重新装 A | PV 同 slot 用 16 次，G/U 同 slot 用 2 次；跨 NTile 才按需重放 |
| B V1 要 A pair 带 original row_id | 被最新 A 方案取代：只传 compact pair/tag；original row_order 留在控制面 |
| B V1 泛化所有 job 的 M=0 | K/V 固定 51 例外；动态 job M=0 才空完成 |

另有两处 B V1 表述需在后续合并方案时勘误，本轮不覆盖 B 文件：

1. PE 的双行 INT8 乘法共享一个驻留 B。**每个 PE 的每个 bank 存一个 8-bit 权重，两个 bank 共两个权重**，不是每 bank 放两列。4 列/拍是向 64 个 PE 各写一个字节；一个 bank 总共 256 B。
2. HBM 四 tile 的 group 表示调度顺序中的四个物理 B tile，不必是四个连续 NTile；在单个 NTile 的 projection 内通常是四个连续 KTile，G/U 则可能交错 role。

这些澄清不改变“512-bit B 输入、4 拍写满一个 16×16 bank”的目标。

## 16. 后续 RTL 的验证清单

本文只完成方案与公式/地址检查。RTL 实现后必须有以下证据，不能引用旧静态 51 行仿真代替：

| 范围 | 最低验收 |
|---|---|
| M 范围 | 遍历 0..51；覆盖奇数、M=1、51，以及 K/V 固定 51 例外 |
| queue banking | 三 slot 回绕；三行写、双行读并行；row2/row3 跨 group 正确 |
| 同步读 | 可配置读延迟；背压；credit 不溢出；响应 metadata 不串 slot |
| data/scale | 每行数据和 scale 使用不同图案，逐行核对，尾部不产生有效写 |
| compact/profile | 非连续、非升序 row_order；M 相同但 profile 不同必须检测 |
| QOZ | Q/O/Z 映射、切 owner、小 M→大 M 无旧行泄漏、量化写完才 complete |
| PBUF | 生产新代与读取旧代并行；同奇偶 bank 的旧 block 不得误当新 block |
| reuse | GU 两次、PV 十六次的结果分别与参考模型匹配，slot 只在最后使用后释放 |
| A/B 身份 | 错 k/n/role/block、运输 seq 与逻辑 k 不相等但合法的情况 |
| 控制吞吐 | A/B/ACC 均 ready 时 tile 内连续 issue、相邻 slot 无固定 IDLE 泡 |
| error/clear | FILL 中、RAM 读在途、REPLAY 中清空；迟到 XBC/VPU 返回不污染新任务 |
| job 集成 | TB 模拟 Gcore/HBM/KVB/VPU/SFU；七种 job 分别检查输入身份、数值和输出上下文 |

性能报告分别计入 A source 等待、B 等待、ACC hazard、issue、首尾时间，不只记录 issue 利用率。

## 17. 实现顺序

1. 冻结 row profile、XBC transport、tile descriptor 和本地 store 协议。
2. 实现统一三 bank row store；分别以 A queue、QOZ、PBUF 参数配置验证。
3. 实现 Local Loader、Pair Reader 的同步读 credit 和跨 slot 预取。
4. 接入 A/B 匹配、GU/PV replay、DEQACC 预约和动态 M。
5. 最后做七种 job 的集成仿真，再讨论 FPGA 资源及 250 MHz 时序。

本轮不新增 RTL，不做综合，也不修改现有 `DEA8` 或 B 侧文件。数值精度、VPU/SFU 内部实现、全量 K/V 激活如何维持，以及动态推理的模型效果，不由本 A 侧加载方案替代验证。
