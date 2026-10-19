# 历史独立Reduce：不进入当前DEA8

更新：2026-10-19。此目录仅保留旧源码/TB供历史对照，**不是待接入模块，也不是下一阶段要恢复的模块**。

当前PCore每核通过一条256bit包链路直连GCore：
- K/V按坐标写GCore KV RAM，实际落存后回commit。
- O/Down由GCore内部4-lane八输入树归约，直接做残差与统计。
- 没有旧512bit独立Reduce接口，没有独立归约结果Tile/发送/commit层。

请用 [PCore说明](../Pcore/README.md)、[GCore说明](../Gcore/README.md)和[当前层级互连](../control/README.md)。本目录不在生产RTL清单、服务器联合验收或资源预算中。

旧仿真报告已清理。即使手动运行旧run_reduce.ps1，结果也只属于历史独立模块，不能证明当前GCore内置归约或八核单层正确。
