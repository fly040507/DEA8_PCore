# Projection与Attention验收记录

对应设计：[Q Projection端到端实现](Projection_Q端到端实现_20260917.md)。
环境：Vivado/XSim2022.2，代表综合器件XCU280；源码位于主开发目录`VLA/pcore`。
验证范围是一个PCore的Q线性Projection，以及一个head/epoch的55-KV-Block Attention。
不包含真实HBM板卡、正式GCore/VPU/SFU、RoPE、全head/layer推理或实现时序签核。

最终`run_xsim.ps1 -Test all`退出码0：共77个模式，38项正常PASS、39项错误注入触发指定断言。
日志中39条Fatal均对应预期错误模式，没有把它们计为正常数值测试。
Python25项PASS，其中新增5项量化单元测试覆盖零块、RNE中点、scale边界、次正规数和非有限值。
受测89个源码/测试/模型/脚本文件的SHA256在最终回归后全部复核一致。

## 1. Projection检查内容

真实通路：

```text
HBM测试源 -> W_Loader -> PE权重Bank
GCore XBC测试源 -> 双K块A缓冲 -> Q_ACT_REG -> MXU
MXU Psum/scale/tag -> DEQACC -> FACC
FACC同步读 -> VPU量化行为模型 -> 正式结果握手 -> QOZ/E_QOZ同步RAM
QOZ外部读端口 -> TB逐元素读回校验
```

没有把完整矩阵结果从参考文件直接写入DUT。Python文件只供监视器比较。
VPU模型读取真实FACC结果后计算量化值；TB还独立核对这些返回值。

| 检查对象 | 每次完整任务的数量 | 判据 |
| --- | ---: | --- |
| HBM Tile/beat | 1024 / 9216 | 精确握手计数及顺序 |
| XBC双块beat | 26112 | 按nt重放、pair/row/epoch及scale正确 |
| INT32 Psum | 52224个16lane向量 | 与独立Python整数点积逐位一致 |
| FP32部分归约写入 | 52224个16lane向量 | 与独立RNE反量化/加法模型逐位一致 |
| 最终FACC读回 | 816个16lane向量 | 与最终FP32矩阵逐位一致 |
| VPU量化结果 | 816组INT8向量及scale | 与独立整数舍入参考一致 |
| 最终QOZ RAM读回 | 816组数据及scale | 内容、row*32+nt地址全部一致 |
| Tile内部连续性 | 每Tile51行 | 不允许行内断流；缺数在边界等待 |
| 完成屏障 | 16次post，1次Projection done | 必须晚于实际归约/写回；完成口支持背压 |

输入包含正负INT8极值、非均匀逐组scale和一整行零值。
FP32结果正确性针对“量化A/W输入及逐组反量化/归约次序”，不能等同于无量化实数矩阵的零误差。

## 2. Projection场景

| 模式 | 实际目的 | 结果 |
| --- | --- | --- |
| default | 完整51×1024×256，实际QOZ读回 | PASS，87473拍 |
| STALL | HBM、XBC插空，VPU接命令/读/返回延迟 | PASS，103497拍 |
| CLEAR_RESTART | 矩阵运行中取消，排空后不同epoch从头执行 | PASS，重启完整任务87473拍 |
| CLEAR_POST | 已写部分QOZ后取消，再次完整计算并读回 | PASS，重启完整任务87473拍 |
| REPEAT | 不做硬复位连续执行两个完整任务 | PASS，每次87473拍 |
| BAD_XBC | 故意发送错误XBC epoch | 指定协议断言触发 |
| EARLY_DONE | VPU未完成51次写回即报告完成 | 指定完成屏障断言触发 |
| BAD_RESULT | VPU返回错误结果上下文 | 指定结果协议断言触发 |
| BAD_QUANT | 故意翻转量化结果一位 | 独立QOZ数值oracle检出 |
| W FIFO depth=8 | 整Tile预留要求与FIFO容量冲突 | 初始化时明确报错，不允许静默死锁 |

Projection周期从任务接受沿计到done_valid有效状态，包含输入暂存等待及当前VPU行为模型执行。
default不等于硬件吞吐上限；本轮不将A-pair接收与计算重叠。
清空重启记录中的87473拍只指重启后完整任务，不包含被取消任务已消耗的周期和恢复等待。

## 3. Attention检查口径

原有`tb_dea8_attention_matrix`验证55次QK和55次PV，共110个Matrix Job、89760个16lane写回向量，使用独立位精确参考。
其无尾部槽的纯矩阵总周期口径为91096拍，不是完整Attention总周期。

`tb_dea8_attention_core`的SOFTMAX模式还执行真实接口下的VPU/SFU数学行为：
Mask/RowMax、alpha、P生成与量化、l更新、54次OACC缩放、倒数与AFIN。
QK逐位检查；PV/AFIN采用`abs_error <= 2e-6 + 2e-6*abs(reference)`，允许EXP数学库带来的微小差异。
不能把数学行为模型描述为正式SFU/VPU的精度或时序验收。
尾部保留PV53与PV54之间独立828拍SCALE槽，且等待实际VPU done，没有QK55。

本轮最终实测：纯矩阵91096拍；普通稳态828拍；含尾部槽矩阵完成91924拍，行为模型AFIN后Attention完成92799拍。
尾部慢完成场景为矩阵92116拍、Attention92991拍，证明控制器仍等待实际完成。
故意跳过最后一次OACC缩放时，被独立PV数值oracle按预期检出。

## 4. W_Loader综合

已对完整W_Loader做OOC综合，不仅仅是FIFO。
实测2个RAMB36E2、700 LUT、2364 FF；Assembler子模块575 LUT/2197 FF，FIFO97 LUT/156 FF，Bank控制28 LUT/11 FF。
没有Critical Warning/Error，日志保留常量输出/package/OOC时钟相关警告。
包含Assembler、FIFO及Bank控制，不包含PE/MXU/DEQACC/Projection其余部分；不是整个PCore资源结论。
未布局布线，不能以4ns约束宣称系统已达到250MHz。

## 5. 可追溯证据

- [全量XSim日志](evidence/20260917_projection/xsim_all.txt)
- [Python单元测试](evidence/20260917_projection/python_unittest.txt)
- [受测源码SHA256](evidence/20260917_projection/SOURCE_SHA256.csv)
- [Projection正常周期](evidence/20260917_projection/projection_cycles.csv)
- [Projection断供周期](evidence/20260917_projection/projection_stall_cycles.csv)
- [计算中clear后重启](evidence/20260917_projection/projection_restart_cycles.csv)
- [post阶段clear后重启](evidence/20260917_projection/projection_clear_post_cycles.csv)
- [连续两次Projection](evidence/20260917_projection/projection_repeat_cycles.csv)
- [Attention完整行为模型周期](evidence/20260917_projection/attention_full_cycles.csv)
- [Attention尾部慢完成周期](evidence/20260917_projection/attention_full_slow_cycles.csv)
- [W_Loader综合日志](evidence/20260917_projection/w_loader_synthesis.txt)
- [W_Loader层次资源](evidence/20260917_projection/hierarchy.rpt)
- [W_Loader资源总表](evidence/20260917_projection/utilization.rpt)
- [W_Loader RAM原语](evidence/20260917_projection/inference.txt)
- [仅综合阶段时序](evidence/20260917_projection/timing_synth_only.rpt)

## 6. 尚需对接

GCore的XHAT重复广播是否可提供；正式VPU的量化/RoPE协议；Projection与Attention共享阵列/存储的Top ownership；
正式SFU/VPU替换行为模型后的数值、背压和完成时序；真实模型权重及全pi0任务精度验证。
这次两个执行入口分别跑通，不代表Projection生成的Q已在同一个物理PCore Top内无缝转入Attention。
发布状态以Git提交历史为准，本文不把本地仿真自动等同于远程发布。
