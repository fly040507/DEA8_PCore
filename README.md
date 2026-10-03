# VLA 工作目录

| 目录 | 用途 |
| --- | --- |
| `V3/` | 当前 PCore 双行 INT8 / shared Matrix / QOZ 执行框架；运行与验收入口见 `V3/README.md` |
| `pcore/` | 保留的旧单 INT8 PCore，对照旧接口时使用 |
| `interaction/` | 当前阶段任务与接口评审输入 |
| `architecture/` | 架构模型、物理预算与图示；与 RTL 功能验证分开 |
| `openpi/`、`paper/` | 模型代码与论文资料 |

V3 仿真在 `V3/` 执行 `powershell -ExecutionPolicy Bypass -File .\run_v3_xsim.ps1`；结果以新生成的 `V3/reports/v3_simulation_summary.txt` 和 `v3_sources_sha256.csv` 为准。`V3/reports/DEQACC_3.3ns/` 中的物理证据只适用于冻结的 DEQACC，不能外推为新 PCore Top 的时序结果。
