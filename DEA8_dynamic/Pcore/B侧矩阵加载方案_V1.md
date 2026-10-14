# DEA8_dynamic Pcore：B 侧矩阵加载方案 V1

当前实施说明：本文保留512-bit传输、packet、8-slot queue和B4 loader布局；行语义、七级DEQACC Δ4前递及公共context按 [PCore整体重构方案V1](C:/Users/fly04/Desktop/VLA/DEA8_dynamic/Pcore/PCore整体重构方案_V1.md) 执行。下文早期original row_id、11级无前递及独立layer计数字段建议不进入当前数据面；HBM四Tile group是四个连续B调度Tile，不限定四个连续NTile。Attention性能边界见 [Attention调度V1](C:/Users/fly04/Desktop/VLA/DEA8_dynamic/Pcore/Attention调度方案_V1.md)。

> 状态：优化方案，尚未进入 RTL 实现。  
> 适用范围：动态动作 token 长度下，Pcore 的 B 侧权重/缓存加载、排队、双 bank 装载和向 MXU 发射。  
> 本文不修改 `DEA8`，也不代表已经完成 Vivado 仿真或综合。

## 1. V1 结论

本版保留“**B 驻留、A 广播**”和 16×16 MXU 的基本原则，重新定义 B 侧输入与装载链路：

```text
HBM PC0 256 bit ─┐
                  ├─ HBM 512-bit pair adapter ─┐
HBM PC1 256 bit ─┘                              │
                                                 ├─ 8-slot B tile queue
KVB 512 bit broadcast ──────────────────────────┘
                                                        │
                                      B4 loader / scale loader
                                                        │
                                      weight bank A/B in 256 PE
                                                        │
                                           MXU B operand side
```

核心决定：

1. 每个 Pcore 的 HBM 逻辑入口为 512 bit，但物理上仍是两路独立的 256-bit PC。两路不要求同周期返回；只有配对成功的 beat 才能组成一个逻辑 beat。
2. KVB 使用一条 512-bit 广播数据路径。广播接收端先对一个 packet 做原子预留，再按 packet 内顺序写入本地 queue。
3. B tile 为 16×16 INT8 数据加 16 个 8-bit scale，共 272 B。数据和 scale 在 queue 中分开存储，但共用 tile descriptor，不能只靠地址碰巧对应。
4. queue 保留 8 个 tile slot；B loader 每个周期向权重 bank 写入 4 列，即 64 个 INT8 权重，连续 4 个 loader 周期完成一个 tile 的数据写入。scale 不进入 PE，在 bank 外的 `E_STAT` 存储中单独装载。
5. 权重 bank 采用双 bank。新 tile 只能写入已经释放的 bank；当前计算仍在使用的 bank 不允许重写。最后一次乘法完成后才释放旧 bank。
6. 对动态行数 `M`，B 侧 tile 的格式和加载周期不随 M 改变，A 侧只发射有效行。`M=0` 是合法 no-op，必须跳过 issue、加载和结果提交，不能把它解释成 51 行。
7. B 侧带宽足够只说明“供数可能满足”，不能自动证明 MXU 无气泡。Projection、QK、PV、G-U 等任务还必须满足 DEQACC 的地址复用间隔、A/ACC ready 和 bank 切换条件。

## 2. 适用矩阵和术语

### 2.1 B tile

每个 tile 的逻辑矩阵为：

```text
B[k][n]，k = 0..15，n = 0..15
```

存储采用列打包，loader 每次取 4 列：

```text
beat j 的有效内容 = B[0..15][4j .. 4j+3]
                 = 64 个 INT8
                 = 512 bit
```

对应的 tile scale：

```text
E_STAT[0..15] = 16 个 8-bit scale = 128 bit
```

scale 的语义必须在 job descriptor 中声明。V1 默认它对应 B tile 的 16 个输出列；如果某个 K/V 量化格式的 scale 是沿 reduction 维度或按别的分组生成，不能通过简单转置假定它仍然对应这 16 列，必须由上游按照声明的 layout 提供，或者在进入 Pcore 前完成重排/重标定。

### 2.2 动态 A 行数

B tile 仍然是固定 16×16，动态的是当前 job 的有效 A 行集合：

```text
M       = 本次 job 的有效行数，0 <= M <= 51
row_id  = 控制中心保存的全局动作 token 行号，不要求连续
```

`row_id` 在一个 18 层任务上下文内保持不变。B loader 不需要知道每一行的 `row_id`，但 B tile descriptor 必须携带 job/epoch/矩阵位置，以防旧 tile 被错误接收。

### 2.3 外部 512 bit 与内部 512 bit

这里有两种不同的 512 bit，不能混为一谈：

| 位置 | 物理形式 | 逻辑用途 |
|---|---:|---|
| HBM 输入 | 2 路独立 256 bit | 通过 adapter 配对成每周期一个逻辑 512 bit |
| KVB 输入 | 1 路 512 bit | 8 个 Pcore 共享广播，按 packet 同步接收 |
| queue 到 loader | 1 路 512 bit | 每周期取一个 4 列数据 beat |
| loader 到 PE bank | 256 个 PE 的本地写端 | 每拍选中 64 个 PE，每个 PE 向目标 bank 写一个 INT8 权重 |

HBM 的两路 PC 不是两个可随意拼接的“半 tile 缓存”。它们只是同一逻辑输入的两个物理返回通道；配对后才进入统一的 tile queue。

## 3. HBM 两个 PC 的接收与合成

### 3.1 固定 striping

V1 采用固定半宽拼接：

```text
logical_beat[255:0]   = PC0_beat[255:0]
logical_beat[511:256] = PC1_beat[255:0]
```

PC0/PC1 也可以反过来映射，但必须在 adapter 中固定，不能按响应到达先后动态交换。地址映射、burst 拆分和半宽位置由 HBM adapter 处理，Pcore 内部只看到逻辑 512-bit beat。

### 3.2 配对状态

两个 PC 各自使用小型 elastic FIFO，至少保存以下信息：

| 字段 | 作用 |
|---|---|
| `generation` | 区分 reset/flush 后的事务代次 |
| `job_id` | 区分外部总控发布的矩阵任务 |
| `segment_seq` | 区分同一任务的 HBM segment |
| `beat_idx` | segment 内 beat 序号 |
| `payload[255:0]` | 半宽数据 |
| `resp_err` | HBM 返回错误 |
| `last` | AXI 返回边界信息，仅作协议检查，不替代 tile/group 边界 |

只有两边队头的身份完全一致时，才允许执行：

```text
pc0_pop = pc1_pop = pair_ready
logical_payload = {pc1_payload, pc0_payload}
```

两边不要求同周期到达。若某一路暂时没有数据，另一侧必须停留在 FIFO 中，不能和别的 `beat_idx` 拼接。

### 3.3 错误和边界

- `last` 不能直接当作 group 的最后一个 beat；AXI burst 可能因为 4 KiB 边界而被拆开。
- adapter 初期建议每个 PC 使用有序 ID，减少乱序配对的状态量；后续需要多 outstanding 时，仍然必须按 `generation + job_id + segment_seq + beat_idx` 配对。
- 两个 PC 的错误、超时、序号不一致、generation 不一致，都置位 sticky `protocol_error`。
- 错误发生后停止向 B queue 写入和向 MXU 发射，当前 job 的结果不再提交；清空或 reset 后才能复用这些 slot。
- 如果系统要求一个 group 的 17 个逻辑 beat 在外部连续到达，必须由 HBM adapter 额外提供足够 staging；仅有两个 256-bit AXI 口并不能证明这一点。V1 允许 `valid` 气泡，queue 必须能承受 PC skew。

### 3.4 HBM 数据格式

V1 采用按 4 tile 分组的逻辑格式。一个 group 包含 4 个连续 N tile：

```text
beat 0       : tile0..tile3 的 scale，共 4 × 128 bit = 512 bit
beat 1..4    : tile0 data，4 个 512-bit beat
beat 5..8    : tile1 data
beat 9..12   : tile2 data
beat 13..16  : tile3 data
```

因此：

```text
4 tiles = 17 个逻辑 512-bit beat
平均 = 4.25 beat/tile
```

scale beat 中每个 tile 占固定 128 bit，具体 bit mapping 固定为：

```text
scale_beat[127:0]   = tile0_scale[15:0]
scale_beat[255:128] = tile1_scale[15:0]
scale_beat[383:256] = tile2_scale[15:0]
scale_beat[511:384] = tile3_scale[15:0]
```

不能因为数据 tile 先到，就把 scale 直接写入“当前空闲 scale 地址”。必须根据 group counter 和 tile index 写入同一 slot 的 scale 区域。

segment header 只出现一次，不重复占用每个 group 的数据 beat。header 至少描述：`magic/version`、`generation`、`job_id`、`core_id`、`layer`、`op`、`role`、`base_n`、`tile_count`、`group_count`、`segment_seq`、`layout` 和 `flags`。保留字段全部置零，V1 不依赖 CRC 作为地址正确性的证明。

## 4. KVB 512 bit 广播接收

### 4.1 packet 形式

KVB 使用一条 512-bit 广播路径，每个 packet 传 2 个 B tile：

```text
beat 0       : tile0 scale 256 bit + packet identity 256 bit
beat 1..4    : tile0 data
beat 5..8    : tile1 data
```

其中 tile scale 仍然是 16×8 bit。两 tile 的 scale 可以各占 128 bit，剩余 256 bit 放 packet identity 和保留字段。

```text
2 tiles = 9 个 512-bit beat
平均 = 4.5 beat/tile
```

KVB 的 `head_id` 表示共享的 KV head/context，不表示每个 Pcore 自己的 query head。packet 至少携带：

```text
generation, job_id, block_id, op(QK/PV), kv_head_id,
tile_base, packet_seq, layout, role(K/V), flags
```

### 4.2 八核原子接收

广播源不能只根据某一个 Pcore 的 `ready` 就开始发送。建议使用两阶段接收：

1. 8 个 Pcore 分别检查本地 queue 是否有连续 2 个空 slot、当前 job 是否匹配、旧事务是否已清理。
2. 8 个 ready 经过树形汇总生成 `packet_grant`。
3. 只有 `packet_grant=1` 时，8 个 Pcore 同时接受该 packet，并各自预留 2 个 slot。
4. packet 开始后允许源端出现合法 `valid` 气泡，但顺序、packet identity 和 beat counter 不能改变。

这样不会出现 8 个 Pcore 只接收到部分 packet 的状态。ready 建议经过寄存器树，避免形成 8 核组合 ready 的长路径。

### 4.3 源锁定

一个 job 开始接收后，B source 锁定为 HBM 或 KVB：

```text
source_lock = HBM | KVB
```

不能在 queue 还有未消费 tile 或 loader 仍有 pending descriptor 时切换 source。不同矩阵任务之间由控制中心执行 drain/barrier，再更新 `source_lock`。

## 5. B tile queue

### 5.1 slot 状态

每个 Pcore 配置 8 个 slot，slot 状态为：

```text
FREE -> FILL -> READY -> LOADING -> FREE
```

状态含义：

- `FREE`：未被任何已接收或保留事务占用
- `FILL`：已预留，正在接收数据/scale
- `READY`：数据、scale、descriptor 都完整
- `LOADING`：已经绑定到一个 PE weight bank，loader 正在或即将写入

queue 使用严格顺序的 `wptr/rptr`，不做任意 slot 分配。group admission 时一次预留 4 个 HBM slot，packet admission 时一次预留 2 个 KVB slot；预留后不能在 group/packet 中途因为 queue full 而部分接收。

### 5.2 物理存储

推荐物理结构：

| 存储 | 深度×宽度 | 用途 |
|---|---:|---|
| `B_DATA_Q` | `8 × 4 × 512 bit` | 每 slot 保存 4 个数据 beat |
| `B_SCALE_Q` | `8 × 128 bit` | 每 slot 保存 16 个 scale |
| `B_META_Q` | `8 × descriptor` | 保存 job/矩阵位置/role/layout 等 |
| slot state | `8 × state` | FREE/FILL/READY/LOADING |

数据 payload 为 `8 × 256 B = 2048 B`，scale 为 `8 × 16 B = 128 B`，合计 2176 B，不含 descriptor、指针和校验位。

`B_SCALE_Q` 不能被实现成“每个 512-bit scale beat 一次写一个 slot”的假设：一个 HBM scale beat 同时更新 4 个 slot 的 128-bit 区域；KVB scale beat 同时更新 2 个 slot。RTL 需要采用多 bank 写、寄存器阵列，或先由 scale unpacker 分成多个写请求。数据区则保持每周期一个 512-bit 写入。

### 5.3 READY 判定

一个 slot 只有同时满足以下条件才置 `READY`：

```text
all_data_beats_received
all_16_scales_received
descriptor_valid
identity/order_check_pass
```

数据先到或 scale 先到都可以，不能根据其中一个到达就让 loader 读取。每个 tile 的 READY 可以早于同组后续 tile 的 READY，从而让 loader 尽早取前面的 tile。

## 6. B4 loader 与 scale loader

### 6.1 loader 工作方式

`B4_LOADER` 每次从一个 `READY` slot 读取 512-bit 数据，拆成 4 个 column group：

```text
queue beat[511:0] -> B[k=0..15][n=0..3]
queue beat[511:0] -> B[k=0..15][n=4..7]
queue beat[511:0] -> B[k=0..15][n=8..11]
queue beat[511:0] -> B[k=0..15][n=12..15]
```

从 queue 读出的 512-bit 数据进入 `B_DATA_HOLD`，scale 进入 `E_STAT_HOLD`。对于同步 RAM，读请求和数据返回至少相差一个时钟，因此 loader 必须有 valid/ready holding register：

```text
queue read request -> B_DATA_HOLD.valid -> PE bank write
                    -> next request
```

若下游因为 bank 尚未释放而不能接收，hold register 必须保持，不能丢数据或推进 `rptr`。

### 6.2 scale 进入位置

scale 不进入 PE，也不和每个 INT8 权重打包到 PE 写口。推荐路径：

```text
B_SCALE_Q
  -> scale unpack / E_STAT_HOLD
  -> target bank 的 E_STAT_BANK_A/B[15:0]
  -> DEQACC 或相应反量化路径
```

scale 可以比 4 个数据 beat 更早写入目标 `E_STAT_BANK`，但只有 data 四拍完成、最后一次 bank write commit 后，整个 B bank 才对 MXU 标记为 `READY`。这样既能隐藏 scale 装载，又不会出现数据已可算而 scale 尚未准备好的状态。

### 6.3 bank 写端口

每个 PE 的两套 weight bank 各保存本 PE 对应的一个权重。四列/拍由 MXU 外围分发到 64 个 PE，不扩大单 PE 写口：

```text
weight_bank[bank=0..1][pe] : signed INT8
```

scale 存在 PE 外部：

```text
E_STAT_BANK[bank][16] : signed/unsigned 8-bit scale
```

因此“queue 中有一份权重”和“PE bank 中有一份权重”是两个物理存储：

- queue：等待装载的 tile，可被 loader 顺序读出
- PE bank：当前/下一 tile 的驻留权重，供 MXU 乘法使用

V1 不依赖 queue 与 PE bank 共享 RAM，也不允许在 MXU 仍使用某 bank 时用新 tile 覆盖该 bank。

## 7. 双 bank 切换和首拍/尾拍

### 7.1 时间定义

设一个 tile 的有效 A 发射周期为 `P = ceil(M/2)`，A 的第 `j` 个双行 pair 在周期 `I_j` 进入 MXU 的 S0；第一拍加载数据的 bank write 在 `I_j` 之前已经完成。

V1 约定：

```text
S0 使用 bank 的第 j 个 pair：I_j
S1/DSP 实际使用该权重：I_j + 1
```

因此最后一个 pair 的实际乘法使用发生在最后一个 S0 后一拍。旧 bank 必须等最后一次实际使用完成后才释放。

### 7.2 保守释放规则

默认规则：

```text
bank_release = last_mul_commit
```

禁止在最后一个权重写入周期同时依赖“旧权重已经失效”的模糊仿真语义。若同一边沿既写 bank 又让 MXU 读 bank，后续 RTL 必须明确采用 bypass 或明确规定读写优先级；V1 先按禁止冲突设计，便于综合和仿真一致。

### 7.3 可用的 look-ahead

可以提前把下一个 tile 的 scale、descriptor 和 queue 数据读入 holding register。在最后一次旧 tile 的实际乘法完成之前，新 tile 不能写到同一个 bank；但是在最后一次 bank write 的边沿完成时，如果以下条件全部成立，可以让下一 tile 的第一个 S0 在该边沿发起，下一边沿的 S1 使用新权重：

```text
next_data_valid
next_scale_valid
next_meta_valid
target_bank_write_complete_this_cycle
A_pair_valid
DEQACC/ACC reservation ready
```

如果实现不采用这个 look-ahead，而是等 `bank_ready` 注册信号下一拍才开始，P=4 时会多出至少 1 拍；该余量要在调度模型中明确计入，不能仍按理想 4 拍/tile 计算。

### 7.4 预装两个初始 bank

为了避免首 tile 启动被 B 加载阻塞，控制中心可以在 job 发射前要求：

```text
bank A READY
bank B READY 或 bank B 正在预装
```

若系统要求“从第一个外部 beat 开始计时”，首 tile 的 B 加载延迟必须单独计入；不能把 steady-state 的 4/4.25/4.5 拍直接套到首 tile。

## 8. 吞吐和动态 M 的计算

### 8.1 理想输入条件下的上限

在 B queue 已有 ready tile、A 已准备好、ACC 地址间隔允许的条件下：

```text
P_compute = ceil(M/2)
P_hbm_avg = 4.25 beat/tile
P_kvb_avg = 4.50 beat/tile
P_loader  = 4 write cycles/tile
```

内部无额外等待时，B 侧供数约束可写成：

```text
P_tile >= max(P_compute, P_loader, source_service_interval)
```

但这只是 B 侧局部下界。还需加入：

- bank 释放延迟
- synchronous RAM holding register 的 backpressure
- DEQACC 对同一累加地址的 RAW 间隔
- A source/XBC/QOZ/PBUF 的 ready
- tile/job 首尾的 control barrier

### 8.2 M 小于 9 的情况

只看 MXU 的双行计算时：

| M | P=ceil(M/2) | 主要约束 |
|---:|---:|---|
| 0 | 0 | no-op，不产生请求、不占用 bank |
| 1..2 | 1 | B loader/切换与 ACC 更可能成为约束 |
| 3..4 | 2 | B loader 约束明显 |
| 5..6 | 3 | 仍可能由 B 侧供数约束 |
| 7..8 | 4 | 接近内部 4 拍 loader 下界 |
| 9..51 | 5..26 | 计算逐渐成为主约束 |

结论不是“小 M 一定只能跑 4 拍”，而是小 M 下应减少空转和首尾等待，不能只优化矩阵乘法阵列。

### 8.3 不连续 row_id

A pair FIFO 中不再用“pair index 推导真实行号”的假设。每个双行 entry 至少携带：

```text
row_id0, row_id1, row_valid0, row_valid1
```

MXU 只对 `row_valid=1` 的行产生 Psum；结果写回地址由 `row_id` 或 job 的 row map 决定。B tile 的 `n/k` 坐标与 row_id 无关。

## 9. 与 DEQACC 的边界

B loader 完成的是“权重可用”，不是“结果一定可连续提交”。

### 9.1 必须由控制中心预留

启动一个 tile 前，控制中心至少确认：

```text
b_bank_ready
scale_ready
a_pair_ready
acc_context_ready
acc_destination_valid
```

`acc_context_ready` 应包含当前 operation、目标 bank/地址、最终 tile 标记和 generation。不能把 `ready` 只看成 B queue 非空。

### 9.2 同地址累加间隔

现有 `DEQACC_3.3ns.sv` 的同步 RAM 读写路径要求对相同 accumulator 地址保守地保持足够间隔；按当前 D0..D10 结构，不能因为 B 侧可以每 4 拍供一个 tile，就直接断言同一地址可以每 4 拍发起。

因此 V1 调度器需要二选一：

1. 用 accumulator scoreboard 只在地址 hazard 消失后发射；或
2. 后续在 DEQACC 中加入明确的 forwarding/累加重排结构，再更新约束。

V1 采用第 1 种，不改写 DEQACC。性能模型必须把因 scoreboard 产生的 bubble 单独统计。

## 10. Descriptor 和数据识别

### 10.1 通用 descriptor

每个 READY tile 都必须绑定一份 descriptor。建议字段如下：

| 字段 | 建议宽度 | 作用 |
|---|---:|---|
| `generation` | 8 | reset/flush 后代次 |
| `job_id` | 8 | 外部总控任务 |
| `layer_id` | 8 | 18 层上下文 |
| `op` | 3 | Q/K/V/O/Down/G-U 等 |
| `role` | 2 | weight/K/V/G/U 等 |
| `base_k` | 8 | 当前 K 方向起点 |
| `base_n` | 8 | 当前 N 方向起点 |
| `tile_k` | 8 | K tile 序号 |
| `tile_n` | 8 | N tile 序号 |
| `segment_seq` | 8 | 外部 segment 序号 |
| `layout` | 3 | 数据/scale 布局 |
| `final_k` | 1 | 是否为该输出的最后 K tile |
| `final_n` | 1 | 是否为该输出的最后 N tile |
| `valid_rows` | 6 | 动态 M；B 侧一般只用于一致性检查 |
| `flags` | 8 | flush、error、保留 |

descriptor 宽度允许按实现增加，未使用字段置零。关键是 identity 必须随数据走到 `B bank ready` 和 MXU job context，不能在 queue 出队时重新猜测。

### 10.2 CRC 的边界

V1 不把 CRC 当作地址绑定证明。CRC 只能发现传输内容变化；如果软件或 adapter 取错了地址，再对错误 payload 计算 CRC，CRC 仍可能通过。

若后续需要检测地址错绑，应使用与 descriptor 绑定的 reference/checksum，或在数据生产端把 tile identity 纳入校验值，例如：

```text
check = CRC(payload || job_id || tile_k || tile_n || role)
```

接收端必须使用期望 identity 重新计算，而不是仅检查 payload 自己携带的 CRC。

## 11. 各矩阵来源的适配

| 矩阵任务 | B source | V1 接收方式 |
|---|---|---|
| Q/K/V projection | HBM | 两路 256 bit 合成逻辑 512 bit，写 HBM B queue |
| O projection | HBM | 同上 |
| Down projection | HBM | 同上 |
| Attention QK/PV | KVB | 512 bit broadcast，8 核原子 packet 接收 |
| G-U | HBM | 同 HBM queue，`role=G/U` 由 descriptor 区分 |

G-U 的 G/U 交错布局必须明确“物理 tile 数”和“K 方向 tile 数”的区别。不能复用一个过窄的 `k_tile` 字段同时表示 G/U 角色和物理传输序号；建议使用独立的 `role`、`tile_k` 和 `segment_seq`。

## 12. 控制状态机建议

V1 不把所有外部传输和 MXU 计算塞在一个大状态机中，采用三个相互握手的局部状态机：

### 12.1 Receive FSM

```text
IDLE
  -> HEADER
  -> RESERVE
  -> RECEIVE_DATA/SCALE
  -> CHECK
  -> READY
```

Receive FSM 只负责格式、配对、slot 状态和协议错误；不直接决定 MXU 什么时候算。

### 12.2 Load FSM

```text
WAIT_READY
  -> READ_HOLD
  -> WRITE_SCALE
  -> WRITE_B0..B3
  -> BANK_READY
  -> WAIT_ISSUE_DONE
  -> RELEASE_SLOT
```

`WRITE_SCALE` 可以和 queue 后续数据接收并行，但 `BANK_READY` 必须等 data、scale、metadata 全部完成。

### 12.3 Issue FSM

Issue FSM 接收外部 job 和 A/ACC ready，选择可用 bank：

```text
WAIT_JOB
  -> WAIT_B_READY/A_READY/ACC_READY
  -> ISSUE_PAIR_0 ... ISSUE_PAIR_last
  -> WAIT_LAST_MUL
  -> RELEASE_BANK
  -> NEXT_TILE or JOB_DONE
```

Issue FSM 只提交有效 pair。`M=0` 直接进入 `JOB_DONE`，但必须生成明确的 done/empty 事件，不能让上游一直等待一个不存在的 Psum。

## 13. V1 需要修改/否定的旧说法

| 旧说法 | V1 修正 |
|---|---|
| 两路 HBM 256 bit 总能每周期组成 512 bit | 只有两路队头 identity 对齐时才能组成；PC skew 必须由 elastic FIFO 吸收 |
| 每个 scale beat 直接写一个 slot | HBM scale beat 同时包含 4 个 tile 的 scale，必须 unpack/多 bank 写 |
| loader 4 拍即可保证 tile 连续无气泡 | 还要满足 bank release、同步 RAM 返回、A/ACC ready 和 DEQACC hazard |
| queue 有 8 slots 就必然隐藏所有 HBM 延迟 | 只有在 source service、slot reservation、消费速率满足条件时才能隐藏 |
| M 小时把 51 行 mask 掉即可 | 需要动态 row map；M=0 是 no-op，不能回退到 51 行 |
| KVB 的 head 可直接用本地 query head | 广播使用共享 KV head/context，query head 由上游映射 |
| CRC 能证明 tile 地址正确 | CRC 不能证明取址正确，必须把 identity 纳入独立校验 |

## 14. 后续 RTL 接口冻结建议

在开始写 RTL 前，至少冻结以下接口字段和行为：

1. HBM adapter 是否向 Pcore 保证两个 PC 的 logical beat 顺序；若不保证，Pcore 接收端必须使用上面的配对 FIFO。
2. HBM header 的 `base_n/tile_count/group_count/layout` 编码。
3. KVB packet 的 2-tile beat 顺序、`role=K/V`、`kv_head_id` 和 8 核原子 grant。
4. `B_DATA_Q`、`B_SCALE_Q`、`B_META_Q` 的写入时序与同周期读写规则。
5. bank release 是保守等待最后一次乘法，还是采用明确的 last-write look-ahead。
6. DEQACC scoreboard 的 hazard ready 接口；不能只接一个 `acc_ready` 而不说明它是否涵盖地址冲突。
7. 动态 A entry 的 `row_id0/row_id1/valid` 编码以及 `M=0` done 行为。
8. `generation` 的分配、flush 时如何丢弃旧 HBM/KVB 返回，以及 epoch 回绕前如何确认旧事务已经排空。

## 15. 验证入口（后续实现时）

本 V1 尚未进行 RTL 仿真。后续至少需要以下独立测试：

### HBM adapter

- PC0/PC1 同周期、错 1 拍、错多拍返回
- beat 序号交叉、burst 被 4 KiB 拆分
- 半宽错误、`last` 位置异常、generation 不一致
- 4 tile group 中只 READY 前面的 tile

### B queue/loader

- 8 slot 满、预留、同时写入和 loader 读取
- scale beat 同时更新 4 个 slot
- scale 先到、data 先到、数据气泡
- bank A/B 交替，最后一次乘法与下一个 bank 写入的边界
- source error 后停止，clear 后完整恢复

### KVB broadcast

- 8 核全部 grant、任一核 backpressure、packet 中途 valid 气泡
- K/V role、block/head/tile identity 错配
- 2 个 tile 的 scale 和 data 不互换

### 动态 M

- `M=0,1,2,7,8,9,50,51`
- row_id 连续和不连续
- 最后一双行只有 `row_valid0=1`
- 同一个 18 层上下文中多个 job 复用 row map

### 系统边界

- 通过 scoreboard 检查相同 DEQACC 地址的发射间隔
- 统计首 tile、稳态、尾 tile 三种周期，不能只报平均值
- 检查 tile descriptor 与最终 bank、Psum destination 全程一致

## 16. 当前范围与下一步

### 本 V1 已确定

- 每个 Pcore 的 HBM 两路 256 bit 到逻辑 512 bit 的配对规则
- KVB 512 bit packet 广播和 8 核原子接收规则
- 8-slot B queue、4 列/周期 loader、scale 外置存储
- 双 bank 的写入、释放和首尾时序边界
- 动态 M、非连续 row_id、M=0 的语义
- B 侧与 DEQACC hazard 的边界

### 本 V1 没有声称完成

- 没有修改 `DEA8`
- 没有编写新的 `DEA8_dynamic/Pcore` RTL
- 没有完成 Vivado 仿真或综合
- 没有证明 512 bit 外部通道在真实 HBM service schedule 下始终无气泡
- 没有重新设计 A 侧 QOZ/XBC/PBUF，也没有替代 DEQACC 的 accumulator forwarding

下一步应先把第 14 节的接口字段冻结，再按“HBM adapter/queue → loader/dual bank → MXU issue”顺序实现和验证，最后将动态 A 行、DEQACC scoreboard 接入同一个 job-level testbench。

