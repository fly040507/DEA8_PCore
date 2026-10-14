# DEQACC V1 实现与仿真结果

日期：2026-10-13。**V1 RTL已实现，默认接入DEQACC副本Matrix；功能仿真通过。未运行综合、布局或布线。**

方案：[DEQACC_V1_优化方案.md](DEQACC_V1_优化方案.md)。全部修改在 `DEQACC/`；冻结的 `DEA8/`、GitHub同步仓库与旧浮点golden未修改。

## 1. 完成情况

| 阶段 | 状态 | 证据 |
| --- | --- | --- |
| 独立入口与旧参考 | 完成 | `deqacc_v1.f`；A11模块及冻结golden保留；源码hash见报告目录 |
| Q0/Q1直接反量化 | 完成 | 137,992笔逐位比较，2级、II=1 |
| A0～A3 FAR/CLOSE加法 | 完成 | 137,992笔逐位比较，4级、II=1；special/bypass/rounding等 |
| 32-lane、4×8、local ACC、C | 完成 | 10,486笔commit、metadata/address/mask/data/7级检查 |
| A3/C旁路及RAW条件 | 完成 | Δ4/5/6/7；A3命中276、C命中271；Δ1/2/3预期拒绝 |
| post-route与250MHz物理验证 | 未动 | 用户要求本轮不综合、不布线 |
| Matrix与七Job集成 | 完成 | 64 Tile Matrix、动态M、七Job265,408issues、Attention尾部定向检查 |

这是仿真验收，不是全输入空间形式等价证明；250MHz功能时钟为TB的4ns，不代表物理时序满足。

## 2. RTL 与接入

新增 `Pcore/rtl/`：

| 文件 | 内容 |
| --- | --- |
| `deqacc_v1_pkg.sv` | V1级数、局部key、物理地址 |
| `dequant_lane_v1.sv` | abs/lead/base → direct normal/subnormal RNE/pack |
| `fp32_add_lane_v1.sv` | 四级FAR/CLOSE、effective exponent、精确RNE、special/bypass |
| `acc_slice_v1.sv` | 四列、三bank、两parity；每parity两个64-bit RAM；组内validity |
| `deqacc_v1_group8.sv` | 两micro-cluster、8 lane、局部keys、A3/C旁路和局部commit |
| `deqacc_v1_control.sv` | 集中完整metadata与row mask，七级完成与done |
| `DEQACC_V1.sv` | 四组拼接、旧外部端口、在途bank预留、commit_write输出 |

修改 `pcore_pkg.sv`：新增 `USE_DEQACC_V1=1`，活动 `DEQACC_PIPE_STAGES=7`；A11选择时为11。修改 `dea8_matrix.sv`：按该开关选择V1/A11。修改 `pcore_all.f`、`rtl/pcore.f`：加入V1源文件。

旧A11算术未覆盖；`tb_deqacc32.sv`显式实例化A11，延迟检查因此固定11，独立于新Matrix默认配置。

### 数据依赖与接口

- 输入没有ready；独立地址连续流II=1，同parity依赖间隔必须≥4拍
- 四拍依赖选已RNE的A3结果；五拍读写冲突选C结果；更长间隔走RAM
- 两parity独立匹配，未写parity保持旧内容
- RAW检查为仿真断言，不是新增硬件stall机制；上游必须提供合法流
- generation在reset清零、clear推进，clear同时清所有在途valid与ACC validity；新Job由现有控制流程等待完成，不支持跨未drain Job重标身份
- 外部result/VPU端口在同bank有当前输入或在途事务时反压；不同bank继续服务
- 保留1024-bit commit_write兼容出口；内部RAM写回和反馈按组局部连接

## 3. 仿真结果

所有工具通过cmd先call Vivado 2022.2 `settings64.bat`。仅xvlog/xelab/xsim，无synth/place/route。冻结 `fp32_legacy_ref_pkg.sv` 与上传的旧副本对比无差异。

| 测试 | 结果 | 日志 |
| --- | --- | --- |
| 单lane | 137,992 Dequant + 137,992 FPADD；CLOSE 26,714、FAR异号54,260、bypass5,959 | `Pcore/reports/v1_tb_deqacc_v1_arithmetic.log` |
| 完整stream | 10,486笔；5,000笔与A11同输入对照；七级、II=1、旁路、clear、全ACC模型检查 | `Pcore/reports/v1_tb_deqacc_v1_stream.log` |
| RAW负例 | Δ1/2/3均仅触发指定RAW Fatal，按预期拒绝记录为PASS | `Pcore/reports/v1_BAD_RAW*.log` |
| 真实Matrix | 64 Tile，1,664 issues/commits，max issue gap=1 | `Pcore/reports/v1_tb_matrix.log` |
| 动态M | M=1/2/3/7/16/31/51，真实MXU逐笔数值一致 | `Pcore/reports/v1_tb_deqacc_v1_dynamic_matrix.log` |
| 完整PCore七Job | 265,408 issues；110 Attention子任务；Q/O/Z、输出数量和数值通过 | `Pcore/reports/v1_seven_jobs.log` |
| 旧Matrix链Attention定向 | 45,760 issues；body=416；steady=430；PV53→PV54=859；服务尾439 | `Pcore/reports/v1_chain_attention.log` |

Stream在clear前完整检查三个bank全部有效parity/列，外部写后再次检查，clear后再次检查。外部同bank在途反压、不同bank并发、同步read-first读写、越界读0和odd tail均有检查。

动态M实际同地址间隔：M≤31时最小17拍，M=51时26拍。该工程仍是B2→B1装载，不据此宣称已支持未来B4的4.25～4.5拍供数；四拍feedback由专门stream验证。

### 完整七Job周期（FUNCTIONAL）

4ns TB时钟；旧列来自迁移后的A11 FUNCTIONAL记录，非旧PERFORMANCE数字。

| Job | A11周期 | V1周期 | 减少周期 | V1全Job矩阵占比 |
| --- | ---: | ---: | ---: | ---: |
| K | 3,791 | 3,783 | 8 | 87.97% |
| V | 3,659 | 3,651 | 8 | 91.15% |
| Q | 27,143 | 27,079 | 64 | 98.31% |
| Attention | 49,257 | 49,025 | 232 | 93.34% |
| O | 28,276 | 28,021 | 255 | 95.01% |
| G-U | 107,448 | 107,320 | 128 | 99.23% |
| Down | 54,900 | 54,645 | 255 | 97.44% |
| 合计 | 274,474 | 273,524 | 950 | — |

合计为各Job总周期相加，不含Job间完成握手等待。FUNCTIONAL包含人工背压，K/V包含发送及commit收尾；本轮不以这些数字代替PERFORMANCE基线。

## 4. 复现

从 `DEQACC/Pcore/` 执行：

```powershell
# 短套件：lane、stream、动态M、Matrix、三种预期RAW拒绝
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_deqacc_v1.ps1
# 再加当前完整七Job FUNCTIONAL
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_deqacc_v1.ps1 -SevenJobs
```

脚本编译 `pcore_v1_sim.f`，独立库 `v1_suite`，核对退出码、PASS和Fatal/Error；负例要求精确RAW消息。工具调用timeout由外部终端设置，短套件≥300000ms，七Job建议3600000ms。

`Pcore/reports/v1_simulation_summary.txt` 是短套件最近结果；七Job单独见 `v1_seven_jobs.log`。`v1_sources_sha256.csv`记录对应RTL/golden hash。七JobO2快照成功生成；一次后台运行被^C终止，之后前台完整运行PASS，使用最终完整日志作为证据。

## 5. 偏离与修复记录

- V1独立开发后已接入副本默认Matrix，故活动package tail预算改为7；旧A11选择分支保留。正式DEA8没有改动
- 源码初次编译的函数名`matches`为SV关键字，已改为`key_match`
- 旧Matrix链TB的精确时间常量改为随DEQACC级数计算；没有删除数值或issue数量检查
- Attention服务尾与DEQACC尾不同：固定SFU26＋AFIN408＋5拍握手仍是439，不能随11→7扣四拍。初次补跑因错误预测尾435而Fatal，修正后定向测试确认859/439通过
- Attention-only fixture使用Projection Q对应的量化数据，保持原QK/PV golden检查
- 完整旧Matrix链补跑未在修正后重跑其所有七Job；已有完整`tb_pcore_control`七JobPASS，受修正影响的旧链Attention定向PASS。旧链其他扩展FAULT/stress未在本轮签核
- 局部bitmap、分组和keep_hierarchy按方案实现；没有宣称综合后fanout、资源或routing已改善

## 6. 剩余边界

功能实现与本轮要求的仿真已完成。综合可实现性、资源和4ns post-route尚未验证；本轮明确不执行这些步骤。

下一阶段可在明确启动物理验证后检查Q1、FAR A1、CLOSE A2和A3→A0 feedback的实际时序；同时对4×8输入分发、局部bitmap与输出总线测fanout。合并进DEA8、GitHub推送均需后续指令。
