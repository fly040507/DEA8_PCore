# DEA8 FPGA VLA 工程

更新：2026-10-17。当前固定 `M=51` 的工程在 [DEA8/](DEA8/README.md)，目标U50。18层、10步去噪是系统目标，尚未完成真实八核单层或十步端到端验收。

## 对接入口

| 读者 | 入口 |
|---|---|
| VPU/SFU负责人 | **[PCore最新接入说明](DEA8/Pcore/README.md)**：七Job、触发条件、数据、访存、done/flush、相对GitHub旧版的变化 |
| 系统连接 | [DEA8总览](DEA8/README.md) |
| GCore与共享归约 | [GCore README](DEA8/Gcore/README.md)、[共线协议](DEA8/Gcore/GCore_Reduce_Plan.md) |

当前拓扑：`PCore x8 -> 每核一条256-bit包链路 -> GCore`。K/V按坐标落入共享KV，O/Down跨核归约和Residual在GCore内部完成。**独立DEA8/reduce、旧Collective、旧V3不是当前连接目标。**

PCore继续使用双行INT8 MXU、**11级DEQACC**，本次不改流水。VPU/SFU算术由外部负责人实现，PCore提供命令、数据、存储、系数及取消接口。

## 当前验证

- PCore：新包接口下七Job功能链通过；Matrix/QOZ/workspace为真实RTL，VPU/SFU/HBM和外部响应为TB模型
- GCore：23个功能仿真场景通过，覆盖第1/9/18层宏观链路；单路真实rsqrt、内部四lane归约。U50本体OOC为109 DSP、48229 LUT、17502 FF、152.5 BRAM36等效、4 URAM（该OOC早于本轮宏观控制改动）
- 未完成：真实八核完整PCore与GCore整层联调、真实VPU/SFU替换、DEA8总控、HBM、4ns布局布线签核

## 目录定位

| 路径 | 用途 |
|---|---|
| `DEA8/Pcore`、`DEA8/Gcore` | 当前生产设计与测试 |
| `DEA8/control`、`DEA8/HBM` | 真实全局总控与供数的待接入边界 |
| `DEA8/reduce` | 废弃的独立归约，仅供历史对照 |
| `pcore` | 旧单INT8方案，不能与当前双行PCore混接 |
| `DEA8_dynamic`、`DEQACC`、`architecture` | 独立探索、历史方案或资源资料，不是本次接入基线 |
| `interaction` | 阶段输入，不自动等同于已实现接口 |

运行步骤、当前证据和未完成边界分别见PCore/GCore README。
