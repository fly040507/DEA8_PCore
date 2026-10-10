# DEA8：八核 VLA 计算工程

进度核对：2026-10-10。

DEA8 面向 pi0 Action Expert 的 FPGA 加速。系统目标是组织 **10 步去噪、18 层、8 个 PCore** 的计算；当前已落地的是单核 PCore 与独立八核 FP32 Reduce，系统总控、GCore 和真实 HBM 仍待接入。

**当前里程碑：迁移后的单核七 Job 全链路 PASS，Reduce 独立仿真 PASS。尚未完成真实八核系统联调。**

## 1. 当前方案

固定模型 profile：51 个 suffix token、hidden width 1024、FFN width 4096、8 个 Query head、1 个 KV head，每个 head 256 维。

单层矩阵计算顺序：

```text
K projection → V projection → Q projection → Attention
→ O projection → G-U → Down projection
```

这七个 Job 覆盖 Transformer 层的矩阵主体。RMSNorm、Residual、KV 管理等共享操作由 GCore 承担；服务器/FPGA 的 suffix embedding、最终输出与 Euler 更新边界仍需系统层明确。

```text
                     DEA8 control
                 八核 Job 分发、阶段屏障
                          |
       GCore ── XBC/KVB ──┼── HBM 权重供数
                          v
                      PCore ×8
                Matrix / DEQACC / QOZ
                    VPU、SFU 接口
                   /              \
       K/V：136-bit Tile 流    O/Down：512-bit 行流
                |                  |
                |             8 路 FP32 Reduce
                |                  |
                +──────→ GCore ←───+
```

K/V 是不同核的列分片，由 GCore 按 header 坐标接收，不做跨核数值加法。O/Down 是各核对同一输出的部分贡献，需要 Reduce 求和。

## 2. 模块分工与进度

| 目录 | 职责 | 当前进度 |
| --- | --- | --- |
| [Pcore/](Pcore/README.md) | 单核矩阵计算、DEQACC、QOZ、七 Job 控制及输出 | RTL 已实现；迁移后七 Job 与协议仿真 PASS |
| [reduce/](reduce/README.md) | 八路 O/Down FP32 归约、Tile 输出与 commit | 独立 RTL 和基本数值/传输仿真 PASS；待接真实八核 |
| [Gcore/](Gcore/README.md) | 共享激活、Norm/Residual、KV 管理、供数与结果接收 | 当前为目录和接口边界，真实 RTL 待接入 |
| [control/](control/README.md) | 十步/层级调度、八核任务和跨模块完成屏障 | 当前为总控边界，真实 RTL 待接入 |
| [HBM/](HBM/README.md) | HBM 适配、地址映射、权重搬运 | 当前由 TB 供数，真实控制器待接入 |

当前权威工程路径为 `DEA8/`。根目录 `../pcore/` 保留旧单 INT8 设计，仅供对照。

## 3. 最近完成的工作

- 工程迁移：原 PCore 与归约设计按物理职责归入 `Pcore/`、`reduce/`，清理当前模块和文件命名
- PCore 输出集成：K/V Tile sender、O/Down 行流输出纳入 PCore 内部
- 仿真模型优化：VPU32/SFU4 并行服务、连续请求与响应、QK_POST 16 行统计访问、P_POST 流水处理
- 完成条件解耦：VPU 和 SFU 只等待各自通道排空
- 新路径验证：单核七 Job、PCore 协议、Reduce 独立仿真均有 PASS 记录

## 4. 已有证据与验收边界

| 证据 | 已确认内容 |
| --- | --- |
| [七 Job 日志](Pcore/reports/pcore_control_after_migration.log) | K/V/Q/Attention/O/G-U/Down 串行完成；265,408 matrix issues；110 个 Attention 子任务；FUNCTIONAL 模式 |
| [PCore 协议日志](Pcore/reports/pcore_protocol_after_migration.log) | Job 前置条件、错误任务、完成保持、FAULT、迟到响应和 flush 等检查 PASS |
| [Reduce 日志](reduce/reports/reduce_sim.log) | 八路输入、51 行输出、FP32 数值和 commit 的基本场景 PASS |

这些是现有行为级仿真证据。VPU/SFU 算术、GCore、HBM 和外部完成响应仍由 TB 模拟；不代表真实外部单元吞吐、八核系统集成或 250 MHz 综合/布局布线签核。

迁移后的七 Job 日志是 FUNCTIONAL 模式，包含人工背压。旧输出接口下的 PERFORMANCE 数字不能直接作为当前输出方案的性能基线。

## 5. 从哪里开始看、如何运行

1. 阅读 [PCore README](Pcore/README.md)：单核数据流、七 Job 进度、当前周期与仿真方式
2. 阅读 [Reduce README](reduce/README.md)：八路输入、归约树、输出/commit 和验证范围
3. 对接输出端口时，以 [PCore 外发与 Reduce](Pcore/docs/PCore_Output_and_Reduce.md) 和 `Pcore/rtl/dea8_tile_link_pkg.sv` 为依据

从 `DEA8/` 目录执行：

```powershell
# PCore 完整回归，包含多个 TB 和额外场景，耗时较长
.\Pcore\run_pcore_xsim.ps1

# Reduce 独立仿真
.\reduce\run_reduce.ps1
```

默认使用 Vivado 2022.2，安装路径 `D:\Xilinx\Vivado\2022.2`；脚本支持 `-VivadoRoot`。只测七 Job 时，使用 PCore README 中的单 TB 入口，不必运行完整回归。

## 6. 下一阶段

1. 在当前输出接口下建立七 Job PERFORMANCE 基线，区分矩阵计算、后处理、发送与 commit 等待
2. 核对 ALPHA_EXP/RECIP 的 SFU4 计算吞吐与 workspace 搬运模型
3. 接入真实八核 PCore → Reduce → GCore，验证数据身份、反压、提交和阶段屏障
4. 接入 GCore、DEA8 总控与 HBM，逐步扩大到完整层和十步去噪

文档待同步：[整体架构说明](Pcore/docs/DEA8_整体架构与单层流程说明.md) 仍保留旧版 K/V 经 Reduce、32-lane 归约和旧载荷宽度。当前输出接口以本 README、模块 README、输出说明及 RTL 为准。
