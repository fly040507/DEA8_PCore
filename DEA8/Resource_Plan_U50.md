# DEA8 U50 资源评估口径

更新：2026-10-19。本文替代旧118DSP GCore、独立Reduce、TB版VPU/SFU和旧LUTRAM预算。**GCore和RoPE修复后的单个完整PCore均已完成官方IP版面积综合；八核仍为线性外推。** 未做布局布线。

本轮已按[RAM重映射方案](RAM_Mapping_Plan.md)完成RTL和两套新综合：GCore KV/XHAT重组、两个FACC统一BRAM。八核加GCore线性外推1223 BRAM36等效、304 URAM，已包含新响应队列。按用户要求未重跑仿真、不开展LUT优化；[实施及新旧对比](reports/resource_synth/RAM_Remap_20261019.md)。

## 单PCore实测与当前首要风险

完整顶层`dea8_pcore_top`于16:33完成RAM重映射后OOC综合：104598 LUT（12.00%）、102251 FF（5.87%）、500 DSP（8.40%）、143 BRAM36等效（10.64%）、35 URAM（5.47%）。85项输入哈希与当前文件一致，黑盒0。详见[PCore资源汇总](reports/resource_synth/pcore_ram_remap_20261019/Summary.md)，[14:45改造前基线](reports/resource_synth/pcore_preview/Summary.md)保留。

13:45快照缺失RoPE ROM，旧资源与热点分析保留在[修复前资源分析](reports/resource_synth/pcore_preview/Analysis_20261019_1345.md)。本次直接初始化宽ROM，整核已保留12 RAMB36 + 1 RAMB18；无驱动警告消失。RTL及综合后RAM网表均通过408地址、13120项系数检查；完整七Job未在本轮修改后重跑。

| 资源 | RAM重映射后8PCore+GCore外推 | 整器件占比 |
|---|---:|---:|
| LUT | 866566 | **99.41%** |
| FF | 851206 | 48.83% |
| DSP | 4109 | 69.04% |
| BRAM36等效 | 1223 | 91.00% |
| URAM | 304 | 47.50% |

该外推已包含真实RoPE及新RAM映射，但未计平台shell、DEA8全局控制、互连及物理优化开销；仅剩5114 LUT、121 BRAM36等效，不是八核综合或可部署结论。**LUT仍是整体部署的首要风险，本轮按用户要求只处理BRAM/URAM。** LUT优化留到后续阶段，BRAM也不能视为已有充分平台余量。

## 当前GCore实测

完整 `dea8_gcore`、内部rsqrt启用，U50 OOC综合通过，黑盒0。

| 资源 | 使用量 | 整器件占比 |
|---|---:|---:|
| LUT | 29,782 | 3.42% |
| FF | 33,198 | 1.90% |
| DSP | 109 | 1.83% |
| BRAM36等效 | 79 | 5.88% |
| URAM | 24 | 3.75% |

原语为77 RAMB36E2 + 4 RAMB18E2；URAM为KV16、XHAT4、RESID4。证据见[GCore资源汇总](reports/resource_synth/gcore_ram_remap_20261019/Summary.md)。[改造前211 BRAM/4 URAM基线](reports/resource_synth/gcore_preview/Summary.md)保留。此次为用户授权的本机面积预览，RAM新映射功能验收尚待后续完成。

## 本轮测量与服务器准入

本机已按用户要求跳过仿真，分别完成下面两个完整模块的面积预览；服务器正式准入仍须先完成[功能回归](Server_Verification.md)：
- 完整GCore：官方FP32 ADD/MUL、内部rsqrt、四lane归约/残差、Norm、KV及控制。
- 单个完整PCore：Matrix、VPU/SFU、Mask/RoPE、存储和本核控制；不以裸Matrix代替。

服务器准入后的输出在`reports/resource_synth/gcore/`与`pcore/`；本轮预览在`gcore_ram_remap_20261019/`与`pcore_ram_remap_20261019/`，改造前`*_preview/`保持不覆盖。本阶段**不做八核综合、opt/place/route或频率签核**。

## 当前算术预算

| 部分 | 当前结构 | DSP预算 |
|---|---|---:|
| 单PCore基核 | MXU256 + 32路官方FPADD×2 | 320 |
| 单PCore VPU | 32MUL、32ADD、2个QK差值ADD | 132 |
| 单PCore SFU | GELU/P_EXP/共享RECIP等 | 48 |
| 单PCore合计 | RoPE修复后的完整顶层网表 | 500，实测 |
| GCore | 34ADD×2 + 16MUL×2 + 单rsqrt9，已综合 | 109 |
| 八核加GCore外推 | 8×500+109 | 约4109 |

FP32 ADD/MUL均为官方Full_Usage、2DSP；ADD11拍，MUL8拍。EXP/RECIP/RSQRT的DSP、表RAM和控制开销要看生成配置和新综合，不能强行按每个2DSP记账。详情见 [FP_Resource_Mapping.md](FP_Resource_Mapping.md)。

## 当前存储与风险

- payload采用同步BRAM/URAM；PE驻留权重、控制/valid及小holding保留寄存器。
- Q/O/Z复用QOZ，不计独立ZBUF；每核只计一套共享Matrix。
- 归约在GCore内部，不再加独立Reduce及结果Tile资源。
- 浅宽FIFO、VPU/SFU工作缓存、RoPE ROM必须按端口/宽深统计，不能用payload总bit除容量。
- 单PCore已测143 BRAM36等效（含RoPE和两个同构FACC），GCore已测79；八核加GCore外推1223（91.00%），剩121块，尚未计平台与互连开销。
- LUT、BRAM、URAM和布局区域都可能比DSP先成为约束；RAM优先不保证RAM总量更少。

## 测量、汇总与决策

服务器交回两个模块各自的utilization、hierarchical utilization、RAM明细、DSP/RAM原语数、DCP、日志及输入哈希。官方IP必须被展开，blackbox=0；若有未解析模块，结果不能用于预算。

按实际测得值先做 `GCore + 8×PCore`外推，再单列跨核连线/缓冲、全局控制、HBM/PCIe、平台shell和调试余量。外推不是八核综合；不能保证综合共享、扇出复制或跨SLR开销与线性相加一致。

整器件参考容量：LUT约872k、FF约1743k、DSP5952、BRAM36等效1344、URAM640。最终shell未冻结，不能把全部芯片资源当应用可用量；平台动态区需另行扣除。

资源接近上限时先按层次报告定位浅宽RAM碎片和LUT热点，再决定是否修改组织；用户看过结果前不启动八核综合。本轮也不以4ns约束宣称250MHz可运行。

## 唯一历史GCore综合

保留 `Gcore/.sim/gcore_synth.dcp`及`Gcore/reports/gcore_*utilization*.rpt`、`gcore_synth_summary.txt`与源码哈希。2026-10-16结果为48229 LUT、17502 FF、109 DSP、152.5 BRAM36、4 URAM。

该结果对应旧FP后端/旧FIFO映射，不是当前官方IP的面积。新的报告不得覆盖它，也不得直接将其与当前单PCore预算相加后称为实测系统资源。
