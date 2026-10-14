# DEQACC V3 / PCore开发副本

版本入口：[V3说明](../DEQACC_V3_版本说明.md)。**2026-10-14暂时冻结，短仿真PASS，4ns post-route WNS=+0.544ns/TNS=0/hold通过。**本副本Matrix默认连接七级DEQACC，V3功能为32 lane、II=1、同地址依赖间隔≥4拍。物理实现No-Pblock，先3.5ns目标、一轮3.45ns已有网表收尾，最终恢复4ns验收，严格裕度门槛+0.5ns。

## V3实现

| 文件 | 职责 |
| --- | --- |
| `rtl/DEQACC_V1.sv` | V3兼容顶层：完整ACC、32lane、读写/commit接口 |
| `rtl/deqacc_v1_control.sv` | 物理地址捕获、来源比较前移、身份/完成流水 |
| `rtl/dequant_lane_v1.sv` | 两级反量化、normal/subnormal并行RNE |
| `rtl/fp32_add_lane_v1.sv` | 四级FAR/CLOSE FP32、LZA与精确修正 |
| `rtl/acc_slice_v1.sv` | 单个完整三bank、两parity ACC |
| `rtl/deqacc_v2_fanout.sv`、`deqacc_v2_scale_ingress.sv` | 分级控制及scale输入 |
| `rtl/deqacc_v2_timing_shell.sv` | BUFG和全接口launch/capture观测壳，额外FF不算核心级数 |

V1/V2文件名保留为兼容名称，内容和冻结hash定义版本；不以文件后缀判断算法版本。正常filelist包含旧兼容模块，当前选择由`USE_DEQACC_V1=1`控制；切回A11会改变设计，不属于冻结V3。

## 仿真与物理验证

```powershell
# 短套件：算术、stream、动态M、64Tile Matrix、RAW负例
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_deqacc_v3.ps1
# 完整PCore七Job仅显式需要时运行，耗时较长
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_deqacc_v3.ps1 -SevenJobs
# 精简全流程，不生成逐lane/Pblock长统计
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_deqacc_v3_route.ps1
```

报告为`reports/v3_simulation/`和`reports/v3_postroute/`；每级logic/route/total/slack见`stages.csv`。时序是post-route STA，不是综合估算或硅片测量。

冻结manifest为`V3_FROZEN.sha256.csv`。复现入口先验证冻结源hash，不会静默覆盖已存在证据。日志返回码0不代表测试成功，脚本同时核对PASS/Fatal/Error与物理裕度。

只核对冻结状态、不重跑仿真或实现：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\freeze_deqacc_v3.ps1 -VerifyOnly
```

## 系统边界

完整PCore副本仍保留K/V/Q/Attention/O/G-U/Down控制、QOZ、VPU/SFU接口与输出。短套件覆盖DEQACC、真实Matrix和动态M，未重新跑V3完整七Job/八核系统；其余模块中的历史README只描述原接口边界，不扩展V3验收范围。

修改仅在独立DEQACC目录，DEA8冻结。旧方案文档在`../history/`，旧区域实验的布线数据已删除；旧golden、A11源码与test-only发布参考保留。
