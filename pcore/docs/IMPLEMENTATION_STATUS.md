# 实现状态（2026-09-12）

DEQACC已从占位原型替换为实际RTL：L0～L3算术、L4同步RAM提交；详见 DEQACC_详细设计.md 和 DEQACC_RTL接入说明.md。Python整数位精确模型用于生成独立XSim预期值。本次完成数值与周期仿真，不等于完成目标器件综合、时序或完整Attention验证。

当前冻结规格：冻结规格_2026-09-12.md。旧2026-09-11发布快照保持历史状态。

| 模块 | 本次状态 | 仍待完成 |
| --- | --- | --- |
| W_Loader | HBM拆包、双FIFO、完整Tile预留、16拍装载、首拍scale、唯一bank状态所有者 | FPGA FIFO宏和系统HBM接口集成 |
| MXU | 独立输入寄存器、ACTIVE scale、pipe[1:5]、首Tile末加载沿启动、末乘法沿切bank | 目标器件综合/时序、真实QOZ同步读集成 |
| PE | 双INT8权重、signed乘法、INT16乘积寄存器 | DSP映射/频率实测 |
| DEQACC | 实际FP32 RNE反量化/加法、16lane、同步读旧值、L4提交、RAW断言 | 目标器件综合/时序，生产级Sequencer目的描述符接入 |
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
后续应将Matrix Sequencer/QOZ接入已验证的MXU/DEQACC模块，再完善Attention完成握手、PBUF/SBUF双地址、alpha代际保护。当前Attention控制器仍不能作为实际执行器使用。
