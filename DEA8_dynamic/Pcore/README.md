# 动态 PCore：统一控制与 Q/K/V Projection

顶层已接入 Q/K/V 三种非空 Job，共用控制中心、Projection scheduler、ACC reader 和 Pair BUF。Q 写 QOZ；K/V 经 PCore 内部 sender 直传 GCore，等待每个 Tile 的匹配 commit 才完成。矩阵、存储、外发为真实 RTL；RoPE/量化与 GCore 接收由 TB 模拟。Attention、G-U、O/Down 的完整 Job 尚未接入，不能据此声称七 Job 已跑通。最新验证记录见文末；历史记录不能替代当前源码回归。

原动态计算核、XBC/local A加载、HBM双PC/KVB512、QOZ/PBUF模块继续保留。矩阵算术及存储为真实RTL；VPU/SFU算术不在本工程实现。

所有改动位于 `DEA8_dynamic/Pcore`。`DEA8`、独立 `DEQACC` 目录只读。

## 整体重构方案入口

[PCore整体重构方案V1](C:/Users/fly04/Desktop/VLA/DEA8_dynamic/Pcore/PCore整体重构方案_V1.md) 确定后续七Job、三mode、单控制中心、共享Pair BUF、后处理接口和内部外发。专用调度见 [Attention V1](C:/Users/fly04/Desktop/VLA/DEA8_dynamic/Pcore/Attention调度方案_V1.md)。这些是待实施方案，不代表本页计算核已经接好完整PCore。

## 计算合同

- `M=0..51`，仅使用 compact row `0..M-1`；不接收 original token 序号
- `P=ceil(M/2)`；每个 Tile 发射 P 个双行 pair，奇数 M 的末 pair 为 `01`
- `M=0`：空任务完成，不加载 B、不启动 PE、不提交 ACC；不会把 0 改成 51
- PE 不增加 M、scale、tag；仍用一个 DSP48E2 计算共享 B 的两路 INT8 乘法
- 同一 K 归约链的首 Tile `add_old=0`，后续 Tile `add_old=1`；累加顺序不重排
- 切换 M 后，新增或重用的输出区域必须先覆盖，再累加；不能把旧任务残留视为新的初始值

## 模块与存储

| 模块 | 本阶段实现 |
|---|---|
| `dea8_pe_2row.sv` | 原实现直接复用：2 个 INT8 权重 bank、DSP multiply、拆包与高半修正 |
| `dea8_mxu_2row.sv` | 256 PE、双行广播、四列/拍写口、整向量 E_STAT 装载、七级旁带 |
| `DEQACC_V1.sv` | 当前七级实现；32 lane、四算术组、一套完整 ACC、A3/C 前递；增加动态行范围保护 |
| `dea8_compute_core.sv` | 当前计算边界的执行控制：Job、bank 身份/释放、A pair 计数、RAW 间隔、真实 commit 完成 |
| `pcore_pkg.sv` | 动态行数 helper、`b4_t`、`compute_job_t`、带 M 的事务 metadata |
| `dea8_profile.sv` | 一份不可变 compact→original 行表，配置/完整提交、in_use保护、保持型同步读取 |
| `dea8_row3_store.sv` | 三个1R1W同步row bank；A queue、QOZ、PBUF复用同一原语，各有独立RAM |
| `dea8_quant_store.sv` | 参数化对象管理：完整写入、owner/version、bind、同步读信用和release；不复制payload |
| `dea8_local_memory.sv` | 一份QOZ与两代PBUF；统一管理接口，源切换等待已接受读返回全部消费 |
| `dea8_local_a_loader.sv` | 两项命令预取；三行同步读返回直接写A queue，最后一个返回被接受才形成source-consumed fence |
| `dea8_a_queue.sv` | 三slot、完整M行后READY；G/U重放2次、PV重放16次；同步双行供数与背压保持 |
| `dea8_hbm_pair.sv` | 两个深度2的PC elastic FIFO；队头身份相同才合成512-bit |
| `dea8_b_queue.sv` | 八slot；HBM四Tile/17beat、KVB两Tile/9beat；data/scale完整后READY，连续四组加载 |
| `dea8_matrix_frontend.sv` | 矩阵work级绑定：父token、work/occurrence、source/role、queue排空与真实compute完成 |
| `dea8_pcore_control.sv` | 唯一外部Job/context、七opcode解码、profile/core检查、三mode启动、completion/fault/flush |
| `dea8_projection_scheduler.sv` | 五种Projection几何、canonical Q列号、两个FACC独立owner；顶层已接Q/K/V，V逐NTile单half capture |
| `dea8_result_reader.sv` | 两项返回信用、同步ACC读、双行FP32 capture；目标接受最后一笔才释放FACC |
| `dea8_pair_buffer.sv` | 唯一两half RAM，16个row bank/half；RoPE同row两operand，V同时读取16个token bank并选两个feature；两项返回信用 |
| `dea8_projection_post.sv` | Q/K/V复用；QOZ acquire或KV返回、Pair/token、command/armed/go/done、读写完整性屏障 |
| `dea8_tile_link_pkg.sv` | 与DEA8相同的128-bit header和64-bit commit字段布局 |
| `dea8_pcore_output.sv` | 核内K/V双向量转单word；全局列坐标、顺序、mask、last检查；Job完成等待目标commit |
| `dea8_kv_tile_sender.sv` | 单个64×136-bit同步Tile RAM；填完整后发送，匹配commit后才释放 |
| `pcore_top.sv` | 纯连接顶层、全局fault握手门控；不维护第二个Job FSM、不实现非矩阵算术 |

最大存储容量不随 M 改变。M 只限制有效行、读写范围和传输次数。

| 物理数据存储 | 大小 / 位置 |
|---|---|
| PE 权重 bank A/B | 2×256×8 bit，共 512 B；每个 PE 的每个 bank 只有一个权重 |
| Q_ACT_REG | 2×16×8 bit，32 B；PE 外，两个激活行向 16 列广播 |
| E_STAT_BANK A/B | 2×16×8 bit，32 B；PE 外；group 0 写入目标 bank |
| MXU 中间结果 | PE 的两个 INT16 输出、三级中间加法树、第四级 Psum 输出寄存器 |
| MXU 旁带 `[0:6]` | 两个 A scale、16 个 B scale、mask、metadata，随有效事务推进 |
| FACC-A / FACC-B | 每套 even 26×512 bit、odd 25×512 bit；每套 3,264 B |
| OACC | even 416×512 bit、odd 400×512 bit；共 52,224 B |

ACC 总数据容量 58,752 B，不含 validity / 控制。四算术组各交换两行×四列数据，没有四份 FACC/OACC 副本。`dea8_acc_store.sv` 中当前只实例化基础 `dea8_acc_bank`，不实例化旧 store 顶层。

加载新增payload：A queue 2601 B、B queue 2176 B、两PC弹性FIFO合计128 B、B读出holding为64 B data+16 B scale。metadata、validity和物理RAM补齐另计。

本地量化payload：QOZ为32×51×136 bit，共27744 B；PBUF为2×51×136 bit，共1734 B。valid bitmap、descriptor、两项读返回FIFO、RAM同步输出寄存器和loader命令寄存器另计，不能将payload容量当作综合后的BRAM数量。

Pair声明payload为2×16×4×512 bit，共8192 B，逻辑有效数据为2×51×512 bit。每bank深度仅4，当前采用distributed RAM提示；RAM输出寄存器、两项reply FIFO与metadata另计，实际映射和时序仍需综合确认。没有另建两套RoPE/G-U缓存或整层FP32结果缓存；V的token-group服务和G-U接入尚未完成。

公共类型已删除未使用的XBC4/B2/B1、旧matrix service、嵌套post/unit描述符和11级兼容延迟。七opcode/三mode保留，G-U静态来源修正为XBC/HBM。A/B与pipeline tag新增完整父token/work身份，Tile序号为16 bit，不再模64辨认数据。

## 流水边界

| MXU | 工作 |
|---|---|
| S0 | A 写入 Q_ACT_REG；A scale、active B scale、mask/tag 同沿写旁带 0 |
| S1 | 共享 B 的 DSP packed multiply |
| S2 | 两个 INT16 乘积拆包，高半符号修正 |
| S3 | 16→8 加法树 |
| S4 | 8→4 加法树 |
| S5 | 4→2 加法树 |
| S6 | 2→1 直接写 Psum 输出寄存器；旁带 6 同时输出 |

Psum、两路 A scale、B scale 向量、mask/tag 直接接 DEQACC，不再加队列或额外 Psum 寄存级。

| DEQACC | 工作 |
|---|---|
| Q0 | 捕获 INT32 Psum / Ea / Eb / fold / key；幅值、lead、指数基值 |
| Q1 | 形成 FP32 partial；ACC 同步读由已寄存的 Q0 控制驱动 |
| A0 | old 选择：A3 最新前递、C 前递、RAM，或 `add_old=0` 的零值 |
| A1 | FP32 对齐、加减 |
| A2 | 精确 LZD 与规格化；不声称实现 LZA |
| A3 | RNE 舍入、指数与特殊值处理 |
| C | 写回 ACC，输出 commit / data / metadata / last |

若 S0 在边沿 t 接受，MXU response 在 t+6 出现，下一边沿进入 Q0，C 在 t+13 提交。核心的 `done_valid` 在最后 C 后一拍置位，并保持到 `done_ready`。这与“MXU 七级 + DEQACC 七级”一致。

## 四拍 B 加载与吞吐

`b4_t.data` 为 512 bit：四列，每列 16 个 INT8。group 0/1/2/3 分别写列 0..3 / 4..7 / 8..11 / 12..15。`b4_t.scales` 是额外的 128-bit loader 旁带，只有 group 0 有效，不等同于外部 HBM 的 512-bit beat 格式。

每拍 64 个 PE 向指定 weight bank 写一个字节。E_STAT 同 group 0 一次写完。四个 data group 完成才形成完整 bank。

- 最后 B 写拍可同沿接受下一 Tile 的首 S0；乘法在下一沿才使用新权重
- 旧 bank 在最后 S1 真实使用后释放，不能在最后 S0 就覆盖
- A queue 必须先确认整 Tile 完整；首 pair 用 `a_tile_available` / `a_tile_reserve` 预留
- Tile 内连续发射依赖预留后的 A 源连续供数；核心没有 DEQACC 逐 Tile 排空等待

理想供数、ACC 无外部占用时，验证目标和实际启动间隔为：

```text
I_tile = max(ceil(M/2), 4)
last_C - first_S0 = (tiles-1) * I_tile + (P-1) + 13
```

同地址、同 parity 的依赖事务最小间隔为四拍：Δ4 用 A3，Δ5 用 C，Δ6 及以后可读到正确 RAM 值。M≤6 时显式保底四拍；这与四拍 B loader 相容，不给每个 KTile 添加七拍排空。

此公式不是 HBM/KVB 全路径性能承诺。外部供数的 4.25/4.5 拍平均服务、同步 queue 读取、首拍准备等，应在后续加载链路联调中另计。

## Job 与外部接口

`compute_job_t` 是本阶段的计算 Job，不是 DEA8 总控七种 Job 的新替代协议：

| 控制方式 | 行为 |
|---|---|
| 普通 K 归约，`nt_per_tile=0` | 所有 Tile 写同一输出 NTile；首 Tile 覆盖/沿用初值，后续累加 |
| PV，`nt_per_tile=1` | 每 Tile 改变 nt；写 `OACC[pair*16+nt]`；是否加旧 OACC 由 Job 指定 |
| G-U，`mode=MAT_GU` | 偶 Tile Gate→FACC-A，奇 Tile Up→FACC-B；各自独立 K 归约 |

- A：`a_valid/a_ready`，343-bit `a2_t`，另带目标 B bank；包括272-bit INT8/scale payload、完整token/work、16-bit Tile序号、pair/mask，不再携带无用slot/reserved字段
- B：`b_valid/b_ready`，`b4_t`；顺序、tile 身份、group、bank owner 检查
- 结果读取：一次同步返回 even/odd 两行各 16 个 FP32；超出 M 的地址不接收，奇数末行的 odd 数据返回零
- VPU 写入：相同 32-FP32 bundle，可按 parity 写；不能写当前 M 范围外的行
- `protocol_error` sticky：非法 M Job 以 error + done 结束；非法 A/B 阻止后续传输，必须 clear 后重试
- `clear`：取消在途计算、bank/context/validity；不清大数据 RAM

ACC 外部 ready 处理 DEQACC 当拍/在途的同 bank 冲突，不等同于“该 NTile 已完成 K 归约”。后续控制器必须依据 final_k 的实际 commit 与行计数释放结果。VPU 写口当前需要该 ACC 已建立的矩阵 M 上下文；更完整的 acquire / flush / job 身份协议属于后续控制接入。

## 当前加载接口边界

`dea8_matrix_frontend`接收的是矩阵work descriptor及归一化beat，不是最终DEA8七Job接口，也不是HBM AXI控制器。

- A slot descriptor先预留，beat再写入；480-bit `a3_beat_t`包含408-bit payload以及token/work/occurrence/group/mask。最终XBC的运输接口与local loader应按A方案补齐/生成内部字段，不能把当前内部结构直接当成外部461-bit协议。
- HBM两个256-bit逻辑PC分别携带70-bit beat tag，允许skew/背压；segment地址、原始AXI burst和物理HBM控制器尚未实现。
- B packet descriptor锁定source/mode/role/block。KVB首beat低256bit存两套scale、高256bit校验当前归一化descriptor；最终kv_head/context及广播grant适配仍待接入。
- KVB本阶段只验证单核接收，不代表八核原子广播已经完成。
- Profile模块已验证，但`in_use`引用仍需由后续PCore/QOZ/输出控制接入，不声称18层生命周期已经联调。
- 目前不同matrix work仍使用compute核的IDLE/RUN/DRAIN及完整排空边界；未实现Attention V1的active+prepared、同C换Block和跨BlockB驻留保留。

## QOZ/PBUF 与 local A 路径

```text
量化写入 -> quant_store管理 -> row3 RAM
                   acquire / complete / bind
                              |
local_cmd -> 两项loader命令 -> 同步三行read / 两项返回信用
                              |
                        三槽A queue -> MXU -> DEQACC -> ACC
```

| 对象 | 物理布局与完整条件 |
|---|---|
| QOZ_Q | 独占QOZ，logical tile 0..15映射physical 0..15；全部16 Tile的前M行写完才complete |
| QOZ_O | 独占QOZ，logical tile 0..15映射physical 16..31；同样等待全部16 Tile |
| QOZ_Z | 独占QOZ，logical tile 0..31映射physical 0..31；等待全部32 Tile |
| PBUF | 两个独立generation，各一Tile；set必须等于block_id奇偶；当前代被读时可填另一代 |

Q/O/Z是同一payload RAM的三个互斥用途，不是同时驻留三份矩阵。Acquire只失效validity，不清数据RAM。重新获得对象后，小M到大M仍须把全部新有效行写齐，不能读取旧payload补齐。

对象身份包含kind、content_version、data_context、profile_id/version、head、M和block。Bind必须精确匹配完整对象；生产者和消费者分别锁定token，可以来自不同外部Job。写入和读返回还检查tile、compact row/group、mask和版本。重复写、同拍同row-bank写、超M或错token数据不产生RAM写副作用。

单拍可写最多三个不同row-bank的136-bit entry；VPU双行量化返回可只置其中两路mask。三行同步读用固定row group，尾group由M生成mask。Data和scale在同一136-bit entry中读写，不另设一份scale影子RAM。

两个manager各有两项返回信用。接受读请求前同时计入FIFO和同步RAM在途返回；消费回复才减读引用。统一端口在旧源未排空时不切QOZ/PBUF，以免返回乱序。错误锁存后停止两个manager的新事务，clear共同撤销validity与旧回复。

Local loader只缓存两项命令和计数，不缓存第二份完整A Tile。请求可以先于目标slot授予发出；数据必须等目标descriptor被A queue接受后才能写入。`local_cmd.destination`绑定父token/work/occurrence、M及重放次数；PV只读一次P Tile，再由A queue重放16次。

当前公共端口使用packed类型，按现有容量参数的总线宽度如下。valid/ready是独立控制信号，不计入payload；不是将所有字段复制到PE。

| 类型 | 位宽 | 用途 |
|---|---:|---|
| `local_object_t` | 82 | acquire/bind对象身份；生产者/消费者token另带32 bit |
| `local_write_t` | 487 | 三个136-bit entry、三行坐标/mask、写身份 |
| `local_read_t` | 79 | 消费者token、版本、tile/group、请求序号 |
| `local_response_t` | 490 | 原读身份、三行mask、408-bit data/scale |
| `local_load_cmd_t` | 117 | A slot目的描述符与源kind/set/version/tile |
| `local_release_t` | 52 | 已绑定消费者token、kind/set/version |

`source_read_closed`只表示当前work的全部源返回已写入A queue，**不是矩阵退休或对象自动释放**。还须等待算法退休屏障：PBUF等对应PV退休；QOZ_Q等QK54完成、全部Q读引用归零，在获取QOZ_O之前释放；O/Z等全部NTile矩阵结束。Attention整体done仍须等AFIN/量化及QOZ_O complete，不能先等整体done才尝试Q→O换owner。Manager的release_ready只检查owner和未结读引用，不能代替scheduler的算法屏障。M=0在矩阵入口走空分支，不acquire零行对象。

独立frontend和memory分别提供protocol_error；新顶层统一汇集错误并关闭对外握手。Q路径已把Job和QOZ存活期接到profile in_use；Attention/O/Down的跨Job绑定与release仍未接通。

## 外部 Job 与 Projection 后处理合同

`pcore_job_t`由控制中心锁存一份；scheduler/post通过共享context读取，不在每条内部命令复制完整Job。包含opcode、job_id/user_tag、core/head、data/profile、position/feature/transfer context和输入/输出内容版本。`kv_column_base0/1`为已解析的全局列坐标，不把`feature_context`这个查询键直接当列地址。CORE_ID为顶层参数。

- 一次只接一个外部Job；completion保持到DEA8接受
- 父token为generation+job_id，unit token为generation+内部command_id，另保留parent_token
- K/V固定51行并使用identity行号；其它Job使用已提交profile的M，M=0不启动矩阵、unit或QOZ对象
- 非空Attention/G-U/O/Down返回UNSUPPORTED；Q缺profile或QOZ非空返回PRECONDITION；错误核号、位置溢出或K/V布局不合法返回INVALID
- K/V不要求动态profile已提交，也不占用QOZ；已有Q/O/Z对象保持不变
- fault不修改已经有效的completion，不为已退休Job重复生成fault/cancel completion
- cancel/clear共同失效内部validity与在途返回；等待source、VPU、SFU三项flush ack后恢复，不清大payload RAM

Q主路径：

```text
外部 Q -> VALIDATE -> Projection start
  -> work 0..15: canonical 0,8,1,9,...,7,15
  -> XBC/HBM -> MXU/DEQACC -> 真实C退休
  -> 双FACC -> 有信用的ACC reader -> 唯一Pair BUF
  -> VPU command -> armed -> go -> Pair/profile读取
  -> 两canonical Tile量化返回 -> QOZ真实写入 -> unit done -> Pair释放
  -> 16个NTile已capture、8条unit命令结清、QOZ完整 -> completion
```

FACC与Pair是不同生命周期。空闲FACC即可开始下一NTile；当前Pair被unit占用时，已提交FACC可等待读出，不能阻止另一个空闲FACC计算。Pair预约移到capture之前，reader只在目标有空间时发同步读。FACC释放只看最后一个capture bundle真实被Pair接受，不等独立unit全部算完。

VPU负责人接入：

| 端口 | 权限和完成条件 |
|---|---|
| `unit_cmd_valid/ready` | 接受一条command，仅绑定任务，不允许立刻读Pair/QOZ |
| `unit_armed_valid/ready` | 回显当前command token，表示已准备 |
| `unit_go_valid/ready` | 接受go后才授权数据访问 |
| `unit_rd/unit_out_reply` | Q/K同row两个16 FP32操作数；V按group/feature-pair序号返回两个feature的16token；两项返回信用 |
| `unit_profile_*` | Q查询compact→original；K返回identity row，与动态M无关；V无RoPE，不允许此查询 |
| `unit_wr` | 与local_write_t同格式，token必须是当前unit token；一拍一个canonical Tile、最多三row-bank entry，常用双行 |
| `unit_quant` | K/V专用双向量返回，当前unit token、Tile、index、mask、token_mask、last；不能写QOZ |
| `unit_done_*` | token/function/status回显；本命令全部读返回已消费、量化结果已接受、profile回复排空，才允许成功done |

PCore将合法unit token转换为QOZ producer的parent token，数据/scale不改写。写坐标、mask、版本和重复返回均在RAM写之前检查。Data/scale/tag在停顿时一起保持。

### K/V单元扫描与外发

| Job | Pair命令 | 读请求 `row` 的含义 | 量化返回 | 外发 |
|---|---|---|---|---|
| K | 一条RoPE命令，nt0=0、nt1=1，identity_rows=1 | 0..50，两个配对feature向量 | 先Tile0的26笔，再Tile1的26笔；末mask=01 | 每Tile51个136-bit word |
| V | 每NTile一条V_QUANT命令，共两条；只capture half0 | 0..31；group=index/8，feature_pair=index%8 | 每Tile32笔双feature向量，mask=11 | 每Tile64个136-bit word |

V响应的每个向量含同一feature的16token；group3仅低3token有效，其余13项由Pair读口输出FP32零，sender再按token_mask强制INT8 padding清零。两组向量合计32个FP32，但不是两个token行。

K列坐标须16对齐，base0<128、base1=base0+128；V须16对齐且base1=base0+16，两块均在256列内。`unit_cmd.column_base0/1`将解析坐标直接交给VPU，K的RoPE频率与外发header使用同一份坐标。

Tile RAM保存`{scale[7:0],data[127:0]}`，不是`qvec16_t`内部的`{data,scale}`打包次序。GCore以header的kind/layout、tile_seq、column_base和transfer key恢复落点。真实GCore及transfer-context映射表尚未实现，当前TB验证协议和坐标，不声称已完成GCore集成。

header映射：transfer_id=`job.transfer_context`，transfer_epoch=`job.transfer_epoch`，destination_id=`job.data_context`，token_origin=0。DEA8/GCore负责将这个key绑定到目标对象/行映射；`data_context`在本接口作为目标逻辑对象号，不是RAM地址。transfer_epoch由DEA8分配，不能使用各核独立的parent generation，避免以后八核Reduce的header因局部取消/拒绝次数不同而不一致。

Pair在读引用和量化返回结清后可释放；sender另持有输出副本，等待commit。K/V外部completion必须同时满足矩阵退休、Pair命令完成及两个Tile的commit。下一Job无需用clear清理正常完成的sender；clear仅用于取消/故障恢复。

`source_context`提供同Job不变的访存context；`source_work_valid/ready`发布归一化NTile工作量。当前接口不是HBM AXI地址控制器。Q后处理只用VPU接口；SFU当前仅参加flush屏障，其算术command/workspace服务随Attention/G-U接入，不能把当前Q接口当成已完成全部VPU/SFU服务。

## 仿真入口与证据

依据 `interaction/仿真说明.docx`：每次在同一个 cmd 内先加载 `settings64.bat`，再调用官方 xvlog / xelab / xsim。独立编译库、新 snapshot、统一时间单位，含 glbl 与真实 DSP48E2 模型。

```powershell
& .\run_compute_xsim.ps1
```

本机沙箱内启动 Vivado 自带 C 编译器失败；在获准的沙箱外通过同样的官方入口运行成功。没有替换工具、改 PATH/RDI/TCL 或修改 Vivado 安装。

普通测试必须同时满足退出码 0、无 Fatal/Error、明确 PASS。RAW 负例仅允许一次指定 DUT RAW Fatal，不能拿工具启动失败或 watchdog 当通过。脚本在运行前固定源码哈希，并在运行结束再次比对。

计算核历史基线（2026-10-13，不作为本轮修改后的签核）：

- [仿真汇总](reports/simulation_summary_20261013_110839.txt)
- [源码 SHA256](reports/sources_sha256_20261013_110839.csv)

| 测试 | 覆盖 |
|---|---|
| PE | 131,072 个有符号乘积；全 INT8 A0/B 组合、A1 扫描、双 bank、clear |
| Dequant / FPADD | 各 211,978 笔，FP32 特殊值、次正规数、RNE、极端指数、clear |
| DEQACC stream | 344 个 commit；32 lane II=1；Δ4/5/6/7、奇偶独立前递、OACC、clear |
| RAW 负例 | Δ1/2/3 精确触发指定 DUT 拒绝 |
| 真实计算链路 | 71 个正常 Job，M=0..51；64 KTile、128 Gate/Up 交错 Tile、PV 多 NTile与跨 Block累加；18,560 个 Psum / FP32 commit、1,412 次 ACC 读回 |
| 协议与取消 | 在途取消后无旧输出；M>51、非法 A mask、非法 B group 三种拒绝；供数气泡、小→大/大→小 M、奇数尾行保护 |

数据由 TB 生成，但乘法、加法树、反量化、累加、ACC 读写由实际 RTL 完成。golden 独立计算 INT8 点积并使用冻结的 FP32 reference，未向 DUT 注入预期结果。

## A/B加载基线：2026-10-14 00:00

入口仍为 `run_compute_xsim.ps1`。默认O2，全部重新xvlog/xelab；源码固定后运行，结束复核hash。7个常规测试和3个精确RAW负例全部通过。

证据：[本轮汇总](C:/Users/fly04/Desktop/VLA/DEA8_dynamic/Pcore/reports/simulation_summary_20261014_000028.txt)、[源码SHA256](C:/Users/fly04/Desktop/VLA/DEA8_dynamic/Pcore/reports/sources_sha256_20261014_000028.csv)。

| 测试 | 实际证据 |
|---|---|
| Profile | 52个M配置、1326次非连续行lookup；live引用/响应保持；重复行、部分提交、非法M三项拒绝 |
| A queue | 9个slot事务、162个pair；三槽环绕，1/2/16次重放，停顿保持，row2/row3不同group正确选路 |
| 真实加载前端 | 64个work用例，M=0..51；17424个Psum和FP32 commit、1401次ACC读回；A/B占用峰值3/8，PC反压149拍 |
| 加载用途 | 64K单NTile归约、128个G/U交错微Tile单NTile、QK/PV路径及P重放16次；实际RAM数据/scale经DSP计算 |
| 前端协议 | 错A occurrence、错B role、错KVB头、两PC tag不一致四项拒绝；真实算术在途取消及正常恢复 |
| 原计算核兼容 | 71个work、18560笔Psum/commit、1412次读回，A3/C命中481/485；全M、RAW间隔、取消和三项协议拒绝 |
| PE / 算术 / DEQACC | 131072个乘积；反量化与FPADD各211978笔；344笔32-lane stream commit，Δ4/5/6/7及parity前递 |
| RAW负例 | Δ1/2/3均只触发指定DUT RAW Fatal，工具启动失败和watchdog不计通过 |

本轮修正了两处仿真问题：A queue复位前未初始化slot索引的结构体数组访问导致0ps内核异常；TB结构体返回丢失work_seq，改为显式packed-vector返回。默认O2已完成数值验证，不靠O0启动代替正确性。

取消用例等待真实issue后再clear，不把“输入发送完”当成“矩阵已启动”。脚本同时拦截FATAL_ERROR/内部断言，并仍要求明确PASS。失败日志保留为诊断历史。

`CASE FRONTEND ... total_with_reads`包含TB额外读回与done保持，不是纯matrix work时间或完整Attention周期。本轮未执行完整Q projection的16NTile、110个Attention子Job、32NTile G-U或外部七Job序列，不据此声称整PCore完成。

## 本地存储基线：2026-10-14 00:56

完整回归10项常规测试和3项精确RAW负例全部通过；默认O2、重新编译/展开，运行前后核对34个源码/脚本/filelist哈希。

证据：[最新汇总](C:/Users/fly04/Desktop/VLA/DEA8_dynamic/Pcore/reports/simulation_summary_20261014_005612.txt)、[最新源码SHA256](C:/Users/fly04/Desktop/VLA/DEA8_dynamic/Pcore/reports/sources_sha256_20261014_005612.csv)。上面的00:00记录是历史A/B基线，不是本次源码的签核。

| 新增验证 | 实际结果 |
|---|---|
| QOZ/PBUF真实RAM | M=1..51，115次对象acquire；12475笔写入、10290个读返回；不同写lane到row-bank选路、Q/O/Z复用和两代PBUF并存 |
| 存储边界 | 两项信用峰值、3312拍请求反压；部分region不能bind，未消费回复阻止release；8项非法访问拒绝，clear撤销旧回复 |
| Local loader协议 | 36个Tile、264个正常三行beat；两项命令队列环绕，授权前预取、230拍回复背压；错请求序号与取消后的旧token返回两项拒绝 |
| 本地源真实算术 | 64个正常work，QK覆盖M=0..51；PV重放16次、跨work累加、O/Down本地源；13488个Psum与FP32 commit，1785次ACC读回 |
| 本地取消/恢复 | 源读在途和PE计算在途两种取消；8494次请求=8492个消费回复+2个明确撤销读，clear后重新启动并完成数值比对 |
| 邻接回归 | 原XBC前端64个work、17424笔数值提交；独立计算核71个work、18560笔数值提交；Profile/A queue/PE/算术/DEQACC及RAWΔ1/2/3仍通过 |

TB只提供量化源fixture、B运输数据和存储管理指令，真实row3 RAM、A/B queues、DSP、加法树、反量化及ACC均由RTL执行。Fixture不向DUT写入golden Psum或ACC。独立loader负例使用协议返回模型；数值链路用真实QOZ/PBUF RAM，两者不能混为一种证据。

先前loader负例的TB源保持检查与故意篡改序号冲突，已限制为“合法返回必须保持”；错回复仍必须被DUT拒绝。原检查与全部数值检查保留，失败日志仅作诊断历史。

`CASE LOCAL ... total_with_fixture_reads`还包含整region fixture预填、TB读回和管理握手，不能作为Block周期或完整Attention时间。当前完成的是各matrix work的本地源接入，还没有110子Job、全NTile Projection/G-U、非矩阵任务或七Job联动。

本次未综合、未布局布线、未上传GitHub。旧DEA8与独立DEQACC的245个源码/脚本哈希未变。

## 历史基线：2026-10-14 统一控制与 Q Job

该时间戳的Q-only版本以默认O2重新编译/展开；14项常规测试和3项RAW负例全部通过，44个源码/脚本/filelist哈希在运行前后保持一致。这组哈希只对应当时源码，不是当前Q/K/V版本的签核。

历史证据：[完整回归汇总](C:/Users/fly04/Desktop/VLA/DEA8_dynamic/Pcore/reports/simulation_summary_20261014_094826.txt)、[源码SHA256](C:/Users/fly04/Desktop/VLA/DEA8_dynamic/Pcore/reports/sources_sha256_20261014_094826.csv)。

| 本轮新增测试 | 实际覆盖 / 边界 |
|---|---|
| 控制中心 | 18个指令案例，七opcode/三mode；K/V有效行固定51、其它取profile；6项拒绝、错done token、cancel/三方flush ack、completion背压及迟到fault不重复返回；engine退休由TB模拟，不是七Job数值验证 |
| Projection scheduler | 五种几何、Q canonical顺序、交替FACC和真实capture release；矩阵退休由协议模型提供，不是五种Projection已接通 |
| Q后处理组件 | 真实Pair/QOZ RAM、8个Pair、24个双operand回复、48笔量化写；两项读信用和command保持；7项非法unit访问拒绝，RAM validity及写计数均无副作用 |
| 完整Q | M=0/1/11/51，共33792个Psum和FP32 commit，504次非连续profile查询；每个非空Job自动发布16个矩阵work、8条RoPE/量化command；最终QOZ全部有效行的INT8/scale逐项核对 |
| 并行与对象保护 | 2800拍matrix work与post重叠，其中2667拍为真实MXU issue与post重叠；QOZ存活时拒绝覆盖及profile改写，3次重复Q返回PRECONDITION |
| 邻接回归 | 原有Profile、A queue、QOZ/PBUF、local loader、local compute、XBC frontend、PE、Dequant/FPADD、DEQACC及isolated compute全部重新通过；RAWΔ1/2/3只触发指定DUT拒绝 |

完整Q的几何为 `[M,1024]×[1024,256]`；M=51包含26624笔双行bundle。Golden独立生成INT8点积、按k顺序进行冻结FP32反量化/累加，再核对真实Pair操作数和最终QOZ payload；没有向矩阵链路注入golden Psum或ACC。

VPU代理通过实际command/armed/go、Pair/profile读返回、量化写入和done完成任务。RoPE系数、FP32乘加/RNE及MXINT8-B16量化由TB计算，**不验证真实VPU/SFU的近似精度、资源或吞吐**。代理缓存一个Pair的临时结果、按两行量化beat写回；这些TB数组不是DUT新增RAM。独立post测试的FP32 capture fixture仅用于协议检查，不代替上述数值链路。

| Q用例 | matrix work | Psum / commit | unit command | `cycles_with_done_hold` |
|---|---:|---:|---:|---:|
| M=0 | 0 | 0 | 0 | 8 |
| M=1 | 16 | 1024 | 8 | 5510 |
| M=11，STRESS | 16 | 6144 | 8 | 7719 |
| M=51 | 16 | 26624 | 8 | 27563 |

上述周期从TB提交过程开始统计，包含源代理/VPU代理、完成保持，以及非空用例随后的profile保护和重复Q拒绝检查。它不是严格的外部Job接受沿到首次completion沿，也不是理想供数的PERFORMANCE签核；后续需单独增加边沿时间戳，不能直接据此推算十步去噪时间。

本轮修复了：动态结构体选择导致全零capture descriptor，改用显式两路选择；将Pair预约从矩阵启动前移至FACC读出前，消除后处理对下一NTile的串行限制；防止故障Job在clear时重复返回cancel，以及有效completion后的迟到fault重复返回。TB的capture fixture改用显式packed-vector构造，保留全部DUT合法性和数值检查。失败日志仅作诊断历史。

本轮只修改`DEA8_dynamic/Pcore`；未综合、未布局布线、未上传。没有完整Attention/G-U或七Job联动证据。

## 尚未完成

- Q/K/V完整路径已接入；O/Down的local源绑定与FP32外发、Attention/G-U scheduler及七Job前后相连仍待实现
- QOZ/PBUF的跨Jobconsumer绑定和release、G-U final capture
- HBM segment/地址协议、KVB kv_head/context及八核原子广播适配
- 通用unit/workspace服务、内部FP发送，以及active+prepared跨work边界
- 综合、布局布线和 250 MHz 签核；仿真中的 4 ns 时钟不证明物理时序达标

下一步用同一Projection scheduler接O/Down的local源绑定、释放与独立512-bit Reduce输出，再接G-U/Attention；改造matrix work的active+prepared边界以满足跨Block隐藏。当前文件清单不导入旧wrapper、兼容scheduler或重复算术链。
