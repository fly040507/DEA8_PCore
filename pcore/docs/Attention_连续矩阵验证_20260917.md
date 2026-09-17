# Attention 连续矩阵 RTL 验证记录

后续更新见 [完整联调与尾部828拍时隙](Attention_完整联调与尾部时隙_20260917.md)。
本文件是早一轮纯矩阵基准记录，91096不包含新增尾部SCALE时隙；不要用它作为最新集成Attention总周期。

日期：2026-09-17。工具：Vivado/XSim 2022.2，Python 3.12。
对应设计：[连续矩阵调度](Attention_连续矩阵调度_20260917.md)。

## 1. 回归结果

`run_xsim.ps1 -Test all` 正常退出，退出码 0。
合计 56 个模式：28 项正常功能/恢复测试通过，28 项错误注入触发指定断言。
原始日志中的 28 条 Fatal 均为脚本校验过的预期失败，不是被忽略的正常路径错误。
Python unittest 20 项通过，退出码 0。

| 测试组 | 模式数 | 覆盖重点 |
| --- | ---: | --- |
| 新连续 Attention Matrix | 9 | 连续110 Job、断供、依赖等待、Done背压、复位、三种协议错误、关闭预加载 |
| 旧 KVB Adapter | 11 | 保留历史前端回归，不是新版 Attention 活跃路径 |
| XBC Adapter | 1 | 数据及 scale 拆分、背压 |
| HBM + MXU | 3 | 原行加载模式、流式 HBM、tile 内断流保护 |
| 旧 Attention Controller | 1 | 保留历史命令顺序回归 |
| DEQACC | 6 | FP32 加法/反量化、有效气泡、RAW/目标/地址保护 |
| HBM QK Engine | 5 | 旧路径 Job、断供、复位、QOZ 冲突 |
| Matrix Engine | 4 | QK/PV/QK/PV，含已缩放旧 OACC 的逐位验证 |
| Attention Core | 1 | 完整55对矩阵 Job 与外部测试客户端联调 |
| Accumulator Fabric | 2 | Bank 预留和访问保护 |
| Attention Scheduler | 2 | 延迟完成、背压、上下文检查 |
| Attention Buffers | 2 | 双缓冲、Bank 冲突保护 |
| Attention State | 4 | 标量状态、alpha 代际和消费者保护 |
| P Result Link | 3 | SFU 到 VPU 结果流、完成/epoch 检查 |
| External Stubs | 2 | 历史壳接口回归，非新版正式 GCore 实现 |

## 2. 新矩阵路径的数值证据

default、STARVE、DEPENDENCY_WAIT、DONE_BACKPRESSURE、NO_PREFETCH 各完成一次全长运行。
每次均验证 110 个 Job、28160 列加载、89760 个 16-lane FP32 向量。
即每次 1436160 个 FP32 输出逐位比较，共五组全长场景。
默认场景还记录到 27760 次满 FIFO 同拍 push/pop。

整数 oracle 使用带符号且随 Job/row/tile/column 变化的激活、权重、scale，独立于 DUT 浮点函数。
本测试数值选在 FP32 可精确表达范围，覆盖矩阵与跨 tile/block 累加；FP32 极值及舍入由独立 DEQACC 测试补充。
不能用该测试代替真实 Softmax/量化误差评估。

## 3. 周期证据

下表是相对 Top Job 接受沿 T0 的 Done 采样沿编号，不是包含起始沿的事件数。

| 模式 | 首个 Done | 最后 Done | 说明 |
| --- | ---: | ---: | --- |
| default | 844 | 91096 | 后109次完成间隔全部为828 |
| NO_PREFETCH | 844 | 92731 | 后109次完成间隔全部为843，满足844预算 |
| STARVE | 1744 | 92362 | 三处断供；等待结束后恢复正确计算 |
| DEPENDENCY_WAIT | 844 | 91133 | 权重已ready但资源许可延迟37拍，未提前计算 |
| DONE_BACKPRESSURE | 880 | 91132 | 当前描述符保持至Done被接受，不越过握手启动下一Job |

默认最后实际 RAM 写入在 T91094，寄存 Commit 被 Sequencer 采样在 T91095，Done 在 T91096。
方案的 91097 是矩阵侧保守预算，不应把 Done 与 RAM 写入沿混称为同一事件。
RESET_JOB 验证预加载中途复位和释放后无残留工作；三项 BAD 模式验证列号、epoch、Job 顺序错误。

## 4. 证据文件

- [全量 XSim 日志](evidence/20260917/xsim_all.txt)
- [Python 测试日志](evidence/20260917/python_unittest.txt)
- [默认逐 Job 周期 CSV](evidence/20260917/attention_matrix_cycles.csv)
- [无预加载周期 CSV](evidence/20260917/attention_matrix_noprefetch_cycles.csv)
- [断供周期 CSV](evidence/20260917/attention_matrix_starve_cycles.csv)
- [依赖等待周期 CSV](evidence/20260917/attention_matrix_dependency_cycles.csv)
- [完成背压周期 CSV](evidence/20260917/attention_matrix_backpressure_cycles.csv)
- [受测 RTL、TB、脚本 SHA256](evidence/20260917/RTL_SHA256.csv)

每个周期 CSV 分别记录 first_mul、final_ram_write、final_commit、block_done。
复位与错误模式的 CSV 可能只有表头及首乘法记录，因为它们应在 Job 完成前结束；判断依据是日志断言而非全长周期表。

## 5. 不应夸大的结论

828 拍来自已预留资源的矩阵执行通路，不保证完整 Attention Core 每次发起矩阵都无额外等待。
正式集成保留 VPU/SFU 依赖许可；PV54 前的最后 OACC 缩放以及最终 A_FIN 不包含在矩阵测试周期中。
Attention Core 使用非通用算术 VPU/SFU fixture；联调 PASS 不代表真实 EXP、Mask、量化和在线 Softmax 数值正确。
未执行目标器件综合、布局布线或板上测试，不能据仿真声称250 MHz已达成。
本次只修改开发目录，没有更新发布快照或上传 GitHub。
