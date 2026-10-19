# DEA8 工程交接

更新：2026-10-19。本文只描述现行DEA8；旧版本的11级DEQACC、外部VPU/SFU服务、独立Reduce和旧FP实现不作为接入依据。

## 范围与真实实现

目标平台U50，固定51行、hidden1024、8个PCore。最终系统目标为18层、10步去噪；本阶段验证第1/9/18层三个独立checkpoint，不假装执行跳过的层。

| 部分 | 当前实现 |
|---|---|
| 完整PCore | `Pcore/rtl/dea8_pcore_top.sv`；内部控制、Matrix、真实VPU/SFU、Mask/RoPE和存储 |
| 完整GCore | `Gcore/rtl/dea8_gcore.sv`；官方FP算术、真实rsqrt、内置归约、残差、Norm、KV与供数 |
| 八核与层级接线 | `control/rtl/dea8_pcore_cluster.sv`、`dea8_layer_top.sv` |
| 仍由TB模拟 | DEA8全局策略、外部HBM权重/γ、最终接收及允许预置的初始RESID/prefix |
| 尚未接入 | 真实HBM/PCIe、prefix装载、全局策略RTL、步间算子及板级验证 |

DEA8总控发布七种PCore Job和GCore宏观Job；PCore/GCore各自有局部控制。GCore不代替DEA8发布PCore Job，PCore不自行循环18层或10步。

## 一层的顺序与屏障

`K -> V -> Q -> Attention -> O -> G-U -> Down`。K/V/Q/G-U从GCore的XBC取A；Attention从QOZ/PBUF取A、KVB取B；O/Down从QOZ取A。其余B来自外部HBM适配。

- START建立初始XHAT，K/V接收必须在对应PCore外发前授权。
- K/V逐Tile实际写KV RAM后回commit；本核done包含提交等待。
- Attention先使用QOZ_Q，再把最终量化结果写QOZ_O。
- O/Down边输出partial，GCore边归约、残差写回及统计。PCore done不等于GCore服务done。
- O的FFN XHAT先就绪后可启动G-U，不必等O后台γ加载完全退休；必须同时满足PCore O结束及GCore用途/版本条件。
- G-U的GELU、乘U和量化与矩阵重叠，Z写共享QOZ；Down使用Z。
- 第18层Down后GCore输出final norm FP32流，不请求第19层参数。action output projection/Euler更新不因七Job存在而自动实现。

[详细单层流程](Pcore/docs/DEA8_整体架构与单层流程说明.md)、[GCore宏观接口](Gcore/GCore_Overall_Plan.md#17-宏观控制的实际接口)。

## 接口事实

| 路径 | 组织 |
|---|---|
| XBC | `xbc4_t`，当前563bit，四行同Tile；前端拆成双行 |
| HBM/KVB到PCore | `b2_t`，当前288bit，两列量化数据及元数据；不是物理HBM AXI beat |
| PCore到GCore | 八条独立256bit流，valid/ready/last；首拍header |
| K Tile | 1 header + 51个136bit有效payload，feature-B16 |
| V Tile | 1 header + 64个136bit有效payload，token-B16；不能写成51拍 |
| O/Down Tile | 1 header + 102个256bit FP32 payload |
| KV commit | GCore实际落RAM后返回；O/Down没有逐核反向commit |
| GCore final | 512bit FP32向量，共3264次握手 |

包字段用 `dea8_tile_link_pkg`编码。K核c列坐标为16c与128+16c，V为32c与32c+16；O/Down八核坐标相同，source_id不同。不要依据到达时间猜测坐标。

VPU/SFU的command/data/ACC/workspace/RoPE口是PCore内部接口，见 [PCore README](Pcore/README.md)。其他同学替换内部单元时必须保持token、ready/valid、done和flush合同，不把完整PCore拆成最终TB服务模型。

## 数值与配置

- MXU 7级，INT20 partial；DEQACC 16级。
- 官方ADD/SUB11拍、MUL8拍，各2DSP；EXP21、RECIP29、RSQRT32。
- GCore残差存BF16，先扩展FP32参加运算，写回时BF16 RNE。归约和统计遵循固定树顺序。
- Norm执行 `X * rsqrt(mean(X²)+epsilon) * gamma`，两次FP32乘法分时复用。γ为导出的实际乘数，不能默认折叠权重。
- Mask遵循官方pi0：state不看action，action互相可见；padding被屏蔽。当前ROM默认有效prefix816、suffix51。
- RoPE前后128配对；position、Mask/RoPE版本和context必须匹配。配置错误拒绝Job，不用ready/done常高绕过。

## 取消与恢复

cluster锁存取消，单拍clear，等待8核真实flush_done及HBM drain ack。层级top协调GCore与PCore排空，不直接把请求回接ack。

外部HBM/XBC/KVB旧返回必须撤销；内部RAM可能已部分更新，取消不承诺回滚。恢复要重新提供合法RESID/版本并正式import，不能只清error重跑混合残差。

## 验证证据与边界

- 当前完整单核七Job：279571拍，265408矩阵issue，94.93%；55QK/55PV。内部无TB算术，输入及下游为外部模型。
- 原始PASS、日志和编译哈希：`Pcore/reports/compute/`；图/CSV：`reports/seven_job_native/`。
- GCore官方IP回归：`reports/native_20261019/gcore/`；Mask、冷Norm/import、取消等定向测试：`reports/layer_native/`。
- 八核第1/9/18层及压力/恢复尚待服务器实际展开、运行。只有编译记录，不能写已联合通过。
- 4ns只用于约束和仿真时间换算，不是当前时序签核。
- GCore历史109DSP/152.5BRAM36报告保留；其源码不是当前官方IP版本，不能替代新资源报告。

## 服务器本阶段

按 [服务器说明](Server_Verification.md) 先完成仿真准入，再执行：

```text
python run_dea8.py synth --target gcore --server-heavy
python run_dea8.py synth --target pcore --server-heavy
```

目标分别是完整 `dea8_gcore`和包含VPU/SFU的完整 `dea8_pcore_top`，不是裸Matrix或DEQACC。资源输出 `reports/resource_synth/gcore/`、`pcore/`，不覆盖GCore历史报告。当前入口拒绝未指定目标的综合以及place-route。

本阶段不综合八核、不运行opt/place/route。先用单模块LUT/FF/DSP/BRAM/URAM及层次RAM结果估算八核，确认平台shell余量后再决定下一阶段。

## 构建与修改

正式RTL清单：`Pcore/pcore_rtl.f`和`Gcore/gcore_rtl.f`。单核runner为`Pcore/run_compute.py`；层级runner为`run_dea8.py`。改源码/IP配置/ROM/gold后重编译并展开，不能复用旧快照冒充新PASS。

`pcore_all.f`、旧控制签核脚本、`reduce/`和旧DEQACC时序工具保留为兼容/历史入口，不是当前完整PCore验收或官方IP面积入口。参考 `DEA8_zhao`时不修改该目录，不改变设计版本名称。
