# Attention 尾部联调验证记录

设计解释见 [完整联调与尾部时隙](Attention_完整联调与尾部时隙_20260917.md)。
工具：Vivado/XSim 2022.2；参考模型：Python标准库独立FP32计算。
范围：一个head/epoch的完整55-Block Attention，不是所有head/layer的完整VLA推理。

## 最终全量回归

`run_xsim.ps1 -Test all` 正常结束，退出码0：共59个测试模式，30项正常测试PASS，29项错误注入触发指定断言。
Python unittest 20项PASS。受测59个源码/测试/脚本文件的SHA256与结束后文件一致。
原始日志中的29条Fatal全部对应预期错误模式，不能将它们误认为正常路径错误，也不能仅凭进程返回码判断仿真通过。

## 已完成的专门联调

`run_xsim.ps1 -Test fullattention` 退出码0，四种模式全部按预期完成：

| 模式 | 结果 | 说明 |
| --- | --- | --- |
| 旧恒等fixture | PASS | 保留接口兼容回归，不作为新性能结论 |
| SOFTMAX | PASS | 有效mask、非恒等alpha、P量化、真实QK/PV、最终归一化 |
| TAIL_SLOW | PASS | 尾部完成延迟后，PV54等待实际Done，数值仍正确 |
| SKIP_TAIL_SCALE | 预期错误PASS | 故意跳过最后缩放，PV54首向量被独立oracle检出 |

SOFTMAX和TAIL_SLOW分别比较44880个QK中间归约向量、44880个PV写回向量、816个AFIN向量。
每向量16个FP32 lane；QK逐位检查，PV/AFIN采用文档列明的误差阈值。
同时核对所有alpha和l更新、完成握手、PBUF代际、OACC访问预留以及尾部权重预加载。

## 正常场景的计数

| 事件 | 次数 |
| --- | ---: |
| Matrix Start / Done | 110 / 110 |
| QK / PV | 55 / 55 |
| VPU QK_POST / P_POST | 55 / 55 |
| VPU OACC_SCALE / AFIN | 54 / 1 |
| SFU ALPHA_EXP / P_EXP / RECIP | 55 / 55 / 1 |
| 普通矩阵完成间隔828拍 | 108 |
| 尾部矩阵完成间隔1656拍 | 1 |

Top到矩阵Done为91924拍，Top到行为模型AFIN后Attention Done为92799拍。
纯矩阵基准为91096拍，因此集成矩阵完成时间恰好增加828拍。

TAIL_SLOW：Matrix Done=92116，Attention Done=92991；VPU的Done推迟200拍，但正常尾部原有8拍Done后裕量，因此总时间相对正常增加192拍。
这一结果验证的是完成握手优先于固定预算，而不是强制将每个延迟都算成200拍净增长。

SKIP_TAIL_SCALE预期报错示例：

```text
Softmax PV oracle mismatch block=54 word=0 lane=0
got=bf332f50 expected=bff924fa
```

这说明测试并非仅仅等待828拍或检查任务数量；没有最后一次数值缩放时会失败。

## 原始证据

- [最终全量回归日志](evidence/20260917_tail/xsim_all.txt)
- [专门联调日志](evidence/20260917_tail/xsim_fullattention.txt)
- [正常全流程时序CSV](evidence/20260917_tail/attention_full_cycles.csv)
- [尾部慢完成时序CSV](evidence/20260917_tail/attention_full_slow_cycles.csv)
- [跳过尾部缩放的错误注入CSV](evidence/20260917_tail/attention_full_negative_cycles.csv)
- [Python unittest日志](evidence/20260917_tail/python_unittest.txt)
- [源码及测试SHA256清单](evidence/20260917_tail/SOURCE_SHA256.csv)

真实SFU/VPU精度、吞吐、资源、目标时钟、AFIN正式输出接口仍需由正式模块实现后重新验收。
所有数学行为模型只用于仿真；本次没有推送GitHub或修改独立发布快照。
