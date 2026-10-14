# DEA8_dynamic PCore 整体重构方案 V1

日期：2026-10-13。状态：设计方案，不是已完成 RTL。本文补齐 A/B、MXU、DEQACC、Attention 之外的控制、Projection、G-U、后处理、存储与输出方案。

保留 DEA8 的七种外部 Job、三种矩阵模式及功能边界；重新组织内部结构，不照搬旧工程的控制包装和兼容模块。V1 是文档版本，工程仍为 `DEA8_dynamic`。

## 1. 基线和完成范围

| 依据 | 本文采用的内容 |
|---|---|
| [DEA8 PCore](C:/Users/fly04/Desktop/VLA/DEA8/Pcore/README.md)及活动 RTL | 七 Job 的几何、后处理、Q/O/Z 生命周期、本核完成与全局完成的区别 |
| [A 侧 V1](C:/Users/fly04/Desktop/VLA/DEA8_dynamic/Pcore/A侧矩阵加载方案_V1.md) | compact row、三行输入、3-slot A queue、QOZ/PBUF 三 row bank |
| [B 侧 V1](C:/Users/fly04/Desktop/VLA/DEA8_dynamic/Pcore/B侧矩阵加载方案_V1.md) | HBM 两 PC 合成512 bit、KVB512、8-slot B queue、四列/拍装载 |
| [当前计算链路](C:/Users/fly04/Desktop/VLA/DEA8_dynamic/Pcore/README.md) | 双行 PE/MXU、七级 DEQACC、32 lane、同址 Δ≥4、A3/C 前递 |
| [Attention 调度 V1](C:/Users/fly04/Desktop/VLA/DEA8_dynamic/Pcore/Attention调度方案_V1.md) | 110个子 Job、启动/稳态/尾部、同C交接、SCALE提前准备与真实提交 fence |
| [DEA8 Reduce](C:/Users/fly04/Desktop/VLA/DEA8/reduce/README.md) | 八路512-bit行流、每路8项FIFO、固定FP32树、单结果Tile及commit |

优先关系：本次用户要求 → 本文的整体边界与公共合同 → 各专用 V1 方案 → 旧 DEA8 的功能参考。已有计算链路的数值定义和已验证流水不因文档整理而被改写。

覆盖旧方案中的三处过时假设：

- 数据面没有 original row_id；只有 compact row/pair。原始行序保存在 profile，由 RoPE、mask 接口和接收端查询。
- DEQACC 是当前七级带前递实现，不是11级无前递实现。
- HBM 的四 Tile group 是四个连续的 **B 调度 Tile**，不是必须四个连续 NTile；可包含 G/U、不同 k，输出列含义由 descriptor 指定。

`DEA8/`、独立 `DEQACC/` 只读。本轮不实现 SFU/VPU 算术，不修改 RTL，不仿真、不综合、不上传。

## 2. 对齐的是能力，不是复制历史文件

旧 DEA8 已有单核七 Job 仿真与独立 Reduce 基本仿真；Gcore、HBM、DEA8总控仍是边界说明，VPU/SFU 由 TB 模拟。dynamic 不能把这些证据当作新设计已通过。

| 能力 | dynamic 当前状态 | 本方案的最终目标 |
|---|---|---|
| 双行 MXU、PE、七级 DEQACC | 已有隔离计算链路和真实RTL仿真 | 保留数值/流水，接公共执行控制 |
| A/B输入、QOZ/PBUF | V1方案；完整链未接 | 三行A、512-bit B真实接收、同步RAM及预取 |
| 七 Job控制、Projection/G-U | 尚未重建 | 一个总控，三个调度器，一套矩阵链路 |
| Attention完整Job | 调度V1；尚未实现 | 55QK+55PV及实际后处理/存储接口交互 |
| K/V/O/Down外发 | 尚未重建 | PCore内部发送，沿原外部协议 |
| Reduce | 旧版独立模块，未作为dynamic验证 | 支持动态M的八核同context归约 |
| Gcore/HBM/DEA8总控 | 不声称已有完整RTL | 明确边界，以TB服务完成单核验收 |

重构不导入 `legacy/`、旧wrapper、旧scheduler或第二套DEQACC。需要的功能逐项落在下面的模块中。

## 3. 七 Job、三模式与固定几何

`M` 是动态 profile 的行数，`E` 是当前 Job 的有效行数：K/V 的 E=51，其余 E=M。令 `P=ceil(E/2)`、`R=max(4,P)`。

| 外部 Job | 模式 | A/B来源 | 单核矩阵几何 | 后处理和目的 |
|---|---|---|---|---|
| K | Projection | XBC/HBM | `[51,1024]×[1024,32]`，64K×2N | RoPE、feature-B16量化，直送Gcore |
| V | Projection | XBC/HBM | `[51,1024]×[1024,32]`，64K×2N | token-B16量化/重排，直送Gcore |
| Q | Projection | XBC/HBM | `[M,1024]×[1024,256]`，64K×16N | RoPE、feature-B16量化，写QOZ_Q |
| Attention | Attention | QOZ_Q或PBUF/KVB | QK：16K；PV：16N；各55Block | 在线Softmax、SCALE、A_FIN量化，写QOZ_O |
| O | Projection | QOZ_O/HBM | `[M,256]×[256,1024]`，16K×64N | 本核FP32 partial送Reduce |
| G-U | G-U | XBC/HBM | Gate/Up各`[M,1024]×[1024,512]`，各64K×32N | GELU(G)×U、feature-B16量化，写QOZ_Z |
| Down | Projection | QOZ_Z/HBM | `[M,512]×[512,1024]`，32K×64N | 本核FP32 partial送Reduce |

三个 mode 是算法调度类型，不是三套 PE。保留 `MAT_PROJECTION/MAT_ATTENTION/MAT_GU`，但算术只认识 A/B、scale、ACC目的、覆盖/累加及tag。

- Projection scheduler：服务 K/V/Q/O/Down，用静态 operation contract 选择几何和后处理。
- Attention scheduler：服务一个完整 Attention Job，生成冻结的110个矩阵子 Job和依赖事件。
- G-U scheduler：服务一个完整G-U Job，生成G/U交错和32个Z Tile的提交。

不对外增加 Q_POST、SCALE、GELU、KV_SEND 等新 Job；它们是对应完整 Job 的内部任务。DEA8不需管理微Tile和单元启动拍。

K/V Job即使profile M=0仍按51行运行。其余五种M=0：配置和命令合法后返回带empty标志的成功completion，不收A/B、不做算术、不外发零行Tile，也不伪造Q/O/Z内容。后续空Job同样走空分支，不等待空region。空Job不得清除其它仍存活的存储对象。

## 4. 重构后的模块组织

```text
DEA8总控: profile配置 / 七Job / completion / cancel
                              |
                       pcore_control
                  单个Job生命周期、context、fault
                      |       |       |
                 Projection Attention G-U scheduler
                      +-------+-------+
                              |
                  matrix_frontend / compute_core
                    Tile身份绑定、bank/ACC预约
                       |                 |
 XBC3 --+           A queue            B queue <-- HBM双PC
        |          3-slot/row3          8-slot  <-- KVB512
 QOZ ---+--> A loader / pair reader    B4 loader
 PBUF --+                |                 |
                         +------ MXU ------+
                                  |
                              DEQACC7
                                  |
                        一套FACC-A/B/OACC
                           |             |
                  result reader     final GU commit tap
                           |             |
                           +--> shared Pair BUF
                           |       |
              unit_service / workspace / VPU-SFU接口
                      |            |
                QOZ/PBUF写入    pcore_output
                               |           |
                         KV tile sender   FP行serializer
                               |           |
                             Gcore       Reduce -> Gcore
```

### 4.1 唯一的Job控制中心

`pcore_control` 持有一个外部Job；负责合法性、核号、profile、资源前置条件、选择mode、单元命令仲裁、故障和completion。它不再叠加旧 `control -> exec -> ctrl -> job_adapter` 的多份外部Job状态机。

可以保留一个纯连接 `pcore_top`，但它没有第二套job/busy/done计数。三个scheduler只持有本算法进度，不重复判断外部Job接受/退休。

公共矩阵 frontend 汇集A/B、预取、bank和ACC预约。只允许当前选中的scheduler驱动；因为外部Job串行，不建立三个竞争队列和通用优先级仲裁器。

控制中心的生命周期：`IDLE -> VALIDATE -> ACTIVE -> RETIRE -> COMPLETE -> IDLE`。VALIDATE锁定operation/profile并检查前置条件；ACTIVE允许矩阵、unit和output各自并行；RETIRE只等待真实未结事务；COMPLETE保持一份completion。运行中fault进入FAULT，clear后在FLUSH_WAIT等各方ack再恢复。未启动的非法Job可直接返回错误completion，不先启动算术再取消。

### 4.2 已有compute_core的收敛方向

保留当前 MXU/DEQACC 数值链。将 `dea8_compute_core` 的入口整理为active+prepared的矩阵work上下文，分离descriptor接受、source关闭、issue结束和真实C退休。保留跨work预装bank，不在每个NTile/Block完成时清整个计算系统。

不要同时实例化现有isolated core和一个“新matrix core”；当前文件的控制边界将被重构，原计算测试作为邻接回归保留。具体名字不是需要兼容的外部协议。

## 5. context、profile和descriptor

### 5.1 只在一个地方保存完整Job

外部Job最少包含：opcode、job_id、user_tag、core_id、head/data_context、profile_id/version、position/feature-layout context、transfer context。DEA8保留层数/去噪步语义，PCore不增加layer计数器。

`pcore_control` 一次锁存不可变Job。内部使用小token和用途明确的坐标，不在每个命令、数据和done中再嵌套完整Job、两套VPU/SFU描述符。

父Job token使用 `(generation,job_id)`，unit command token使用 `(generation,command_id)`，默认各字段16 bit；前者标任务，后者标该任务内的一条单元命令，不能混为同一个ID。另给矩阵work/subjob_seq和A/B occurrence_seq各16 bit。16-bit计数不能在旧事务仍存活时回绕；开始Job时检查最大工作量可表示。沿用A方案运输字段名command_id时，在源配置处明确它绑定父Job，不让单元命令号改变XBC身份。

| 描述符 | 内容 | 保存位置 |
|---|---|---|
| Job context | 完整外部Job、E、profile、operation contract | 控制中心1份 |
| Matrix work | job token、work_seq、mode、QK/PV或G/U用途、block/nt、K范围、ACC及fold | active+prepared各1份 |
| A slot | job/context版本、逻辑A切片、occurrence、E、复用次数/用途 | A queue每slot1份 |
| B slot/bank | 同Job身份、role、k/nt/block、tile occurrence、scale/data完整性 | B queue/两个驻留bank |
| Pipeline tag | 稳定的work/Tile身份、pair、nt、ACC、add_old、final_k/last、E和fold | S0..S6、DEQACC spine |
| Unit command | command token、function、元素数、输入/输出对象版本、scan order | 每unit active+prepared |
| Transfer header | 全局传输身份、目标、列坐标、rows、layout | sender/Reduce持有 |

`tile_seq` 是调度顺序；`k/nt` 是数学坐标；`slot/bank` 是物理位置。三者不可互相代替。当前计算测试中的低6-bit transport tile_idx不能成为完整工程的唯一身份。

### 5.2 profile服务

保留51×6-bit row_order、M、profile_id/version、valid bitmap和commit。配置须检查M≤51、行号范围、无重复；允许非升序。K/V使用identity profile，不受动态选择缩短。

profile在关联Job、Q/O/Z、单元返回和输出仍存活时不可改写。V1只有一个已提交动态profile，不新增多profile cache。DEA8先完成引用释放，再配置下一profile。

- Matrix/ACC/量化存储只看compact row。
- Q RoPE：`position_base+row_order[row]`；K RoPE：`position_base+row`。检查position位宽溢出。
- Mask请求引用query profile和key context；上游提供正确mask，不生成错误的compact三角mask。
- 输出接收端通过transfer context恢复compact→original映射。

### 5.3 参数与计数位宽

容量参数和运行范围分开：MAX_ROWS=51、TILE=16、ROW_LANES=2、A_ROW_BANKS=3、A_SLOTS=3、B_SLOTS=8，FP32/INT8/scale沿现有数值格式。运行E/P不改变RAM声明容量。当前DSP打包、四级树和B4分发仍约束16×16，不宣称改TILE即可支持任意阵列。

索引位宽覆盖0..N-1，完成计数位宽覆盖0..N，分别使用对应clog2；例如64个输出NTile需要6-bit索引、7-bit完成计数，32个Z Tile需要6-bit完成计数。prefix有效位由helper按E生成，不用32-bit字面量左移51位。读延迟、credit、unit流水和source服务为独立参数，不用一个统一延迟数字替代实际接口边沿。

## 6. A/B和矩阵执行公共规则

保留A/B V1的物理结构和格式，三个mode共用它们：

| 工作 | A用途 | B用途 |
|---|---|---|
| Projection | 每个k切片一次，跨nt按源重新取/replay | 每个(k,nt)一个权重Tile |
| QK | Q feature tile0..15 | 对应block的16个K转置切片 |
| PV | 一个P slot重放16次 | 对应block的16个V输出切片 |
| G-U | 一个A slot给G(k,nt)、U(k,nt)各一次 | 顺序G0,U0,G1,U1…G63,U63 |

A slot使用结束且读返回排空才释放。B queue在四组数据/scales已交给驻留bank、没有pending RAM返回后释放；PE bank另等最后S1使用完成。不要把queue slot占用延长到整个矩阵退休。

HBM source锁整个Projection/G-U Job，KVB source锁整个Attention Job；QK/PV只改变role，不在110个子Job之间flush KVB。A侧可以在旧源最后一Tile复制完成且返回排空后预取下一work。

Tile放行必须同时检查：A完整/首pair已准备、B完整/最终写拍look-ahead、身份匹配、下游完整Tile接收保证、ACC访问预约、RAW条件。启动后连续P拍，不允许DEQACC mid-Tile反压。

同址归约Δ≥4；正常内部Tile节奏R满足要求。G/U相同分支的相邻k间隔为2R，也满足。不要为每笔地址另建大型CAM：规则化counter/预约先保证，边界断言再检查；未来增加任意地址访问才扩展hazard机制。

外部访存只有数据产生/消费计数推进，不依赖估计完成时间。最大51行容量保持，runtime末行mask由E生成。

## 7. Projection：一套调度器服务五种Job

### 7.1 NTile工作组织

每个NTile按k递增归约，不改FP32累加顺序。首KTile覆盖，之后累加；最后KTile全部P笔C完成才形成 `nt_committed`。

FACC-A/B采用双bank流水：当前NTile计算，前一NTile读出/后处理/外发。bank身份由内部work次序或显式FREE选择分配，不能按canonical_nt奇偶硬选；Q的0、8两Tile都为偶数，仍必须能分别占两个bank。

```text
FREE -> COMPUTE -> COMMITTED -> READING -> FREE
```

最后数据被目标接受且读返回排空后即可释放FACC，不必等独立单元全部算完；已经进入Pair BUF、单元持有级或output holding的数据另有自己的引用。目标没有接收时，FACC仍不能复用。

只允许active+prepared下一个NTile，不缓存整层FP32结果。必要时在NTile边界等空bank，不牺牲数值/所有权换固定周期。

### 7.2 后处理触发与canonical列号

| Job | Trigger | 实际动作 | 结果提交 |
|---|---|---|---|
| K | 两个本核配对Tile都已capture | RoPE→feature-B16量化 | 两个KV Tile发送并commit |
| V | 一个NTile全K归约完成并capture | 按token分组量化/转置重排 | 每NTile64个136-bit word并commit |
| Q | 一个RoPE Tile pair都已capture | RoPE→feature-B16量化 | 两个canonical Tile写QOZ_Q |
| O/Down | 一个NTile全K归约完成 | FACC读回→512-bit行发送 | 本核该NTile最后行被Reduce接受 |

Q沿原配对计划计算canonical `0,8,1,9,…,7,15`。内部work_seq递增，写QOZ时使用canonical列号，不能按返回顺序直接存0..15。

K的两块全局列范围由权重/layout contract确定，如 `[base,base+15]` 和 `[base+128,base+143]`；RoPE frequency与KV header都据此生成，不假定本核32列连续。

O/Down没有VPU“后处理完成”的假任务；直接由结果reader和output接收触发。它们读QOZ_O/Z，完成全部源读引用后释放输入对象。为简化控制，V1在全部矩阵计算退休且源读返回排空后释放，不提前跨NTile销毁源。

### 7.3 性能口径

每NTile矩阵预约下界为 `K_tiles*R`。HBM四Tile17beat，持续平均下界为 `4.25*K_tiles`，另计segment header/真实停顿。

- 小M下Q的64K NTile：内部下界256拍，HBM数据+scale服务272拍。
- K/V的E始终为51，其64K NTile内部下界1664拍，不随动态M降为256拍；HBM数据+scale服务仍是272拍。
- O的16K NTile：内部下界64拍，HBM服务68拍。
- Down的32K NTile：内部下界128拍，HBM服务136拍。

这不是要求每个NTile一定多暴露对应拍数：queue和跨NTile预取可移走局部等待，但无法消除长期总带宽下界。报告同时列issues、loader等待、source等待、bank等待和后处理尾部，不用PE发射次数代替总周期。

## 8. G-U：独立分支累加，复用Pair BUF

每个nt有128个物理B Tile：G0,U0,…,G63,U63。A只填64次，每个slot重放两次；不新增GU replay RAM、专用XBC adapter或第二个AFIFO。

- FACC-A固定Gate，FACC-B固定Up，各自首k覆盖、后续累加。
- 最后G/U的C写回继续进入原ACC；同时将final_k真实commit的数据送入已预约的Pair BUF对应half。
- Pair BUF没有反压到正在运行的DEQACC。必须在最后G的Tile启动前确认整个结果capture位置已预留；如果上个nt尚未消费完，则在Tile启动前等，而不是丢commit。
- 下一nt可以在旧Pair后处理期间开始前63个k的G/U计算，不必等旧Z已量化才开始；到最终capture前再检查Pair可用。

Gate和Up的完成位独立计数，按前E行全部capture判断齐备，不再依赖固定pair25/末mask01。偶数M、M=1都能完成。

Pair READY后给SFU发GELU任务，VPU准备接GELU(G)与同row的U，做FP32乘法、B16 scale/量化、写QOZ_Z。不增加独立ZBUF。

G/U Pair BUF保持一行/次读取，M=51是51个行事务，不扩成双行G/U计算缓存。其1024-bit输出是同一行的两个操作数，不是32个Z结果。

推荐用返回tag关联Up：GELU返回后读取仍在Pair中的同row Up，配对后送VPU；使用小返回holding和credit即可，不在PCore另缓存整Tile Up。Pair的release等待所有Gate/Up读取与join输入被接受，不仅等待Gate请求全部发出。

SFU4的816个Gate标量输入至少204拍；一般为4E拍，不能把51个Pair行事务误报成51拍完整GELU。VPU/SFU继续流水并行，合法返回气泡由ready/credit处理。G-U的矩阵窗口很长，优先简单实现，不为了极限利用率增加多Pair Tile队列。

Z第nt的M行数据/scale全部写入形成 `z_tile_committed(nt)`；整G-U完成还要32个Z Tile全部提交、单元done结清。Pair可先释放，Z提交和Job完成不能提前。

## 9. 一套共享Pair BUF，不保留两份后处理缓存

旧设计RoPE/V的halves缓存与GU Pair BUF分开；七Job串行，没有同时占用的必要。dynamic统一一个Pair BUF，逻辑含两个 `[51,16] FP32` half：

| 使用方式 | half0 | half1 | 输出 |
|---|---|---|---|
| RoPE | 第一组配对特征 | 第二组配对特征 | 同row两路512-bit |
| G-U | Gate | Up | 同row两路512-bit |
| V_QUANT | 一个V feature Tile | 不使用 | 两个feature各16token |

为兼容V的16token并行读取，按row%16分bank：`PAIR_HALF[2][16]`，每half每bank深度4、宽512 bit。每个物理bank为1R1W。

```text
half = operand/feature half
bank = row % 16
addr = floor(row/16)
payload_capacity = 2*16*4*512 bit = 8192 B
logical_valid_payload = 2*51*512 bit = 6528 B
```

两个half必须是独立物理读bank集合。不能把它们塞进同一1R RAM再假定同拍读两个地址。两行capture写不同row bank；RoPE/GU读相同row的两个half；V读half0全部16个row bank的一个token group，并选两个feature列。

不承诺8192B会映射为特定数量BRAM/LUTRAM；实际布局和选路时序后续综合确认。省掉的是重复逻辑缓存，不能据此直接宣称具体芯片资源已节省多少。

Pair拥有type、Job/command token、canonical Tile pair、E、两个written bitmap和read refs。FREE/FILL/READY/IN_USE状态只维护一处，Post service没有第二套完整capture RAM。Attention不占用这个Pair BUF。

## 10. 存储、有效性和唯一所有者

| 物理存储 | 最大payload | 所有者 / 用途 |
|---|---:|---|
| A queue，3×51×136 | 2601 B | A frontend；完整Tile+G/U或PV replay |
| B queue，8×(256+16)B | 2176 B | B frontend；data/scales分别存，slot身份相同 |
| PE权重A/B | 512 B | bank allocator；最后S1才释放 |
| E_STAT A/B | 32 B | MXU外围；与驻留B绑定 |
| Q_ACT_REG | 32 B | MXU；唯一双行激活输入寄存器 |
| FACC-A/B | 2×3264 B | ACC owner；归约、QK或G/U |
| OACC | 52224 B | Attention矩阵 / SCALE / AFIN分阶段互斥 |
| QOZ | 27744 B | Q/O/Z一个owner，三row bank |
| PBUF两代 | 1734 B | 两个P block内容版本，三row bank |
| 共享Pair BUF | 8192 B声明容量 | RoPE/V/G-U互斥复用 |
| SBUF两代 | 6528 B | masked FP32 Score，各最多51×16 |
| m、aa、l、reciprocal | 共816 B | 每种51个FP32，一代有效状态 |
| alpha两代 | 408 B | 每代51个FP32，按block代际释放 |
| KV sender | 1088 B | 64×136-bit，等待目标commit |
| FP output holding | 128 B基准 | 两行512-bit，serializer，不是整Tile副本 |
| Reduce输入FIFO | 4096 B | 八路各8×512-bit |
| Reduce结果Tile | 3264 B | 最大51×512-bit，动态前M行 |

数字仅为payload/声明容量，不含metadata、流水寄存器、弹性级及物理RAM补齐。

### 10.1 QOZ/PBUF

QOZ按A V1：Q逻辑16Tile映射物理0..15，O映射16..31，Z32Tile映射0..31；只有一个活动owner。每Tile51-bit bitmap记录成功写入，前E行完整且data/scale已落RAM才commit。

生命周期：Q producer→Attention Q consumer→释放Q→O producer→O projection→释放O→Z producer→Down→释放Z。普通Job完成不清除供后续Job使用的对象。

QOZ、PBUF和A queue共用row3存储原语/规则，但各自有独立RAM和描述符；不把它们合并成一个任意寻址大pool。Local Loader只有一个3行读请求通道，引用随同步返回走到A slot。

PBUF两代各保存P[M,16]，生产b+1不覆盖PV(b)引用。释放要求对应PV已退休且源读引用归零；profile/E/head/block必须匹配。

### 10.2 ACC访问

FACC地址pair；OACC地址`pair*16+nt`。所有units/result reader使用 `(pair,nt)` 或物理地址，去掉动态 `/P`、`%P` 转换和重复的逻辑地址定义。

一套ACC管理维护bank的context/E和读写owner。后处理使用统一result接口，不经各scheduler层层转发RAM请求。每个读请求预留response容量；基础信用深度4，目标32FP32/拍。

DEQACC流水冲突保护与完整结果可读是两件事：bank没有当拍碰撞，不代表K归约已完成。结果reader由 `nt_committed` 授权；SCALE由前PV真实退休授权；AFIN由PV54真实退休授权。

### 10.3 workspace

保留SBUF两代、alpha两代和m/aa/l/reciprocal一代，不复制到VPU/SFU内部整套影子RAM。workspace提供两个独立逻辑服务端口，分别给VPU/SFU；相同物理对象冲突由权限/仲裁处理，不假定无限端口。

SBUF可按两行×16 FP32写入，以支持QK_POST32；SFU4按row/column-group读4Score。若落地只做单行SBUF写口，必须采用Attention V1中较慢的预算，不声称32-result写入。

统计量支持连续4/16行span+mask，不按每元素一次控制握手。相同profile/E内按版本更新，超出E的旧RAM内容不有效。默认m=-inf、l=0由valid表达，不清整块RAM。

## 11. VPU/SFU接入合同

### 11.1 只保留实际需要的功能

VPU：ROPE_QUANT、V_QUANT、GU_MUL_QUANT、QK_POST、P_POST、OACC_SCALE、AFIN_QUANT。

SFU：GELU、ALPHA_EXP、P_EXP、RECIP；RoPE系数服务独立小接口，可用ROM，不把它伪装成一个完整函数Job。

不把CAPTURE、普通FP外发、无算术的owner切换定义为VPU功能。GU分为SFU GELU和VPU乘法/量化两个内部command，但外部仍只有一个G-U Job。

元素数都按实际有效标量：RoPE pair为32E，V/GU/QK_POST/P_POST为16E，SCALE/AFIN为256E，GELU/P_EXP为16E，ALPHA/RECIP为E。V的padding不算有效元素。

### 11.2 命令和数据接口

每unit一个active加一个prepared descriptor；不要求同时运行两个算术任务。cmd接受仅绑定任务；armed表示控制、合法系数/首请求和返回容量已准备；go才授权访问依赖对象。优先保证SCALE准备能够提前，其它工作遵守同一含义，不新增深命令队列。

| 接口 | payload / 使用规则 |
|---|---|
| cmd/armed/go/done | token + function +坐标/对象版本；done回显token/function/status并与锁存命令核对，不复制完整外部Job |
| ACC读/写 | 1024-bit双行FP32 +pair/nt/mask/token；统一credit/owner保护 |
| RoPE Pair/GU join | 两路512-bit FP32，含operand_role；这是操作数，不是默认两行 |
| Gate→SFU / GELU返回 | 512-bit行向量+row/token；SFU4自行分组/组装，ready限制真实服务速率 |
| P_EXP→VPU | 128-bit FP32/拍+row/group/token，或等价有计数的组装接口 |
| 量化结果→store/output | 两个136-bit vector entry +axis/canonical tile/坐标/mask/token；feature轴表示行，V的token轴表示两列，不混用row mask |
| workspace请求/返回 | Score按row/group，统计按span/mask；禁止任意跨对象寻址 |
| RoPE系数 | row/profile、position、frequency range请求；对应16对FP32 cos/sin返回 |
| flush/ack | VPU/SFU独立确认active/prepared及旧返回已撤销 |

通道背压时data/scale/tag/last一起保持。同步RAM请求先预约返回容量。控制中心按token绑定权限，不相信unit自己声称某个目的buffer可写。

只有身份、坐标、mask、数目、顺序均合法的数据能产生写副作用。`last`不替代written bitmap/计数。命令与数据token不是profile或bank parity的别名。

### 11.3 准备、数据fence、done三种事件

- prepare不允许提前读尚由矩阵独占的OACC。
- output fence由PCore观察真实写入/数据接受形成，依赖该输出的矩阵可放行。
- unit done表示命令/返回完整结清；旧token继续保留，迟到错误仍fault。
- 整体Job完成需所有必要fence和done，不能只等矩阵issue结束。

Attention同沿 `scale_will_commit`、最大值/alpha/PBUF代际、PV53尾slot严格遵守Attention V1。其它scheduler不另写一套unit token/done checker。

## 12. 七 Job启动与最终完成屏障

| Job | 外部启动前置条件 | 后处理开始条件 | 完整Job完成条件 |
|---|---|---|---|
| K | 核/Job合法，完整51行X context，HBM source可绑定 | 两个RoPE half capture完整 | KV两个Tile目标commit；单元/输入返回排空 |
| V | 同K，使用token-B16布局 | 每NTile capture完整 | KV两个Tile各64word发送并commit；单元结清 |
| Q | profile已commit，X context正确，QOZ可acquire | 配对两half完整 | QOZ_Q16Tile各M行完整提交；unit done结清 |
| Attention | QOZ_Q已complete且profile/context/E匹配；KVB角色正确 | 由QK/PV/fence逐事件触发 | PV54→RECIP→AFIN量化，QOZ_O完整提交且所有command结清 |
| O | QOZ_O已complete且context/E匹配 | 每NTile `nt_committed` | 64个partial Tile各M行交给Reduce，输入O引用释放 |
| G-U | profile/X/HBM正确，QOZ_Z可acquire | 当前nt两个分支前M行capture完成 | Z32Tile提交，SFU/VPU返回结清 |
| Down | QOZ_Z已complete且context/E匹配 | 每NTile `nt_committed` | 64个partial Tile各M行交给Reduce，输入Z引用释放 |

无法由当前Job自产生的缺失源对象应返回PRECONDITION错误，不在单外部Job规则下无限等一个无法启动的生产者。合法HBM/XBC/KVB数据气泡可以等待，具体超时/取消由接口约定处理。

外部一次只接受一个Job；completion valid保持到DEA8接收。可以预取同Job的下一NTile/Block和内部单元command，不扩成跨外部Job乱序运行。

## 13. PCore内部外发及Reduce

### 13.1 两类payload，两条端口，不重新合成collective

`pcore_output`在PCore内部，接K/V量化结果或O/Down最终FACC读回。两条路径共享控制语义而非统一超宽payload：

- K/V：128-bit header、136-bit data、last、匹配commit；一个64×136-bit sender。
- O/Down：128-bit header、512-bit data、last；两行holding按行发出，不加整FP32 Tile BUF。
- Reduce→Gcore：一条128-bit header、一条512-bit data、last、commit。

K每Tile51word；V每Tile64word，四个token group的最后一组只有3token有效、padding填零。K/V固定51，不能随动态M缩短。

O/Down每Tile M个512-bit word，串行row计数0..M-1。header.rows=M，列坐标为nt*16。FP output holding数据被Reduce接受后才退休；读取请求发完不等于数据已经外发。

FP serializer支持末行consume与下一bundle refill同沿；result reader按可用容量预约返回，不复制旧WAIT_INPUT/SEND两段之间的强制空拍。目标无反压时连续M个行beat；同步读、header和尾部仍按实际时钟统计。返回FIFO/credit寄存器容量另计，不藏成第二个完整FP32 Tile。

### 13.2 数据识别

保留当前128-bit `tile_header_t` 的transfer_id/epoch、destination_id、token_origin、column_base、rows、kind、layout、source_id、tile_seq。K列可能非连续，以两Tile各自column_base说明；V按feature shard布局说明。

非连续行不靠token_origin+row恢复；DEA8/Gcore在传输开始前建立不可变 `transfer context -> profile/version/row_order` 映射。PCore、八核Reduce和Gcore共享这个解释，原始行表不随每行重复传。

同一transfer key不得在旧sender/Reduce/commit仍存活时改映射。当前没有真实Gcore接口实现，此查询合同必须在后续接入时落实，不能把128-bit header本身当成已携带全部行映射。

### 13.3 动态Reduce

沿用八路各8项512-bit FIFO、16-lane固定八输入FP32树、单51行结果Tile。不在接收侧复制八个完整Tile，不因M动态新增双结果Tile。

八header除source_id外必须相同，尤其transfer context/profile对应关系、M、kind、nt/column_base。八路同一个compact row都存在才归约；每路独立accepted-row计数恢复顺序。

树仍按 `(0+1),(2+3),(4+5),(6+7)` → 两组 → 最终求和，golden使用同顺序。动态只改变输入/结果/send行数和last，树速率不变。

结果前M行全部写入后发header和M行，等待Gcore commit再释放。COLLECT/SEND/WAIT_COMMIT期间不接下一Tile是V1保留的简单边界。

O最小NTile矩阵窗口64内部拍、HBM持续服务68拍；小M时Reduce收集/树尾/发送/commit的固定开销可能占较大比例。是否完全隐藏取决于真实树延迟、核间差异和Gcore commit，不能只比M与64。接收反压由FACC和两行holding承受，bank复用受控，不以溢出换隐藏。

PCore本核done只证明partial已交给Reduce。八核归约结果的Gcore commit由DEA8总控另设全局屏障；不把Reduce内部done回接成PCore第八种Job。

## 14. fault、clear与对象释放

一个FAULT出口统一收集源格式、context、非法unit返回、early done、存储权限和输出错误。错误在写RAM/输出前拦截，已经有效的completion保持不被后来的错误改写。

明确三个不同动作：

| 动作 | 影响 |
|---|---|
| 普通Tile/work退休 | 释放相关slot/bank/ref，不清ACC或QOZ有效对象 |
| 普通外部Job退休 | 结束source lock、command token、临时buffer；持久Q/O/Z按生命周期保留 |
| cancel/clear | 撤销整个Job和prepared工作，失效generation/valid，等待unit和外部源flush完成 |

不使用“每次adapter切换operation_clear”去清DEQACC/QOZ。数据RAM不大范围清零，只清有效状态/预约/未结事务。

输入采用generation/occurrence绑定，仍要求源在flush后停止旧流。迟到旧返回可丢弃但不得写新对象；错误context返回进入fault。job_ready在两unit、A/B返回与外发flush均结清后恢复。

profile和transfer context的复用也要等上述引用解除；只增加一位DEQACC局部generation不能替代外部完整事务隔离。

## 15. 拟议主路径模块清单

这是后续实现的职责划分，不是现在已存在的filelist。简单的局部功能可放在同文件，避免为了列表数量增加层级。

| 模块/职责 | 计划 |
|---|---|
| `pcore_pkg` / control与link公共类型 | 保留七opcode/三mode；去嵌套整Job、早期unused枚举、旧transport类型 |
| `pcore_top` | 纯连接；不维护第二个Job FSM |
| `pcore_control` | 唯一外部Job生命周期、profile引用、completion/fault/flush |
| `projection_scheduler` | 一个实现服务五种projection |
| `attention_scheduler` | active/prepared、110子Job、非矩阵依赖和尾slot |
| `gu_scheduler` | G/U交错、复用A、finalcapture及Z退休 |
| `matrix_frontend` / 当前`dea8_compute_core` | 三mode共用；A/B身份、预取、bank/ACC预约、issue/retire |
| `a_frontend` | XBC3/local loader、3-slot/row3、同步pair reader；无GU专用副本 |
| `b_frontend` | 双PC配对/KVB、8-slot、B4 loader；source锁及slot/bank分开释放 |
| PE/MXU/七级DEQACC和ACC | 已有算术继续使用；补控制token/owner边界而非再建算术版本 |
| `qoz_manager` + `pbuf_manager` + `row3_store` | 一个公共RAM原语，不复制不同数据布局的store |
| `pair_buffer` | 唯一两half缓存，RoPE/V/GU共享 |
| `unit_service` | VPU/SFU命令、prepare/go、token/credit/访问校验；不实现算术 |
| `workspace` | 一份S/m/aa/l/alpha/reciprocal，动态有效范围 |
| `result_reader` | 公共FACC/OACC访问和retirement；不在三scheduler各写一份 |
| `pcore_output` / KV sender | PCore内部；136/512-bit两条路径 |
| dynamic Reduce | 单独目录；原树+动态M协议，不叫collective |

不迁入旧 `dea8_attention_scheduler_v4`、早期scheduler、GU scheduler+adapter双份、GU replay/XBC专用链、B2→B1 serializer、旧11级DEQACC及timing shell。旧文件留在DEA8作参考，dynamic主filelist只收活动实现与必要基础原语。

层级整理不删除协议检查、pipeline tag、validity、必要credit和所有权；这些是正确性，不是冗余。

## 16. 仿真目标和实施顺序

### 16.1 七Job应有计数

令动态P=ceil(M/2)。数值TB中的合法矩阵bundle数量：

| Job | MXU issue / DEQACC commit |
|---|---:|
| K / V | 各3328 |
| Q | 1024P |
| Attention | 1760P |
| O | 1024P |
| G-U | 4096P |
| Down | 2048P |
| 七Job合计 | `6656+9952P`，M=51为265408 |

M=0只执行K/V的6656笔，其余空Job仍各有合法completion。上述是计数，不是总周期；每笔有最多32个FP32有效结果，奇数尾mask要独立验证。

### 16.2 要对齐DEA8的验收能力

1. 先接真实A/B RAM、queues和同步返回，用当前MXU/DEQACC数值scoreboard验证全M、四拍loader和Δ4。
2. 完成公共context/QOZ/PBUF及Projection；先Q `[M,1024]×[1024,256]`，再K/V/O/Down及canonical列号/后处理。
3. 完成共享Pair BUF和G-U，SFU/VPU由TB做真实数据/存储握手，验证GELU×Up/量化Z及下一nt重叠。
4. 完成Attention V1，用真实矩阵/存储和并行VPU32/SFU4 agent，验证110子Job、所有M、SCALE真实RAM写回及总Job周期。
5. 同一PCore无clear跑K→V→Q→Attention→O→G-U→Down，Q/O/Z真实前后相连；另用fixture隔离各Job，避免只测联动而漏前置条件。
6. 补protocol/negative/cancel/flush、迟到返回、末拍停顿和多seed压力；不删旧有效检查来达性能目标。
7. 动态Reduce独立全M/错context/背压/commit测试，随后八个PCore联调；未联调前不声称全局完成。

TB模拟DEA8/Gcore、XBC、HBM、KVB、VPU/SFU，不向DUT注入golden Psum/ACC。非矩阵吞吐依接口限速，GU的两操作数口不能误作32-result口；真实RAM写入和接受形成fence。

FUNCTIONAL核对FP32操作顺序、MXINT8-B16格式和位级结果；PERFORMANCE采用无人工断供但有限端口/真实流水的模型；STRESS允许合法停顿，只检查正确性并记录原因。总Job、首拍、稳态、尾部独立统计。

仿真按 [interaction仿真说明](C:/Users/fly04/Desktop/VLA/interaction/仿真说明.docx) 使用官方Vivado环境、独立编译库、PASS/Fatal/源码hash检查。4ns仿真时钟不等于250MHz物理时序通过。

## 17. 本轮结论

剩余设计收敛为：七种完整外部Job、三个算法scheduler、一个控制中心、一条矩阵算术链、一份共享Pair BUF、一套公共unit/ACC/workspace接口、PCore内部两类外发。

当前已验证部分仍只是动态计算核；本文与Attention V1是下一阶段实现合同。尚未证明完整七Job、动态Reduce、多核HBM/KVB实际带宽、真实VPU/SFU算术或综合/P&R时序。下一步先完成公共context与A/B存储连接，再按第16节逐层接入，不一次复制整个DEA8 RTL目录。
