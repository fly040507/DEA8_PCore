# GCore整体与PCore协同方案汇总

> 当前口径：FP32 ADD/SUB与MUL均为官方IP、每实例2DSP，延迟ADD11/MUL8。mean复用MUL0，反馈FIFO随延迟派生。冷Norm10014拍属于迁移前基线；当前RAM映射和八核完整层待服务器验收。面积见[资源口径](../docs/Resources.md)。

更新：2026-10-19。宏观接口沿用2026-10-17定义，算术/存储以下文当前口径为准。

本文与GCore RTL均位于`DEA8/Gcore`。设计名称继续沿用DEA8，不增加版本名称；PCore和层级接线见各自当前README。

当前官方IP实现的通过范围见README；历史23场景不代替新版本验收，第1/9/18层联合测试尚待服务器。先完成仿真，再分别综合GCore与一个完整PCore测资源；本阶段不综合八核、不布局布线。接口见第17节，历史OOC不是当前源码综合结果。

## 1. 范围与分工

固定M=51，隐藏维度1024，8个PCore，目标器件U50。

| 模块 | 负责 | 不负责 |
|---|---|---|
| DEA8总控 | 去噪步、18层、阶段job、跨模块依赖、参数和数据版本绑定 | GCore逐行、逐Tile算术调度 |
| PCore | 矩阵计算、内部VPU/SFU任务控制、本核结果外发 | 八核结果归约、全局层循环 |
| GCore | XBC、共享KV及KVB、八核接收归约、残差、RMSNorm、量化 | PCore内部RoPE/GELU/Softmax算术、全局去噪循环 |
| HBM及上层适配 | 权重、γ和prefix等数据的提供与地址转换 | 代替计算模块判断任务完成 |

不再保留独立的Reduce/Collective功能边界。八核O/Down直接进入GCore归约；K/V也经相同的八路物理链路进入GCore，但仅按坐标存储，不做数值相加。

初始X生成、action输出投影、去噪步更新及prefix装载，不因下面8类job成立而自动得到覆盖；须由DEA8其他模块或服务器明确承担。

## 2. 8类宏观Job

目标是DEA8发布阶段级任务，GCore内部展开服务，不要求DEA8逐Tile、逐行发命令。

| Job | 本地工作 | 前提与输出 |
|---|---|---|
| `START` | 第1层γ准备、初始X平方和、RMSNorm、量化 | 初始X已存在；产出Attention输入XHAT |
| `K` | XBC供给K Projection；同时接收、提交八核K | XHAT有效；产出完整suffix K |
| `V` | XBC供给V Projection；同时接收、提交八核V | 同一Attention输入XHAT；产出完整suffix V |
| `Q` | XBC供给Q Projection | 同一Attention输入XHAT；不接收Q结果 |
| `ATTENTION` | 按完整110子任务顺序提供KVB | 对应prefix、suffix K/V均有效 |
| `O` | 八核归约、残差、平方和、FFN前Norm及量化；触发下一组γ预取 | 旧残差有效；产出FFN输入XHAT |
| `GU` | XBC供给G-U | FFN输入XHAT有效；Gate/Up的A复用在PCore内完成 |
| `DOWN` | 八核归约、残差、平方和；非末层生成下一层Attention输入 | 末层转入输出边界，不生成不存在的第19层输入 |

`START`对应每步去噪的首层准备，不是每层都执行一次。各job内部可包含并行服务，例如K/V的XBC发送与结果接收不能被强行串行化。

上述8类宏观job由`dea8_gcore_jobs`自动展开。原`GC_NORM`、`GC_XBC_RUN`、`GC_KV_RX`、`GC_KVB_RUN`、`GC_RESIDUAL_APPLY`等服务级接口保留用于管理、单测与兼容；宏观job占用期间不接受外部服务命令，防止两套控制混用。

## 3. 单层数据流程

```text
Attention输入XHAT
  -> K/V/Q Projection
  -> PCore完成K/Q RoPE和量化，V按token方向量化
  -> K/V送GCore，Q留在PCore QOZ
  -> GCore提供prefix+suffix K/V
  -> Attention
  -> O Projection
  -> GCore八核归约 + 旧残差
  -> BF16残差R_L + 平方和统计
  -> RMSNorm(γ_ffn[L]) + 量化
  -> FFN输入XHAT
  -> G-U
  -> PCore完成GELU(Gate)×Up、量化，Z复用QOZ
  -> Down Projection
  -> GCore八核归约 + 中间残差R_L
  -> BF16残差X_(L+1) + 平方和统计
  -> 非末层RMSNorm(γ_attn[L+1]) + 量化
  -> 下一层Attention输入XHAT
```

按模型层号，同一层的`γ_attn[L]`先使用，`γ_ffn[L]`后使用。我们把下一层Attention前的Norm放在本层Down之后调度，但不改变参数归属。

## 4. γ管理

### 4.1 HBM与片上缓存

- 全部γ存HBM，10步去噪重复使用同一组模型参数，不保存10份。
- 每组1024个FP32，占4KiB；GCore两组缓存合计8KiB。
- 18层、每层两组，共144KiB；若最终Norm另有一组，则另外4KiB。
- 只使用一套γ加载接口。一次事务串行传两组，不设置两组独立加载接口。
- 沿用32bit数据通路时，一次两组共2048拍有效负载。这里的“一条线”指一条逻辑总线，不是一根物理bit线。

γ表示导出后实际参与归一化乘法的系数。参数导出需与模型中的实际参数表达对应，不能仅凭同名checkpoint张量就省略必要的变换。

### 4.2 生命周期

| 时机 | 操作 |
|---|---|
| 首次启动 | 加载第1层两组γ，使用`γ_attn[1]`完成首层Norm |
| 第L层O后处理 | 使用`γ_ffn[L]`完成Norm |
| 本层γ最后一次读取结束 | 释放第L层两组缓存有效标志 |
| G-U等计算窗口 | 通过同一接口串行加载第L+1层两组γ |
| 第L层Down之后 | 使用`γ_attn[L+1]`，生成下一层Attention输入 |
| 第18层 | 不加载不存在的第19层γ，按最终Norm归属准备参数 |

释放不等于清零RAM，更不等于全局clear。必须保留有效的RESID、SQ_ACC、KV对象及其版本信息。

隐藏γ传输需要HBM响应和带宽配合。现有RTL在O的FFN Norm结束后释放两槽并发起下一组预取；允许γ加载与GU供数、Down归约并行，但与Norm读取互斥。Down可接收归约数据，进入Norm前必须等待整笔γ事务完成。

## 5. 计算单元与精度

| 单元 | 配置 | 计算与复用 |
|---|---|---|
| 八输入加法树 | 4棵FP32树，每棵三级 | 八核归约时每拍产生4个元素；统计时复用 |
| 残差加法器 | 4路FP32 | 归约结果与旧BF16残差相加 |
| 乘法器 | 16路 | 复用完成平方、`X×inv`、中间结果`×γ` |
| 平方和统计 | 两棵树求SUM8，第三棵求SUM64 | 不另建完整统计归约阵列 |
| 行累加器 | 1路FP32 | SUM64累加到对应行SQ_ACC |
| 归一化准备 | 均值缩放、epsilon处理、单通道rsqrt | 产生51个行系数 |
| 量化单元 | 8路、流水处理 | 每16元素产生一个INT8块与8bit scale |

BF16残差输入无损扩展到FP32。归约、残差加法、乘法及统计使用FP32；残差写回时舍入为BF16。无需另做一套BF16加法器。

```text
SQ_ACC[m] = Σ_j X[m,j]^2
inv[m]    = rsqrt(SQ_ACC[m]/1024 + epsilon)
H[m,j]    = X[m,j] × inv[m]
Y[m,j]    = H[m,j] × γ[j]
```

后两次乘法共用16路乘法器，以反馈FIFO衔接，不因γ再增加16路乘法器。γ只影响最后一次归一化乘法，不参与残差加法。

## 6. 归约、残差和统计调度

一个N-Tile是`[51,16]`，共816个元素。4路归约需要204次有效发射；每行分四个quarter，完成残差加法后拼为一个256bit BF16残差字写回。

该Tile写回后扫描51行：每次读16个BF16，16路平方产生16个FP32，两棵树形成两个SUM8。

SUM8缓存逻辑规模为`[51,8] FP32`，用于保存连续四个N-Tile覆盖64列的部分和。前三个Tile为每行积累六个SUM8；第四个Tile的新两个SUM8与前六项对齐，流水进入第三棵树，形成SUM64，再累加SQ_ACC。

**第四个Tile不需要再独立扫描51行来求SUM64。** 平方、SUM8、SUM64和行累加处理不同流水中的行；树有延迟，但可连续接收输入。也不必为此强行新增51项SUM64中间缓存。

归约与统计因复用加法树，按阶段先后执行，不承诺二者同时占用同一棵树。当前官方IP服务定向回归中，Tile包头到残差、统计退休最长396拍；204次归约、51次平方输入之外仍有实际IP/读写/控制尾部。这是特定供数条件下的计时，不是任意断供下的上界，也不是完整八核隐藏验收。

## 7. 主要存储

| 存储 | 逻辑/物理组织 | 保存内容 |
|---|---|---|
| RESID | `[51,1024] BF16`，256bit向量字 | 当前残差，O/Down更新；已有实现优先URAM |
| XHAT | INT8与B16 scale，两个URAM银行，各双端口读 | Norm量化结果，重排为四行XBC响应；合计4 URAM |
| 共享KV RAM | 64个逻辑分区合并为8个owner URAM银行 | prefix与suffix，按坐标写入，直接服务KVB；合计16 URAM |
| SUM8 RAM | 有效`[51,8] FP32`，物理补齐64行 | 四个N-Tile的局部平方和 |
| SQ_ACC RAM | 51个FP32，物理补齐64项 | 每行1024元素平方和 |
| INV RAM | 51个FP32，物理补齐64项 | 每行归一化系数 |
| γ RAM | 两组1024个FP32 | 当前参数；小块预读缓存供乘法流水使用 |

共享KV RAM仍有64个逻辑分区，每分区136bit×440，prefix偏移0..407、suffix偏移408..439。物理上按owner合并成8个4096×144银行，地址为`{kind,local_feature,parity,offset[8:0]}`；每个分区保留512个地址。K/V保持逻辑隔离，不假设18层prefix都在片上常驻。XHAT为两个2048×144银行，双端口读出后仍返回四行；两类读取均为3拍RAM和8项信用/响应队列。详见[资源口径](../docs/Resources.md)。

不新增`[51,16] FP32`归约结果Tile。PCore FACC负责发送前保存结果，GCore归约后直接做残差、写RESID。XHAT被XBC读取期间不能被下一次Norm提前覆盖。

## 8. FIFO与资源口径

| FIFO | 数量、宽度与深度 | 内容 | 逻辑容量 |
|---|---|---|---:|
| 八路接收FIFO | 8个`256bit×4` | K/V/O/Down负载；Header另存保持寄存器 | 1024B |
| 残差读取浅FIFO | `300bit×4` | 256bit残差、32bit inv、12bit位置 | 150B |
| 第一次乘法反馈FIFO | `1036bit×16` | 512bit中间结果、512bit γ、12bit位置 | 2072B |
| 第二次乘法结果FIFO | `524bit×16` | 512bit结果、12bit位置 | 1048B |

以上逻辑容量合计4294B，不含其他流水、Header保持寄存器及rsqrt队列。反馈深度按 `1<<clog2(MUL_LATENCY+4)` 派生，当前为16；反馈携带对应γ，避免预读缓存切换后第二次乘法读错参数。FIFO均已改同步BRAM加小head cache，不能继续采用旧LUTRAM面积。

以下仅为2026-10-16旧后端/FIFO映射的历史报告，**不用于当前资源预算**：

| 对象 | 总LUT | 其中LUTRAM | FF | BRAM/DSP |
|---|---:|---:|---:|---|
| 八路完整接收前端、深度4，独立OOC | 2791 | 1184 | 241 | 0/0 |
| 残差读取浅FIFO，整机层级报告 | 2004 | 172 | 7 | 0/0 |
| 第一次乘法反馈FIFO，整机层级报告 | 949 | 592 | 25 | 0/0 |
| 第二次乘法结果FIFO，整机层级报告 | 1213 | 300 | 17 | 0/0 |

历史四类FIFO合计2248个LUTRAM；当前已BRAM化且反馈深度改变，旧数值不能照搬。新资源须经单GCore官方IP综合测量；不同综合边界的总LUT不能简单相加当作精确整机成本。

rsqrt包装内部结果队列逻辑深度32，已有综合使用1个RAMB36和1个RAMB18；包装中的控制及元数据逻辑不能全部算成纯FIFO成本。

## 9. 八路共享输出链路

### 9.1 物理传输

每个PCore一条256bit到GCore的独立链路，共八条。每路独立`valid/ready/last`，复用本核的接收FIFO，不再给K/V和O/Down各建一套宽入口。

| 类型 | 首拍 | 后续负载 | 一个Tile总握手拍数 |
|---|---|---|---:|
| K | Header | 51拍，每拍16个INT8及一个scale，有效136bit | 52 |
| V | Header | 64拍，有效136bit，沿token-B16组织 | 65 |
| O/Down | Header | 102拍，每拍8个FP32，有效256bit | 103 |

上述拍数只计有效握手，不含背压。O/Down一个256bit负载由4路归约分两次消费，因此102个负载对应204次归约发射。

### 9.2 身份与接收

Header在首拍，后续负载继承其身份。至少绑定任务/传输身份、源核、kind、layout、token起点、全局列起点和Tile序号；layer、step等信息可由活动传输身份关联，不能依赖到达时间猜测。

K/V八路可以独立推进，按列坐标写所属bank；O/Down必须匹配八核同一Tile、行及half后同步消费。某核先到不代表可以与其他核下一行的数据相加。

Header应检查物理端口与source_id一致、尺寸和布局正确、Tile不重复、长度及last精确匹配。实际写入KV RAM后才发Tile提交，不把收到最后一拍等同于存储完成。

## 10. K/V坐标与布局

| 对象 | 第c核负责的feature列 |
|---|---|
| K | `[16c,16c+15]`和`[128+16c,143+16c]` |
| V | `[32c,32c+15]`和`[32c+16,32c+31]` |

K每个负载对应一个token行的16个连续feature，scale沿该feature块共享。V每个负载对应一个feature的16个连续token，scale沿该token块共享。V最后一组仅token48..50有效，其余13个元素清零；**V继续使用64拍，不改为51拍。**

K/V拼接通过全局坐标落入最终KV存储完成，不另做完整拼接临时矩阵，也不做二次RoPE或重新量化。

## 11. XBC与RoPE配对

**为RoPE调整HBM侧权重的输出列顺序，不调整XBC输入X的feature顺序。**

XBC顺序：输出N-Tile -> 输入K-Tile0..63 -> 四行组0..12。每个A Tile13个beat，每拍四行、每行16个INT8及scale；最后一组row48..50有效，第四行无效。完整`xbc4_t`为563bit。

| 阶段 | 输出N-Tile数 | 逻辑XBC beat数 |
|---|---:|---:|
| K | 2 | 1664 |
| V | 2 | 1664 |
| Q | 16 | 13312 |
| G-U | 32 | 26624 |

K第c核先后取得自己的两半列，在本核完成RoPE配对。Q的一个256维head按`0..15、128..143、16..31、144..159……`取得输出，两半旋转后恢复canonical特征顺序写QOZ。

Q/K必须使用一致的真实token位置和RoPE版本。DEA8提供位置配置，不能把padding后的prefix存储长度直接当作真实位置。已经在PCore完成RoPE的K进入GCore后不再旋转。

XBC广播使用逐核pending-mask：已接受某beat的核不能重复接收；尚未接受的核看到的数据、scale和tag保持不变。G-U的下一N-Tile重放遵守八核prefetch许可，不无限提前发送。

## 12. KVB与K的逻辑转置

PCore只接收可以直接装载的B侧`[16,16]`矩阵，转置和全局取数顺序由GCore负责。通过KV bank与读地址实现K的逻辑转置，不复制整块K。

设Attention block为b，内部Tile为t，Tile内下标为i、j：

```text
QK: B[i,j] = K_rot[16b+j, 16t+i]
PV: B[i,j] = V[16b+i, 16t+j]
```

QK的一列是一个key的16个feature，取对应K scale；PV的一列是一个feature的16个token，取对应V scale。两种scale不能互换或按到达序号猜测。

完整`b2_t`为288bit，每拍两列，每Tile8拍。PCore内部再序列化为16次权重列装载，不承担K转置。

```text
QK0 -> QK1 -> PV0 -> QK2 -> PV1 -> ... -> QK54 -> PV53 -> PV54
```

共110个子任务、每子任务16个Tile、每Tile8拍，即14080个逻辑B2 beat。按握手和有限预取推进，不按定时器越过ready，不补QK55。PV53到PV54的特殊空时隙由PCore调度承担。

当前55个block包含51个prefix block和4个suffix block。padding K返回零，padding V元素清零；无效key的score仍需PCore VPU加Mask，零K不能代替Mask。

## 13. 控制与完成条件

### 13.1 上下文和资源

DEA8命令需绑定job身份、去噪步/数据代次、layer_id、对象版本、γ参数标识及位置/RoPE配置。层参数切换与残差统计身份应区分，不能通过普通全局clear换层。

GCore控制内部展开宏观job，并按资源仲裁：RESID/Norm计算存在互斥，XBC、KV接收、KVB和后台γ加载按实际端口与对象所有权协同。不能用一个全局busy无差别阻塞全部服务，导致本可隐藏的加载暴露。

接收服务必须在PCore输出前就绪。K/V job内部先准备接收、再允许供数与输出推进，不能等PCore job完成才开始接收。DEA8不因某个模块的局部done而跳过其他模块的依赖。

### 13.2 局部完成

| 完成信号 | 表示 | 不表示 |
|---|---|---|
| PCore K/V/O/Down done | 本核算术及后处理完成，所有输出可靠交接，满足发送缓冲协议 | GCore归约/Norm已完成 |
| GCore K/V done | XBC发送完成，全部K/V负载实际写入且提交完成 | 代替PCore判断其他内部活动结束 |
| GCore Q/GU done | XBC数据被全部目标核接受 | PCore矩阵及后处理结束 |
| GCore Attention done | 完整KVB供数被八核接受 | Attention算术结束 |
| GCore O/Down done | 本job包含的本地接收、计算、写回及参数事务完成 | 全局层/步完成 |

KVB供数结束后，KV仍保留引用；由DEA8在八核Attention真正完成后释放，避免过早覆盖。

### 13.3 数据可用早于Job全部完成

保留带对象版本的`xhat_ready`等持久有效状态，不能只提供一个全部完成脉冲。

O的Norm结束后，FFN XHAT已经可用，可让DEA8启动PCore G-U及GCore GU供数；与此同时，下一组γ继续加载。若γ更新属于O job，则GCore O保持未完成直到该事务结束。

控制使用一个前台槽及一个O后台γ槽，允许O剩余的γ加载与GU供数共存。O后台完成不会覆盖GU的命令身份；两份完成均保持到DEA8握手。

## 14. 冷、热Norm与统计有效性

冷/热指是否已有匹配当前残差的平方和，与温度或γ是否缓存无关。

- 冷Norm：外部提供初始X但没有匹配统计，需要先扫描3264个16元素字。
- 热Norm：O/Down接收归约与残差流程已经建立SQ_ACC，跳过独立平方和扫描。
- 热Norm仍需读完整X做归一化，并非跳过全部残差读取。
- 残差内容或版本改变后旧统计失效；仅更换γ不改变平方和。
- 当前RTL还核对context/generation，后续层切换必须明确统计身份承接，不能数学上可复用、控制上却无意失效。

若每步初始X没有随附统计，18层普通Norm为：START一次冷Norm、18次O后的热Norm、17次非末层Down后的热Norm，共36次；末尾final norm另计。若上层已提供有效统计，首次也不必强制冷扫描。

已有测试：热Norm6636拍，其中6528次向量乘法发射；冷Norm9936拍，额外3300拍对应3264次统计扫描及其尾部。这些是具体测试条件下的总时间，不含事先γ加载时间，也不是所有配置的固定常数。

## 15. 末层与仍需确认的边界

本阶段保持8类宏观job，用末层DOWN分支在GCore完成`final_norm`，输出FP32，不再量化成下一层XHAT。action projection仍属于外部边界。后续系统对接还需落实：

1. action projection接收GCore的FP32向量流；如需BF16/INT8，由边界适配处理。
2. 最后一个FP32向量实际握手后才完成DOWN，不能仅以乘法流水结束判断。
3. HBM侧γ与prefix的请求、加载完成及带宽保证。当前prefix预置假设不代表换层装载已实现或已隐藏。

首次X导入/登记、配置、取消、恢复、KV引用释放等可保留为管理接口，不必为了维持“8类”而删除必要功能；它们不等于新增矩阵阶段job。

## 16. 证据与实现状态

| 类别 | 已有证据 | 不能据此声称 |
|---|---|---|
| 资源 | RAM映射后OOC：109 DSP、29782 LUT、33198 FF、79 BRAM36等效、24 URAM | 八核联合可布通，或250MHz已签核 |
| 算术/统计 | 冷热Norm、O/Down统计及量化的既有功能仿真 | 任意外部背压下保持相同拍数 |
| 八路接收 | TB模拟八路生产者，真实接收、KV存储及KVB参与验证 | 八个真实PCore整层联调完成 |
| PCore联接 | 真实PCore输出接入单个物理端口的既有测试 | 八核全部内部VPU/SFU均已完成 |
| 宏观控制 | 已落地8类job、γ预取、数据可用状态及三类代表层仿真 | 已执行完整18层、10步去噪或真实八核联调 |

面积保留2026-10-19 RAM映射基线；服务级功能数字属于迁移前记录。当前八核联合和RAM映射功能仍待验收；没有布局布线结果。

相关文件：

- [GCore原设计说明](../Gcore/GCore_Design.md)
- [GCore共享接收与归约方案](../Gcore/GCore_Reduce_Plan.md)
- [GCore层级资源报告](../reports/resource_synth/gcore_ram_remap_20261019/utilization_hier.rpt)
- [当前资源与验证边界](../docs/Resources.md)
- [验证复现入口](../docs/Verification.md)
- [本地openpi Gemma实现](../../openpi/src/openpi/models/gemma.py)

## 17. 宏观控制的实际接口

### 17.1 配置及提交顺序

1. 预置RESID、当前层prefix RAM；`config`登记数据context/generation，`preloaded`登记对象。
2. `layer_valid/ready`提交`gcore_layer_t`，等待`layer_done`成功；请求数据在握手后可改变，GCore保留副本。
3. 首层提交`START`；中间层应已持有上一层Down生成的Attention XHAT。
4. 顺序提交K、V、Q、ATTENTION、O、GU、DOWN。O的FFN XHAT就绪后即可发GU，不必先等待O完成。
5. 完成KVB供数不释放KV；DEA8确认八核Attention算完后，通过`kv_release`释放引用。
6. 非末层Down完成后，预置下一层prefix并提交新的`layer`。不做全局clear，不改变RESID的数据context/generation，不丢弃SQ_ACC。

`layer`包含：层号1..18、当前context及四组transfer、prefix/XHAT/K/V对象ID、当前两组γ ID、下一层两组γ ID、final γ ID和epsilon。下一层`attn_gamma/ffn_gamma`必须与前层预取的`next_attn_gamma/next_ffn_gamma`一致；第18层未使用的两个next ID允许为0。γ值由HBM返回，不硬编码在RTL内。prefix登记意味着调用方已完成物理预置，不等于GCore执行了prefix DMA。

`context_id/generation`绑定本次数据代次；层号、PCore epoch、prefix/suffix版本、transfer身份放在层配置中。只换层不换数据代次，避免有效的平方和被无意失效。

### 17.2 总线与完成

| 接口 | 类型/有效位宽 | 用途 |
|---|---|---|
| `job` | `gcore_job_t`，56bit | op3、command_id16、context16、generation16、layer5 |
| `job_done` | `gcore_job_done_t`，92bit | 原Job、status4、内部执行cycles32；保持至握手 |
| `xhat_status` | `gcore_xhat_t`，71bit | 持久valid、Attention/FFN用途、层号、对象及版本，不是单拍脉冲 |
| `gamma_fetch` | `gamma_fetch_t`，102bit | token、context、generation、目标层、final标志、两个参数ID |
| `gamma_data` | `gamma_beat_t`，65bit | token32、FP32 value32、整笔事务last1 |
| `final_data` | `gcore_final_t`，578bit | Job/层身份、index12、16个FP32、last1 |

全部流接口使用独立`valid/ready`，背压时保持数据；这里列出的是逻辑字段总宽，不是HBM物理AXI总线宽度。

- 普通γ事务：param0的1024项，再param1的1024项，`last`仅在第2048项置位。GCore内部自动产生slot/index和每组last。
- final γ事务：仅param0的1024项，最后一项置`last`；不请求第19层参数。
- 参数请求保持到HBM接受；返回必须匹配token、顺序和长度，非有限值拒绝。每组最后一项写入后才发布有效。
- `final_data.index = n_tile * 51 + row`；lane i为全局列`16*n_tile+i`。共3264个向量、52224个FP32。
- K/V done同时等待XBC和16次KV commit；Q/GU done仅表示XBC交接完成；ATTENTION done仅表示KVB交接完成。
- O先完成归约/残差/FFN Norm并发布XHAT，再把γ事务转交后台槽；O done等该事务结束。
- DOWN先归约/残差，等γ可用后热Norm；第18层改为FP32输出，不覆盖XHAT。

### 17.3 本轮验收边界

`tb_gcore_layers`以第1、第9、第18层为三个独立代表场景。初始RESID和prefix由TB预置；中间/末层的初始XHAT通过真实Norm建立，属于输入准备，不假装执行了跳过的层。第1层另检查Down后普通换层保留统计、热Norm不退回冷扫描。

另有START加载中取消、Down归约中后台γ错包两类恢复场景。γ错误与包错误、内部rsqrt错误一起进入计算停止条件；失败后禁止迟到写回。清理仍需外部flush ack；已部分改写的RESID由调用方恢复合法版本，再登记和重启，不做隐含回滚。

HBM、DEA8和八核PCore边界由TB模拟；GCore接收、KV RAM/KVB、XBC、γ缓存、归约/残差/统计、真实rsqrt、Norm和量化都使用实际RTL。没有跑完整18层、10步去噪，也没有用golden直接替换GCore算术结果。

仿真入口：`run_gcore_xsim.ps1 -Test layers`；全部回归为`-Test all`。历史23场景及161941/149945/149939拍属于旧实现和外部PCore模型，不是八个真实PCore的完整层延迟。旧运行和后端综合已从本优化副本清理；当前仅保留2026-10-19 GCore RAM映射面积基线，见[资源口径](../docs/Resources.md)。没有八核联合或250MHz签核。
