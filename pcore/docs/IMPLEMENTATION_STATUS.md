# 实现状态

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
