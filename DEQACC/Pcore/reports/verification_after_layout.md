# DEA8 PCore 重构后验证

## 当前路径验证

- `pcore_all.f` 完整源文件清单：Vivado 2022.2 编译通过，返回码为 0。
- `tb_pcore_control_protocol`：通过。检查 precondition、非法 Job、错误核号、完成保持、排队等待、迟到响应、FAULT 和双 flush ack。
- 七 Job 完整行为结果：`pcore_control_after_migration.log` 已在新路径重新运行通过，包含 K、V、Q、Attention、O、G-U、Down；总 issues=265408，Attention 子任务=110。

## 迁移说明

本次目录和标识重构没有改变矩阵、控制或接口逻辑，只做了路径、文件名、模块名和工程说明清理。完整七 Job 仿真已在当前路径重新展开并通过，协议 TB 也重新通过。

## 范围

以上是行为级验证，不代表综合、布局布线或 250 MHz 时序签核。Reduce 的当前验证见 `../../reduce/reports/reduce_sim.log`。
