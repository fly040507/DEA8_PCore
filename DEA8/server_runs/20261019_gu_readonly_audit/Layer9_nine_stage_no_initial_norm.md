# Layer9九段口径：不含初始RMS/配置准备

起点：量化X就绪后的K受理，TB cycle 12172。终点：本层Down及下一层Attention输入准备完成，TB cycle 305620（正式结束时刻1222478ns对应posedge；cycle从首个2ns上升沿计为1）。总计293448周期=1173.792µs。不是从run_layer进入时开始计时的305585周期；剔除12137周期=48.548µs准备区间。

按相邻Job受理边界划分控制间隙，O单独截止最后PCore O完成，其后至GU受理单列FFN残差/Norm显露尾部。这样九行互不重叠、可相加。与LAYER_PERF的TB任务起止口径存在1～数拍差异，不混用两种边界。

原Layer9受理周期依据探针冻结probe.py infer_phase记录：K12172、V16283、Q19968、Attention47502、O97868、GU133625；Down243238依据job_status_20261019_234950.json；O完成126768依据layer9_o_exposed_latency.json。

Layer9退出前未独立保存Down的PCore完成cycle。令D为Down受理至最后PCore完成的真实周期，绝不把单核fixture或剩余层的时长冒充Layer9实测。

| 阶段 | 周期 | 时间µs @4ns | Matrix发射/核 | 发射拍占比 |
|---|---:|---:|---:|---:|
| K（含至V受理的收尾/派发） | 4111 | 16.444 | 3328 | 80.95% |
| V（含至Q受理的收尾/派发） | 3685 | 14.740 | 3328 | 90.31% |
| Q（含至Attention受理的派发） | 27534 | 110.136 | 26624 | 96.69% |
| Attention（含至O受理的KV释放/派发） | 50366 | 201.464 | 45760 | 90.85% |
| O（截止最后PCore完成） | 28900 | 115.600 | 26624 | 92.12% |
| FFN前残差/Norm等显露尾部（至GU受理） | 6857 | 27.428 | 0 | 0% |
| G-U（含至Down受理的退休/派发） | 109613 | 438.452 | 106496 | 97.16% |
| Down（截止最后PCore完成） | D，未独立归档 | 0.004D | 53248 | 53248/D |
| 下一层Attention前残差/Norm等显露尾部 | 62382-D | 249.528-0.004D | 0 | 0% |
| **整层合计，不含初始准备** | **293448** | **1173.792** | **265408（8核2123264）** | **90.44%** |

FFN和下一层Attention前残差/Norm两行只列矩阵完成后的显露尾部，重叠部分已包含在O/Down行中，不代表该服务完整耗时。该整层时间含两次残差更新和两次逻辑RMSNorm（FFN前、下一层Attention前），不执行下一层K/V/Q/Attention。Down不得填联合62383周期，也不得挪用P1单核55453周期。

为避免余下在途数据丢失，capture_down_boundary.py只读观察原Layer1/18的TB job_end数组并独立保存；不attach、不暂停、不发信号、不写模拟器或正式运行文件，不重跑EDA。

## 后续边界实测（不冒充Layer9）

2026-10-20 01:53:31捕获Layer1、01:56:42捕获Layer18：两层八核各自Down受理到完成均为**55524周期＝222.096µs**，每核Matrix发射53248次，发射拍占比**95.90%**。两层PCore已完成，但捕获时GCore残差/RMS仍在后台收尾，联合Job尚未完成。后续以各层正式阶段完成周期分离其尾部，Layer18尾部是Final Norm/FP32输出，不是下一层Attention输入准备。

证据：同目录down_completion_layer1.json、down_completion_layer18.json，包含八核完整job_start/job_end数组及完成位，观测仅只读。Layer9的D仍不能直接标作已测得55524周期。

Layer1于02:01:16正式PASS后，其最后PCore Down完成cycle298766，整层完成cycle305624，后续显露尾部实测6858周期。完整、无未知数的九行实测表见同目录Layer1_nine_stage_measured.md；剔除初始准备后总计293448周期。
