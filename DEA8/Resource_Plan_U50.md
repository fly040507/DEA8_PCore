# DEA8 U50 资源评估口径

更新：2026-10-19。本文替代旧118DSP GCore、独立Reduce、TB版VPU/SFU和旧LUTRAM预算。**当前资源数字都是结构预算，除明确标注的历史OOC外尚无新综合结果。**

## 本阶段要测什么

先完成 [服务器仿真准入](Server_Verification.md)，再分别综合：
- 完整GCore：官方FP32 ADD/MUL、内部rsqrt、四lane归约/残差、Norm、KV及控制。
- 单个完整PCore：Matrix、VPU/SFU、Mask/RoPE、存储和本核控制；不以裸Matrix代替。

输出在 `reports/resource_synth/gcore/`与`pcore/`。本阶段只做综合资源测量，**不做八核综合、opt/place/route或频率签核**。

## 当前算术预算

| 部分 | 当前结构 | DSP预算 |
|---|---|---:|
| 单PCore基核 | MXU256 + 32路官方FPADD×2 | 320 |
| 单PCore VPU | 32MUL、32ADD、2个QK差值ADD | 132 |
| 单PCore SFU | GELU/P_EXP/共享RECIP等 | 约48 |
| 单PCore合计 | 包含真实VPU/SFU | 约500 |
| GCore | 34ADD×2 + 16MUL×2 + 单rsqrt约9 | 约109 |
| 八核加GCore外推 | 8×500+109 | 约4109 |

FP32 ADD/MUL均为官方Full_Usage、2DSP；ADD11拍，MUL8拍。EXP/RECIP/RSQRT的DSP、表RAM和控制开销要看生成配置和新综合，不能强行按每个2DSP记账。详情见 [FP_Resource_Mapping.md](FP_Resource_Mapping.md)。

## 当前存储与风险

- payload采用同步BRAM/URAM；PE驻留权重、控制/valid及小holding保留寄存器。
- Q/O/Z复用QOZ，不计独立ZBUF；每核只计一套共享Matrix。
- 归约在GCore内部，不再加独立Reduce及结果Tile资源。
- 浅宽FIFO、VPU/SFU工作缓存、RoPE ROM必须按端口/宽深统计，不能用payload总bit除容量。
- 当前粗估单完整PCore约128～154 BRAM36，GCore约210～240 BRAM36；八核外推1234～1472，存在越过整器件1344块的风险。这不是已综合超限结论。
- LUT、BRAM、URAM和布局区域都可能比DSP先成为约束；RAM优先不保证RAM总量更少。

## 测量、汇总与决策

服务器交回两个模块各自的utilization、hierarchical utilization、RAM明细、DSP/RAM原语数、DCP、日志及输入哈希。官方IP必须被展开，blackbox=0；若有未解析模块，结果不能用于预算。

按实际测得值先做 `GCore + 8×PCore`外推，再单列跨核连线/缓冲、全局控制、HBM/PCIe、平台shell和调试余量。外推不是八核综合；不能保证综合共享、扇出复制或跨SLR开销与线性相加一致。

整器件参考容量：LUT约872k、FF约1743k、DSP5952、BRAM36等效1344、URAM640。最终shell未冻结，不能把全部芯片资源当应用可用量；平台动态区需另行扣除。

资源接近上限时先按层次报告定位浅宽RAM碎片和LUT热点，再决定是否修改组织；用户看过结果前不启动八核综合。本轮也不以4ns约束宣称250MHz可运行。

## 唯一历史GCore综合

保留 `Gcore/.sim/gcore_synth.dcp`及`Gcore/reports/gcore_*utilization*.rpt`、`gcore_synth_summary.txt`与源码哈希。2026-10-16结果为48229 LUT、17502 FF、109 DSP、152.5 BRAM36、4 URAM。

该结果对应旧FP后端/旧FIFO映射，不是当前官方IP的面积。新的报告不得覆盖它，也不得直接将其与当前单PCore预算相加后称为实测系统资源。
