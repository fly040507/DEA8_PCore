# 实现状态（2026-09-12）

DEQACC详细设计已补充到 DEQACC_详细设计.md，包含五级逐沿时序、16lane数据通路、累加端口、清零/冒险及浮点语义。deqacc_bitexact.py提供整数运算实现的FP32参考模型，新增7项测试（含两万组随机对照）；当前Python合计20项通过。这是设计与模型验证，尚未替换下表所列占位RTL，也未完成FP32综合时序签核。

当前冻结规格：冻结规格_2026-09-12.md。旧2026-09-11发布快照保持历史状态。

| 模块 | 本次状态 | 仍待完成 |
| --- | --- | --- |
| W_Loader | HBM拆包、双FIFO、完整Tile预留、16拍装载、首拍scale、唯一bank状态所有者 | FPGA FIFO宏和系统HBM接口集成 |
| MXU | 独立输入寄存器、ACTIVE scale、pipe[1:5]、首Tile末加载沿启动、末乘法沿切bank | 目标器件综合/时序、真实QOZ同步读集成 |
| PE | 双INT8权重、signed乘法、INT16乘积寄存器 | DSP映射/频率实测 |
| DEQACC | 保留符号/绝对值/指数原型 | partial_fp仍为0；真实五级FP32与写回未实现 |
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

Python：13项通过；移除旧全局freeze模型测试，改为连续51行与六阶段post-edge对齐检查。

输入接口契约：上游在首行发射前预留整个Tile的激活与下游容量。
bank_load_enable只管Bank Load启动，不是停顿输入；当前不提供运行中freeze。
后续应以本次W_Loader/MXU接口接Matrix Sequencer与QOZ，再接真实DEQACC和Attention执行器。
