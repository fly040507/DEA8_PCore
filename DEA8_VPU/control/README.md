# DEA8 Control

更新：2026-10-23。层/去噪步策略仍由外部DEA8总控负责；本阶段TB只模拟这一层策略，不替代任何PCore/GCore内部服务。

## 两个正式模块

| 模块 | 责任 |
|---|---|
| `rtl/dea8_pcore_cluster.sv` | 生成8份完整PCore；八路job/done；独立HBM；组级cancel/flush汇总 |
| `rtl/dea8_layer_top.sv` | 真实GCore+cluster；内部接XBC/KVB、8路tx256、KV commit、GU预取许可 |

每核内部有自己的control，不设置中央逐拍微调度器。QK/PV、Tile、VPU/SFU启动条件归各核所有；外部只发七种Job。层级top不自行循环18层或10步。

## 正常交互

- 各核job/done独立valid/ready；done保留原Job和状态，保持至接受
- XBC/KVB共同payload+逐核valid/ready，GCore pending-mask防止先接收核重复接受
- K/V真实落KV RAM后commit返回；O/Down在GCore内部四lane归约、Residual、统计、Norm
- GU遵守GCore的N-Tile预取许可；O后FFN XHAT与8核O完成即可GU，不必等后台γ退休
- 不恢复核外Reduce或外发桥
- RoPE由`pc_rope_load_*`公开端口预载：共享address/data/last，每核独立valid/ready/loaded；收到每核握手后分别撤销valid

## 取消与故障

cluster的 `RUN -> PULSE -> FLUSH -> RETIRE`：锁存活动Job，单拍clear，再等8核真实flush_done和外部HBM drain ack。clear不能一直拉高，否则算术流水不能恢复并确认排空。

layer top将GCore flush与cluster取消联动。GCore external_flush_ack来自cluster完成和HBM ack，不能直接回接请求。取消排空不依赖上层先接受普通done，取消状态另行退休。

- 组故障统一排空；各核返回CHILD_ERROR/CANCELLED，不伪造普通成功
- 外部HBM必须撤销旧返回并确认drain；内部清FIFO不能区分无generation的迟到权重
- Residual可能部分写回；恢复须重新提供合法初始对象/版本，不承诺回滚
- Mask/系数可在同observation保留，但计算数据有效性不能因此保留

## 验证状态

八核RTL、真实层级TB已纳入统一编译。八核完整展开/仿真、取消/背压验收交服务器，**尚无八核联合PASS**。命令和计数见[验证说明](../docs/Verification.md)。
