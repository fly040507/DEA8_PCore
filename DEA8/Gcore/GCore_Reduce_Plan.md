# GCore 最新方案：内置 Reduce 与共享算术

日期：2026-10-16。固定 `M=51`、hidden=1024，目标平台 U50。

**状态：方案已落实到RTL，15个仿真场景通过，本体OOC实测109 DSP；尚未做4ns布局布线签核。** GCore直接接收八个PCore输出，内置4-lane归约；独立Reduce退出当前构建与连接，旧目录仅留历史证据。验证入口见 [README](README.md) 和 [本轮回归结果](reports/summary.txt)。

依据：[用户草案](../GCore方案.txt)、其后七条注释，以及本轮“256-bit共线、首拍信息、浅FIFO、无归约结果Tile”要求。草案中的 `FP16` 为笔误，残差始终为 BF16；DSP 合计采用已修正的109。本文不增加新的设计版本名称。

## 1. 结论与边界

| 项目 | 最新方案 |
|---|---|
| Reduce 归属 | O/Down 八核 FP32 归约移入 GCore，不再作为目标架构中的独立顶层 |
| PCore输出链路 | 每核一条256-bit共用链路，K/V/O/Down分包复用，共八条，不是八核共用一条 |
| 分包 | 一拍header；O/Down为102个FP32 payload beat，K为51个MXINT8 beat，V保留64个MXINT8 beat |
| 接收FIFO | 建议每核共用一条256-bit*4 payload FIFO；O/Down每beat分两拍处理，K/V每beat一拍写入 |
| 接收缓存边界 | header单独锁存；不缓存完整FP32归约结果Tile，不重新建立八核输入Tile副本 |
| 归约与残差 | 4-lane；每路七个 FPADD 求八核和，再接一个残差 FPADD |
| 共享加法树 | 四棵八输入树；分时用于八核归约、SUM8、SUM64 |
| 平方与归一化 | 共用16路通用 FP32 乘法器；归一化两次乘法分时执行 |
| 行统计 | SUM8 按行缓存；每四个 N-Tile 组成 SUM64，再累加到51行总平方和 |
| 统计调度 | 每个 N-Tile 内先归约及残差，再处理该 Tile 的平方统计，争取一起隐藏 |
| rsqrt | 一路真实 FP32 IP，与单路 epsilon 加法流水重叠 |
| gamma | 在线乘；从模型参数导出并加载，不默认折叠进矩阵权重 |
| 量化 | 已实现8-lane MXINT8-B16，II=2；Y FIFO吸收乘法输出突发 |
| DSP | 算术结构预算109，包含Reduce；本轮OOC实测109 |

DEA8总控继续负责层号、去噪步数、PCore七类Job和跨模块依赖。GCore局部控制接收命令、调度内部共享资源，不在内部展开18层或10步。

K/V接收、共享KV存储、KVB供数、XHAT存储及XBC重放保留原有职责；K/V与O/Down的前向物理接口合并。PCore内部外发模块必须配套改包和拆分FP32行，但不改变其矩阵计算链路，不在PCore外另建发送封装。归约后只写既有BF16 RESID，不再设置独立的 `[51,16]` FP32结果Tile。

## 2. 精度与完整公式

所有加法、乘法和统计中间结果使用 FP32。BF16 输入无损扩展为 FP32；不另设 BF16 算术核。残差在写回 RESID 时执行一次 BF16 RNE 舍入。

```text
delta[r,c] = 固定三级八核 FP32 归约树(partial[0..7,r,c])
X_new[r,c] = BF16_RNE(FP32(X_old[r,c]) + delta[r,c])
sq[r]     = 按本文 SUM8 / SUM64 顺序累加 FP32(X_new[r,c])^2
u[r]      = FP32(sq[r] * 2^-10 + epsilon)
inv[r]    = RSQRT_FP32(u[r])
H[r,c]    = FP32(FP32(X_new[r,c]) * inv[r])
Y[r,c]    = FP32(H[r,c] * gamma[c])
XHAT      = MXINT8_B16_ENCODE(Y)
```

- 平方使用实际写入的 BF16 残差，不能改用舍入前的 FP32 相加结果。
- `inv[r]`按行选择，`gamma[c]`按列选择；51行复用同一组1024个gamma。
- `sq/1024`不需要通用除法器；沿用正确处理零、下溢及舍入的二次幂缩放逻辑，不能只对原始指数域做无保护减法。
- NaN/Inf、统计溢出和非法参数保留故障检查，不以静默量化掩盖。

当前草案保留 FP32 的 `Y`直接进入 MXINT8 量化，不在两次乘法之间插入 BF16 舍入。官方标准pi0在乘gamma之后转回输入dtype；如果验收目标要求这一 BF16 输出边界，需要另行明确并同步量化参考模型，不能混用两种口径。这里不默认为已完成官方模型位精确对齐。

## 3. 四路归约与残差

每个算术lane负责一列，使用七个流水FPADD构成固定八输入树：

```text
(core0+core1)  (core2+core3)  (core4+core5)  (core6+core7)
        \          /                 \          /
           FPADD                         FPADD
                       \       /
                         FPADD
                            |
             + FP32(X_old) / 残差FPADD
                            |
                      BF16 RNE写回
```

### 3.1 共用链路与分包

目标连接：`PCore[0..7].output -> GCore.rx[0..7]`。每个PCore只保留一条K/V/O/Down共用的前向数据链路，八条链路并行、独立握手。

| 信号 | 每核宽度 | 约定 |
|---|---:|---|
| tx_data | 256 bit | header和payload复用，不再另设前向header数据总线 |
| tx_valid / tx_ready | 各1 bit | 仅valid与ready同时为1时消费；等待时数据和last保持稳定 |
| tx_last | 1 bit | header为0，payload仅最后一个beat为1 |
| KV commit返回 | 现有64-bit typed数据及valid/ready | 保留写入确认；共用前向数据线不取消反向控制 |

接收端按 `HEADER -> PAYLOAD -> DRAIN/RETIRE -> HEADER` 解析。一拍header使用低128位，高128位为零；不依靠payload数值特征判断消息类型。没有新包交错，也不把一个Tile拆到多个事务中。

“一组线”指八条 `256-bit` 链路各自复用，不是八核仲裁一条256-bit链路。后者仅O/Down传输就至少需要 `8*(1+102)=824` 个有效握手拍，已超过O的416拍参考窗口。

### 3.2 Header与数据定位

沿用现有128-bit `tile_header_t`的主体语义：`transfer_id`、`transfer_epoch`、`destination_id`、`token_origin`、`column_base`、`rows`、`columns`、`kind`、`layout`、`source_id`、`tile_seq`。建议将原23-bit reserved划分为：

| 字段 | 位数 | 用途 |
|---|---:|---|
| protocol_version | 3 | 区分新256-bit包协议与旧独立header/data接口 |
| payload_beats | 8 | K=51、V=64、O/Down=102；按kind/layout再次校验，不盲信来包长度 |
| dtype | 2 | FP32或MXINT8-B16 |
| scale_axis | 2 | NONE、FEATURE_B16、TOKEN_B16 |
| reserved | 8 | 必须为零 |

总宽度仍为128bit。这只是接口协议标识，不增加工程设计版本名称。RTL实施时两端同时更新定义，不能把新header当成旧版 `reserved==0` 的包接收。

- `source_id`必须等于物理输入端口0..7；不再接收独立Reduce产生的source_id=8聚合流。
- O/Down八个header必须指向同一事务、kind、Tile、token起点及输出列坐标，仅source_id不同。
- K/V按各核实际列坐标写不同位置，不要求八核column_base相同；还需校验本核允许写的列和重复覆盖。
- 当前固定映射保持：K的 `column_base=core_id*16+tile_seq*128`，V的 `column_base=core_id*32+tile_seq*16`；每核两块16列。若后续调整核间切分，必须同步更新参数清单及接收校验。
- O/Down的 `column_base=tile_seq*16`，64个N-Tile顺序退休；global row由 `token_origin+row`确定。
- Header只是数据描述符，不是新任务指令；只有匹配DEA8已经授权的活动服务/context时才允许进入处理。

### 3.3 Payload格式与V的例外

下表是每核每个16列Tile的有效握手数量，不是包括背压的完成周期：

| kind | layout / scale轴 | header | payload | 总有效beat |
|---|---|---:|---:|---:|
| O/Down | FP32行序，NONE | 1 | 102 | 103 |
| K | K_ROWS，FEATURE_B16 | 1 | 51 | 52 |
| V | V_GROUPS，TOKEN_B16 | 1 | 64 | 65 |

O/Down按行发送。payload序号 `b=2*row+half`，row为0..50，half为0/1；每beat八个FP32，依次对应 `column_base+8*half+[0..7]`。元素i固定放在 `tx_data[32*i+:32]`，b=101时last为1。

K/V统一使用 `tx_data[127:0]=INT8 data`、`tx_data[135:128]=scale`、`tx_data[255:136]=0`。高120位不携带隐藏地址或第二个scale；元素i位于data的第i个字节。

K的第r个beat对应第r行的16列，共51beat。V不能直接照抄这个计数：当前PCore按token方向B16量化，`b=16*token_group+feature_offset`，四组token、每组16个feature向量，共64beat；每个向量中的16个INT8沿token方向排列，scale也属于这16个token。最后一组只有token 48..50有效，其余13个INT8填零。

因此本次推荐 **K=51、V=64**，保留现有V量化轴和PV供数语义。不能为了统一51beat，直接把按token量化的V转成“每行16元素加一个scale”；这会改变数值含义。若以后坚持V也51beat，需另行设计scale传送或转置/重新量化，并同步修改V后处理、KV存储、KVB及PV参考模型，本轮不默许这一变化。

依据为当前[PCore外发](../Pcore/rtl/dea8_pcore_output.sv)与[GCore KV接收](rtl/dea8_gcore_kv_receive.sv)中的 `QUANT_TOKEN_B16`、`LAYOUT_V_GROUPS` 和64beat检查。V尾组填零和非法scale检查继续保留。

### 3.4 FIFO宽度与深度

建议每核设置一条 **256-bit*4 payload FIFO**，K/V/O/Down按当前包类型分时复用，不再并列设置一套136-bit KV FIFO和一套512-bit O/Down FIFO。header单独锁存，不占payload FIFO，也不在每个word里重复保存整份地址/事务信息。

| 项目 | 目标 |
|---|---|
| FIFO数量 | 八条，每个PCore输入一条 |
| 初始参数 | `RX_DATA_BITS=256`、`RX_DEPTH=4`，深度可参数化到8做对比 |
| 每核payload容量 | 1024bit=128B |
| 八核payload容量 | 8192bit=1KiB，不含header、指针和额外接口寄存器 |
| O/Down消费 | 同一head低128位、高128位分两次发射，每次四个FP32 |
| K/V消费 | 取head低136位，一次写入对应KV bank后弹出；八核可独立推进 |

对比当前独立Reduce的八条 `512-bit*8` FIFO，新payload容量由4KiB降为1KiB，逻辑位数下降75%；完整FP32归约结果Tile另省 `51*16*4=3264B`。这不是物理BRAM/LUT节省的实测比例。

FIFO为256bit而不是128bit，是为了每个链路beat直接一次入队。四个归约lane只需一条128-bit内部读切片，不要求FIFO物理宽度也等于128bit。`128-bit*8`容量相同，但接收一个256-bit beat需要双写bank或拆分holding及双份信用，不作为控制简单的首选。

深度4用于吸收短期核间偏差和取数交接，不保证八核任意长时间错位都能无背压。O/Down生产者可每拍给八个FP32，但四lane平均两拍才消费一个beat，因此必须正常拉低ready；不能声称102个数据beat连续接收且只有浅FIFO。若要求整包连续突发不反压，就必须大幅加深缓存或提高计算吞吐，违背当前小缓存目标。

浅FIFO优先评估LUTRAM/SRL及小型holding，不把1KiB全部铺成FF，也不因“优先RAM”强制为256bit宽、4深的每核FIFO分配碎片化大BRAM。LUTRAM也是RAM；具体映射按实际综合冻结。接口若增加ready寄存或skid，其额外在途容量必须纳入信用和满判断。

### 3.5 归约、残差与接收路由

每个O/Down payload beat消费两次。设beat内子相位 `sub=0/1`：

```text
八核对应FIFO head全部有效，且当前算术入口可接收
  sub=0：每核head[127:0]   -> 四lane固定八输入树
  sub=1：每核head[255:128] -> 四lane固定八输入树
          第二次发射真正被接受后，八个FIFO共同pop

row = beat_index / 2
half = beat_index % 2
quarter = 2*half + sub
```

八路使用同一个归约消费序号，不以各核不同的接收计数代替；任一路尚未到达时等待。若在两次发射之间暂停，head、sub和元数据保持，不能提前弹出，也不能重复发射低半部分。

一行两个256-bit beat，共四次四lane发射；一个Tile仍为204次发射。传输的102个beat和204次计算重叠执行，不相加成306拍；实际端到端时间另含header、核间等待、读写、流水和退休开销。

- 旧残差仍按完整16元素读取，按quarter切片并对齐归约结果，不能错用下一行。
- 四个quarter的BF16结果组装成256-bit字后写回RESID；保留少量旧残差holding、输出组装和在途标签，不设置 `[51,16]` FP32结果缓存，也不在GCore保存八核完整输入Tile。
- K/V不经过归约树。相同RX前端按header路由到现有KV写通路，用column_base、layout和payload序号恢复bank及地址；“拼接”是按坐标写入，不做加法。
- 前端统一不等于消费规则统一：O/Down八核汇合，K/V逐核独立；不能让K/V也等待八核同一拍才能落RAM。

### 3.6 描述符生命周期与完成

每核只允许一个未退休包，FIFO中不混入下一Tile，因此可只保留一个header寄存器。接收payload完毕后，描述符继续保留到FIFO排空及相应写回完成；不能为了提前接下一个header而覆盖旧地址信息。

K/V继续在实际写入KV RAM后返回现有匹配commit，PCore收到后释放自身64*136-bit Tile sender。O/Down保留“末payload交付即可完成本核发送”的语义，不凭空增加逐核FP32 commit；GCore接收FIFO接管已经握手的数据，DEA8总控另等GCore残差服务完成。

O/Down下一Tile的header先保持反压，直到当前八核Tile的归约、残差写回和本Tile统计阶段退休。这样以Tile为界切换共享树，不需要为省少量交接拍引入多Tile描述符队列。

接收端按类型计数校验last，header及payload的保留位/填零位必须正确；FP32非有限值、MX非法scale、缺核、身份错配、重复Tile进入故障或等待/上层超时。不能用watchdog替代确定的协议检查。取消/故障使相应结果对象及统计失效，flush在途包后才能重启，防止部分残差被重复相加。

## 4. 按 N-Tile 隐藏平方统计

采用 `nt`外层、`row`内层顺序，不采用先完成一行1024个平方再换下一行的方式。

```text
N-Tile n：
  八核partial -> 4-lane归约 -> 残差相加 -> BF16写回
  等当前共享资源可切换
  读取该Tile的51行 -> 16-lane平方 -> 两棵SUM8树
  必要时并行输出SUM64并更新行总和
  排空相关流水，准备下一个N-Tile
```

204拍归约发射与51拍平方扫描合计255拍。256-bit链路的102个数据beat已经包含在归约消费过程中，不能再重复计入。以 O/Down 的416/832拍有效矩阵窗口为参考，有余量容纳header、读写、排空和模式交接；先用控制简单、有余量的方案，不追求零间隔切换。

这只是隐藏目标，条件是八核供数、背压和真实Tile间隔满足要求。需要仿真证明，不能把 `255<416`直接当成已经隐藏成功。若4-lane算力确实成为瓶颈，再评估8-lane；先排除断供、握手和模式切换浪费。

O/Down后的统计随Tile建立，因此后续NORM可复用有效的 `sq`，不再完整暴露3264拍平方扫描。首次预置/导入的残差如果没有对应统计，仍需一次完整扫描；残差替换、取消或版本变化必须使旧统计失效。

## 5. SUM8、SUM64与行累加

设 `g=nt/4`、`s=nt%4`。对每行r：

```text
SUM8_BUF[r,2*s]   = SUM8(square[r,16*nt + 0 : 16*nt + 7])
SUM8_BUF[r,2*s+1] = SUM8(square[r,16*nt + 8 : 16*nt +15])

s==3时：
  sum64[r,g] = SUM8_TREE(SUM8_BUF[r,0..7])
  SQ_ACC[r]  = g==0 ? sum64[r,g] : FP32_ADD(SQ_ACC[r],sum64[r,g])
```

每四个N-Tile完成64列，每行最终累加16个SUM64，覆盖1024列。第一批直接初始化SQ_ACC；不依赖复位清空RAM数据。

共享树的分工：

| 模式 | 树0 | 树1 | 树2 | 树3 |
|---|---|---|---|---|
| 八核归约 | 列lane0 | 列lane1 | 列lane2 | 列lane3 |
| 平方统计 | 当前行前8个平方求和 | 当前行后8个平方求和 | s=3时将八个SUM8合成SUM64 | 暂不分配 |

两棵SUM8树与一棵SUM64树可以流水重叠。完成第4个Tile时，SUM64是连续51行的一批输出，不是严格每隔四拍才输出一个。

`SUM8_BUF[51][8]`逻辑容量1632B，优先使用分bank RAM。可按四组、每组两个SUM8组织；每拍写当前两个，计算SUM64时读取之前六个，并旁路当前两个。同步RAM的旧值和当前值需要对齐，避免同址读写依赖。

一个支持每拍接收数据的流水FPADD足够更新51行SQ_ACC。同一行下一次更新要等后面四个N-Tile，不会每拍反馈同一行；提前读取旧SQ_ACC，并让row/g标签贯穿读、加、写。

必须保留 `SQ_ACC[51]`，但**不强制再增加 `SUM64[51]`整批缓存**。优先让SUM64流直接接累加流水；仅在背压解耦确有需要时增加小FIFO或整批缓存。

新顺序与旧RTL的SUM16后顺序累加不同。独立参考模型必须明确按相邻SUM8、相邻SUM64、g递增累加进行FP32舍入；不能以实数加法结合律要求新旧结果逐位相同。

## 6. 单路 epsilon 与 rsqrt

`SQ_ACC[51]`全部有效后，逐行读取：

```text
SQ_ACC -> 乘2^-10 -> 单路FPADD加epsilon -> 单路FP32 rsqrt -> INV[51]
```

epsilon与rsqrt流水重叠，51行需要51次发射。先采用全部inv有效后进入归一化的简单控制；尾部在粗估中统一留余量，不作为架构争议，仿真时照实计入。

单路rsqrt仍需保留原包装器的输入正规化、非正规数处理、有限值检查、结果信用、背压、取消及IP复位恢复逻辑。它是单通道FP32算术，不是简单将现有双通道的第二个mask长期置零；后者仍会实例化两个IP。

## 7. 在线 gamma 与两次乘法复用

标准pi0的 `gamma=FP32(1+scale)`，来自训练后的checkpoint，不是rsqrt输出，也不是量化scale。语义参考[官方RMSNorm](https://github.com/Physical-Intelligence/openpi/blob/main/src/openpi/models/gemma.py)，参数映射参考[官方权重转换脚本](https://github.com/Physical-Intelligence/openpi/blob/main/examples/convert_jax_model_to_pytorch.py)；本方案针对普通pi0，不混用pi0.5的条件adaRMSNorm。

- 参数导出端生成FP32 gamma；GCore加载并保存，不在每个元素上反复计算 `1+scale`。
- 每层分别保存Attention前和FFN前两组gamma，每组1024个FP32，两组合计8KiB。
- NORM命令或活动context必须明确选择参数组及版本，参数完整且匹配后才能启动。
- gamma按列选择，同一组参数供51行和各去噪步复用；Final RMSNorm的参数另行管理，不能误用层内参数。
- 新目标不再以 `gamma_folded=1`作为省略在线乘法的前提；后续修改控制器时必须消除旧折叠假设，避免重复乘或漏乘。

16路FPMUL继续同时支持平方模式和归一化模式，不改成此前讨论过的专用低有效数乘法方案。

```text
第一次发射：H = FP32(X * inv)
            -> FP32中间缓存 + 标签
第二次发射：Y = FP32(H * gamma)
            -> 量化
```

一个矩阵有3264个16元素向量，每向量两次乘法发射，理想有效发射需求6528拍。它不表示一组数据两拍就能算完；实际乘法流水、反馈、缓存信用和标签必须一起调度。

gamma可采用窄RAM加当前/下一组16元素缓存。每组gamma供51行复用，参数预取争取隐藏；缓存不能在使用旧gamma的在途数据退出前被覆盖。

## 8. 量化与存储

量化与归一化输出流水重叠，不增加一次全矩阵扫描。本轮已选用并验证8-lane：每两拍处理16个元素，通过Y FIFO吸收乘法反馈调度产生的突发。

始终使用完整16元素的最大绝对值和一个共享scale。若分两拍处理八个元素，要组装为完整128-bit数据加8-bit scale后写XHAT，不能变成两个独立B8块。量化仍消耗LUT、FF和流水级，只是不新增DSP。

| 存储 | 逻辑内容/容量 | 处理原则 |
|---|---|---|
| RESID | 51*1024个BF16，102KiB | 复用原有残差RAM，256-bit行片段读写 |
| 八核共用RX FIFO | 每路256-bit*4，合计1KiB | K/V/O/Down分时复用；FP32 head分两次发射后共同pop |
| 包描述符 | 每核一份128-bit header及计数/状态 | 不与下一包混排，保留至退休；不逐beat重复标签 |
| 旧残差holding | 当前16个BF16及必要流水对齐 | 与归约row/quarter标签一致 |
| 残差组装 | 四个quarter组成16个BF16 | 小寄存器/holding，不缓存整块FP32结果Tile |
| SUM8_BUF | 51*8个FP32，1632B | 分bank RAM，支持两个新值与六个旧值配对 |
| SQ_ACC | 51个FP32，204B | 每行总平方和、有效位及源残差版本 |
| INV | 51个FP32，204B | 匹配残差版本及epsilon，逐行读出 |
| GAMMA | 当前层两组FP32参数，8KiB | 参数身份、版本、完整性；可预取下一层 |
| 乘法反馈 | FP32 H、gamma选择信息及事务标签 | 容量随流水调度确定，不先建整矩阵临时RAM |
| XHAT | 每行每16列一个136-bit MXINT8字 | 复用原存储及XBC，不改变其打包规则 |
| SUM64额外缓存 | 可选 | 不列为必需51项寄存器阵列 |

表中容量是逻辑载荷，不是物理BRAM占用；RAM宽度、端口和bank划分会影响实际资源。所有数据RAM优先采用BRAM/URAM，有效位和小型对齐状态才使用寄存器。

## 9. DSP预算与周期口径

| 算术资源 | 数量 | 每路DSP | 合计 |
|---|---:|---:|---:|
| 四棵八输入FP32树 | 28个FPADD | 2 | 56 |
| 残差FP32相加 | 4个FPADD | 2 | 8 |
| SQ_ACC累加 | 1个FPADD | 2 | 2 |
| epsilon相加 | 1个FPADD | 2 | 2 |
| 平方/归一化共享乘法 | 16个FPMUL | 2 | 32 |
| FP32 rsqrt | 1路IP | 9 | 9 |
| **合计** | | | **109** |

上述按现有叶算术资源计数，不为量化、指数缩放或窄控制额外计DSP。新增算术必须重新记账。LUT/FF/RAM另行综合统计，不能由DSP下降推断LUT一定下降。

周期只做量级判断：

| 场景 | 有效工作量 | 是否可隐藏 |
|---|---:|---|
| 一个O/Down包前向链路 | 1个header+102个payload握手 | payload与204拍归约重叠；浅FIFO会施加反压 |
| 一个K包 / V包 | 1+51 / 1+64个握手 | 独立KV落RAM，不经过四lane归约 |
| 一个N-Tile归约及残差 | 204拍发射 | 目标隐藏到O/Down矩阵 |
| 当前Tile平方扫描 | 51拍发射 | 与前项在同一矩阵窗口内先后执行 |
| 第四个Tile的SUM64和行累加 | 51行流水 | 与SUM8生成重叠 |
| 冷启动完整平方扫描 | 3264拍 | 无有效统计时需要，不能假定总能隐藏 |
| epsilon/rsqrt | 51行流水 | 两者相互重叠，另有IP及控制尾部 |
| 完整归一化两次乘法 | 6528次向量发射 | 本地主要可见开销，量化跟随流水 |

无统计缓存时，单次RMS加在线gamma及量化仍可粗估约一万拍。O/Down后的统计若成功隐藏，后续不再完整暴露3264拍扫描，主要剩下inv准备、两次乘法及收尾。每层有两次Norm，不能把单次粗估当成整层延迟。

250MHz只用于周期换算，每拍4ns；尚无新版时序签核。启动、末Tile、模式切换和背压以真实仿真计数为准，不为省几十拍增加复杂控制。

## 10. 控制与后续验证

GCore内部共享算术需保证以下边界：

1. Reduce与RMS统计互斥占用树；每次切换前排空上一模式，或使用经过验证的逐级模式标签。
2. 当前Tile残差写回后才能扫描它；统计读取时不与同址写回冲突。
3. 每行统计只更新一次；row、nt、g、事务/版本不能随停顿错位。
4. 所有64个Tile及16批SUM64处理完成后，才将完整sq标为有效；不能只凭残差接收结束提前置位。
5. NORM必须匹配残差、统计、epsilon及gamma身份；inv过期后重新计算，sq可以在源残差不变时复用。
6. 完成、取消、异常和背压继续遵循已提交数据的真实状态；不清RAM内容来代替有效性管理。
7. 统一接收仅改变前向输出协议；新header和拆包必须由PCore内部外发配套实现，不能只修改GCore端。
8. FIFO接收计数、归约beat/sub消费计数、残差写回计数和统计完成计数分开维护；最后payload入队不能触发整个服务完成。

后续RTL验证以独立参考模型为准，重点覆盖：256-bit header/payload包、K51/V64/FP102长度及不同scale轴、八核归约及残差、beat低/高半消费、四quarter组装、全部64个Tile、SUM8跨Tile缓存、16批SUM64累计、冷/热Norm、两组非平凡gamma、8-lane候选量化、随机断供/背压、取消和错误身份。需要专门在FIFO满、sub=1前停顿、末payload已接收但尚未写回、一个核超前/缺失、下一header提前出现时检查不丢不重。

资源测量至少对比 `RX_DEPTH=4/8`，记录FIFO真实LUT/FF/RAM映射。若4深在正常供数下即可隐藏，保留4深；不能为了让测试不反压而直接扩大到完整Tile缓存。

需要分别给出无背压各阶段周期、真实O/Down供数下的隐藏效果，以及从服务命令到完成的总周期。旧仿真和118 DSP本体综合报告仅证明旧实现，不证明本方案已经完成。

## 11. 与重构前代码的区别

| 重构前代码/证据 | 本轮实现 |
|---|---|
| 每核独立136-bit K/V口、512-bit FP32口及独立header | 每核一条256-bit前向包链路，header带内，八核并行 |
| KV与FP32接收FIFO分开、旧Reduce的512-bit*8 FIFO | 每核共用256-bit*4 FIFO，FP32每beat消费两次 |
| 独立Reduce采用16-lane树，收集完整结果Tile再送GCore | GCore内部4-lane归约，直接进入残差路径 |
| V为64个TOKEN_B16向量 | 新链路仍保留V64，不静默改成51个FEATURE_B16向量 |
| GCore 16-lane残差、独立SUM16树 | 4-lane残差、四棵树分时复用 |
| 双通道rsqrt | 单通道rsqrt |
| 默认gamma折叠，在线仅X*inv | 在线X*inv*gamma，两次乘法复用 |
| 16-lane量化 | 已实现8-lane，B16尺度与打包不变 |
| 已综合GCore为118 DSP，不含独立Reduce | 包含Reduce的109 DSP，本轮OOC确认；时序未签核 |

当前RTL入口为 [gcore_rtl.f](gcore_rtl.f)，仿真入口为 [gcore.f](gcore.f)。[原详细设计](GCore_Design.md)保留历史推导，不能覆盖当前接口。

## 12. 本轮实现与周期口径

- `dea8_gcore_packet_rx`：8路256×4共用FIFO；K51/V64/FP102，header带内，单包描述符保持到退休
- `dea8_gcore_compute`：4-lane归约/残差，实际BF16写回后扫描51行；SUM8按4Tile分组为SUM64，16组累计；sq绑定残差对象/版本/context
- `dea8_gcore_gamma`：两组1024 FP32的RAM，逐项加载和完整性检查；NORM通过16-bit `norm_param_id`选择
- 16 FPMUL分时完成平方、X×inv和H×gamma；8-lane量化II=2、全16值共用scale
- 顶层默认单路真实rsqrt；51行发51包mask=01，保留110-bit typed接口用于观测及外部故障注入
- PCore内部外发已配套改包；不在PCore外增加生产发送封装

当前无人工断供/下游暂停的GCore仿真：冷Norm9936拍；已有匹配统计的热Norm6636拍。O/Down每Tile从本核0 header握手至共同归约、残差写回、统计退休最多314拍。八核本体输入同拍到达时，该值小于416拍参考窗口；不代表任意外部断供或物理250MHz已验收。

O/Down paced TB中相邻退休最大434/850拍，包含不同Tile统计尾部的18拍相位差，不应将其当作本体每Tile服务时间。矩阵任务本身未接入该TB，不能据此宣称真实8个PCore和GCore已实现整层无停顿。

具体数值覆盖、故障恢复、真实PCore外发联动结果以本轮日志为准。旧118 DSP报告已在废弃产物清理时删除，保留的本轮报告为48,229 LUT、17,502 FF、109 DSP、152.5 BRAM36等效、4 URAM；无黑盒、0 error/0 critical warning。尚未做4ns实现或真实八核整层验收。
