# DEA8 PCore：单核矩阵计算与七 Job 控制

进度核对：2026-10-10。

PCore 是 DEA8 的单核计算单元：双行 INT8 矩阵计算、FP32 DEQACC 累加、Q/O/Z 本地存储、后处理调度和 K/V/O/Down 输出。**当前 RTL 与迁移后七 Job 全链路仿真已通过；VPU/SFU 算术和外部供数由 TB 模拟。**

八核系统分工见 [DEA8 README](../README.md)，跨核归约见 [Reduce README](../reduce/README.md)。

## 1. 单核方案与接口边界

每核对应一个 256 维 Query head，并承担 K/V 的 32 维 shard、FFN 的 512 维 shard。Projection、Attention、G-U 三类路径共享 `dea8_matrix`，由 `dea8_pcore_control` 接收完整 Job 并调度矩阵、后处理、存储和输出。

| 路径 | 当前职责 |
| --- | --- |
| XBC / HBM | 接收共享激活与权重数据，供给 Projection 和 G-U |
| QOZ / KVB | 保存本核 Q/O/Z，向 Attention 提供 Q 与 K/V 数据 |
| Matrix / DEQACC | 双行 INT8 点积、反量化和 FP32 累加 |
| VPU / SFU | command/data/done、ACC 与 workspace 接口；内部算术由外部单元实现 |
| K/V 输出 | 内部 Tile sender → GCore，128-bit header + 136-bit 数据流，等待 commit |
| O/Down 输出 | PCore → Reduce，128-bit header + 512-bit FP32 行流 |

K/V 完成需等待 sender 清空及目标 commit；O/Down 的 PCore 输出完成由最后一拍数据握手定义。Reduce 到 GCore 的最终 commit 由 Reduce 管理，因此本核 `done` 不等于全局归约结果已提交。

## 2. 七种 Job 已走通的流程

固定顺序：`K → V → Q → Attention → O → G-U → Down`。

| Job | 计算与本地后处理 | 结果去向 |
| --- | --- | --- |
| K | K projection、RoPE、量化 | GCore 的 K 目标对象 |
| V | V projection、量化 | GCore 的 V 目标对象 |
| Q | Q projection、RoPE、量化 | QOZ 的 Q 区域 |
| Attention | 55 QK + 55 PV；在线 softmax、OACC 缩放、最终归一化与量化 | QOZ 的 O 区域 |
| O | 读取本地 O，执行 O projection | Reduce 的 FP32 partial |
| G-U | Gate/Up projection、GELU、逐元素乘法与量化 | QOZ 的 Z 区域 |
| Down | 读取本地 Z，执行 Down projection | Reduce 的 FP32 partial |

PCore 不承担十步去噪/18 层总控，也不承担全 hidden 维度的 RMSNorm、Residual 或 KV 全局管理。

## 3. 已完成的实现与仿真工作

- 三类矩阵路径共享执行核心；QOZ 管理 Q → O → Z 生命周期
- PCore 控制中心组织矩阵子任务、VPU/SFU 后处理和完整 Job 完成
- `dea8_pcore_output`、`dea8_kv_tile_sender` 集成到 PCore，使用 Tile header/data/commit 协议
- 七 Job TB 支持 FUNCTIONAL / PERFORMANCE / STRESS 三模式
- TB 非矩阵模型：VPU32/SFU4 并行运行，请求/响应流水化；QK_POST 使用 16 行统计访问，P_POST 流式处理
- VPU/SFU 完成等待独立排空各自通道，避免人为串行化
- 迁移后的源文件清单编译、完整七 Job 和控制协议仿真通过

## 4. 当前验证结果

证据：[迁移后七 Job 日志](reports/pcore_control_after_migration.log)，2026-10-10 新路径运行，**FUNCTIONAL 模式**，时钟周期 4 ns。

| Job | 总周期 | Matrix issues | 全 Job 矩阵占比 |
| --- | ---: | ---: | ---: |
| K | 3,791 | 3,328 | 87.78% |
| V | 3,659 | 3,328 | 90.95% |
| Q | 27,143 | 26,624 | 98.08% |
| Attention | 49,257 | 45,760 | 92.90% |
| O | 28,276 | 26,624 | 94.15% |
| G-U | 107,448 | 106,496 | 99.11% |
| Down | 54,900 | 53,248 | 96.99% |

总工作量：265,408 issues；Attention 子任务：110。矩阵占比按 `matrix issues / Job 总周期` 统计，包含启动、后处理和外发尾部，不等同于逐 PE 有效 MAC 槽位利用率。

FUNCTIONAL 有人工背压，K/V 还有当前 Tile sender 与 commit 开销；上表用于记录功能跑通状态。当前输出接口下的 PERFORMANCE 基线待重新运行，不用旧接口的性能结果代替。

其他证据：

- [控制协议日志](reports/pcore_protocol_after_migration.log)：前置条件、非法 Job、核身份、完成保持、迟到响应、FAULT 和双 flush ack 等检查 PASS
- [迁移验证说明](reports/verification_after_layout.md)：目录/命名迁移与新路径运行情况；这里的 layout 指工程目录组织，不是芯片布局布线
- [输出完整链日志](reports/pcore_output_full.log)：输出模块集成后的七 Job 记录；保留旧模块名，以新路径迁移日志为当前阅读入口

以上为行为仿真，不代表真实 VPU/SFU 算术、HBM 带宽、八核联调或综合/P&R 时序签核。

## 5. 文件入口

| 路径 | 内容 |
| --- | --- |
| `rtl/dea8_pcore_control.sv` | PCore 顶层控制与单元接口 |
| `rtl/dea8_pcore_exec.sv`、`rtl/dea8_matrix.sv` | 三类 Job 执行与共享矩阵通路 |
| `rtl/dea8_qoz_manager.sv`、`rtl/dea8_qoz_store.sv` | Q/O/Z 所有权和本地存储 |
| `rtl/dea8_pcore_output.sv`、`rtl/dea8_kv_tile_sender.sv` | K/V 与 O/Down 输出 |
| `rtl/dea8_tile_link_pkg.sv` | 与 Reduce/GCore 共用的 header、commit 和布局定义 |
| `tb/tb_pcore_control.sv` | 当前七 Job 数值与流水仿真主入口 |
| `pcore_all.f` | 当前源文件编译清单 |
| `legacy/` | 旧模块兼容回归材料 |

详细说明：[PCore 控制中心](docs/PCore_Control_Center.md)、[PCore 外发与 Reduce](docs/PCore_Output_and_Reduce.md)。整体架构文档中的旧输出宽度与 Reduce 职责尚待同步。

## 6. 如何运行

从本目录执行，只跑当前七 Job TB：

```powershell
$VivadoRoot = 'D:\Xilinx\Vivado\2022.2'
& "$VivadoRoot\bin\xvlog.bat" -sv -f pcore_all.f "$VivadoRoot\data\verilog\src\glbl.v"
# 编译成功后展开；O0 避开此前 XSim O2 在此 TB 上出现的内部断言
& "$VivadoRoot\bin\xelab.bat" tb_pcore_control glbl -s pcore_7job --O0 --debug typical --mt off -timescale 1ns/1ps -L unisims_ver
# 展开成功后运行；默认 FUNCTIONAL
& "$VivadoRoot\bin\xsim.bat" pcore_7job -runall -log reports/pcore_7job.log
```

PERFORMANCE 建议用 XSim options 文件传参，避免 Windows PowerShell 5.1 对 `MODE=PERFORMANCE` 的参数拆分。文件内容：

```text
-runall
-testplusarg MODE=PERFORMANCE
```

保存为本地 `performance.options` 后执行：

```powershell
& "$VivadoRoot\bin\xsim.bat" pcore_7job -f performance.options -log reports/pcore_7job_performance.log
```

加上 `-testplusarg ATTENTION_ONLY` 可聚焦 Attention。最终成功需同时确认返回码、无 Fatal/Error 和 `tb_pcore_control PASS`，不能只看 XSim 退出码。

现有扩展入口：`run_pcore_xsim.ps1` 为多 TB 完整回归；`run_control.ps1` / `run_control_signoff.ps1` 包含控制、fault/cancel 和多 seed stress 等场景。只看七 Job 周期时，不需要默认运行这些长回归。

## 7. 接下来做什么

1. 重建当前输出接口下的七 Job PERFORMANCE 基线，重点分解 K/V 发送与 commit 尾部
2. 核对 ALPHA_EXP/RECIP 的 SFU4 吞吐与 workspace 访问能否合理重叠
3. 对接真实 VPU/SFU、GCore/HBM 与八核 Reduce，确认真实反压和跨模块完成条件
