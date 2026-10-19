# DEA8 GCore 当前实现

更新：2026-10-19。固定M=51、hidden1024、8PCore；完整顶层为 [dea8_gcore.sv](rtl/dea8_gcore.sv)，正式生产清单为 [gcore_rtl.f](gcore_rtl.f)。

## 当前结构与精度

```text
8 × PCore tx256 -> 每核header + 256×4同步FIFO
    K/V -> 按坐标落KV RAM -> commit
    O/Down -> 四路八输入FP32树 -> 四路残差加法
        -> BF16 RNE写RESID -> 当前Tile平方/SUM8/SUM64 -> SQ_ACC

Norm: 统计有效则复用，否则先冷扫RESID
    sq/1024+epsilon -> 单路真实rsqrt -> INV[51]
    RESID*inv -> 反馈FIFO -> 再乘gamma -> Y FIFO
    -> 8-lane量化，完整B16共享scale -> XHAT -> XBC

KV RAM -> KVB -> 八核Attention
第18层Down后 -> final norm FP32流
```

- 官方FP32 ADD11拍/2DSP、MUL8拍/2DSP；单rsqrt32拍。无自研FP32加乘生产旁路。
- 34个ADD：四棵树28、残差4、SQ_ACC1、epsilon1。16个MUL共享平方、均方、X*inv、H*gamma。
- 109DSP是结构预算，当前官方IP版本尚未综合。历史同为109DSP不证明其他资源或时序不变。
- 统计使用实际写回BF16值；四个N-Tile形成SUM64，16组构成每行1024元素平方和。
- Norm两次FP32乘法分时执行；Y直接量化，不额外先舍入BF16，不默认将γ折叠权重。
- payload优先同步BRAM/URAM；RX、读响应和乘法反馈FIFO已经改成同步BRAM加小head cache。
- 反馈/结果深度为 `1<<clog2(MUL_LATENCY+4)`，当前16，不沿用旧深度8。
- 不保存八份FP32输入Tile或独立归约结果Tile；当前Tile先归约/残差，再扫描统计。

[完整控制方案](GCore_Overall_Plan.md)、[接收与共享算术](GCore_Reduce_Plan.md)、[资源口径](../FP_Resource_Mapping.md)。

## 模块入口

| 文件 | 责任 |
|---|---|
| dea8_gcore / services | 公开边界与内部连接，默认INTERNAL_RSQRT=1 |
| dea8_gcore_jobs / control | 宏观展开、对象/版本、互斥、完成与取消 |
| gamma / gamma_fetch | 两组参数RAM、HBM请求/返回/身份/长度校验 |
| packet_rx | 八路header/256×4 payload FIFO、检查、背压与退休 |
| compute / tree8 | 四lane归约/残差、Tile统计、冷/热Norm、乘法复用 |
| fp_add / fp_mul / dsp_alu | 官方ADD/MUL封装及实际延迟对齐 |
| quant8 / rsqrt | 8-lane B16量化、单官方rsqrt及信用队列 |
| residual_store / residual_import | RESID RAM与正式import |
| activation_store / xbc | XHAT及逐核pending-mask广播 |
| kv_receive / kv_store / kvb | 坐标落存、KV提交与完整110子任务供数 |

以上文件位于 `rtl/`，字段以 `gcore_pkg.sv`和PCore公共package为准。旧vector/norm/shared_compute/reduce_sink不在当前生产链路；旧quant仅用于兼容叶测试。

## 控制与完成

DEA8总控理解层/步、发布PCore七Job；GCore只是功能模块，**不发布PCore Job、不自行循环18层/10步**。初始化按config、preloaded、layer握手后START。

| GCore宏观Job | 内部工作与完成 |
|---|---|
| START | 本层两组γ -> 初始Norm -> XHAT完整 |
| K / V | 授权KV接收并XBC，等供数与落存均结束 |
| Q | XBC全部被八核接收 |
| ATTENTION | KVB完成55QK+55PV供数；KV lease仍需显式释放 |
| O | 归约/残差/统计 -> FFN Norm -> 后台γ加载退休 |
| GU | FFN XHAT用途/版本有效后XBC，不必等O后台γ全退 |
| DOWN | 归约/残差/统计 -> 等γ -> 下一层热Norm，末层改final FP32 |

O/Down的GCore服务完成与PCore done不同；O/Down可边矩阵边发送/归约。GU需同时满足八核O完成与FFN XHAT有效，G-U下一N-Tile仍遵守八核prefetch许可。

换层保留RESID、有效SQ_ACC/XHAT，失效旧suffix并登记已预置的新prefix；下一组γ ID需匹配预取。末层不请求第19层参数。

服务级命令用于管理/兼容测试：正式 `GC_IMPORT_RESID`接收3264个256bit残差字，`GC_PREFIX_LOAD`明确拒绝。本阶段prefix预置不是已完成DMA。宏观Job期间不能夹入未经授权的外部服务/γ写。

## 八路256bit协议

| 类型 | header | payload | 退休 |
|---|---|---|---|
| K | 低128有效，高128零 | 51个字，低136为data128+scale8 | 真正写KV后回commit |
| V | 同上 | 64个token-B16字，尾组3token有效 | 同上 |
| O/Down | 同上 | 102个字，每行先低8FP32再高8FP32 | 归约、残差写回及统计全部结清 |

八路独立ready/valid/last，不是争用一条总线。FP32 FIFO head先消费低128、再高128，第二次接受后才pop。K/V独立按坐标写，不等八核凑齐；FP32则必须八核同Tile/行/half对齐。

字段、dtype、量化轴、source_id与列映射见 [dea8_tile_link_pkg.sv](../Pcore/rtl/dea8_tile_link_pkg.sv)。首拍不是最后payload，不能把最后payload入FIFO当Tile已退休。

## γ、rsqrt与末层

HBM返回实际γ乘数；pi0普通RMSNorm的参数导出为 `gamma=1+checkpoint.scale`，GCore不再加1。宏观请求普通2048项、final1024项，GCore生成slot/index/last。加载可与GU供数、Down归约重叠，不覆盖正在Norm使用的参数。

原始 `gamma_load_t`当前92bit，宏观HBM接口使用token+FP32值+last；不得把两者混用。Norm按param_id/context/generation选择参数。H反馈同时保存对应γ，防止预取覆盖导致错配。

默认内部rsqrt真实工作；外部响应忽略。INTERNAL_RSQRT=0仅兼容/故障注入，不用于最终内部无TB验收。当前51行发51个请求、mask=01，不是双lane26包。

final_data每次16个FP32、512bit，index=n_tile*51+row，共3264个向量；最后一次握手后末层DOWN完成。

## 错误与恢复

错误包、token/长度/非有限值不能静默通过。故障后阻止迟到写、失效对象/统计并等待真实flush。已经写回的RESID不自动回滚，需重新提供合法输入，通过正式import恢复，不能仅清error重跑混合残差。

## 当前验证状态

| 项目 | 已通过范围 |
|---|---|
| FP算术 | 4096ADD+4096MUL、BF16、量化、CE停顿 |
| 冷Norm | 3264量化向量、51 inverse，10014拍 |
| 正式import | 外部导入3264残差字后真实冷Norm，不在运行中改内部RAM |
| 服务回归 | baseline/STRESS/坏header/坏packet/活动取消恢复；9792量化、6528残差、128Tile、32commit |
| 单Tile定向计时 | 当前服务回归header到退休最长396拍；非任意背压下上界 |

证据在 `../reports/native_20261019/gcore/`及`../reports/layer_native/`。服务回归的PCore是GCore外部模型；旧恢复场景含内部RESID重装，不代替联合RECOVER。当前八核联合TB使用正式import，但尚未在服务器跑通。

`run_gcore_xsim.ps1 -Test all`仍保留完整单元/服务/代表层测试，测试定义不等于当前版本全部通过。旧23场景和旧9936/6636/314拍已失效，不作为当前结论；`reports/summary.txt`仅对应最近一次脚本运行。

## 服务器与资源

先在DEA8生成输入和官方IP，按 [服务器说明](../Server_Verification.md) 完成仿真。之后分别运行：

```text
python run_dea8.py synth --target gcore --server-heavy
python run_dea8.py synth --target pcore --server-heavy
```

输出 `../reports/resource_synth/gcore/`及`pcore/`，官方IP展开、blackbox=0，只有综合资源，不做布局布线。先看单模块面积，再决定是否综合八核。旧GCore check脚本不是本阶段统一准入入口，不再建议先综合叶IP来生成DCP。

唯一历史综合 `reports/gcore_synth_summary.txt`、`gcore_utilization*.rpt`与`.sim/gcore_synth.dcp`保留：48229LUT、17502FF、109DSP、152.5BRAM36、4URAM，对应2026-10-16旧后端/旧FIFO映射。不是当前官方IP版本资源，也没有250MHz签核。
