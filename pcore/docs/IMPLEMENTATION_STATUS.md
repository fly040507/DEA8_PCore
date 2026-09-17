# 实现状态

## 2026-09-17：Q Projection端到端增量

新增Projection执行入口、成对XBC暂存和后处理结果接口；真实MXU/DEQACC完成64组K归约、16组输出列块。
VPU数学行为壳从实际FACC读取并量化，结果写入真实QOZ/E_QOZ；不是直接注入golden结果。
W Loader/MXU增加同步clear，Projection取消后隔离旧DEQACC事务，再允许新任务；旧Attention调用将clear绑0，保留原复位契约。
完整W Loader已做OOC综合；尚未合并W/KV共享PCore Top、实现RoPE或交付正式VPU/SFU。
详见 [Q Projection实现](Projection_Q端到端实现_20260917.md) 和 [本轮验收记录](Projection与Attention验收记录_20260917.md)。
最终XSim77个模式通过（38正常、39预期错误），Python25项通过，89个受测文件校验一致。
全尺寸Projection正常完成87473拍；Attention含尾部矩阵91924拍、行为AFIN后92799拍。
下文“Projection未实现”等为历史阶段状态，不能用于描述当前独立Projection执行入口。

## 2026-09-17：B侧配对列流增量

W/KV各使用独立64×136bit同步读FIFO，统一BEntry与列写入数据通路；KV元数据在入队前校验，FIFO仅存payload。
HBM保持8数据beat+1scale beat，采用一个272字节Tile Assembler完成行转列；接收与排出不重叠，依靠ready背压。
W路径不再使用512×128数据FIFO和32×128scale FIFO，scale改为逐列同步写E_STAT。
`start`使用同步clear清空KVFIFO，不再拼接复位。
单FIFO在代表器件XCU280的综合中推断为2个RAMB36E2；尚未完成全PCore布局布线/时序签核。
详见 [B侧接口契约](B侧统一列流与接口契约_20260917.md)。下文为历史阶段记录。
最终全量XSim通过67个模式（33正常、34预期错误），Python20项通过。
含尾部槽矩阵Done仍为91924拍，行为模型Attention Done为92799拍；
日志、源码校验与资源报告见 [B侧验证记录](B侧统一列流验证记录_20260917.md)。

## 2026-09-17：完整 Attention 行为模型联调

PV53后新增至少828拍尾部SCALE时隙，并要求真实VPU done后才能启动PV54；没有虚构QK55。
Scheduler已消除普通Block多余交接拍。SFU/VPU可选仿真数学模型经实际接口产生P、缩放OACC并计算AFIN。
正常场景矩阵Done=T91924，比纯矩阵T91096恰好多828；AFIN后的Attention Done=T92799。
独立Python对照覆盖所有PV结果及AFIN；另测尾部慢完成和故意跳过缩放的错误注入。
详见 [完整联调与尾部时隙](Attention_完整联调与尾部时隙_20260917.md)。
最终XSim全量59个模式通过（30正常、29预期错误），Python20项通过；
证据见 [尾部联调验证记录](Attention_尾部联调验证记录_20260917.md)。
仿真数学模型不属于可综合SFU/VPU，不代表正式算术微架构已经实现。

## 2026-09-17：Attention 连续矩阵调度

最新矩阵侧依据改为用户本次连续 KVB / 跨 Job 预加载方案，详见
[Attention 连续矩阵调度](Attention_连续矩阵调度_20260917.md)。
已接入两项 Job 队列、256 项连续 KVFIFO、直接 B-column 写 PE、跨 Job tile0 预加载与最终 commit 屏障。
Attention 主路径不再经过旧 expect_job Adapter 或 tile_columns；HBM 路径仍保留原加载格式。
独立矩阵测试实测稳态 828 拍；该数字不包含完整 VPU/SFU 依赖与尾部 OACC 缩放。
本次 XSim 全量 56 个模式通过（28 正常、28 预期错误），Python 20 项通过；
原始日志、周期 CSV 和受测源码 SHA256 见 [验证记录](Attention_连续矩阵验证_20260917.md)。
以下记录按日期保留；其中“不能跨 Block 预加载”“V column 未确认”等旧描述不适用于新 Attention 路径。
未同步发布快照、未上传 GitHub，未做目标器件综合时序签核。

## 2026-09-14：第六轮 Frontend 增量

新增 KVB Adapter（完整事务 KVFIFO、Expected Context、协议检查、KV_MASK）和 XBC Adapter（原始 XFIFO、两路拆分）。
Attention Core 可选接正式 KVB 接口，QK_POST 提供独立的有效 key mask。
详见 [Frontend 接口与验证](R6_Frontend_接口与验证.md)。以下 09-13 段落是历史状态。
V Payload/量化方向已明确；V 的 key_lane 编码仍保留显式确认开关。
未完成部分仍包括 Projection、CNET、完整 PCore Top 和真实 VPU/SFU 算术。

## 2026-09-13：第六轮进行中

最新 PCore 依据为桌面 README.docx。第六轮当前改动详见 [R6_进度与接口边界.md](R6_进度与接口边界.md)。
已抽出共享 Stationary Loader，QK Engine 改接独立 Bank 的 Accumulator Fabric，
新增双地址 SBUF/PBUF 和完成驱动 Attention Scheduler；第二阶段已接实际 QK/PV Matrix Engine，
并在 Attention Core 中贯通 55 对矩阵 Job 与外部测试客户端，PV 含独立位精确验证。
第三阶段已加入标量 RF/alpha 代际保护和 SFU->VPU P 流，并抽出四个独立仿真壳。
VPU/SFU 壳只提供固定输入联调行为，不是正式算术；GCore/HBM 壳仅独立验证传输。
正式 KVB Adapter、XBC/CNET 接入及完整 PCore Top 仍未完成。
当前 B 入口是规范化列流，不应当标为已冻结 GCore KVB。详见 R6 文档第二阶段更新。
下面保留第五轮验证记录，不能把其中旧 Attention 原型当作第六轮主链。

## 2026-09-12：第五轮基线记录

DEQACC已从占位原型替换为实际RTL：L0～L3算术、L4同步RAM提交；详见 DEQACC_详细设计.md 和 DEQACC_RTL接入说明.md。Python整数位精确模型用于生成独立XSim预期值。本次完成数值与周期仿真，不等于完成目标器件综合、时序或完整Attention验证。

当前冻结规格：冻结规格_2026-09-12.md。旧2026-09-11发布快照保持历史状态。

| 模块 | 本次状态 | 仍待完成 |
| --- | --- | --- |
| W_Loader | HBM拆包、双FIFO、完整Tile预留、16拍装载、首拍scale、唯一bank状态所有者 | FPGA FIFO宏和系统HBM接口集成 |
| MXU | 独立输入寄存器、ACTIVE scale、Tag58/Dest13对齐流水；首Tile末加载沿启动、末乘法沿切bank | 目标器件综合/时序 |
| PE | 双INT8权重、signed乘法、INT16乘积寄存器 | DSP映射/频率实测 |
| DEQACC | 实际FP32 RNE反量化/加法、16lane、同步读旧值、L4提交、RAW断言，QK目的描述符已接入 | 目标器件综合/时序 |
| QK Engine | QK-only Sequencer、同步QOZ/E_QOZ、Job Context、commit barrier，连接Loader/MXU/DEQACC/FACC | PV/Linear扩展、Attention完成握手集成；resources_ready依赖上游真实预留 |
| Accumulator Storage | 独立FACC_A/B与OACC逻辑bank，读写分址、32bit lane写使能，已接DEQACC验证 | 接VPU所有权及多客户端端口；替换旧Attention storage中对应存储，不能重复实例化两套 |
| Attention Controller | 原有55块命令次序原型 | 不含实际832拍执行器、任务完成输入、写回屏障；done仅代表A_FIN命令接受 |
| Attention存储/OACC/alpha | 保留先前原型 | 尚无Top；alpha无代际valid/防覆盖；仲裁不排队 |
| Python | Loader首拍配对与16拍模型、六寄存阶段输出模型 | Attention未达FP32位精确，量化原型非RNE |
| Mask | 保留先前原型 | Action互相可见规则与旧RTL仍不一致，未作为本次MXU验证范围 |

本次XSim：
- 全部filelist通过xvlog。
- 两block/32Tile/1632行，26112个lane数值、scale/tag及精确延迟逐项检查通过。
- 预填满FIFO和流式HBM两种模式通过；延迟首Tile的scale期间不允许加载。
- 注入Tile内激活断流，按预期触发Local stall inside tile。
- Attention原有命令计数测试通过；不是Attention数值验证。

DEQACC XSim覆盖100225组FP32加法、51568组反量化、3433个16lane向量，包含QK归约、PV更新、部分lane写使能保留、间距4同地址复用、reset flush。连续与空拍两种模式通过；间距1/3 RAW、非法SBUF目标、地址越界为预期失败测试。

Python：20项通过；移除旧全局freeze模型测试，改为连续51行与六阶段post-edge对齐检查。

输入接口契约：上游在首行发射前预留整个Tile的激活与下游容量。
bank_load_enable只管Bank Load启动，不是停顿输入；当前不提供运行中freeze。
QK Engine新增验证：两个Job、1632事务；同步QOZ数据与scale、输入/输出/提交Tag和Dest、最后RAM读回与Python逐位一致。供数充分时832拍窗口；断供仅在Tile边界等待。见QK_Job接口与验证.md。

后续应完善Attention完成握手、FACC到VPU Mask/RowMax、PBUF/SBUF双地址及alpha代际保护。当前Attention控制器仍不能作为实际执行器使用。
