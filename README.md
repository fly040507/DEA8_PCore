# DEA8 FPGA VLA 工程

更新：2026-10-19。当前固定 `M=51` 的U50设计位于 [DEA8/](DEA8/README.md)。系统目标为18层、10步去噪；真实八核单层联测尚待服务器完成。

## 当前入口

| 范围 | 说明 |
|---|---|
| 完整PCore | [PCore README](DEA8/Pcore/README.md)：七种Job、矩阵与真实VPU/SFU、Mask/RoPE、RAM及外发 |
| GCore | [GCore README](DEA8/Gcore/README.md)：八核接收、内置归约、残差、Norm、KV及XBC/KVB |
| 系统连接 | [控制与层级互连](DEA8/control/README.md)：8个完整PCore与GCore接线 |
| HBM边界 | [HBM说明](DEA8/HBM/README.md)：当前由TB提供数据，真实物理控制器/DMA未接入 |
| 服务器任务 | [验证说明](DEA8/Server_Verification.md)：仿真优先，之后单独综合GCore与一个PCore看资源 |

当前拓扑为 `PCore x8 -> 每核独立256-bit包链路 -> GCore`。K/V按坐标写入GCore KV；O/Down在GCore内部做4-lane归约和Residual。独立Reduce仅保留为历史源码，不属于生产链路。

## 算术与当前证据

- MXU：双行INT8、256个DSP、7级流水、精确INT20树；三种矩阵策略共用一套阵列。
- DEQACC为16级；官方FP32 ADD/SUB为11拍、MUL为8拍，均为2 DSP。EXP/RECIP/RSQRT按各自IP配置核算。
- PCore内部VPU/SFU已实例化；最终验收TB不模拟其算术。
- 真实单核七Job已通过：279571拍、265408矩阵issue、55QK/55PV。完整八核第1/9/18层及压力/恢复尚未通过服务器验收。
- 资源文档中的单PCore/GCore估算不是综合结果。GCore唯一历史综合报告保留，但对应旧FP后端/FIFO，不代表当前源码。

详细结论和PASS哈希见 [DEA8 README](DEA8/README.md)、[单核计算证据](DEA8/Pcore/reports/compute/)及[七Job指标](DEA8/reports/seven_job_native/metrics.json)。

## 本阶段服务器顺序

1. 完成单核七Job和八核第1/9/18层、背压、取消/恢复仿真。
2. 准入通过后，分别综合官方IP的完整GCore和单个完整PCore，只看资源。
3. 查看LUT/FF/DSP/BRAM/URAM后，再决定是否综合八核。

本阶段不综合八核、不布局布线、不做250MHz时序签核。

## 历史目录

`pcore/`为旧单INT8版；`DEA8_dynamic/`、`DEQACC/`、`architecture/`等为历史或探索内容，不能与当前双行PCore混接。`DEA8/reduce/`保留独立Reduce旧实现作对照。各自任务边界见相应README。
