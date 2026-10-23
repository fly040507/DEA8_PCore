# DEA8_VPU

固定 `M=51`，目标 U50 `xcu50-fsvh2104-2-e`。本目录是 DEA8 的非矩阵计算与存储优化版。

## 当前结果

2026-10-23，真实单 PCore 完整七 Job **PASS**：

- 总周期 **285942**，比 DEA8 旧基线增加 **2.2788%**
- Matrix issues **265408**，55 QK / 55 PV
- **6299** 项量化、**157743** 项 FP 检查通过；DUT 内无 TB 算术代算
- 单核 OOC 综合：**116270 LUT、142773 FF、398 DSP、71.5 BRAM36 等效、40 URAM**

[七 Job逐项结果与原始证据](Pcore/reports/compute/optimized7_banked/Summary.md) · [当前资源口径](docs/Resources.md)

**RTL停在该仿真通过版本，等待用户检查；LUT优化留待下一轮。** LUT尚未达标；单核仿真和资源预览不代表八核联合、布局布线或板级频率通过。

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

本目录仅保留最新完整七Job、当前共享SFU回归、当前单核面积及GCore外推基线。被替代的运行、旧方案报告、快照、波形、DCP、`ip_work`和服务器临时目录已移除。旧DEA8基线数字在结果表中保留。

IP目录仅保留XCI及小型仿真封装，便于核对已验收输入；完整vendor生成产品从Tcl重建。原始PASS与manifest未改写。综合时的输入清单快照保留在`output/pcore_synth_sources.f`，只是原始测量输入，不是编译入口。详见[复现说明](docs/Verification.md)。
