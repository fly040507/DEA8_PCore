# 发布版 V1 仿真参考

来源：`fly040507/DEA8_PCore`提交`af6263595efe13b200101d3774bc1df604f288fb`，2026-10-13核对。仅供V2 lockstep使用，不加入正常RTL/filelist或综合。

| 原模块/文件 | 本目录副本 |
| --- | --- |
| `dequant_lane_v1` | `published_v1_dequant.sv` |
| `acc_slice_v1` | `published_v1_acc.sv` |
| `deqacc_v1_group8` | `published_v1_group.sv` |
| `DEQACC_V1` | `published_v1_top.sv` |
| `fp32_add_lane_v1` | `published_v1_fpadd.sv` |
| `deqacc_v1_control` | `published_v1_control.sv` |

六个副本内容仅做上表模块定义及实例引用的标识符替换。原共享的 FPADD/控制在本轮修改前独立冻结，参考 group/top 改为调用冻结副本。恢复模块原名后的文本 SHA256 与发布版原文件完全一致（FPADD `5BDB57A1...`，控制 `55FBC2F9...`）。没有把 V2 的 scale ingress、中心控制、LZA 或舍入算法复制进参考。

共享未变模块：`pcore_pkg`、`dea8_fp32_pkg`、`deqacc_v1_pkg`、`dea8_acc_store`。共享模块及两份新冻结副本的 hash 记录于 `v1_shared_sha256.csv`，运行脚本先检查。

若以后修改共享模块，必须把旧发布模块也独立冻结并替换对应实例；不得简单更新hash把当前实现同时作为被测和参考。

入口：`run_deqacc_v1.ps1`，编译`deqacc_v1.f`、`v2_lockstep.f`并定义`V2_LOCKSTEP`。TB复用既有stream/golden，并同拍比较两个版本。
