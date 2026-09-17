# Q Projection 端到端实现与验收边界

> 本页保留初版功能设计记录。A侧单pair、等待commit释放及87473拍已被后续优化替代；
> 当前双Bank与55956拍结果见 [A双缓冲与调度验收](Projection_A双缓冲与调度验收_20260917.md)。
> 算术、后处理与GCore重放契约未改变。

## 1. 本轮目标

在真实RTL中完成 `[51,1024] × [1024,256]`，包括INT8矩阵乘法、逐K Tile反量化、FP32归约、
实际FACC读回、VPU测试壳量化和QOZ同步写回；同时重新运行原有55个KV Block的Attention测试。
最新《AI工具意见.docx》SHA256为`6498667EA062931AE3CADE5F1F62916FE10FFF8017A122EDA1B3971D15CFAE80`。

这里的“正确”是对给定MXINT8输入和冻结的FP32运算次序逐项验证，不是证明所有输入、真实pi0任务精度或FPGA时序均已签核。
当前Projection和Attention是两个独立执行入口，尚未合成复用同一组MXU/存储的完整PCore Top。
本轮不修改其他同学的真实GCore、VPU、SFU或HBM控制器。

## 2. 模块与责任

| 内容 | 实现 |
| --- | --- |
| Projection启动、nt/kt/row调度、归约完成屏障 | `dea8_projection_engine.sv`，可综合RTL |
| XBC双块接收、配对存储、校验、同步读取 | `dea8_projection_xpair.sv`，可综合RTL |
| HBM行转列、W FIFO、双Weight Bank加载 | 现有W_Loader真实RTL，接入同步clear |
| 256个PE、INT32 Psum、scale/tag对齐 | 现有MXU，新增同步clear有效位 |
| 反量化、FP32累加、实际存储提交 | 现有DEQACC及Accumulator Fabric |
| FACC读取、结果量化、返回上下文 | `tb/stubs/dea8_projection_vpu_stub.sv`，仅仿真 |
| QOZ数据与scale写入、完成、同步读回 | Projection控制器及实际`dea8_qoz_buffer` |
| HBM/GCore供数 | TB按外部valid/ready端口发送；不直接写PE/FACC/QOZ内部数组 |
| SFU | 纯线性Projection不需要EXP/倒数；Attention测试才调用SFU数学行为模型 |
| 参考答案 | 独立Python整数点积、FP32位精确模型、整数MXINT8量化 |

Projection测试壳只做线性输出的MXINT8量化，不执行RoPE或bias，也不把`VPU_ROPE_Q`当作已经实现。
正式Q可能还需RoPE等模型规定的后处理；这轮验收不能替代该步骤。

## 3. 计算顺序

令输入为A、权重为W、输出为Y。当前常量M=51，K=1024，N=256，Tile=16。

```text
for nt = 0..15:              16个输出列块
    for kt = 0..63:          64个归约块
        加载W[16*kt:16*kt+16, 16*nt:16*nt+16]
        for row = 0..50:
            Psum[n] = sum(k=0..15, A_INT8[row,16*kt+k] * W_INT8[16*kt+k,16*nt+n])
            partial[n] = FP32_RNE(Psum[n] * 2**(E_A[row,kt]+E_W[nt,kt,n]-266))
            FACC[row,n] = partial[n]                         if kt==0
                          FP32_RNE(FACC[row,n]+partial[n])   otherwise
    等待kt63、row50的最后一次真实L4 commit
    发出本nt的VPU量化命令
    读取51个FACC向量，量化后写QOZ[row][nt]与E_QOZ[row][nt]
    确认51次写入和VPU done，才复用FACC计算下一nt
全部16个nt完成后，产生Projection done
```

Projection的`exp_fold=0`，不能误用Attention QK的`-4`。
Psum在每个16元素K组内为INT32；不同K组的scale可能不同，因此不能把64个INT32 Psum先直接相加再统一反量化。
本次参考模型与RTL均遵守“每组先反量化、再依次FP32累加”的顺序。

- Weight Tile数：`16×64=1024`。
- MXU输入/Psum/DEQACC归约向量数：`16×64×51=52224`。
- 每向量16lane，共835584个中间标量结果。
- INT8乘法总数：`51×1024×256=13369344`。
- 最终FP32/QOZ向量数：`16×51=816`，覆盖13056个输出元素。

## 4. A侧缓冲与GCore契约

为避免直接增加一份完整 `[51,1024]` XHAT缓存，本轮采用一份双K块输入缓冲：

```text
XBC一拍: {row上的kt偶数块16个INT8, 相邻kt奇数块16个INT8} + 2个scale
       -> DATA[2][51] x 128bit
       -> SCALE[2][51] x 8bit
       -> 收齐51行后计算偶数kt的51行，再计算奇数kt的51行
       -> 等待这一对K块归约提交完成，释放并接收下一对
```

有效容量为`2×51×(128+8)=13872bit=1734字节`；数据和scale使用不同物理数组、相同地址。
没有额外的完整XHAT RAM，也没有在QOZ中放1024维输入。
这是Projection执行入口的成对暂存，不是W侧“双Tile重排”；HBM W重排仍为原来的单Tile。

GCore测试源按`nt -> pair(0,2,...,62) -> row(0..50)`重放输入。
`xbc_blk`是每beat低半部分的K块编号；高半部分为`xbc_blk+1`。
`xbc_last`在每轮XHAT重放的pair62、row50置1，整个Projection共16次。
256bit接口、两组8bit scale和原有row/block/mask/epoch字段不改变；本轮shape全部lane有效。
51行收齐后才允许MXU发射，保证Tile内部51拍不因XBC断供而停顿；缺数只能在填充/Tile边界等待。

**这一实现要求GCore为16个nt重放16遍XHAT。这个要求是本轮测试集成契约，不等于真实GCore已经同意或实现。**
若真实GCore只能广播一次，应增加/复用完整X缓存，或重新安排输出累加存储与循环次序，不能直接把本TB接法当作系统冻结。
本版本优先正确性，接收下一对A块与当前计算没有重叠；后续可评估双份A-pair缓冲，但不是本次功能验收的前提。

## 5. HBM与W侧

HBM发送顺序为`nt -> kt -> beat0..8`，共9216个256bit握手。
前8beat为16行Weight，第9beat低128bit为16个列scale，剩余高128bit忽略。
每个Weight输出列的scale沿真实K维16个元素共享。
Assembler收齐后排出16列到64×136bit W FIFO，再经双Bank加载到PE。
`hbm_valid=1 && hbm_ready=0`时上游必须保持当前beat。
没有HBM地址生成或实际HBM控制器，TB只提供数据通道；本模块没有宣称完成HBM总线主机。

本轮改动：

1. W_Loader及Stationary Loader增加同步clear，清空Assembler/FIFO计数、Bank状态和加载索引。
2. 每次Projection job接受时自动清W路径；接收量达到本任务9216beat后不再接受额外beat。
3. W FIFO配置小于16项在仿真初始化时明确报错，不再无声等待整Tile而死锁。
4. 全局历史参数改名`LEGACY_WFIFO_DATA_DEPTH/SCALE_DEPTH`；当前主链仍是64项配对FIFO。
5. 单Tile仍每25拍完成接收/排出服务；需要HBM背压，并非无限全速接收。

## 6. VPU量化及QOZ

命令描述符`projection_post_job_t`含head、epoch、nt；这是PCore内部Projection客户端契约，不更改GCore VOP编码。
FP32输入经FACC同步读端口传给测试壳，16个FP32组成512bit。
读响应固定一拍且不可背压，客户端发出读取前必须预留接收空间；本次stub一次只有一个读请求在途。
结果描述符`projection_q_result_t`包含原命令、row、128bit INT8数据、8bit scale和last。
返回数据只能按row0..50依序写入，同一个nt的完成命令必须在全部51条结果被接受之后发出。
FP32输入来自实际归约结果；stub没有golden文件入口，也没有绕过DUT写QOZ。

本次有限FP32测试输入的量化规则：

- 数值解释：`x_hat = q * 2**(E-133)`。
- 16lane共享一个E，选择0..254范围内满足`max(abs(x)) <= 127*2**(E-133)`的最小E。
- 全零块E=0；采用RNE舍入，最后夹紧到signed INT8范围。
- 非有限输入在测试壳报错，NaN/Inf正式处理规则仍需VPU同学确认。
- E=255不作为正常数值scale使用。

该规则是本轮可复现的测试契约，正式VPU选scale、舍入、饱和、RoPE顺序均需一起确认后替换测试壳。
不能把浮点矩阵直接宣称“原样写入QOZ”，因为QOZ本来存INT8和共享scale。

写回地址：`addr=row*QOZ_TILES+nt = row*32+nt`。
Q使用每行tile_idx0..15，不是连续平铺的row*16+nt；每行16..31不属于本轮Q结果有效区域。
只有全部816次写入及最终post_done完成，`qoz_valid`才置1。
外部读取必须只访问有效Q地址；`qoz_valid`不是整个Q/O/Z容量都已初始化的标志。
job_done采用valid/ready保持协议，等待下游接受；后续读取走实际QOZ同步RAM端口，同时返回对应scale。

## 7. clear和错误恢复

不能只清FIFO而让旧MXU/DEQACC事务继续写回。
Projection clear在采样时执行：

```text
屏蔽HBM/XBC/结果握手和所有存储写入
  -> 清W FIFO/Assembler/Bank状态
  -> 清A-pair有效计数
  -> 清MXU输入与旁带有效位、行连续性计数
  -> 撤销qoz_valid与Projection完成状态
  -> 等待PIPE_DRAIN+2 = 13拍，丢弃旧DEQACC事务
  -> 回到IDLE，允许新任务
```

没有将clear拼接成异步rst_n；数据RAM和PE旧数值无需逐项清零，重新加载与有效位负责隔离旧数据。
外部HBM/GCore/VPU测试源在clear时一起取消原事务，新任务必须从beat0/pair0/row0重新开始。
VPU结果的head/epoch/nt、row、last与预期不符会拒绝并锁存错误；XBC也检查上下文、顺序、mask及last。
同epoch的未完成旧客户端不得在下一任务中继续回传；需要系统端取消与epoch管理配合。

## 8. 实际存储边界

| 存储 | 本轮Projection用途 |
| --- | --- |
| A-pair data/scale | 1734字节有效内容，2个K块各51行 |
| W Tile Assembler | 272字节有效内容 |
| W B FIFO | 64×136bit，1088字节逻辑容量，另有缓存队首寄存器 |
| PE Weight A/B | 共512个INT8；沿用现有阵列 |
| E_STAT A/B及ACTIVE | PE外的scale Bank及当前激活副本 |
| FACC_A | 51×16 FP32，3264字节，按nt复用 |
| QOZ | 实际模块容量51×32×128bit + 51×32×8bit；Q使用其中一半 |

当前执行入口复用`dea8_accumulator_fabric`，模块声明还包含FACC_B/OACC，但Projection不访问它们。
不能将此表当作全Projection综合后的物理资源报告；最终应在共享PCore Top确定存储实例及优化结果。
新Projection模块没有与Attention的FACC/QOZ自动物理合并，也没有实现CNET。

## 9. W_Loader OOC结果

本轮对完整`dea8_w_loader`执行了Vivado2022.2 OOC综合，代表器件`xcu280-fsvh2892-2L-e`：

| 层次 | LUT | FF | RAMB36E2 |
| --- | ---: | ---: | ---: |
| W_Loader总计 | 700 | 2364 | 2 |
| Tile Assembler | 575 | 2197 | 0 |
| W FIFO | 97 | 156 | 2 |
| Stationary Bank控制 | 28 | 11 | 0 |

无DSP、无Latch、无LUTRAM。Assembler的权重/scale暂存主要映射为FF及列选择器，不能算成“只有2个BRAM”。
在顶层受约束优化后的FIFO LUT数与孤立FIFO综合不同，这是不同综合上下文，不是资源报告矛盾。
已保留常量输出、package参数和OOC时钟警告；无Critical Warning/Error。
未对整个Projection/Attention做布局布线，也不承诺4ns约束已在系统上满足。

## 10. 运行与验收

在VLA目录执行：

```powershell
powershell -ExecutionPolicy Bypass -File pcore/rtl/run_xsim.ps1 -Test projection -PythonExecutable python
powershell -ExecutionPolicy Bypass -File pcore/rtl/run_xsim.ps1 -Test fullattention -PythonExecutable python
powershell -ExecutionPolicy Bypass -File pcore/rtl/run_xsim.ps1 -Test all -PythonExecutable python
python -m unittest discover -s pcore/tests -v
```

脚本自动生成被Git忽略的参考向量，不能跳过生成然后使用旧向量。
Projection逐项比较52224个INT32 Psum向量、52224个FP32归约向量、816个最终FACC向量、816个量化向量及816次QOZ数据/scale读回。
覆盖正常供数、输入与VPU延迟、矩阵执行中clear、post阶段clear、两次连续Job、错误XBC/VPU上下文、提前done及故意破坏量化结果。
错误量化结果应被独立oracle检出，而不是因TB同时修改输入/预期值产生假通过。

Attention重新验证55次QK+55次PV，共110次矩阵Job；没有QK55。
完整数学行为模型还执行Mask、online Softmax、非恒等alpha缩放和AFIN。
QK及纯矩阵测试保留位精确检查；含数学EXP的PV/AFIN使用既有`2e-6+2e-6*abs(reference)`误差界限，不宣称所有结果逐位一致。
正式SFU/VPU尚未替换，实际pi0全部mask及全head/layer未在本轮覆盖。

最终日志、计数和周期见 [Projection与Attention验收记录](Projection与Attention验收记录_20260917.md)。
