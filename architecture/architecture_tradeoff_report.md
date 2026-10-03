# pi0 Action Expert 架构参数化评估

> 本报告由 `architecture_tradeoff.py` 生成。结果是解析下界，不是周期精确仿真或综合结果。

## 模型参数

- Suffix Token: 51
- Hidden / FFN: 1024 / 4096
- Query Heads / KV Heads / Head Dim: 8 / 1 / 256
- 最大 K/V Token: 867
- 层数 / Flow Steps: 18 / 10

## 矩阵映射

| 算子 | 矩阵 | 切分 | 合并方式 | MMAC/层 |
| --- | --- | --- | --- | --- |
| Q | [51,1024] x [1024,2048] | N | disjoint write / logical concatenate | 106.955 |
| K | [51,1024] x [1024,256] | shared | broadcast once | 13.369 |
| V | [51,1024] x [1024,256] | shared | broadcast once | 13.369 |
| O | [51,2048] x [2048,1024] | K | sum reduction | 106.955 |
| Gate | [51,1024] x [1024,4096] | N | disjoint write / logical concatenate | 213.910 |
| Up | [51,1024] x [1024,4096] | N | disjoint write / logical concatenate | 213.910 |
| Down | [51,4096] x [4096,1024] | K | sum reduction | 213.910 |

## 4 核与 8 核比较

| 核数 | Head/核 | 私有权重 MiB/核/层 | 私有投影 MMAC/核/层 | Attention MMAC/核/层 | 归约深度 | 归约流量 MiB/层 | 解析下界 ms/层 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 4 | 2 | 8.000 | 213.910 | 45.278 | 2 | 1.195 | 3.642 |
| 8 | 1 | 4.000 | 106.955 | 22.639 | 3 | 2.789 | 1.847 |

## 硬件假设

- 权重 / 部分和字节数: 2 / 4
- 频率: 200.0 MHz
- 每核 MAC/cycle: 512.0
- 计算效率: 0.70
- HBM 总带宽 / 有效效率: 316.0 GB/s / 0.70
- 逻辑私有通道数: 8
- 单链路归约带宽: 32.0 GB/s

## 解释

- 4 核和 8 核都保持完整 Head，不引入 Head 内部归约。
- 8 核将每个 Query Head 映射到一个核，私有权重和计算负载约为 4 核的一半。
- 8 核的代价是归约树由 2 级增至 3 级，且总归约流量增加。
- 只有 O 和 Down 沿 K 维切分，因此只有这两个算子做算术求和归约。
- Q、Gate、Up 沿 N 维切分，结果写入互不重叠的地址区间，不进行算术归约。
- 共享 K/V 的计算和广播必须通过实测确认不会限制 8 核利用率。
