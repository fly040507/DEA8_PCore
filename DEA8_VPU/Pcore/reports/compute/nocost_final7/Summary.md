# 无代价优化：完整七Job

2026-10-23 19:55:42完成。**真实单PCore七Job PASS；逐Job周期与本轮优化前完全一致。**

| Job | 优化前/拍 | 当前/拍 | 增量 | Matrix issues |
|---|---:|---:|---:|---:|
| K | 4268 | 4268 | 0 | 3328 |
| V | 3731 | 3731 | 0 | 3328 |
| Q | 27850 | 27850 | 0 | 26624 |
| Attention | 54513 | 54513 | 0 | 45760 |
| O | 28829 | 28829 | 0 | 26624 |
| G-U | 111298 | 111298 | 0 | 106496 |
| Down | 55453 | 55453 | 0 | 53248 |
| **合计** | **285942** | **285942** | **0** | **265408** |

- 55 QK/55 PV；6299项量化、157743项FP检查通过，DUT内部无TB算术代算
- 单命令最大时长也不变：QK_POST91、α53、P_EXP295、P_POST360、scale970、RECIP99、AFIN1529、GELU2261拍；这些有重叠，不能相加
- 4ns折算1.143768ms，RoPE显式预载在Job计时前；不是250MHz时序签核
- 标准参数为空，不等于额外STRESS或八核验收

## 输入与证据

- [原始日志](tb_pcore_seven_native_simulate.log)、[PASS](tb_pcore_seven_native_PASS.json)、[输入清单](compile_sha256.json)
- 118项输入，清单SHA256：`46cdad3277ba164909010d91acc7adb683a45eb5f8d63ab7c8205fba0604e200`
- 9项模块回归位于`../nocost_r2_modules/`，与本次共用相同清单hash
- [最终完整PCore综合](../../../../reports/resource_synth/pcore_nocost_r2/Summary.md)：104422 LUT，较116270减少11848（10.19%）；DSP/BRAM/URAM不增加
- SFU/ACC撤回消融结束后，已逐项核对恢复到本次仿真及最终综合的输入字节；消融报告本身不作为功能PASS
- 基线：[优化前七Job](../optimized7_banked/Summary.md)。更早DEA8的279571拍仅是历史比较，本轮零增量以285942为分母
