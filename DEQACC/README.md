# DEQACC V3

当前正式版本：**V3，2026-10-14暂时冻结；七级、32 lane、250MHz独立OOC post-route WNS=+0.544ns，满足0.5ns裕度**。短仿真全部PASS，126个源/测试/脚本/约束文件hash已固定。方案与完整接口说明见 [DEQACC_V3_版本说明.md](DEQACC_V3_版本说明.md)。

本目录是独立开发副本，`VLA/DEA8/`保持冻结。V3在七级内提前寄存forwarding选择，并使用normal/subnormal并行反量化，保留II=1和同地址最小四拍依赖。

## 工程入口

| 路径 | 用途 |
| --- | --- |
| [Pcore/](Pcore/README.md) | 完整PCore副本、V3 RTL、数值参考和仿真入口 |
| `Pcore/run_deqacc_v3.ps1` | V3短套件；可显式选择七Job |
| `Pcore/run_deqacc_v3_route.ps1` | V3精简综合/布局布线与0.5ns裕度检查 |
| `Pcore/reports/v3_simulation/` | 本轮收尾功能证据 |
| `Pcore/reports/v3_postroute/` | 本轮七级真实路径、资源与routed DCP |
| `Pcore/V3_FROZEN.sha256.csv` | 收尾后冻结的源文件/脚本清单 |
| [history/](history/README.md) | 旧V1/V2文字参考，不是当前源码验证证据 |
| `control/`、`Gcore/`、`HBM/`、`reduce/` | 原完整系统副本的相关模块与接口边界 |

废弃routing/区域实验的DCP、长报告、波形、缓存和实验入口已清理。A11/golden仍在源码中，因为短套件和兼容回归依赖它们，不作为当前V3顶层。

## 复现

从`DEQACC/Pcore/`执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_deqacc_v3.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_deqacc_v3_route.ps1
```

每次工具在同一cmd先call settings64.bat再call官方bat。短仿真timeout≥300000ms，完整实现建议3600000ms。已有收尾报告不会被静默覆盖；冻结后修改源文件会使复现入口拒绝运行，需先明确启动新版本。

当前使用OOC全接口观测壳和BUFG，不代表完整PCore/八核或板级I/O时序。详细收尾结果与冻结状态以版本说明为准。
