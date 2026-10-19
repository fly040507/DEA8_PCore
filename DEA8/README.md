# DEA8 当前设计与工程入口

更新：2026-10-19。固定 `M=51`，目标器件 `xcu50-fsvh2104-2-e`。以当前RTL、生产清单和对应源码哈希的验证结果为准；不以旧方案或旧日志推定完成。

## 当前拓扑

```text
外部DEA8总控（本阶段TB）       外部HBM适配（本阶段TB）
          |                              |
    dea8_layer_top                       |
       GCore -- XBC/KVB --> 8 × 完整PCore <-+
         ^                  Matrix + VPU/SFU + 本核控制
         +---- 8路独立tx256 --------+
         +---- KV commit返回 -------+
```

**归约在GCore内部，没有独立Reduce/Collective，也没有PCore核外发送桥。** PCore的VPU/SFU已接入真实RTL，不再由最终验收TB模拟。

| 对象 | 正式入口 | 职责 |
|---|---|---|
| PCore | [Pcore/README.md](Pcore/README.md)、`Pcore/rtl/dea8_pcore_top.sv` | 七种Job、矩阵与本地后处理、Mask/RoPE、RAM及外发 |
| 八核阵列 | `control/rtl/dea8_pcore_cluster.sv` | 8份完整PCore，独立本核控制、组级取消/排空 |
| 层级互连 | `control/rtl/dea8_layer_top.sv` | GCore/八核、XBC/KVB、tx256、commit/prefetch接线 |
| GCore | [Gcore/README.md](Gcore/README.md)、`Gcore/rtl/dea8_gcore.sv` | KV、供数、四lane归约/残差、统计、Norm/量化、末层输出 |
| DEA8全局策略 | 本阶段TB | 层/步、七阶段发布、全局屏障、HBM与取消源流 |
| HBM适配 | [HBM/README.md](HBM/README.md) | 真实物理控制器/DMA尚未接入；TB供给接口数据 |

## 当前算术与存储

- 每核共享一套Matrix，Projection、Attention、G-U是三种调度策略，不是三套MXU。
- MXU：16×16 PE、权重驻留、双行INT8广播、256 DSP、精确INT20加法树、7级流水。
- DEQACC：`4 + 11 + 1 = 16`级，包含官方FP32 ADD。
- FP32 ADD/SUB：Full_Usage、11拍、2DSP；MUL：Full_Usage、8拍、2DSP。EXP21、RECIP29、RSQRT32；特殊函数资源单列。
- VPU32 lane；SFU四路exp、两条交错GELU链、一个共享倒数核。
- payload优先同步BRAM/URAM，不整片复位；小型valid/tag/owner用寄存器。
- Mask按已核实的官方pi0，非pi0.5；RoPE配置绑定有效prefix位置和系数版本。

具体预算和浅宽RAM风险见[FP资源映射](FP_Resource_Mapping.md)。[RAM重映射](RAM_Mapping_Plan.md)已实施并完成[GCore](reports/resource_synth/gcore_ram_remap_20261019/Summary.md)和[完整单PCore](reports/resource_synth/pcore_ram_remap_20261019/Summary.md)新综合：GCore 79 BRAM/24 URAM，PCore 143 BRAM/35 URAM；八核加GCore外推LUT99.41%、BRAM91.00%、URAM47.50%。详见[新旧对比](reports/resource_synth/RAM_Remap_20261019.md)，尚未计平台与互连开销。原`*_preview`报告保留为改造前基线；本轮按用户要求不重跑仿真。

## 验证状态

| 项目 | 已确认 | 不能据此宣称 |
|---|---|---|
| 真实单核七Job，RoPE初始化修复前 | 279571拍、265408 issue、94.93%；55QK/55PV，6299量化+157743FP检查 | 修复后全核重验、板级250MHz、八核单层或十步去噪 |
| RoPE初始化修复后 | RTL及综合RAM网表：全408地址、13120项系数、背压/flush/非法position检查PASS | 完整七Job已重跑 |
| GCore官方IP定向测试 | 冷Norm、正式RESID import、FP算术；服务基线及四种压力/异常场景 | 真实八核PCore联合通过 |
| 真实八核代表层TB | 已编写并纳入编译；第1/9/18层及压力/恢复待服务器执行 | 展开/仿真已经通过 |
| 当前官方IP面积，RAM重映射后 | GCore：29782LUT、33198FF、109DSP、79BRAM/24URAM；单PCore：104598LUT、102251FF、500DSP、143BRAM/35URAM | 新映射功能已验收、八核联合或250MHz通过 |

[七Job图](reports/seven_job_native/seven_job_native.png)、[指标/哈希](reports/seven_job_native/metrics.json)、原始证据 `Pcore/reports/compute/`。Attention仍有约16拍命令槽尾部等待，未宣称非矩阵完全隐藏。

## 本阶段服务器顺序

1. 完成单核和八核第1/9/18层、压力及取消/恢复仿真。
2. 仿真准入通过后，分别综合官方IP的GCore与单个完整PCore，只看资源。
3. 根据单模块结果评估 `GCore + 8×PCore`，再由用户决定是否做八核综合。

**本阶段不做八核综合，不做布局布线，不做频率签核。** 命令、验收和交回材料见 [Server_Verification.md](Server_Verification.md)。

## 阅读与历史边界

先读本文，再读 [交接说明](HANDOFF.md)、局部README和 [单层流程](Pcore/docs/DEA8_整体架构与单层流程说明.md)。正式清单是 `Pcore/pcore_rtl.f`、`Gcore/gcore_rtl.f`；不要递归编译历史目录。

`reduce/`、`Pcore/legacy/`和旧叶级工具仅供历史对照，不进入当前生产拓扑。2026-10-19清理了旧仿真快照、波形、缓存，以及RAM改造前 `*_preview` 的综合检查点和重复 `ip_work/`；基线资源报告、输入哈希、运行日志、功能验证证据保留。新RAM映射的完整综合结果和检查点保留在 `reports/resource_synth/*_ram_remap_20261019/`。按此前保留要求，2026-10-16的GCore旧综合报告和 `Gcore/.sim/gcore_synth.dcp`仍保留，但不代表当前官方IP源码。清单见 [清理记录](reports/cleanup_20261019.json)。
