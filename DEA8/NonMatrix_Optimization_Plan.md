# PCore非矩阵运算复用与16 lane优化计划

日期：2026-10-20。状态：方案，尚未实施。

本轮仅新增本文，不修改RTL，不运行仿真、综合或布局布线。沿用DEA8当前设计名称，不创建新版本。

## 1. 建议与边界

建议采用以下组合，而不是把所有非矩阵单元统一减半：

| 项目 | 建议 | 原因 |
|---|---|---|
| VPU FP32乘法 | 32路降至共享16路 | RoPE、G-U乘法、OACC缩放、A_FIN、α·l分时复用 |
| VPU FP32加法 | 两套行归约树降至一套，合计16个加法器 | 一行16元素树用15个，另1个用于l更新；RoPE阶段复用这些加法器 |
| QK后处理 | 一次处理一行16元素；aa差值用1个FP32减法器 | 不需要保留两行并行最大值及两个差值减法器 |
| 量化 | 保留一套16元素B16量化，不缩成8元素 | 服务各Job；8元素量化会限制16 lane A_FIN的吞吐 |
| GELU | 双交错链改为单链，II=1 | 当前共享倒数已经限制总输出为1元素/拍，双链不等于2元素/拍 |
| SFU加法 | GELU的2个加法器复用P_EXP的4个减法器中的2个 | 两类操作处于不同Job阶段，保留官方FPADD IP |
| SFU EXP | 第一阶段保留4路 | Attention时序紧；2路的指数运算发射下界已接近单个矩阵block窗口 |
| Attention状态 | 两份完整OACC，DEQ读旧银行、写新银行，VPU在新银行内原地缩放 | 避免同一银行承担两路读、一路写 |
| Attention调度 | QK最后K-Tile的最终Score提交时，立即启动逐行Mask/max/aa/α | 不能等完整QK_POST和整代α结束后才开始16 lane缩放 |

主范围为PCore及其内部VPU/SFU接口和调度。GCore保留既定109 DSP架构；其残差/RMS显露尾部不纳入本次PCore资源压缩。DEA8外部7种Job不增加、不改变语义。

“完全隐藏”按以下口径验收：

- 非Attention：输入依赖满足后，在后继一个N-Tile矩阵窗口内完成后处理、释放银行，不跨多个N-Tile积压。
- Attention：缩放必须赶在下一次PV真正发射之前完成，PBUF必须在对应PV发射前提交。
- 首次填充、最后一个N-Tile后处理、K的最终RoPE配对、Attention尾部没有足够后继矩阵可覆盖，单独计入显露尾部，不能称为零开销。
- 隐藏保证以外部持续供数、接收端满足约定服务率为前提。任意长背压不可能保证完全隐藏，但必须保证功能正确且无丢数。

## 2. 当前实现与证据

### 2.1 已有复用不能重复计算收益

- VPU已有共享32路乘法阵列，不是RoPE、G-U、OACC_SCALE、A_FIN各有32路。
- RoPE加法与P行和已经复用行归约树。
- SFU已有4路EXP、两条交错GELU链、一个共享倒数。两条GELU链共同输出最多1元素/拍。
- 当前VPU命令主体为单在途状态机；减少lane后，必须拆开独立流水的运行控制，不能仅修改一个lane参数。
- OACC目前为一份完整状态，按行奇偶分银行，每个奇偶银行为简单双口1读1写；同银行矩阵访问会阻止VPU读写。

### 2.2 周期基线

MXU为7级，DEQACC当前为16级：反量化前段4级、官方FPADD 11级、提交1级。Attention名义slot为：

```text
416 + (7-1) + 16 = 438拍
```

不能继续套用旧的DEQACC 11级、416+6+11等预算。此前真实计算链路的稳态首发间隔出现439/455拍交替，即两段约894拍；这是旧32 lane实测参考，不是16 lane方案的性能保证。

服务器Layer1旧输入快照实测：Attention为50366拍，整层九阶段293448拍；该结果不等于本方案结果，也不等于最新RAM映射修改后已重跑验证。

现有HIDING记录中的QK_POST 89、ALPHA 53、P_EXP 252、P_POST 315、OACC_SCALE 433、A_FIN 444、GELU 2261拍，属于旧实现命令时长观测上界，不是单个算子平均有效工作时间，不能直接按lane比例缩放。

### 2.3 主要依据

| 内容 | 当前入口 |
|---|---|
| 参数、银行枚举、矩阵描述符 | [pcore_pkg.sv](C:/Users/fly04/Desktop/VLA/DEA8/Pcore/rtl/pcore_pkg.sv) |
| 当前DEQACC、提交旁路 | [DEQACC_3.3ns.sv](C:/Users/fly04/Desktop/VLA/DEA8/Pcore/rtl/DEQACC_3.3ns.sv) |
| FACC/OACC存储和冲突仲裁 | [dea8_acc_store.sv](C:/Users/fly04/Desktop/VLA/DEA8/Pcore/rtl/dea8_acc_store.sv) |
| Attention矩阵/非矩阵命令调度 | [dea8_attention_scheduler_v4.sv](C:/Users/fly04/Desktop/VLA/DEA8/Pcore/rtl/dea8_attention_scheduler_v4.sv)；文件名是已有名称，不代表新建版本 |
| VPU共享乘法、行和、QK后处理 | [VPU目录](C:/Users/fly04/Desktop/VLA/DEA8/Pcore/units/vpu) |
| EXP/GELU/倒数资源 | [dea8_sfu_arithmetic.sv](C:/Users/fly04/Desktop/VLA/DEA8/Pcore/units/sfu/dea8_sfu_arithmetic.sv) |
| 非矩阵活动计数入口 | [tb_pcore_seven_activity.sv](C:/Users/fly04/Desktop/VLA/DEA8/Pcore/tb/compute/tb_pcore_seven_activity.sv) |
| 最新RAM映射资源基线及验证边界 | [RAM_Remap_20261019.md](C:/Users/fly04/Desktop/VLA/DEA8/reports/resource_synth/RAM_Remap_20261019.md) |
| 服务器Layer1计时证据 | [Layer1_nine_stage_measured.md](C:/Users/fly04/Desktop/VLA/DEA8/server_runs/20261019_gu_readonly_audit/Layer1_nine_stage_measured.md) |

## 3. 非Attention按N-Tile缩减资源

固定M=51，双行MXU每个16×16小Tile发射26拍，最后一对仅row50有效。以下只用矩阵有效发射时间作保守隐藏预算，不依赖加载空隙或整个Job剩余时间。

| Job | 单核矩阵尺寸 | 一个输出N-Tile的有效矩阵窗口 | 后处理 |
|---|---|---:|---|
| K/V | [51,1024]×[1024,32] | 64×26=1664拍 | K：RoPE、量化、送出；V：量化、重排、送出 |
| Q | [51,1024]×[1024,256] | 1664拍 | RoPE、量化、写QOZ |
| O | [51,256]×[256,1024] | 16×26=416拍 | FACC读出、FP32送GCore |
| G-U | Gate/Up各[51,1024]×[1024,512] | 同一n的两分支合计2×64×26=3328拍 | GELU(G)×U、B16量化、写QOZ |
| Down | [51,512]×[512,1024] | 32×26=832拍 | FACC读出、FP32送GCore |

### 3.1 Q/K：按配对依赖启动，复用16路乘法

一个RoPE配对组包含两个[51,16]输出Tile。权重列已按配对方式分核，继续保持该映射和真实position语义。

```text
y0 = x0*cos - x1*sin
y1 = x1*cos + x0*sin
```

每个配对组需要3264次FP32乘法、1632次FP32加法，输出102个B16块。

- 共享16路MUL：204拍乘法发射下界；共享16路ADD：102拍加法发射下界。
- 量化16元素/拍：102个块的发射下界为102拍。上述阶段可流水，不能将下界相加当成精确命令延迟。
- 不新建4/8路“独立RoPE单元”：它们虽然也可能满足1664拍，但会和Attention所需的共享16路阵列重复。
- 第一个配对Tile先保存；配对就绪后启动。后处理必须在下一个N-Tile复用其银行前结束，不能用两个N-Tile的3328拍替代1664拍截止时间。
- K仅两个N-Tile，最终配对直到矩阵尾部才齐；这段尾部必须显露或与独立后续工作重叠，不能声称全部隐藏在K矩阵内。
- 保留既有FACC配对所有权和RoPE暂存，不增设第二套RoPE大缓存。

### 3.2 V：减量化并行度，不改输出格式

一套16元素量化足够。保留现有token重排和padding规则：V每个N-Tile仍为64个B16数据/scale包，加首拍信息共65拍；不能误改为51个包。K直传每个N-Tile为51个包，加信息共52拍。

单路内部136bit=16×INT8+8bit scale；数据、scale、Tile列坐标和任务上下文继续同步。外部总线宽度及GCore解释方式保持现状。

### 3.3 G-U：先去掉重复GELU链

单个[51,16]包含816个GELU输入和816次Up逐元素乘法。一条全流水GELU链可持续发射1元素/拍，与现有共享倒数吞吐一致。

沿当前运算顺序，GELU链包含5个MUL、2个ADD、1个EXP、1个RECIP。理想算术延迟为：

```text
5×8 + 2×11 + 21 + 29 = 112拍
816次发射 + 112拍流水尾部 ≈ 928拍下界
```

928拍不含RAM读取、4行信用、命令切换、量化和写回，不是已验证性能。旧实现GELU相关命令最高2261拍，说明主要损耗不能靠“公式相加”忽略。

实施约束：

- 保留现有Pair BUF及51拍逐行转移方案，不为省二十几拍增加宽口大缓存。
- 先保留4行信用，单链II=1；实测不足时再检查信用/读口，不直接复制算术链。
- GELU两处ADD复用P_EXP的4路SUB中的2路；G-U期间不执行Attention P_EXP，两者无需同时占用。
- Up乘法使用共享VPU 16路的有效lane；量化拼齐16元素B16块后写QOZ，保持RNE、饱和及scale规则。
- 阶段目标：每个n的后处理从配对就绪到最终写入不超过3000拍，并且严格早于下一次银行复用；3328拍是硬截止预算，3000拍是拟定余量目标。

第二阶段可研究把GELU的5个MUL也放入共享16路阵列的固定lane，进一步省10 DSP/核。先不做通用交叉开关；若路由、LUT和控制代价高于收益，就保留专用单链。

### 3.4 O/Down：瓶颈是输出服务率，不是再建VPU

每个FP32 Tile为816个元素。256bit输出需102个payload beat，加信息首拍共103拍。

- 复用FACC直接读出及现有sender，不增加PCore输出Tile缓存。
- GCore 4 lane接收/归约的有效处理下界为204拍；连同统计等服务开销，必须实测证明早于O的416拍、Down的832拍截止。
- 旧服务记录约396拍时，O窗口仅剩约20拍余量；不能把103个总线拍当成整个下游处理延迟。
- 用Tile信用及FACC所有权保护未发送完的数据。背压超出预算时延后银行复用，不能静默覆盖FACC。

## 4. Attention双OACC：可行，但不能只增加一块RAM

### 4.1 先确定α对应哪一代

令S_b为加Mask后的第b块Score：

```text
m_b   = max(m_(b-1), rowmax(S_b))
α_b   = exp(m_(b-1) - m_b)
P_b   = exp(S_b - m_b)
C_b   = FP32(α_b * R_(b-1))
R_b   = FP32(C_b + dequant(quant(P_b) * V_b))
```

因此PV(b)刚生成R_b后，应乘QK(b+1)产生的α_(b+1)，准备下一轮的C_(b+1)。不是再乘α_b。

保留当前FP32先加后乘的舍入边界，不把α分配到PV两项，不私自改为FMA。PV(0)旧状态为零；PV(54)生成最终R_54后不再缩放，不存在α_55。

### 4.2 原设想直接接线的问题

若DEQ从OACC_1读旧值、向OACC_1写PV结果，VPU又从OACC_1读刚写结果，则OACC_1每周期需要两读一写。当前奇偶银行各为1R1W，无法直接满足；当前仲裁还会主动阻止同银行VPU访问。

如果改为直接旁路DEQ结果到16 lane VPU，生产32元素/拍、消费16元素/拍，PV期间会积压约半份OACC，即约26KiB；几个深度的skid FIFO不够。该大FIFO的物理宽口成本也不能按总bit数估算。

### 4.3 推荐：读旧银行，写新银行，新银行内原地缩放

两份OACC均保存完整[51,256] FP32。物理A/B轮换，R/W是当前角色名：

```text
OACC_R：已准备的C_b
   │ DEQ读32元素/拍
   ▼
DEQACC：PV_b + C_b
   │ 写原始R_b，32元素/拍
   ▼
OACC_W：原始结果逐步到达
   │ VPU读16元素/拍；仅读已提交行
   ▼
共享MUL16 × α_(b+1)
   │ VPU写16元素/拍，覆盖同地址原始值
   ▼
OACC_W：逐步变成C_(b+1)

全部缩放实际写入 + 旧银行读请求排空后，下一PV交换R/W角色
```

原始积压留在完整OACC_W中，不另建半份OACC FIFO。DEQ不再原地读写同一份OACC。

### 4.4 真双口与奇偶排程

每份OACC仍按行奇偶拆成两个512bit宽银行。OACC_W每个奇偶银行改为同钟真双口URAM：

| 端口 | PV期间用途 | 约束 |
|---|---|---|
| A | DEQ原始PV结果写入，512bit/拍/奇偶银行 | 不可背压，优先级固定最高 |
| B | VPU读原始行，或写已缩放行 | 同一银行同拍只能做其中一种 |

VPU读按even、odd交替。若“读请求到缩放写入”延迟为奇数，持续流下本拍读取的奇偶银行与本拍写回的奇偶银行相反，两个B端口可各承担一个操作。

示例延迟预算：RAM 3拍+MUL 8拍+写回1拍+对齐1拍=13拍。该13拍是拟定实现目标，必须按真实RTL边界重新核对，不直接当作当前延迟。

```text
相对拍      读端B                 写端B（读请求延后13拍）
0           even row0             无
1           odd  row1             无
...
13          odd  row13            even row0
14          even row14            odd  row1
```

- 每个N-Tile按52行槽位排程，最后odd row51为dummy，不参与乘法、量化或RAM写入。共16×52=832槽，816槽为有效数据。
- 上表只证明连续流可排程，不证明气泡、α未就绪、α·l抢占后仍自动成立。实际要有B端口预约/写回信用，禁止仅靠全局拍号奇偶判断。
- 写回结果不能丢弃；发起不可撤销的RAM读前，预留返回缓存、MUL入口和将来的写端口。
- 禁止同一地址跨口读写碰撞；必须在DEQ真实写入之后才允许读取该原始行。
- 下一PV之前检查全部有效行缩放写入、所有相关在途事务排空。清零valid/epoch，不整块复位URAM数据。

UltraRAM每个端口每拍只能读或写一次；上述安排不依赖不存在的三端口RAM。器件约束依据[AMD UG573](https://www.amd.com/content/dam/xilinx/support/documents/user_guides/ug573-ultrascale-memory-resources.pdf)。可参考当前GCore真双口URAM模板，但PCore不跨目录依赖GCore内部模块。

### 4.5 接口、状态与宽度

| 路径/状态 | 建议 |
|---|---|
| DEQ旧值输入 | 1024bit，两个16元素FP32行；源银行随描述符锁存 |
| DEQ原始结果写入 | 1024bit，拆为两个512bit奇偶写口；目的银行单独锁存 |
| VPU OACC读/写 | 各512bit数据路径，16个FP32；独立地址、valid、ready及上下文 |
| α因子 | FP32 32bit按行广播，不给每个元素复制一套α存储 |
| α存储 | 保留两代51个FP32；代号绑定block/job/epoch，消费结束前不能覆盖 |
| m与aa | m为51个FP32；aa同为51个FP32，按行就绪；SBUF需绑定本代m快照或保证消费期间不覆盖 |
| 原始提交进度 | 顺序提交前沿、消费者行/Tile计数、缩放写入计数；不默认增设大型逐元素valid表 |
| PBUF/SBUF | 保留ping-pong所有权，未消费银行不能复用 |

`acc_sel_e`当前2bit、使用3个值，剩余值可表示第二份OACC，不必扩大选择宽度。但现有单一`acc_sel`同时决定读写，必须在矩阵描述符及DEQ旁带中分开`acc_src`和`acc_dst`。

Projection/G-U继续使用相同源/目的FACC。所有`==ACC_OACC`、`<=ACC_OACC`、3银行循环及OACC地址判断都要一起适配，不能只给acc_store增加一个数组元素。

## 5. Attention时序：早算α是必要改动

### 5.1 为什么“等QK全部结束再算α”不稳妥

OACC共有51×256=13056个FP32。16 lane仅有效发射就需816拍；采用规则奇偶排程为832槽。

旧32 lane缩放命令约433拍。不能把它简单改成866拍，再假设自动藏进两个窗口：若先等待QK_POST、整代α、RAM读和MUL尾部，总时间会超过两段约894拍。

### 5.2 最后K-Tile的Score提交即进入SBUF

QK沿K维归约。只对最后一个K-Tile的最终Score使用已有DEQ提交旁路：

```text
DEQ最终K-Tile Score提交（两行32元素/拍）
       │ 逻辑Mask选择：保留Score或写-inf，不占FPADD
       ▼
SBUF奇偶银行：写32元素/拍
       │ 读16元素/拍，逐行
       ▼
rowmax16 → 与旧m比较 → aa=m_old-m_new → SFU EXP → α逐行提交
       │
       └── m_new/SBUF上下文固定，随后P_EXP读取
```

- 使用当前真实`commit_write`旁路，增加最后K-Tile限定，不能把K维中间部分和当最终Score。
- SBUF仍保存加Mask后的S，不改变存储含义。Mask逻辑保持已核实的pi0语义和当前真实实现，不在本轮更改可见性规则。
- 两行Mask是位选择，不是“保留32路FP32 VPU”。SBUF按奇偶1R1W，允许同时接收最终Score和逐行读最大值。
- 不另外增加FACC第三读口，也不再复制一个完整Score Tile。
- α任务可以提前armed，逐行等待aa；无需等全块QK_POST done。完成通知仍表示本代所有结果真正提交，不能提前发done。
- SFU第一阶段仍按“α整代→P_EXP整代”切换功能；关键是α逐行可被缩放消费，不要求α与P_EXP同时占EXP。

拟定首行α链路约为SBUF读3+MAX约2+差值SUB 11+EXP 21=37拍，另计打包和握手。最后K-Tile首行Score比整块提交早约25拍；下一PV原始结果还需经过MXU/DEQ，因此有机会在首个PV结果到达时备好α。该推导必须用首行、末行及每行ready事件验证，不能只看整代done。

### 5.3 独立控制，复用运算，不复制完整VPU

至少区分两个内部执行上下文：

- 行前端：Mask、max、aa、P行和、量化及相应RAM流。
- 共享乘法流：OACC_SCALE、A_FIN、RoPE、G-U乘法及α·l。

Attention稳态允许行前端处理P_(b+1)，同时乘法流缩放R_b。当前整机单命令busy锁不能继续把两者互斥。

α·l共51次乘法，可在共享16路阵列上打包为4次发射。通过小型上下文tag和信用在行边界插入，结果用于更新l；不要为了这4次发射再建32个MUL，也不要每次切换都排空全部8级乘法流水。

必须把RAM返回、4次α·l发射、端口预约和结果写回一并排程，4次发射不等于控制开销一定只有4拍。若该抢占破坏截止，可评估Attention期间复用空闲GELU链的一个MUL处理α·l，不新增DSP；这属于备选接线，不默认同时实施。

SFU保留4 EXP：每块需51个α和816个P，共867次指数运算。若降至2路，仅发射下界已达434拍，尚未包含差值、P减法、EXP流水和切换，无法轻率宣称藏入438拍。

### 5.4 预算与通过门槛

稳态以PV(b)首发为起点，到PV(b+1)首发为截止：

```text
max(首个raw可读时刻, 首个α可用时刻)
  + 832个缩放槽
  + 读到写回尾部L_RW
  + α·l/端口/背压等额外占用
  + 安全余量
  <= 两次PV首发间隔
```

示例：首个raw约23拍、L_RW约13拍、α·l净占4拍，则23+832+13+4=872拍。若可用间隔894拍，名义余量22拍；再预留16拍安全余量，只剩6拍容纳其余损失。

**872/894只是可行性预算，不是仿真承诺。** 还需证明每一行α就绪、B口不冲突、P后处理不拖延PV、读写尾部不超时。更理想的816有效槽安排可以后续研究，但不作为第一版通过条件。

若最坏周期验证不满足：先定位早α、端口气泡和信用问题；仍不满足时给Attention slot增加少量确定余量，并报告真实增量。不得丢事务、提前done，或把被迫等待隐藏在统计口径里。是否接受扩slot由实测代价决定，不把旧894拍强制写成新设计固定常数。

### 5.5 启动与尾部

- 顺序保留QK0、QK1、PV0、QK2、PV1……QK54、PV53、尾部slot、PV54。
- PV0不读旧OACC；在其结果产生后乘α1，准备PV1。
- PV53到PV54间保留额外一个完整block级窗口，不删除，也不虚构QK55。
- PV54直接生成最终R54，不再乘α55。
- A_FIN用16路MUL至少816次有效发射，不能继续承诺旧32路的四百多拍命令时长。
- 可选：当l54真正提交后，提前执行1/l54；在PV54最终值逐行提交后，流式做A_FIN并量化写QOZ。这能把约一半A_FIN工作与PV54重叠，但仍有尾部，不保证整段消失。
- 提前倒数/A_FIN是第二阶段优化，必须先保证最终l、OACC原始行、QOZ写所有权和取消闭环正确。

## 6. 资源预估

### 6.1 第一阶段DSP目标

沿用官方FP32 ADD/MUL每个2 DSP，配置及舍入不变。EXP/RECIP按现有综合映射预算。

| 单核资源 | 当前DSP | 目标DSP | 说明 |
|---|---:|---:|---|
| MXU+DEQACC | 320 | 320 | MXU 256；DEQ 32个FPADD共64 |
| VPU共享MUL | 64 | 32 | 32→16个 |
| VPU行树/最终加法 | 64 | 32 | 32→16个 |
| QK差值SUB | 4 | 2 | 2→1个 |
| GELU MUL | 20 | 10 | 2条→1条，每条5个 |
| GELU专用ADD | 8 | 0 | 复用现有P_EXP SUB中的2个 |
| P_EXP SUB | 8 | 8 | 保留4个 |
| EXP | 4 | 4 | 保留4路，按当前映射 |
| RECIP | 8 | 8 | 保留1路，按当前映射 |
| **合计** | **500** | **416** | **结构估算，减少84 DSP/核** |

可选将GELU MUL再并入共享阵列后，理论再减少10 DSP/核；不计入第一阶段416预算。

### 6.2 双OACC的存储代价

每份OACC有效数据为51×256×32=417792bit，约51KiB。现有512bit宽奇偶银行实际共用16 URAM；保持映射结构再增加一份，初估再用16 URAM/核。

这不是高密度URAM使用：417792/(16×294912)约8.85%。资源来自宽口和奇偶分银行约束，不是容量不足。不能按有效bit数声称只需两块URAM。

| GCore+8PCore线性外推 | 当前基线 | 本方案初估 | U50占比 |
|---|---:|---:|---:|
| DSP | 4109 | 109+8×416=3437 | 57.75%，原69.04% |
| URAM | 304 | 304+8×16=432 | 67.50%，原47.50% |
| BRAM36等效 | 1223 | 不新增大FIFO，算术复用后的变化待综合 | 基线91.00% |
| LUT | 866566 | 减少算术IP、比较/量化复制，但增加端口调度；不提供未经综合的净值 | 基线99.41% |
| FF | 851206 | 待新综合 | 基线48.83% |

若新增OACC改用约16 BRAM36/核，外推BRAM将为1351/1344，已超器件容量。因此第一阶段优先URAM，不把宽OACC塞回BRAM，也不增加26KiB旁路FIFO。

URAM真双口映射数量、宽度拆分及实际读延迟均须后续确认。以上不是八核综合、可布通或250MHz签核结果，未计HBM/PCIe shell和其它全局开销。

LUT仍是主约束。DSP少84不代表LUT按比例下降；实际比较对象是减少的官方算术IP和量化/最大值结构，与新增MUX、端口预约及控制的净差。拒绝为了复用引入大型全互连算子网络。

## 7. 后续实施顺序

| 阶段 | 修改重点 | 通过条件 |
|---|---|---|
| P0 冻结基线 | 保存当前源码/IP配置哈希、RAM报告、七Job及1/9/18层历史来源 | 明确哪些结果对应旧快照；不把最近RAM修改视为已功能回归 |
| P1 调度先验 | 逐行早α时间表、双OACC端口预约表、α·l插入及尾部预算 | 每行依赖与端口均可排程；最坏周期符合第5节不等式，否则先修方案 |
| P2 非Attention复用 | 单GELU、P_SUB复用、量化16、RoPE/行树16的流控制 | Q/K/V/O/G-U/Down数值与格式不变；每个可隐藏Tile按期释放 |
| P3 双OACC | acc_src/dst、四银行选择、真双口奇偶存储、原始/缩放提交前沿 | DEQ连续提交不被堵；无端口碰撞、覆盖或漏写；同一数据仅缩放一次 |
| P4 Attention流水 | 最终Score旁路入SBUF、逐行aa/α、行前端与乘法流解耦 | 真实16 lane完成稳态P准备和缩放；不依赖TB模拟内部算法 |
| P5 启动尾部 | 55组QK/PV、PV53尾部slot、PV54/A_FIN、取消和异常 | 全任务正确完成，110个矩阵子Job，真实总周期可解释 |
| P6 证据收尾 | 单核7 Job、活动统计、服务器8核1/9/18层回归 | 同时报告数值、隐藏deadline、资源和未验证边界 |

P2可以保留旧Attention宽lane参数供过渡回归，但最终目标必须迁移到共享16路和双OACC；保留一套32路Attention算术副本不算本计划完成。

### 7.1 文件影响范围

- 参数及描述符：pcore_pkg、compute配置、内部VPU/SFU命令/行ready元数据。
- 存储/DEQ：acc_store、DEQACC_3.3ns及其元数据路径；不更换已验证INT20矩阵加法树。
- 调度：Attention scheduler、真实VPU/SFU顶层、post/workspace所有权；DEA8外部7 Job接口保持兼容。
- 算术：共享MUL、P树、QK rowmax、SFU arithmetic；保留官方IP，不自写低资源近似FP32替代。
- 验证：在已有真实七Job与全层TB中扩充事件/断言，不另造一套只验证调度假数据的验收链。
- 不修改旧单INT8工程、DEA8_zhao历史工程及既有报告；新证据另存，不清理历史来制造一致性。

## 8. 验证与验收

验证模式：Smoke-and-read。先检查真实模块小路径和逐周期依赖，再跑现有完整RTL回归；不新增pytest体系或用行为模型替换内部VPU/SFU。本文阶段只做静态分析。

### 8.1 功能检查

- 保持矩阵、FP32算术顺序、GELU近似式、RoPE位置、Mask、MXINT8-B16 scale轴、RNE/饱和及打包格式。
- 覆盖α=1、极小α、各行最大值更新位置不同、最后几行才出现新最大值、全Mask及初始化m的异常值策略；不删除现有NaN/Inf保护。
- 覆盖row50有效/row51 dummy、OACC换代、两个α银行寿命、PBUF/SBUF复用、取消后迟到响应和epoch不匹配。
- 量化前FP32与现有参考比较，最终INT8和scale按当前验收标准比较。不得为减少lane放宽正确性检查。
- 矩阵结果、PBUF/QOZ和外发数据均走真实内部RTL；TB只模拟外部供数、总控、接收背压。

### 8.2 时序与隐藏检查

每个N-Tile记录依赖就绪、post启动/最终提交、下一次银行复用时刻；验收post截止，不只比较整Job平均占比。

Attention逐block记录：矩阵首发/末发/提交，首末行aa/α提交，PBUF提交，raw前沿，缩放首读/末写，下次PV首发。最慢的某一行α也必须满足消费需求。

对端口与信用做断言：一个B端口一拍最多一个动作；DEQ端口不被阻塞；不可读未提交raw；不可覆盖仍被消费的α/Score；最终done晚于所有实际写回。

### 8.3 统计口径

- 每种命令调用次数、min/max/mean延迟，与物理算子发射次数分别统计。
- 物理算子有效工作率=有效发射拍/任务区间拍；流水busy另列，不能把8级乘法尾部重复计成8次运算。
- 比较DSP加权有效发射率；不能把32→16后单位数量变化掩盖在简单平均中。
- 旧活动TB监控89个算术IP；按本方案预计约47个。重新核对实例清单、各IP的valid/CE以及量化/MAX，不沿用89这个分母。
- 分开报告稳态隐藏、首尾显露、端口停顿、外部断供/背压；只给Job矩阵占比不足以验收。

### 8.4 环境与后续命令

本地工作目录：`C:\Users\fly04\Desktop\VLA\DEA8`。Python使用已安装的独立运行时，不默认系统Python：

```powershell
$py = 'C:\Users\fly04\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
$vivado = 'D:\Xilinx\Vivado\2022.2'
& $py Pcore/run_compute.py test --vivado $vivado --top tb_pcore_seven_activity --report-tag nonmatrix16
```

该命令为现有runner接口，只有后续RTL与活动TB适配后才运行；正式执行须核对已有IP生成/编译依赖，不擅自升级官方IP或沿用旧展开缓存。

八核长仿真交服务器，进入服务器当前DEA8根目录、使用其已配置Python/Vivado；以下沿用已存在的入口，不表示本文已执行：

```text
python run_dea8.py test --top tb_dea8_layers_native --arg LAYER=1 --server-heavy
python run_dea8.py test --top tb_dea8_layers_native --arg LAYER=9 --server-heavy
python run_dea8.py test --top tb_dea8_layers_native --arg LAYER=18 --server-heavy
```

后续先功能通过再做独立单PCore资源综合，与500 DSP/143 BRAM36等效/35 URAM基线比较；本轮不运行。八核综合和布局布线不在本方案自动执行范围。

## 9. 交付与执行提示

本轮交付只有本文。后续实现交付RTL、更新后的接口说明、真实回归/性能证据；执行结果写入同目录`NonMatrix_Optimization_Plan.report.md`，逐阶段标注完成/部分/未动及证据。不提前创建空报告，不把估算改写成实测。

后续执行提示：

```text
在C:\Users\fly04\Desktop\VLA中读取AGENTS.md及DEA8\NonMatrix_Optimization_Plan.md，再核对当前RTL/IP和历史证据。按P0→P6推进PCore非矩阵复用与16 lane双OACC方案，先证明早α和真双口排程，再实施；保留DEA8七Job、FP32运算顺序、Mask/RoPE/量化语义，不改版本名称，不修改旧工程。使用文档指定Python/Vivado，采用Smoke-and-read及已有真实RTL验证链，单核先行、八核长仿真交服务器；未经追加要求不运行八核综合/布局布线。普通实现细节自行处理，遇到依赖或端口预算推翻方案时说明证据并暂停相关阶段，不伪造隐藏或完成。无论完成或部分完成，都在DEA8\NonMatrix_Optimization_Plan.report.md记录阶段状态、改动、验证、偏离、未完成原因及下一步。
```
