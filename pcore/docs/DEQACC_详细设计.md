# DEQACC 详细设计

设计日期：2026-09-12。依据当前 README 冻结规格，保持 MXU 权重驻留、激活广播、旁带 pipe[1:5]，DEQACC 为 L0～L4。当前已补充真实算术RTL与XSim验证，尚未完成目标器件综合时序和完整Attention集成。新增的舍入、异常和端口规则是本次设计决策，不冒充原 README 条款。

## 1. 边界与职责

每拍接收 MXU 的一个输出向量：同一行 m、同一输出列组 nt、同一归约块 kt 的16个 INT32 Psum。每个 Psum 已在 MXU 内完成16项 INT8 乘积的整数归约。

DEQACC 做两件事：每 lane 使用自身 E_stat 和共享 E_stream 反量化；随后把这个 FP32 部分和与目的地址的旧 FP32 累加值相加。16个 lane 对应16个不同输出元素，绝不能在 DEQACC 中把16个 lane 横向加成一个数。

QK：16个 kt 先各自反量化，再对同一 FACC 地址按 kt 次序累加。不同 kt 的 scale 可以不同，因此不能先把所有 INT32 Psum 相加再统一反量化。

PV：kt 只有一块，但仍需要把 PV 部分和加到已经由 VPU 缩放好的 OACC。kt=0 不代表可以清零 OACC；是否覆盖必须是独立控制字段。

不在本模块执行：Mask、RowMax、exp、alpha 生成、alpha×OACC、P 量化、l 更新、最终 OACC/l。SBUF 只保存 VPU 处理后的 masked score，不是本模块的直接累加目的地。

## 2. 物理结构与画图

左侧五组线：PSUM[511:0]、E_STAT[127:0]、E_STREAM[7:0]、TAG[57:0]、DEST[12:0]，另画valid控制线。它们同沿采样，不增加合包RAM或16×16 Psum暂存阵列。

PSUM 按每32bit固定切片送入16个 lane；E_STAT 按每8bit固定切片送入对应 lane；E_STREAM 广播给16个 lane；TAG 送共享控制流水。不是16根单比特线，也不是所有 lane 动态读取一条总线。

画16个并列 lane，内部从左至右为 L0 SIGN/ABS/EXP、L1 LZC/NORMALIZE、L2 FP32 PACK、L3 FP32 ADD。L4画统一的512bit写回端口。每级之间画寄存器线，并在下方画共同推进的 valid、tag 和目的地址。

FACC_A、FACC_B、OACC 画在 L3 下方。三路512bit同步读响应进入一个3选1 MUX，再经过 OLD_L2_REG，与 L2_PARTIAL_REG 一起进入16个 FP32 加法器。读地址从 L0 控制寄存器发起，不从加法器临时发起。

L3_RESULT_REG 的512bit结果经写使能译码写回三个存储之一；L4是目的 RAM 实际写入沿，不再额外增加一个完整512bit L4暂存寄存器。写回 tag 同时生成 commit。ZERO画成 L2 操作数选择器上的常数输入，不画ZERO存储。

## 3. 输入接口与控制来源

| 信号 | 规格与含义 |
| --- | --- |
| mxu_rsp.psum | 16×32=512bit，lane n 为 [32n+:32] |
| mxu_rsp.e_stat | 16×8=128bit，lane n 为 [8n+:8] |
| mxu_rsp.e_stream | 8bit，共享的A组指数编码 |
| mxu_rsp.tag | 当前pipe_tag_t为58bit，无bank/blk；RTL用$bits(pipe_tag_t)推导 |
| valid | 1bit，同一事务的四路有效 |
| acc_sel | 2bit，FACC_A/FACC_B/OACC；SBUF编码在本接口非法 |
| acc_addr | 当前10bit，FACC仅0～50，OACC仅0～815 |
| acc_clear | 1bit，忽略旧存储、使用+0；不能由 kt==0无条件推导 |

四路Psum/Scale/Tag有效载荷706bit，目的描述符另有13bit，合计719bit，另加valid。目的描述符已由Sequencer经DEQ_DEST_REG和dest_q[1:5]与MXU数据同步推进，禁止从“当前最新命令”现场组合旧事务目的地。

当前固定方案：QK 的目的为分配给当前 block 的 FACC bank，地址=row；第一个有效 kt 设置 acc_clear。PV 的目的为 OACC，地址=nt×SUFFIX_LEN+row，nt 是0～15的输出列组编号；只有初始 PV0 可按初始化策略设置 acc_clear，后续块必须读缩放后的 OACC。普通 Linear/FFN 也使用按输出列组排程的 FACC，逐 kt 归约后交给 VPU，下一个输出列组覆盖前必须等旧结果消费结束。

lane_mask 在写回阶段作为16个32bit lane 的写使能。它是物理 lane 有效性，不是 Attention 可见性 Mask；不可用它代替 score=-inf。被禁用 lane 不改变原 RAM 内容；任何读者都不能使用未初始化的无效 lane。

## 4. 五级逐拍定义

设 MXU 响应在 E0 沿被 DEQACC 接受。表中“写入”均指该沿之后寄存器的新值。

| 时钟沿/阶段 | 数据和存储动作 |
| --- | --- |
| E0 / L0 | 锁存 sign、32bit magnitude、10bit有符号组合指数、scale非法标志、tag和目的描述符。此时不做 FP32 加法。 |
| E1 / L1 | 前导零检测，得到最高有效位 p 和左对齐32bit有效数；锁存初步浮点信息。同步 RAM 同沿采样 L0 的目的读地址，沿后输出旧值。acc_clear 时可以关闭读使能。 |
| E2 / L2 | 完成指数调整、RNE及 FP32打包，写 L2_PARTIAL_REG；同时锁存对应 RAM 响应到 OLD_L2_REG，clear时锁存+0。 |
| E3 / L3 | 16个 FP32加法器分别完成 partial+old，写 L3_RESULT_REG。clear路径可直接旁路partial，但必须保持同样延迟。 |
| E4 / L4 | RAM 采样 L3_RESULT_REG、写地址和lane写使能；实际提交。commit寄存器在沿后报告该事务已提交。 |

因此 DEQACC 是五个逻辑阶段，E0接受到E4提交相隔4个周期。MXU若从 A0输入沿到A5产生结果，DEQACC在A6接受，则A10写回；串联共有11个阶段，首输入到最终提交是10个沿间隔。描述尾延迟时必须标明起点，不再把11级直接写成任意事件后11拍。

必须使用同步1拍读 RAM。若 BRAM/IP 配成2拍读，则将读请求提前到 E0 输入接受沿，由输入描述符直接产生，使数据仍能在 E2进入OLD_L2_REG；否则必须增加延迟，不能沿用本表。

## 5. L0 符号、绝对值和指数

partial_exact = signed(Psum) × 2^q；q = unsigned(E_stream)+unsigned(E_stat)-266+signed(exp_fold)。QK exp_fold=-4；PV和一般矩阵乘法为0，特殊缩放由命令明确提供。

两种scale都只参与指数组合，不需要 FP32 scale乘法器。MXINT8 单个值是 q_int8×2^(E-133)，两个输入的乘积因此减266，而不是减254。

指数中间计算先扩成有符号10bit，再做加减；不能先在8bit相加。当前6bit exp_fold范围-32～31，有限E8M0编码0～254时 q范围-298～273，10bit足够。

magnitude 用32bit无符号保存。INT32最小值的绝对值是0x80000000，不能放回 signed INT32当成正数。scale编码255按非法/NaN处理，优先于 Psum==0，输出规范 quiet NaN 0x7fc00000；有效scale且Psum==0输出+0。

## 6. L1 归一化与 L2 反量化

L1 对非零 magnitude 做32bit LZC。p=31-LZC，normalized=magnitude<<(31-p)，保留全部32bit，不在L1先舍入成24bit。L2计算真正的无偏指数 u=p+q，然后一次完成最终RNE，避免先INT32转FP32、再缩小导致的双重舍入。

正规数：保留24位有效数，舍弃部分生成 guard、round、sticky；进位条件为 guard&&(round||sticky||保留值最低位)。舍入进位后需要再次调整指数。超过最大有限范围按RNE输出有符号Infinity。

非正规数：以2^-149为单位对 magnitude×2^(q+149) 直接做最近偶数舍入。可能得到有符号零、非正规数，或进位成为最小正规数。默认不采用FTZ；之后若项目决定flush-to-zero，必须作为全链路精度变更重新验证。

16项INT8点积本身最多需要20bit有符号表达，可被FP32精确表示；普通范围内反量化只是二进制指数调整。但32bit输入接口和subnormal边界仍须完整定义，不应因典型情况精确就删掉舍入逻辑。

示例：Psum=16、E_stream=127、E_stat=127、QK fold=-4，q=-16，partial=16×2^-16=2^-12，FP32编码0x39800000。

## 7. L3 加法器与共享方式

物理上配置16个FP32加法通道，每通道每拍接收一组 old、partial，目标II=1。FACC是RAM而不是另一组加法器；QK归约与PV更新复用这一组加法器。VPU的alpha乘法器独立，不由本加法器执行。

加法顺序固定为按 kt 的逐块FP32累加，不是树形FP32累加，也不是FP64先累加再转换。每次相加按FP32 RNE舍入。NaN规范化，异号Infinity相加产生NaN，完全抵消产生+0；两项都是-0时保留-0。需实现subnormal与signed-zero一致性。

五级目标意味着 L3 只能占一个物理周期，即组合FP32加法器加结果寄存器。不能直接使用默认多周期 Xilinx Floating-Point IP却仍声称总共五级。优先综合验证单周期加法实现；若达不到系统目标频率，需正式调整为多周期加法器，同时延长tag、写回、commit与资源保留窗口。流水加法器即使延迟变长，仍可保持II=1，但不再是本版固定五级。

本次只冻结接口与运算语义，不虚构单周期FP32加法器已通过Vivado时序。器件、时钟约束和FP实现选择仍是物理签核条件。

## 8. 存储数量、端口与寄存器

| 单元 | 本设计规格 |
| --- | --- |
| FACC_A、FACC_B | 两个逻辑bank，各512bit×51，共6528Byte；每bank独立读地址、写地址、1R1W。保存未加Mask的FP32部分和/最终和。 |
| OACC | 一个512bit×816，52224Byte，独立1R1W；保存当前在线softmax分子，缩放后阶段保存alpha×旧分子。 |
| L0每lane | magnitude32、sign1、scale_exp10、bad_scale1，共44bit；16lane共704bit。 |
| L1每lane | normalized32、合并后的unbiased_exp10、sign1、zero1、bad_scale1，共45bit；16lane共720bit。p只在L1组合逻辑使用，不另存寄存器。 |
| L2每lane | partial32、old32，共64bit；16lane共1024bit。 |
| L3每lane | result32；16lane共512bit。 |
| 共享控制 | E0～E3四组tag58+descriptor13+valid1，共288bit；E4另有commit_valid和commit_tag等报告寄存器。 |

上述数据寄存器共2960bit，顶层控制按当前字段为288bit，不包括commit报告、每lane本地valid/clear延迟、存储输出寄存器、综合复制和FP算术内部附加资源。lane_mask在tag内，不再另算一份。不存在额外256个INT32 Psum暂存寄存器，也不存在存全部kt部分和的RAM。

宽512bit只是逻辑字宽；物理BRAM数量取决于目标器件端口宽深、按32bit lane写使能的映射与拼接。不能用有效容量简单除BRAM容量就声称是最终资源占用。

现有dea8_attention_storage的FACC只有一个共用地址，必须拆成facc_rd_en/rd_bank/rd_addr以及wr_en/wr_bank/wr_addr/wr_lane_en/wdata；不能把读地址与两拍之后的写地址绑在一起。现有OACC已有独立地址，但仍需lane写使能、所有权及提交跟踪。

## 9. 数据线与带宽

| 路径 | 宽度和用途 |
| --- | --- |
| MXU→DEQACC | Psum/Scale/Tag706bit，另有Dest13bit，载荷719bit，加valid1。 |
| L2→16加法器 | partial总512bit、old总512bit；每lane两条32bit输入。 |
| 16加法器→L3寄存器 | 每lane32bit，共512bit。 |
| 每个累加RAM读口 | rd_en1、rd_addr10（FACC可缩为6）、rdata512。 |
| 每个累加RAM写口 | wr_en1、wr_addr10（FACC可缩为6）、lane_we16、wdata512。 |
| 写回控制 | 目的选择2bit共享，非每lane各自选择；16lane写同一逻辑向量地址。 |

每个512bit数据方向可传64Byte/拍，时钟f MHz时为0.064f GB/s，例如250MHz时16GB/s。1R1W同时读写合计32GB/s只是片上端口聚合数，不是HBM带宽。每lane数据方向32bit，250MHz时1GB/s；实际频率未确定。

## 10. 相关冒险与清零

当前方案不加累加前递网络。调度必须保证对同一bank同一地址的两个有效输入事务接受沿至少相隔4拍：前事务E4写回，后事务最早E5读取，不依赖RAM同址读写模式。间距3会在同一沿读写，禁止；间距更小会读到旧值，必须在输入前阻止并在仿真报错。

QK一个kt处理51行，下一kt回到同一行相隔51拍，满足要求。普通矩阵若有效M小于4，需要在Tile边界补空拍或后续新增前递，不可宣称任意尺寸都无气泡。未来若改变L3延迟，应从实际commit沿重新推导间距。

acc_clear使该事务不读旧存储，L2选择常数+0，L3可旁路partial。不需要ZERO RAM、不需要预先逐地址清FACC。PV0在无有效旧OACC时明确clear；PV1以后禁止clear。clear并不消除正在写同地址的事务排序约束。

不整块复位BRAM。每个新tile/block靠clear与有效性控制保证先写后读。reset清流水valid和所有权，旧RAM数据仍存在但不得被视为有效。

## 11. OACC与VPU的交接

PV期间DEQACC拥有OACC读写端口，SCALE期间VPU拥有同一组端口，AFIN只读。控制器以真实提交而非MXU最后发射切换所有者。

基础正确性方案：最后PV事务L4提交后，才允许VPU发出第一条SCALE读取；最后SCALE写回提交后，才允许下一PV开始读取。这样无需依赖BRAM读写同址的读优先/写优先行为。VPU必须提供scale_commit_done而不仅是scale_issue_done。

要进一步使两个阶段首尾相接，可在最后PV提交同沿读取另一个已提交的地址，但需显式验证地址、不共享写口、响应所有权，属于后续优化，不作为当前100%利用率承诺。816拍是每阶段有效向量数量；总时间还包括流水头尾、首Tile16拍及实际资源等待。

SCALE使用下一PV块对应的alpha_b，遵守O_b=alpha_b×O_(b-1)+PV_b。alpha双bank按block/epoch和valid识别，不能仅靠A/B交替猜代际。SCALE不回到DEQACC做乘法。最终PV54提交后才允许倒数和AFIN消费最终OACC。

## 12. 完成与验证接口

commit_valid在L4实际写入时产生，携带原tag、目标、地址、lane_mask；final_k表示该输出元素归约完成，last表示命令末事务，两者不得混用。命令完成需要最后事务已提交且本命令inflight计数为零，不依赖固定等待11拍。

无Tile内反压。开始前Sequencer要保证16路DEQACC每拍可接收、存储独占且无RAW冲突；valid空拍可自然推进。禁止只暂停tag或只暂停加法器。当前rhs ready只能作为协议检查，不能使MXU输出原地等待。

算术验收：INT32最小值、零、全INT8极值、scale0/254/255、QK=-4/PV=0、RNE中点、subnormal边界、溢出、加法抵消、Infinity/NaN。测试使用二进制整数精确参考，不能以Python双精度连续累加替代逐次FP32。

时序验收：连续816向量，每lane独立scale与tag；E0输入/E4提交逐项比对；QK16块不同scale归约；PVclear与非clear；三种目的路由；非法SBUF目的；同地址间距3拒绝、4允许；最后写回后才释放所有权；reset途中不误写。

## 13. RTL落实清单与当前状态

现有dea8_deqacc_lane.sv已实现L0～L3；dea8_deqacc.sv提供共享控制、16lane顶层、目的描述符与L4提交。dea8_accumulator_storage.sv提供分离读写地址的FACC/OACC实现。目前旧Attention storage仍保留作为未集成原型，新存储在DEQACC及整链测试中使用；后续Top应以新实现替换旧累加存储，而不是额外增加一套。

deqacc_bitexact.py为独立整数参考模型；dea8_fp32_pkg.sv为实际组合算术RTL，不调用real/shortreal或Python。XSim已覆盖边界、随机数值及写回时序，详见DEQACC_RTL接入说明.md。下一关口是目标器件综合、FP32加法器目标频率评估和Attention执行器集成。
