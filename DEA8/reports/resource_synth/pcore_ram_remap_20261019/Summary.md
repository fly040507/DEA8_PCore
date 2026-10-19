# 单核PCore RAM重映射综合

2026-10-19 16:33完成，Vivado 2022.2，U50 `xcu50-fsvh2104-2-e`。完整顶层`dea8_pcore_top`，含Matrix、真实VPU/SFU、Mask/RoPE、本核控制、存储与外发。

**综合通过，黑盒0、错误0、严重警告0。按用户要求未重跑仿真，没有布局布线或250MHz签核。** 日志共305条普通警告，不宣称零警告。

## 完整单核资源

| 资源 | 使用 | 整器件占比 | 改造前 | 变化 |
|---|---:|---:|---:|---:|
| LUT | 104598 | 12.00% | 104573 | +25 |
| FF | 102251 | 5.87% | 103264 | -1013 |
| DSP48E2 | 500 | 8.40% | 500 | 0 |
| BRAM36等效 | 143 | 10.64% | 128 | +15 |
| URAM | 35 | 5.47% | 51 | -16 |

BRAM为136 RAMB36E2 + 14 RAMB18E2。LUT包含99583逻辑LUT、2048分布式RAM LUT、2967 SRL；锁存器为0。本轮没有处理既有LUTRAM或开展LUT优化。

## FACC同构映射核对

| 物理对象 | RAMB36 | RAMB18 | BRAM36等效 | URAM |
|---|---:|---:|---:|---:|
| FACC-A even | 7 | 1 | 7.5 | 0 |
| FACC-A odd | 7 | 1 | 7.5 | 0 |
| FACC-B even | 7 | 1 | 7.5 | 0 |
| FACC-B odd | 7 | 1 | 7.5 | 0 |
| 两个FACC合计 | 28 | 4 | 30 | 0 |

- 四个银行在`ram.rpt`中均是BRAM；逻辑深度even26、odd25，512bit字宽，外部读延迟仍为3拍
- OACC保持16 URAM、QOZ保持4 URAM、VPU data RAM保持15 URAM，合计35
- RoPE仍保留12 RAMB36 + 1 RAMB18，即12.5 BRAM36等效，没有因本轮重映射再次被裁掉
- 上述FACC资源已经计入完整单核143 BRAM，不可再相加

综合仍提示部分VPU saved/quant RAM输出寄存器未合并；本轮没有插入额外功能流水解决这些时序提示，也不据此宣称4ns通过。

## 证据和复现

- [资源总表](utilization.rpt)、[层次表](utilization_hier.rpt)、[RAM明细](ram.rpt)、[原语计数](primitives.tsv)
- [运行范围](scope.txt)、[输入哈希](inputs_sha256.json)、[成功记录](PASS.json)、[日志](synth.log)
- manifest SHA256：`5ee7d63009f05f4cb7efc9ab19627adc8d807897a4a018b460f8dbae8961d8ee`；85项输入在运行前后及复核时一致
- [改造前基线报告](../pcore_preview/Summary.md)、哈希及日志保留；旧检查点和临时IP构建目录已清理

在DEA8目录加载Vivado环境后执行：

```text
python run_dea8.py synth --target pcore --resource-preview --report-tag ram_remap_20261019
```

`simulation_gate_passed=false`：本轮未执行RAM叶级、七Job或八核仿真，旧PASS不构成新映射功能验收。[两模块及八核外推汇总](../RAM_Remap_20261019.md)。
