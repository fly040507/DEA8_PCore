# DEA8：仅保留Layer1、9、18独立层仿真

按用户要求于2026-10-20清理。仅保留 **GCore + 8个真实PCore** 的三项独立层正式PASS证据，不代表完成18层连续运行。

## 结果位置

`20261019_sim01/scheduler_v3/cases/` 下仅保留：

- `tb_dea8_layers_native__LAYER_1/`
- `tb_dea8_layers_native__LAYER_9/`
- `tb_dea8_layers_native__LAYER_18/`

每项保留原始 `result.json`、`xsim.result.json`、`xsim.console.log` 和 `xsim.jou`。
PASS、正常退出码0、错误记录、日志哈希和原始480项输入manifest在清理前后重新核验。
官方DSP模型OPMODE含X告警仍保留在日志中；PASS不表示无告警。

## 性能口径

不含初始RMS/配置准备，从K受理计到本层完成，4ns/拍：

| 层 | 周期 | 时间µs | Matrix发射/核 |
|---|---:|---:|---:|
| Layer1 | 293448 | 1173.792 | 265408 |
| Layer9 | 293448 | 1173.792 | 265408 |
| Layer18 | 293440 | 1173.760 | 265408 |

九阶段报告和原始只读边界记录保存在 `20261019_gu_readonly_audit/`。
Layer9的独立Down完成边界没有保存，不能借用Layer1/18的边界冒充实测。
Layer18最终输出3264字；Layer1/9只准备下一层输入，不运行下一层计算。

## 保留与删除

- 保留原始manifest、源文件清单、工具环境、编译/展开文本记录，以及外部TB等价wait修正和原始runner文件，供审计、重建参考。部分runner输入为了维持原manifest可验证性仍位于原目录，它们不是保留的其他仿真结果。
- 删除其他测试结果、旧实验、压力/取消/恢复测试数据、临时文件、编译库/仿真快照(`xsim.dir`)、波形(`.wdb`)和重复日志。
- 源码仍以 `/home/zhaofei/DEA8` 为准，未修改。删除目录中的源码符号链接不会删除目标源码。
- **当前是结果归档，不是可立即启动的仿真工作区。** 看波形或重新运行需重新编译/生成；不要直接运行历史调度器，它原本面向50项矩阵。
- 不启动仿真，不启动综合，不自动恢复。

清理清单和核验报告：`cleanup_20261020/`。
当前三项归档状态：`cleanup_20261020/status.json`；入口指针仍为 `20261019_sim01/SCHEDULER_CURRENT.json`。
