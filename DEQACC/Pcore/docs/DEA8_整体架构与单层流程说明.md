# DEA8 整体架构与单层流程说明

核对日期：2026-10-08。当前 PCore 版本仍为 DEA8 PCore。

依据：当前 `DEA8/Pcore/README.md`、`DEA8/Pcore/docs/PCore_Control_Center.md`、`DEA8/Pcore/rtl/pcore_pkg.sv`、`Reduce/README.md`、本地 openpi 模型代码。`260920_VLA_report_v2.pptx` 只作为历史整体框架参考，不能覆盖当前 RTL 与接口约定。

## 1. 先区分系统设计与已经实现的部分

| 部分 | 系统职责 | 当前状态 |
|---|---|---|
| DEA8 总控 | 管理 10 步去噪、18 层、八核任务、数据身份及跨模块屏障 | 系统职责已划分，不是当前 PCore 控制 RTL 已实现的功能 |
| GCore | 共享激活、Residual、RMSNorm、输入量化、KV 管理及广播供数 | 系统设计职责；尚未由当前单核仿真证明真实 RTL 集成 |
| PCore ×8 | 私有矩阵计算、每个 Query head 的 Attention、本地后处理控制 | DEA8 PCore 单核矩阵与七种完整 Job 控制已实现；SFU/VPU 算术由 TB 模拟 |
| Reduce | K/V 流式拼接、O/Down 八核 FP32 归约 | 独立首版 RTL 功能仿真通过，尚未连接真实八核 PCore/GCore |
| HBM 与供数适配 | 保存权重/scale、提供数据，支持缓存与搬运 | PCore 有数据接口；真实 HBM 控制器、DMA 与系统地址分配未在单核验收中实现 |

“单核七 Job 验证通过”不等于“整个 DEA8 已实现”。“接口能够接入”也不等于真实 SFU/VPU 已经达到目标吞吐。本文描述当前设计如何组成系统，并标出这些边界。

## 2. 服务器与 FPGA 的分工

目标：服务器运行 pi0 的其他部分，FPGA 承担 Action Expert 的十步去噪计算，并与服务器对接。

本地 openpi `sample_actions()` 的实际顺序是：

1. 图像与语言形成 prefix，执行一次 prefix 前向，生成各层 KV cache。
2. 初始化动作噪声 `x_t`，从 `t=1` 开始。
3. 每一步根据状态、当前动作和 timestep 形成 suffix embedding。
4. suffix 经过 Action Expert，各层 Attention 使用 prefix KV 与本步 suffix KV。
5. 输出最后 50 个动作 token 的速度 `v_t`。
6. 更新 `x_next=x_t+dt*v_t`，其中十步时 `dt=-0.1`。
7. 重复十次，得到最终动作。

固定 profile 的 suffix 为 51 个 token：1 个 state token，加 50 个 action token；hidden width 为 1024，18 层，FFN width 为 4096，8 个 Query head、1 个 KV head，每个 head 为 256 维。

**还需要系统层明确**：suffix embedding、最后的 final RMSNorm、action output projection、Euler 更新到底在服务器还是 FPGA；哪些数据一次传入、哪些逐步传入。目前七种 PCore Job 是 Transformer 层的主体，不自动涵盖上述所有边界运算。

prefix KV 在十步之间复用；suffix KV 每一步、每层重新产生。不能把十次 suffix 不断追加成越来越长的 KV 序列。

## 3. DEA8 的整体数据路径

```text
服务器：prefix KV / 输入与上下文 / 控制配置
                    |
                DEA8 总控
          配置 GCore、PCore、Reduce、供数模块
                    |
       +------------+-----------------------------+
       |                                          |
     GCore                               HBM / 权重供数适配
  X、Residual、Norm、KV                     各核私有 W + scale
       | XBC / KVB                              |
       +------------------+---------------------+
                          v
                    PCore 0..7
              本核控制 + Matrix + 本地存储
              SFU/VPU 接口，算术由各自负责人实现
                | kv_out       | reduce_out
                v              v
                       Reduce
                 K/V 坐标拼接 / O、Down 求和
                          |
                          v
                        GCore
            KV 写入 / Residual / 下一阶段共享激活
```

DEA8 总控传的是任务与数据上下文，不负责每个 PE 的逐拍动作。PCore 控制把一个外部 Job 分解成矩阵子任务、后处理命令、存储读写与输出事务。

## 4. 五个模块分别负责什么

### 4.1 DEA8 总控：系统级顺序与屏障

- 知道当前第几步去噪、第几层，选择对应权重与 prefix KV。
- 向八个 PCore 发布同一阶段、不同核身份的 Job。
- 配置 GCore 的输入、缓存对象与广播源。
- 在 K/V/O/Down 外发前配置 Reduce 的事务、目标对象与预期核任务身份。
- 跟踪八核完成、Reduce 输出完成、GCore 目标数据可读三个不同事件。
- 协调取消、异常和输入源撤销，防止旧数据进入新任务。

不能只看到八核 PCore `done` 就开始依赖全局结果的下一阶段。PCore 的 done 只保证本核约定完成；跨核归约和最终存储提交还需要独立屏障。

### 4.2 GCore：完整向量与共享状态

GCore 持有完整 `[51,1024]` 激活，而不是某个核的 256/512 维私有片段。它承担系统设计中的：

- 保存当前层输入和 Residual 原始值。
- 对完整 hidden 维度做 RMSNorm，并形成适合 XBC 的量化数据与 scale。
- 接收 Reduce 的 K/V 分块，按坐标写入 KV 目标存储。
- 管理 prefix KV 与本步 suffix KV 的逻辑拼接、Mask、位置和有效长度。
- 经 KVB 为八个 Query head 提供同一份 K/V。
- 接收 O/Down 的全局归约结果，与 Residual 相加，准备后续阶段。

GCore 的 Norm/Residual 与 PCore 内 VPU 的局部向量后处理不是同一职责。跨 1024 维的 RMSNorm 不能简单变成八个核各对局部片段独立归一化。

### 4.3 PCore：私有计算与局部控制

每核对应一个 256 维 Query head，同时承担 K/V 的 32 维 shard 和 FFN 的 512 维 shard。

PCore 不理解十步与十八层，只接收外部 Job、数据身份、位置和布局配置。当前七种 Job 都是完整逻辑任务，包含对应的本地后处理，而不是只发矩阵任务再由 DEA8 补发独立 Post Job。

### 4.4 Reduce：外部拼接与归约

- K/V：不同核产生不同输出列，按地址摆放，**不做数值加法**。
- O/Down：不同核产生同一输出元素的不同输入维贡献，逐元素 FP32 求和。
- 不做 RoPE、GELU、量化、RMSNorm、Residual。
- 不属于 PCore 内部；PCore 只负责输出合法包并响应反压。

当前 KV 路径：8 个浅输入 FIFO，经轮询仲裁输出一路。不会等完整 Tile、完整行或整张矩阵才发送。

当前 FP32 路径：8 核同序号包对齐后，32 个标量 lane 各经过八输入树归约。每 lane 为 7 个 FP32 加法节点，三层树共 224 个 FP32 加法节点；这不是 224 个 DSP 的资源结论。

### 4.5 HBM：数据源，不是计算模块

HBM 主要保存私有权重及量化 scale；系统是否还把 prefix KV 等冷数据放 HBM，由 GCore 缓存与搬运方案决定。

权重按分核方式组织：Q/K/V/Gate/Up 按输出列切分；O/Down 按输入维切分。RoPE 配对布局也需体现在权重列映射中，不能只凭物理核号默认连续列。

当前 PCore 接口接收已经解析的权重列包，不是直接包含完整 AXI/HBM 控制器。因此“HBM 供数由 TB 模拟”不能解释成真实 HBM 带宽已经验收。

## 5. 互连、载荷与握手

以下宽度均为有效载荷或明确的结构体宽度，不把元数据宽度混算成 HBM 通道位宽。

| 路径 | 方向 | 内容与粒度 | 用途 |
|---|---|---|---|
| DEA8 Job/done | DEA8 ↔ PCore | opcode、Job 身份、context、位置、布局、状态 | 系统任务控制 |
| XBC | GCore → 八核 PCore | 当前 `xbc4_t`：4 个同 Tile 行片段，每片 16INT8+8bit scale | K/V/Q/G-U 的共享 A |
| HBM 权重入口 | 权重适配 → PCore | `b2_t`：2 列，每列 16INT8+8bit scale | 五种 Projection 与 G-U 的 B |
| KVB | KV 供数适配 → 八核 PCore | K/V Tile 数据、scale、block 与有效信息 | Attention 的 B |
| kv_out | PCore → Reduce | 2×16INT8+2×8bit scale，272bit 有效载荷 | K/V 输出 |
| reduce_out | PCore → Reduce | 2×16FP32，1024bit 有效载荷 | O/Down partial |
| Reduce KV 输出 | Reduce → GCore | 272bit 有效载荷，加目标坐标 | 增量写 K/V |
| Reduce FP32 输出 | Reduce → GCore | 1024bit 有效载荷，加坐标 | 归约后的完整输出片段 |
| VPU/SFU command/done | PCore ↔ 单元 | 带 token 的命令、数量、目标和完成回显 | 非矩阵调度 |
| VPU/SFU 数据与存储口 | PCore ↔ 单元 | FP32 流、量化流、ACC 口、workspace 口 | 后处理计算与提交 |

`xbc4_t` 的量化载荷为 `4×136=544bit`，加 valid/索引等字段后当前结构体为 563bit。前端将一个四行包拆成两个 A2 包，不代表 MXU 一拍计算四行。

`b2_t` 量化载荷为 `2×136=272bit`，加字段后当前结构体为 288bit。加载侧再串行成每拍一列 `b1_t`。这是内部传输格式，不是“HBM 物理数据线就是 288bit”。

A2 FIFO 当前一项为 288bit：两行量化载荷 272bit，加 row_valid、pair、tile、slot 等字段。A2/B FIFO 深度参数当前均为 64。

所有流均使用 valid/ready：只有两者同拍有效才转移；valid=1 且 ready=0 时，数据和全部元数据必须保持。广播源还需保证八核都收到同一份数据，不能只用某一个核的 ready 决定整个广播成功；具体扇出和缓存属于系统集成适配。

Reduce 的 KV 单路最多每拍接收并送出一包。八核可以同时写各自浅 FIFO，但持续总输入超过单路吞吐后必然反压。这是当前节省缓存和接口资源的明确取舍，不是八核永不等待的网络。

## 6. 一层 Transformer 的完整计算

忽略 batch 维，输入 `X:[51,1024]`。下述是 pi0 常规 RMSNorm 路径；不要把 pi05 的 adaptive RMSNorm 调制直接套入 pi0。

### 6.1 Attention 前归一化

GCore 保存 `X`，计算 `Xn=RMSNorm(X)`，量化后通过 XBC 供给 K/V/Q。

`RMSNorm(x)=x/sqrt(mean(x²)+eps) × gamma`。本地 openpi 用 FP32 求均方与归一化，eps=1e-6；其参数存储形式是 `gamma=1+scale`。硬件导出参数时必须区分存的是 gamma 还是代码里的 scale。

Residual 需要未归一化的 X。归一化结果不能直接覆盖唯一一份原始 X。

### 6.2 K Projection 与 K 后处理

每核计算 `[51,1024]×[1024,32]`，八核合成 `[51,256]` 的单 KV head。

K 做 RoPE，再按 feature-B16 量化，送 Reduce。为保证本核独立完成 RoPE，核 c 的 32 列可映射为 `[16c..16c+15]` 与 `[128+16c..143+16c]`，两半构成 16 对。

每核两 Tile，每 Tile 26 个双行包，共 52 包；八核 416 包。Reduce 按核号、Tile、pair 和目标位置写入，而不是把八包凑成一次超宽输出。

### 6.3 V Projection 与 V 后处理

每核同样计算 `[51,1024]×[1024,32]`，输出不做 RoPE。

V 在 PV 中作为驻留 B，归约维是 token，因此当前采用 token-B16 量化与重排：一个 scale 对应同一 feature 的 16 个 token。不能把 V 的 scale 布局直接当成 K 的 feature-B16 布局。

每核每个 16-feature Tile 发 4 个 token group×8 个双 feature 包，即 32 包；两 Tile 共 64 包，八核 512 包。最后 group 只有 3 个有效 token，token_mask 为 0x0007。

### 6.4 Q Projection 与 Q 后处理

每核计算 `[51,1024]×[1024,256]`，八核组成 `[51,2048]`，正好 8 个 256 维 Query head。

Q 做本核 RoPE，再 feature-B16 量化，写本地 QOZ_Q，不经过 Reduce。Q 的 Tile 计算顺序为 `0,8,1,9,...,7,15`，方便两半配对；写回地址仍是原 feature Tile。

### 6.5 Attention

每个核用自己的 Q 和同一份全局 K/V，得到 `[51,256]` 的本 head Attention 输出。

固定容量为 55 个 KV block，每 block 16 个 token，共 880 槽。55 是当前 profile 容量，不能解释为 880 个 token 全部有效。实际 prefix/suffix 有效长度、padding 和 Attention Mask 由上下文决定。

每 block 两类矩阵：

```text
QK_b : [51,256] × [256,16] -> [51,16]
PV_b : [51,16]  × [16,256] -> [51,256]
```

QK 沿 K=256 切 16 个 Tile，累加到 FACC；PV 沿输出 N=256 切 16 个 Tile，累加到 OACC。两者都发射 `16×26=416` 次。

DEQACC 在 QK 中折入 `1/sqrt(256)=2^-4`。VPU 加 Mask，再更新当前行最大值。SFU 计算指数，VPU 求行和、更新 l，并量化 P 到 ping-pong PBUF。

在线 Softmax 对每行更新：

```text
m_new = max(m_old, max(S_b))
aa    = m_old - m_new
alpha = exp(aa)
P_b   = exp(S_b - m_new)
l_new = alpha*l_old + sum(P_b)
O_new = alpha*O_old + P_b*V_b
```

这里 P_b 是未除以 l 的概率权重；最终才做 `A_FIN=O/l`。矩阵中的 P_b 经 MXINT8 量化，故硬件结果包含这一步量化误差。

### 6.6 O Projection、跨核归约与第一条 Residual

Attention 最终量化结果写 QOZ_O。每核计算 `[51,256]×[256,1024]`，得到 `[51,1024]` FP32 partial。

八个核是把 O Projection 的 K=2048 拆成八段256，必须求和：`Y_O=sum_c(partial_c)`。不是把八份1024列拼成8192列。

每核按两个行片段×16列发送 64×26=1664 包。归约可以随完整 partial 分块逐步输出；不要求整张矩阵先完成。GCore 对已归约的片段做 `X1=X+Y_O`，维护下一阶段完整可用屏障。

### 6.7 FFN 前归一化与 G-U

GCore 计算 `Xf=RMSNorm(X1)`，量化后 XBC 广播。

每核执行两个矩阵 `[51,1024]×[1024,512]`：Gate 与 Up。八核按输出列合成逻辑4096维 FFN，但中间不需要集中存整张4096维矩阵。

本核后处理：SFU 算 `GELU(G)`，VPU 算 `Z=GELU(G)⊙U`，再产生 block scale、量化，写 QOZ_Z。Z 是本核 `[51,512]`，供本核 Down 使用。

### 6.8 Down Projection、跨核归约与第二条 Residual

每核计算 `[51,512]×[512,1024]`，得到同一输出坐标的 FP32 partial。

八核分别贡献 FFN 输入4096维中的512维，因此再次求和，GCore 做 `X_next=X1+sum_c(partialDown_c)`。

至此一层完成，X_next 成为下一层输入。18层后还有模型 final norm、输出投影与动作更新；它们不在这七种层内 Job 表中。

## 7. PCore 内部的组成

```text
DEA8 Job -> PCore Control
              | Projection / Attention / G-U Engine
              v
           Shared Matrix
 A: XBC -> A前端/FIFO/Replay 或 QOZ/PBUF读口
 B: HBM/KVB -> B前端/FIFO -> 权重bank加载
              |
              v
       MXU：16×16双行PE阵列
              | 32个INT32 Psum + scale/tag
              v
       DEQACC：反量化 + FP32累加
              | FACC / OACC
              v
 PCore Post / Workspace / QOZ Manager
              | VPU、SFU命令与数据/存储接口
              +-> kv_out / reduce_out / 本地QOZ
```

Projection、Attention、G-U 是三个调度策略，不是三套 MXU。它们复用同一个 Matrix 数据通路，区别是 A/B 来源、遍历方式、累加目标和后处理依赖。

### 7.1 MXU 与 PE

- 16×16 共256个 PE。列方向对应16个输出 feature，归约方向对应16个输入 feature。
- 每个 PE 保留两份 INT8 权重，选择 active bank；另一 bank 可以加载下一 Tile。
- Q_ACT_REG 放两行各16个INT8。每个输入 feature 的 A 广播给16个输出 PE；没有每个 PE 独立复制一份激活存储的设计要求。
- 一个 DSP48E2 通过共享 B 的打包乘法得到两行乘积，随后解包、修正高位进位，再分别送两棵加法树。
- tag 和 scale 不进入 PE；权重 scale 保存在 PE 外的 E_STAT bank，激活 scale 在旁带流水中同行。

七阶段：S0 Q_ACT_REG与旁带捕获；S1 DSP乘法；S2解包修正；S3 16→8；S4 8→4；S5 4→2；S6 2→1直接写Psum输出寄存器。旁带同步到对应输出，不额外叠加历史单行方案的流水级。

一拍输出两行×16列，即32个INT32 Psum、1024bit有效载荷。E_stream为两行各8bit，E_stat为16列各8bit，另带tag与valid。

51行用26个pair，第25个pair仅row50有效。不能拿下一Tile的row0填进这个空lane。

### 7.2 双缓冲权重如何隐藏加载

16列权重加载需要16拍；一个完整Tile的激活发射需要26拍。若下一Tile供数及时，inactive bank的16拍可藏在当前Tile的26拍里。

首Tile缺少前一个计算窗口，允许暴露加载；换bank还要确认最后一次乘法已读走旧权重，不能只看到最后A进入S0就马上覆盖。

完整Tile预约保证A的26个pair可连续发射。双缓冲只解决已有数据的重叠，不保证真实HBM、KVB或广播源永不断供。

### 7.3 DEQACC 与尺度

当前DEQACC为11级D0..D10，不再是历史五级L0..L4。阶段功能覆盖绝对值/前导位、规格化/指数、FP32打包、同步ACC读返回、分级FP32加法和提交。

当前MXINT8约定可写为 `value=q×2^(E-133)`，因此16项整数点积反量化为 `Psum×2^(E_A+E_B-266)`，QK再折入指数-4。

E是8bit块指数编码，不是任意8bit线性scale数值；不能把E直接乘到Psum上。零/异常指数和舍入边界以当前数值实现及测试约定为准。

不同K Tile的scale可能不同，因此每个Tile Psum先反量化，再FP32累加。不能把整个1024维都按同一个scale做INT32累加后只反量化一次。

### 7.4 本地存储分别放什么

| 存储 | 内容 | 逻辑容量/作用 |
|---|---|---|
| PE W bank A/B | INT8驻留权重 | 每bank 256个INT8；双缓冲 |
| E_STAT bank A/B | 16列权重指数 | 每bank 16×8bit，不进PE |
| Q_ACT_REG | 当前两行激活 | 2×16INT8 |
| A/B FIFO | 激活pair/权重列与元数据 | 消除短时供数波动、保证顺序 |
| FACC A/B | K维归约后的FP32输出Tile/Score | 每bank 51×16FP32，3264byte |
| OACC | Attention跨block的输出累计 | 51×256FP32，52224byte |
| SBUF双bank | 加Mask后的Score | 每bank 51×16FP32 |
| PBUF双bank | 量化后的未归一化P及scale | PV的A，ping-pong |
| m、aa、l、1/l | 行最大值、差值、行和、倒数 | 各51FP32 |
| alpha双bank | 两代缩放系数 | 每bank 51FP32 |
| K/Q/V Pair缓存 | RoPE两半配对与V重排 | 两组51×16FP32逻辑内容 |
| GU Pair/Replay | G/U配对及共享A复用 | 避免Gate/Up重复外部供数，支持流式后处理 |
| QOZ | Q、Attention输出O、FFN中间Z | 同一物理区域，最大51×512INT8加scale |

FACC首K Tile通过选择“不加旧值”覆盖，不需要独立ZERO存储。OACC初始化也由有效状态与运算控制保证，不要求对全RAM逐项清零才能开始。

QOZ不是三份完整缓存。生命周期是 Q写入→QK消费→释放Q→写O→O Projection消费→释放O→G-U写Z→Down消费→释放Z。最后读请求已发出不等于可释放，还必须等读响应排空。

量化数据最大容量按51×512为26112byte，feature-B16每16元素一个8bit指数，再需1632byte；这是逻辑有效容量，不等于RTL实际RAM映射与填充容量。

## 8. Attention 的控制与隐藏

启动序列为 `QK0,QK1,PV0,QK2,PV1,...,QK54,PV53,尾部时隙,PV54`。共55次QK、55次PV，不存在QK55。

QK(b+1)之后的Mask/最大值/exp/行和/量化可以利用PV(b)窗口。VPU/SFU负责人需要据接口和目标吞吐适配，PCore用完成事件推进，不把它们写死成“第N拍必完成”。

OACC_SCALE(b)必须等PV(b-1)提交。可以与不访问同一OACC写目标的QK重叠，但不能与本block PV无保护地同时读改写OACC。

P_POST先配置好接收者，SFU再流式产生P_EXP结果；不必新建完整FP32 P矩阵缓存。alpha双代只有在对应l更新和OACC缩放都消费完后才能复用。m/aa下一代覆盖也必须等前代P_EXP不再读取。

PV53到PV54之间没有下一个QK窗口，需要显式尾部余量。PV54后计算1/l，再执行A_FIN和量化写O，不能声称尾部完全隐藏。

历史独立Matrix调度验收给过body416、steady434、尾间隔867、final tail439；这些是特定供数与后处理模型的证据。当前完整控制TB串行访问存储，Attention为273292拍，不能据此直接计算真实FPGA十步性能，也不能把434拍当成所有真实单元组合必达的周期。

全Mask行需要特殊约定：m可保持负无穷，P/l/O为零，1/l对l=0返回零，避免负无穷减负无穷与除零传播NaN。当前TB覆盖该边界，真实单元仍需实现并验证。

## 9. PCore 控制怎样让 VPU/SFU 接入

外部一次接受一个完整Job；内部可同时有一个VPU命令与一个SFU命令。矩阵完成Tile、ACC提交、输入包到齐、单元完成、QOZ提交等事件共同决定下一步。

| Job/阶段 | 单元何时启动 | 单元负责什么 | 完成后谁继续 |
|---|---|---|---|
| K/Q | 两个RoPE half已计算并配对 | VPU RoPE+量化；SFU系数服务 | K外发或Q写QOZ |
| V | 一个输出Tile FP32结果可读 | VPU token方向量化与重排 | V外发 |
| QK_POST | 对应FACC完整提交，旧统计量不再被前代占用 | VPU Mask、m/aa、写SBUF | SFU指数阶段 |
| ALPHA_EXP | aa完整写入，目标alpha bank可用 | SFU exp(aa) | l更新与OACC缩放 |
| P_EXP/P_POST | SBUF/m有效，VPU接收命令已配置 | SFU exp；VPU行和、l更新、量化P | PV获得完整PBUF |
| OACC_SCALE | 前一PV提交且对应alpha有效 | VPU FP32缩放并写OACC | 当前PV |
| A_FIN | PV54提交、RECIP完成 | VPU OACC×1/l并量化 | QOZ_O提交 |
| GU_POST | 同一坐标Gate/Up配对完成 | SFU GELU；VPU逐元素乘、量化 | QOZ_Z提交 |

RoPE系数请求通过PCore校验后转发SFU系数服务，可以用ROM实现，不要求运行时三角函数电路。VPU负责cos/sin乘加，不是SFU代替VPU完成整段RoPE。

命令带token与坐标，返回在写存储或外发前检查身份、数量、mask和last。done必须表示承诺的数据全部被接受/写完，而不是仅表示算术最后一拍结束。

ACC访问口与workspace访问口分开：FACC/OACC通过ACC接口；SBUF和统计量通过mem接口；GELU/P_EXP通过function_result；量化结果通过vector_result由PCore写回。单元不能自行绕过QOZ Manager直接写RAM。

clear时VPU/SFU分别确认flush；DEA8还要撤销旧XBC/HBM/KVB输入。只清PCore内部状态不能解决系统中仍在途的旧数据。

## 10. 一层调度的系统级屏障

建议把每个阶段看成“启动条件→并行计算/流式后处理→真正可消费”，而不是只串七个名字：

1. 保存Residual X，完成Attention前Norm/量化，共享X对象可读。
2. 配置K Reduce事务，运行八核K；等K目标提交。
3. 配置V Reduce事务，运行八核V；等V目标提交。
4. 运行八核Q，等各核QOZ_Q完整；K/V与Mask/位置同时可用。
5. 运行八核Attention，等各核QOZ_O完整。
6. 配置O Reduce事务，运行八核O；边归约边写/做Residual，等完整X1可用。
7. 完成FFN前Norm/量化，运行八核G-U，等各核QOZ_Z完整。
8. 配置Down Reduce事务，运行八核Down；归约并加Residual，等X_next完整。

这是易于理解的合法层调度。未来可优化独立阶段重叠，但不能删除上述真实数据依赖。PCore一次一个外部Job也不等于内部矩阵、后处理和外发必须完全串行。

## 11. 已有证据与尚未证明的内容

2026-10-07的单核完整控制数值TB连续跑K/V/Q/Attention/O/G-U/Down，中间不clear。Q→Attention→O与G-U→Down使用真实QOZ结果，Matrix和DSP使用真实RTL模型，非矩阵算术由TB实现。

总矩阵发射265408次；Attention110个子任务。对应证据为 `DEA8/Pcore/reports/control_seven_jobs_signoff.log` 与 `control_sources_sha256.csv`。这是既有记录，本次整理未重新仿真。

Reduce的2026-10-08独立TB覆盖四类功能与异常/恢复，但输入不是来自已连接的真实八核数值整链。真实八核→Reduce→GCore仍是下一阶段集成工作。

未证明：真实HBM持续供数、XBC/KVB物理广播、实际SFU/VPU数值与吞吐、完整PCore 250MHz时序、八核资源/布线、18层十步端到端延迟、服务器传输开销。

已有DEQACC物理报告只对应其特定冻结实现，不代表整个DEA8已通过4ns。PPT中旧十步450ms、旧816拍block和旧利用率不能作为当前设计结论。

## 12. 汇报时可以用的一段总述

DEA8采用一个系统总控、一个共享GCore、八个私有PCore、一个外部Reduce和HBM供数体系。GCore负责完整激活和共享KV，PCore负责分片矩阵与局部后处理控制，Reduce负责KV拼接和输出归约。单层按K、V、Q、Attention、O、G-U、Down执行，Norm与Residual在共享侧衔接。PCore内三种调度策略复用同一双行MXU与DEQACC，Q/O/Z复用一个本地量化缓存。当前单核完整Job功能验证和独立Reduce功能验证已有证据，真实八核系统、实际SFU/VPU和十步去噪仍需集成验证。
