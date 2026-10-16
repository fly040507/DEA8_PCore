# DEA8 U50 资源映射方案

> 2026-10-16重构后修正：独立Reduce已退出当前拓扑；GCore内置4-lane归约，在线γ、单路rsqrt。本版OOC实测48,229 LUT、17,502 FF、109 DSP、152.5 BRAM36等效、4 URAM，无黑盒。下文118 DSP本体报告及包含独立Reduce的整机合计均为历史数据；整机仍需重新核算，4ns尚未签核。见 [GCore README](Gcore/README.md)。

日期：2026-10-16。对象：固定 `M=51` 的当前 `DEA8/`。

**这是首版资源方案，不能整体当成当前源码的综合报告。** GCore随后已按118 DSP方案实施并完成本体OOC；PCore/VPU/SFU及Reduce部分仍为待实施预算，不改变设计版本名称。

## 实施后的修正

2026-10-16，GCore本体真实OOC：47,644 LUT、17,729 FF、118 DSP、147.5 BRAM36等效、4 URAM，无黑盒。原GCore的20k～30k LUT及145 BRAM手算已失效，详见[GCore实测](Gcore/README.md#当前本体ooc实测)。真实IP完整body场景保留原XHAT/Residual严格检查；最终回归证据以GCore reports及源码hash为准。

另需修正下文的TDP计数：**32bit真双口bank需要一个RAMB36，不能按一个RAMB18算。** 按原组织不再优化时，PCore的POST_TILE_STORE与统计量分别应由8修正为16 BRAM36，单核BRAM由95变111。GCore预留148块后，GCore＋八核＋Reduce约需1108 BRAM36，占示例动态区99.3%，不能通过整机容量准入。

因此，下文第1/10节的原整机LUT/BRAM总数和SLR余量只保留为首版推导，**不再作为可部署结论**。一种后续可选修正是把FACC-A也迁往URAM：每核增加16 URAM、减少16 BRAM，使修正后的单核回到95 BRAM、URAM增为56；含Reduce整机约980 BRAM、452 URAM。此项尚未修改PCore RTL，不能计为已获得的收益。GCore本轮只落实自身算术、RAM与接口，不顺带重构PCore。

## 1. 结论与预算边界

- 算术：保留256个DSP/MXU；FP32乘加优先采用DSP后端，特殊函数优先IP或RAM系数表配合DSP
- 存储：数据阵列采用显式同步BRAM/URAM；FF只保留驻留权重、广播输入、流水、元数据和很浅的弹性保持
- 不机械地把小计数器、指数加法、比较、掩码和移位全部搬到DSP
- 不机械地把每个逻辑bank都拆成独立RAM；先证明端口需求，再合并物理空间
- 主预算包含每核32-lane VPU、4-lane SFU；它们目前没有真实算术RTL，下表属于新增实现预算
- 不把Projection、Attention、G-U重复计算为三套Matrix，不计算legacy/独立单测中的私有Matrix

| 范围 | LUT，估算 | FF，估算 | DSP，分配预算 | BRAM36等效 | URAM288 |
|---|---:|---:|---:|---:|---:|
| GCore | 20k～30k | 30k～45k | 118 | 145 | 4 |
| 单PCore，含VPU/SFU | 45k～69k | 66k～102k | 488 | 95 | 40 |
| **GCore＋8 PCore** | **380k～582k** | **558k～861k** | **4022** | **905** | **324** |
| 建议8-lane内部折叠Reduce | 12k～17k | 20k～30k | 112 | 72 | 0 |
| **上述部分合计** | **392k～599k** | **578k～891k** | **4134** | **977** | **324** |

DSP/RAM数是选定结构的预算；LUT/FF是手算区间，不是工具给出的置信区间或保证上限。IP后端是否兼容、RAM端口重写、宽选择网络、反压缓存、实际流水配置都会改变结果。

不含：未实现的DEA8总控、HBM应用侧搬运器、服务器接口、去噪步间EHU、调试ILA和额外跨SLR缓冲。标准平台静态区只通过下面的可用资源基数扣除，不再次重复计入。

## 2. U50资源基数

芯片为 `xcu50-fsvh2104-2-e`。整器件数据来自[DS965](https://docs.amd.com/api/khub/documents/bL9LYRI5VCVESoD52k53qA/content)；平台示例来自[UG1120 U50 XDMA base_5](https://docs.amd.com/r/en-US/ug1120-alveo-platforms/U50-Gen3x16-XDMA-base_5-Platform)。

| 资源 | 整器件 | base_5动态区示例 |
|---|---:|---:|
| LUT | 约872k | 约704k |
| FF | 约1743k | 约1410k |
| DSP48E2 | 5952 | 4920 |
| BRAM36等效 | 1344 | 1116 |
| URAM288 | 640 | 544 |

最终使用哪一种shell尚未冻结；不能把base_5可用量视为所有部署方式的通用值。单BRAM36为36 Kibit，单URAM为288 Kibit；本文件中KiB均按1024字节计算。

## 3. 当前工程核对

权威路径为 `Pcore/rtl`、`Gcore/rtl`、`reduce/rtl`。`../pcore`是旧单INT8版本，`Pcore/legacy`和独立TB私有实例不加入部署预算。

| 当前事实 | 源码入口 | 对方案的影响 |
|---|---|---|
| 三种Matrix模式共享一套执行核心 | `dea8_pcore_exec`→`dea8_matrix_job_dispatch`→`dea8_matrix` | 每核只算一次MXU/DEQACC/ACC |
| 每PE一个显式DSP，双行INT8共享B | `dea8_pe_2row`、`dea8_mxu_2row` | 256DSP/核，不能再乘以双行 |
| 每拍DEQACC处理2×16个partial | `DEQACC_3.3ns.sv`及lane | 必须保留32路并行累加，不能只预算16路 |
| FACC-A/B明确使用distributed提示 | `dea8_acc_store` | 属于主要待迁移的LUTRAM |
| Post halves是16个浅宽bank、组合读取 | `dea8_pcore_post` | 不能只改属性宣称已经变成BRAM |
| GU Pair BUF同拍写两行、组合读一行G/U | `dea8_gu_pair_buffer` | 要按实际端口重排，而不是保留异步读强推BRAM |
| workspace提供两路16元素span | `dea8_pcore_workspace` | m/l等不能简单改成单端口51×32 RAM |
| QOZ是32 Tile共享物理区 | `dea8_qoz_store` | 不再分别增加Q、O、Z三套缓存 |
| PBUF仅一个51×16块的双缓冲 | Attention frontend中的`TILES=1,BANKS=2` | 不误算为两套完整Q矩阵 |
| GCore prefix只由TB预置 | `dea8_gcore_kv_store` | 板上需未来装入路径；综合裁剪不能作为资源节省 |
| VPU32/SFU4目前为TB服务 | `tb_pcore_control.sv` | 本文给设计和预算，不宣称这些算术已实现 |

根README与部分早期文档的GCore进度、外发宽度已滞后；本方案以当前模块和局部README为准，不用旧日志代替新综合结果。

## 4. 通用算术后端

### 4.1 IP选择与精度准入

建议建立统一的算术封装，而不是各模块直接使用互不一致的IP配置。封装覆盖数据、valid/ready或CE、token、异常、flush以及实际延迟。

| 运算 | 首选后端 | 配置原则 |
|---|---|---|
| FP32 add/sub | Floating-Point v7.1，DSP Full_Usage候选 | II=1；RNE；不使用改变求和顺序的累加器IP |
| FP32 multiply | 同一IP，DSP Full_Usage | II=1；不默认用FMA替代先乘再加 |
| rsqrt | 原生Rec_Square_Root IP | GCore两路，FP32，II=1 |
| reciprocal | 原生Reciprocal IP | 每核一路，51个l顺序处理 |
| exp | 原生Exponential IP，BRAM Full usage | 每核四路，ALPHA/P复用 |
| INT8×INT8双行打包 | 显式DSP48E2 | 保留已验证的有符号恢复关系 |
| 17～20bit整数树 | 初始保留carry实现 | 优先评估复用PE DSP后加器，不为每个节点新建DSP |
| MAX、mask、量化指数、地址计数 | 小规模LUT/carry | 浮点比较并非单纯整数加法；mask优先select |

[AMD公开同代UltraScale+参考](https://download.amd.com/docnav/documents/ip_attachments/floating-point.html)给出的样例：FP32 add/sub Full为2DSP，multiply Full为2DSP，reciprocal为8DSP，rsqrt为9DSP。它们用于预算，不是Vivado 2022.2在XCU50上的实测。不能使用网上样例Fmax直接认定本工程满足250MHz。

乘法还可采用Max_Usage：同一参考中的Full约114LUT/2DSP，Max约74LUT/3DSP。GCore的16路与八核VPU的256路全部改Max，账面多272DSP、少约10.9k LUT；含Reduce的DSP预算变为4406，占示例动态区89.6%。这是LUT仍超预算时的候选，不默认启用：样例节省量不是当前器件保证值，且要先给尚未实现的HBM搬运与总控留余量。

**IP不能不经验证直接替换。** [PG060](https://docs.amd.com/api/khub/documents/ym1A7qsltTGP_saZFTrikQ/content)说明多数运算将输入/输出非正规数置零；现有自研包和测试覆盖逐渐下溢。原生rsqrt、reciprocal、exp也不是数学函数正确舍入的同义词。

准入顺序：先生成候选IP并核对2022.2实际行为；正常值、非正规数、NaN/Inf、正负零、舍入边界逐类比较。未批准精度变化前，不以FTZ重写golden或删除已有检查。若IP不兼容，保留原FP语义外壳，把尾数add/sub和可分离的舍入加法放入DSP；每路先预留最多2DSP，LUT重新实测。严格兼容后端未映射前，不能保证仍落在上表的低LUT区间。

不在本方案中默许TF32、FP16、BF16替代FP32累加，也不默认将普通乘加融合成FMA。量化仍需保持当前scale编码、舍入和饱和规则。

### 4.2 延迟与反压

- DSP/IP可以减少LUT，但不能把普通整数DSP加法当成完整FP32加法；对阶、规格化、舍入仍要硬件
- IP实际延迟由生成配置决定，不继续假设全部等于现有4/6/11拍
- DEQACC不可中途停顿：结果和metadata同延迟前推，存储写入带宽必须保证每拍一个A2结果
- GCore可全流水CE暂停；若用NonBlocking IP，必须统一ACLKEN并冻结全部相关metadata，或在外面提供覆盖最大在途量的结果缓存，不能只放一项FIFO
- SFU/VPU采用带信用的输入/结果FIFO；credit覆盖算术在途、未接收结果和拼包空间，不能在下游停顿时继续覆盖结果
- reset/flush要遵守IP复位保持周期并排空或取消旧token；IP自己的valid不能代替系统generation
- DEQACC反馈链的读到写延迟必须小于最短同地址重访间隔26拍；若超过，必须新增旁路或调度间隔，不能直接沿用现有发射
- Attention slot改由实际MXU尾部、DEQACC尾部、RAM延迟和交接余量推导；433/434不是不可修改的常数

## 5. GCore：rsqrt与算术分配

对第r行：`u[r] = sum(FP32(BF16(R[r,d]))^2)/1024 + epsilon`，`inv[r]=rsqrt(u[r])`。平方和顺序及BF16写回舍入继续遵守现有定义。

```text
51个行平方和 → 乘2^-10（指数处理，不做通用除法）→ 两路epsilon加法
  → 26个双行请求 → 两个FP32 rsqrt IP → inv[51] RAM
  → 16-lane归一化乘法 → BlockMax/scale/RNE → XHAT RAM
```

| 硬件 | 数量 | DSP预算 |
|---|---:|---:|
| 残差FP32加法 | 16 | 32 |
| SUM16固定树 | 15 | 30 |
| 行平方和累加 | 1 | 2 |
| epsilon加法 | 2 | 4 |
| 平方/归一化共享乘法 | 16 | 32 |
| 原生FP32 rsqrt | 2 | 18 |
| **合计** | 34 add、16 mul、2 rsqrt | **118** |

当前乘法一侧来自BF16，未来可用8×24有效尾数特化，争取每路1DSP；本预算仍按通用FP32每路2DSP计，不提前扣除16DSP收益。

rsqrt包装器：保持既有110-bit请求/响应；token、row、mask与数据一起预约、一起出队。51行共26包，最后mask=01；无效第二lane内部可输入1.0避免无意义除零，对外结果固定0。两路输出成对提交，不因一路被接收就覆盖另一lane。u非正/非有限、重复行、错误token、迟到返回继续报错。

原生rsqrt精度按PG060约1ULP，不保证与当前TB中高精度计算后转FP32逐bit相等。IP自身使用其匹配C模型检查；另统计对旧参考的ULP、BF16/INT8量化翻转和最终误差。当前8拍TB服务延迟不能继续作为真实IP延迟。无背压时首个请求到末个响应约为`25 + L_rsqrt`个间隔，另计准备、打包、写回尾部。

### 5.1 rsqrt怎样接入

`rsqrt`是`1/sqrt(u)`，不是`1/u`。Norm仍负责平方和、除1024和加epsilon，新增包装器只接收已经形成的正有限FP32 `u`，调用两个原生倒平方根IP，将结果写回inv RAM。它不是额外增加两条完整RMSNorm链。

若解释计算原理，可把正数写成`u = 2^e*z`，其中`1 <= z < 2`；再令`e = 2q+r`、`r`为0或1，得到`rsqrt(u) = 2^-q / sqrt(z*2^r)`。指数部分主要是拆解与调整，真正需要逼近的是有限区间内的倒平方根。自研实现通常可采用RAM初值表再做Newton迭代：`y_next = y*(1.5 - 0.5*u*y*y)`，乘加放DSP；**这只是可选算法解释，不宣称AMD IP内部一定采用该结构**。

本轮首选原生IP而非自行实现上述迭代：生成与数值模型配套，资源和延迟可以直接确认，也避免重新承担初值误差、迭代次数、指数奇偶、下溢与舍入证明。若原生IP精度或非正规数行为无法满足现有合同，再评估自研DSP＋RAM后端；当前18DSP预算不自动适用于自研版本。

## 6. PCore：MXU、DEQACC、VPU、SFU

### 6.1 MXU与DEQACC

每核256个PE继续各用一个DSP处理两行INT8，共256DSP，而不是512DSP。

DEQACC反量化的主动作是INT32符号/幅值、前导位、指数相加和打包，不应误建32个通用FP32乘法器。32个`partial+old`才是需要浮点加法后端的部分，预算64DSP；Psum、scale和tag继续统一对齐。

每核整数树共`2×16×15=480`个节点。全部采用TWO24、每DSP两个不超过24bit的加法，仍需240DSP/核、1920DSP/八核。加在主预算上将达到6054DSP，超过整器件5952，更超过示例动态区4920。因此不能全部迁移。

第一优先候选是两个相邻k的PE级联，在第二个DSP现有后加器内先合并两个packed product，再恢复两行17bit结果。低槽两个乘积的最大正和32768，仍在有符号18bit范围内；不能据此推导16项也能直接packed累加。此候选不增加DSP，有机会减少第一层LUT树和部分逐PE修正；尚需显式原语、S1/S2/S3重新对齐、级联摆放和RTL等价验证，主预算未提前扣收益。

整数代数检查已做117649组边界组合及200000组固定种子随机组合，双行结果匹配逐项乘加。**这仅证明两个packed product的代数关系，不是DSP原语或4ns时序验证。**

### 6.2 VPU：32个加法器＋32个乘法器复用

| 功能 | 资源使用方式 | 不另建的结构 |
|---|---|---|
| RoPE | 32 mul分两拍生成每行64个乘积，32 add/sub形成两半输出 | 不建16组完整四乘二加复数单元 |
| QK_POST | mask select、MAX树、少量旧m比较及aa减法 | mask为0/-inf时不做32路通用FP加法 |
| P_POST | 32 add按两棵SUM16树加两路l更新组织；乘法器计算alpha×l | 不额外复制30个FP加法节点 |
| OACC_SCALE | 32 mul处理两行×16个FP32 | 不建独立OACC乘法器阵列 |
| A_FIN | 32 mul计算OACC×recip，接共享量化 | 不建第二套归一化乘法阵列 |
| G-U POST | 同一mul阵列计算GELU(G)×U | 不重复实现SFU的GELU |
| feature/token量化 | MAX16、指数/移位、RNE、饱和 | 不使用FP32除法生成INT8 |

加/乘各32路、每路先预算2DSP，共128DSP/核。功能在一个VPU命令内选择固定数据通路，避免任意32×32浮点交叉开关。统计树的每个节点仍有自己的物理算子，只是与其他不同时运行的功能复用，不是用一个串行加法器假装32-lane。

两个量化块共享配置，各保存一行16元素；量化缓存、延迟对齐和边界FIFO另留2BRAM36/核。比较/RNE逻辑及路由仍消耗LUT，VPU预算不是只有128DSP。

### 6.3 SFU：四路exp、一路reciprocal、四路GELU

| 部件 | 建议结构 | DSP预算/核 | RAM |
|---|---|---:|---|
| ALPHA_EXP与P_EXP | 四个原生Exponential IP，启用BRAM Full usage | 4，须以生成配置复核 | 4 BRAM36 |
| P_EXP中的S-m | 四路FP32 sub，与exp吞吐匹配 | 8 | 在途/拼包缓存 |
| RECIP | 一路FP32 Reciprocal IP，l=0显式返回0 | 8 | 结果写workspace |
| GELU | 四路分段二次多项式，系数ROM＋DSP Horner，FP32边界 | 16预留 | 4 BRAM36 |
| 地址/转换/实现余量 | 只对实际算术使用DSP | 4预留 | 余量包含在小缓存预算 |
| **合计** | exp/GELU等按function命令互斥 | **40** | **8 BRAM36＋RoPE窗口4URAM** |

PG060允许单精度Exponential的系数表使用一个RAMB36，不能沿用默认distributed memory再声称RAM优先。exp的具体LUT/DSP须按此配置重新生成，网上默认配置的846LUT样例不是本方案的实测值。

GELU建议直接逼近当前tanh版完整GELU函数，不在每个lane内照抄`x^3→exp→reciprocal`形成大网络。初始候选区间[-8,8]分256段，3个24bit系数共72bit/段，残差输入不超过18bit；两个DSP Horner乘加后定点转FP32。区间外采用对应渐近形式。系数格式、截断、连续性和误差界尚需独立拟合验证；没有宣称当前预算已经达到某个误差指标。不能将tanh版悄悄改成erf版。

RECIP只有51个输入，一路II=1约51拍发射；不为满足SFU4名称而复制四个8DSP倒数IP。若尾部必须达到26拍，可改两路：额外8DSP/核、八核增加64DSP，属于明确可选开销。

RoPE不实现实时sin/cos。每核预置51行×128频率×sin/cos各FP32，共51KiB系数窗口；采用256bit×1632的URAM组织，4URAM/核。每拍读取4对系数，四拍拼成既有16对系数响应，保持原接口并通过ready限制发射。窗口必须绑定position_base/frequency/context；未来装载服务需要另接，不能把TB计算三角函数当硬件ROM已装入。

SFU/GELU结果与VPU之间用有界RAM FIFO配对，继续回显token；不能复制Up整Tile作为每个GELU lane的私有缓存。当前一行GU在途的控制结构会限制SFU平均利用率，仍需验证整个后处理窗口能在下一GU Tile最终提交前排空。

Attention准入目标：`T_QK_POST + T_ALPHA + T_P_EXP_and_P_POST_tail < 实际matrix slot`，其中P_POST与P_EXP流式重叠；4-lane P_EXP仅算术发射下限是204拍，不能把IP尾部、workspace访问和拼包当零拍。

## 7. PCore物理存储计划

不更改外部接口宽度；对现有组合读改成同步读时，必须显式增加请求/响应保持和credit。表中的等效块数按RAM宽深补齐计，不按payload除容量。

| 存储 | 物理组织与端口 | BRAM36 | URAM |
|---|---|---:|---:|
| AFIFO | 2×288×32，奇偶写bank，各1R1W | 8 | 0 |
| BFIFO | 288×64，1R1W；不另计旧版WFIFO/scale FIFO | 4 | 0 |
| GU A Replay | 两Tile，2×288×26；合并地址后单1R1W | 8 | 0 |
| PBUF | 2个逻辑bank×奇偶，各136×26/25；保守分开 | 8 | 0 |
| FACC-A | 两个512bit奇偶bank，深26/25 | 16 | 0 |
| FACC-B | 同样两个512bit奇偶bank，URAM承载 | 0 | 16 |
| OACC | 两个512bit奇偶bank，深416/400 | 0 | 16 |
| QOZ | 两个136bit奇偶bank，深832，Q/O/Z复用 | 0 | 4 |
| 共享POST_TILE_STORE | 16×32bit×128，TDP；K/Q/V与GU分时 | 8 | 0 |
| SBUF | 合并两代为512×102，VPU写、SFU读，SDP | 8 | 0 |
| m/aa/l/recip/alpha[2] | 16个32bit bank，每bank24地址，TDP | 8 | 0 |
| KV Tile sender | 136×64，同步预读，等待commit才释放 | 2 | 0 |
| ACC返回队列 | 1024×4，SDP＋前端保持；不是LUTRAM | 15 | 0 |
| VPU量化/拼包暂存预算 | 单端口或1R1W，避免多读口复制 | 2 | 0 |
| SFU GELU系数 | 4×72×256 ROM | 4 | 0 |
| SFU exp表 | 4个IP各一RAMB36 | 4 | 0 |
| RoPE系数窗口 | 256×1632，同步读、四拍组包 | 0 | 4 |
| **单核合计** | 2×RAMB18按1×BRAM36计 | **95** | **40** |

FACC-A保留BRAM、B/OACC改URAM，是为平衡两类存储的容量，不是逻辑差异。三类ACC统一实际读延迟（必要时对BRAM补拍），DEQACC及VPU按统一响应协议处理。若一开始全部ACC都用BRAM，需额外32BRAM/核、八核增加256块，将超过示例动态区的总BRAM预算；不能只加属性而不核对整机。

### 7.1 POST_TILE_STORE为什么能同时支持转置和双行捕获

存储对象为两半的`[51,16]FP32`，最多声明64行；G/U是两个half，K/Q是RoPE的两个half，V仅使用其中一半。PCore七Job串行，当前GU Pair BUF内部也不允许同一Tile同时捕获和输出，因此可以复用物理空间，保持各自控制/valid合同。

对元素`(half,row,feature)`：

```text
bank = (row + feature) mod 16
addr = half*64 + floor(row/16)*16 + feature
```

- 捕获两个相邻row：每行16元素各落遍16bank，两个row每bank各一次写，使用TDP两端口
- RoPE读同一row的两个half：每bank各两次读
- V读16个token的两个feature：对每个feature，16个token各落遍16bank，两feature每bank各两次读
- GU读取一行G/U：与RoPE双half读相同，继续51个行握手，不改成26个pair输出

每bank32×128只需一个RAMB18，合计16 RAMB18=8 BRAM36。模式间需旋转/重排网络，**其LUT成本已经保留在区间预算中，不声称RAM替换就没有路由成本**。不能边捕获两行又要求同bank两个额外读口；若将来改成这样的重叠，必须重新分bank或增加端口，不沿用本计数。

### 7.2 SBUF与统计量

SBUF只有VPU写、SFU读，两个逻辑代存不同地址，适合一个1R1W物理阵列。统计量接口则是两路span读/写，采用`row%16`分bank，`object*4+row/16`寻址；六个逻辑对象占24地址。每bank最多两项操作，TDP分别服务VPU/SFU，同地址冲突由生命周期和显式检查拦截。

m初值负无穷、l初值零和各对象未写状态继续由小valid位图表达，不清整片RAM。能用顺序计数证明的重复写保护可压缩，但不能删除重复/越界/旧token检查。Q的Tile非顺序生产仍需保留Tile级提交状态。

### 7.3 保留FF的例外

- PE双份8bit驻留权重：每核4096FF；256路同时使用，不强行改成少数RAM读口
- Q_ACT_REG双行共256bit、E_STAT和scale/tag流水
- job/token/owner/valid、指针、小计数器和状态机
- RAM输出寄存器及一到两项弹性保持

这些不是LUTRAM。长数据FIFO不让工具随意改成SRL/LUTRAM；很浅的控制保持也不为“RAM优先”浪费十几块URAM。

## 8. GCore存储计划

| 存储 | 方案 | BRAM36 | URAM |
|---|---|---:|---:|
| RESID | 256×3264，URAM 1R1W | 0 | 4 |
| XHAT | 4×136×832，四行同步读取 | 16 | 0 |
| K/V合并窗口 | K/V各16 feature Tile×2 parity，共64bank；136×440 | 128 | 0 |
| sq＋inv | 各51×32，时间复用TDP端口，两个RAMB18 | 1 | 0 |
| **合计** | 单prefix窗口，suffix64槽 | **145** | **4** |

KV每bank地址0..407为prefix，408..439为suffix。保持对象、版本和lease独立，但不再给prefix/suffix各建一套浅RAM。K padding行仍在输出强制零，不能依赖未写RAM内容。

八核写路由静态化：K核c仅能写feature Tile c或c+8；V核c仅能写2c或2c+1。根据固定核号直接接对应bank，在入口核对header，不让64个bank各实现一个136bit八选一写交叉开关。未来prefix loader与suffix producer分阶段取得写口，不支持同一bank的无界多写端口。

sq在扫描/Residual阶段是读旧值＋写新值，rsqrt阶段是两行只读；inv在rsqrt阶段双行写，apply阶段只读。各用一个TDP RAMB18可满足，但同步读旧sq要提前一阶段请求，不是直接换数组属性。

八路两word接收保持、XBC/KVB广播holding和token队列继续少量FF；若后续加深才评估共享RAM。FIFO和广播容量应按credit计算，不能为了省LUT删掉反压保护。

## 9. Reduce计划

建议保持外部8×512bit输入、512bit输出不变，内部将16-lane树折叠为8-lane，两拍处理一行。每个FP元素仍严格遵守原固定八输入树，不改变浮点求和结合顺序。

- 7节点×8lane=56个FP加法器，按每个2DSP预算，共112DSP
- 前端8个512×8 FIFO采用BRAM，约64 BRAM36
- 结果Tile两个256bit half-bank共约8 BRAM36，先装满51行再发送并等待commit
- 同一个输入行的两半被树接受后才pop FIFO；half、row和transfer标签必须同步
- 无断供算术发射下限102拍，另有3级FP加法延迟、51拍发送、GCore写回和commit；不能据此直接宣布一定隐藏在下一NTile内

若以后实测无法隐藏，可恢复16-lane：额外112DSP，数据接口和数值顺序均不变。8-lane不是当前RTL已经完成的修改。

## 10. 汇总、占比与区域预算

DSP账本：GCore=`34×2+16×2+2×9=118`；PCore=`256+32×2+32×2+32×2+40=488`；GCore＋八核=`118+8×488=4022`；再加8-lane Reduce112，共4134。

| 资源 | GCore＋8 PCore | 占整器件 | 占base_5动态区 |
|---|---:|---:|---:|
| LUT | 380k～582k | 43.6%～66.7% | 54.0%～82.7% |
| FF | 558k～861k | 32.0%～49.4% | 39.6%～61.1% |
| DSP | 4022 | 67.6% | 81.7% |
| BRAM36 | 905 | 67.3% | 81.1% |
| URAM | 324 | 50.6% | 59.6% |

| 加上建议Reduce后 | 总量 | 占整器件 | 占base_5动态区 |
|---|---:|---:|---:|
| LUT | 392k～599k | 45.0%～68.7% | 55.7%～85.1% |
| FF | 578k～891k | 33.2%～51.1% | 41.0%～63.2% |
| DSP | 4134 | 69.5% | 84.0% |
| BRAM36 | 977 | 72.7% | 87.5% |
| URAM | 324 | 50.6% | 59.6% |

余量不是都能给新算子：BRAM示例只剩139块，DSP剩786个，还要给总控、应用侧HBM队列、跨SLR缓冲和布线复制。若LUT落在上界，局部拥塞仍有风险。18层/10步复用同一硬件，不将资源再乘18或10；单层prefix/权重切换是带宽与调度问题，不代表已经缓存18层。

### 10.1 两个SLR不能只看总量

示例动态区SLR0/SLR1的BRAM分别552/564，DSP2352/2568，URAM各272。四个PCore各放一个SLR：

| 资源示例 | SLR0 | SLR1 |
|---|---:|---:|
| BRAM | 4×95＋Reduce72＋GCore XHAT/统计17=469 | 4×95＋KV128=508 |
| DSP | 4×488＋Reduce112=2064 | 4×488＋GCore118=2070 |
| URAM | 4×40=160 | 4×40＋RESID4=164 |

这只是静态容量分配草案，不是布局结果。GCore子模块允许分开放置：KV与共享FP计算偏SLR1，XHAT/广播及Reduce偏SLR0。跨SLR数据通路加寄存器切片和独立反压，不把整个GCore强绑一侧，也不默认一个巨大的八核组合广播网可以满足4ns。

## 11. 如何降低LUT以及验证顺序

1. 先落实静态bank写路由、同步RAM、POST_TILE_STORE复用，去掉无必要的宽交叉开关和重复物理缓存；不先改整数数值链
2. 生成少量候选FP add/mul/rsqrt/exp IP，确认DSP/BRAM配置、实际延迟和数值边界；现有严格参考继续保留
3. 对照算术封装替换或改造后端；先做单算子，再做MXU→DEQACC、GCore Norm/Residual等真实链路仿真
4. 对两个PE packed归约候选做显式DSP模型等价测试、完整矩阵测试，再决定是否纳入部署结构
5. 接VPU/SFU的有限吞吐RTL或匹配IP模型，保留七Job/55组QK-PV的全部检查，测非矩阵隐藏余量
6. 之后再做少量OOC综合确认本表，再做八核系统资源、SLR和250MHz实现；不能反过来将此手算当签核

首轮资源实测优先级：POST/RAM映射、DEQACC浮点后端、单核含VPU/SFU、GCore、Reduce。若LUT接近动态区85%以上或BRAM近90%，先调整后端/存储和局部路由，不直接给全系统下“资源足够”的结论。

本轮已经完成：当前实例关系和存储端口的静态核对、预算加总及百分比复算、两个packed乘积的整数代数检查。未完成：新资源映射RTL、IP生成、综合、时序、GELU拟合与真实八核联调。所有上表收益均待实施和验证。
