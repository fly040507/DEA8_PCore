# DEA8_VPU

固定 `M=51`，目标 U50 `xcu50-fsvh2104-2-e`。本目录是 DEA8 的非矩阵计算与存储优化版。

## 当前结果

2026-10-23，真实单 PCore 完整七 Job **PASS**：

- 总周期 **285942**，比 DEA8 旧基线增加 **2.2788%**
- Matrix issues **265408**，55 QK / 55 PV
- **6299** 项量化、**157743** 项 FP 检查通过；DUT 内无 TB 算术代算
- 无代价优化后单核 OOC：**104422 LUT、142551 FF、398 DSP、71.5 BRAM36 等效、40 URAM**
- 相比本轮116270 LUT基线，减少**11848 LUT（10.19%）**；七个Job的周期逐项完全不变

[七 Job逐项结果与原始证据](Pcore/reports/compute/nocost_final7/Summary.md) · [当前资源口径](docs/Resources.md)

**本轮无代价优化与完整七Job验证已完成，RTL停在该版本。** 既定候选覆盖SFU、VPU、宽MUX、静态FF转置、QK及DEQACC/ACC外围；没有用新增DSP/BRAM换LUT。系统70%不是本轮验收要求；单核仿真和资源预览不代表八核联合、布局布线或板级频率通过。

## 目录入口

| 目录/文件 | 内容 |
|---|---|
| [Pcore](Pcore/README.md) | 完整 PCore：Matrix、VPU/SFU、存储、本核控制与外发 |
| [Gcore](Gcore/README.md) | KV、四lane归约/残差、统计、Norm/量化、XBC/KVB |
| [control](control/README.md) | 八核阵列、层级互连和取消排空 |
| [HBM](HBM/README.md) | 供数接口；物理HBM/DMA仍未接入 |
| [docs/NonMatrix.md](docs/NonMatrix.md) | 当前算术复用、存储组织和方案差异 |
| [docs/Verification.md](docs/Verification.md) | 环境、复现命令、八核待验收范围 |
| [docs/HANDOFF.md](docs/HANDOFF.md) | 接入约束、恢复与当前停点 |
| [reports](reports/README.md) | 当前有效证据索引、保留与清理范围 |
| `tb/`、`tools/` | 层级测试、输入生成及单模块资源测量 |
| `run_dea8.py` | 层级验证和GCore/单PCore综合入口 |

生产清单：`Pcore/pcore_rtl.f`、`Gcore/gcore_rtl.f`。按清单编译，不递归编译历史/兼容模块。

## 当前拓扑

```text
外部DEA8策略 / HBM适配
          |
    dea8_layer_top
       GCore <--- 8路独立tx256 --- 8 × 完整PCore
         |                           Matrix + VPU/SFU
         +---------- XBC/KVB ----------+
         +---------- KV commit --------+
```

归约位于GCore内部。PCore不再依赖核外VPU/SFU服务或独立Reduce。

## 清理与复现

前一轮已清理被替代产物。本轮新增`nocost_final7`、`nocost_r2_modules`、邻接回归和`pcore_nocost_r2`证据；此前`optimized7_banked`/`pcore_banked_20261023`保留为优化前基线，不能代表当前RTL。综合试验和消融见[证据索引](reports/README.md)。旧DEA8基线数字在结果表中保留。

本轮已从Tcl重建IP；配置、gold与原始PASS未改写。新综合DCP和`ip_work`暂留供定位跨层归属，发布前可清理。`output/pcore_synth_sources.f`为runner生成的综合输入清单，不是编译入口。详见[复现说明](docs/Verification.md)。
