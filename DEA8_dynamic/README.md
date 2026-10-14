# DEA8 Dynamic

动态行数重构工程：compact row、三行 A 加载、512-bit B 输入、四拍驻留装载、双行 MXU、七级 DEQACC；保留七种外部 Job 和三种矩阵模式。

所有修改仅在本目录。旧 `DEA8/`、独立 `DEQACC/` 只读；不覆盖原设计。

## 当前进度

- PCore 七种完整 Job 已接入：K、V、Q、Attention、O、G-U、Down
- 一条真实矩阵算术链，统一外部 Job 控制；内部 active + prepared、QOZ/PBUF 所有权和共享 Pair BUF
- Attention 110 个矩阵子 Job，动态 Block 间隔；VPU/SFU 算术由有限速率 TB 模型承担，RTL 保留完整接口和数据完成屏障
- 七 Job 已有 M=11 无 clear 数值证据；真实 Q→Attention→O、G-U→Down，M=0 边界也已通过；最大 M 和修复后的整套回归正在补齐
- 独立动态 Reduce 已实现，全部 M=1..51、背压、commit 和非法 header/last 验证通过
- `Control/`、`Gcore/`、`HBM/` 目前只保留目录/参考材料，不是整机模块实现

**未综合、未布局布线、未签核 250 MHz。** 仿真时钟为 4 ns，不等于物理时序通过。八个真实动态 PCore、Reduce、GCore、HBM 和 DEA8 总控尚未系统联调。

## 设计入口

| 文档 | 内容 |
|---|---|
| [PCore 实现与验证](Pcore/README.md) | 当前完成度、七 Job、接口、存储、周期和证据 |
| [整体重构 V1](Pcore/PCore整体重构方案_V1.md) | 实施前的冻结架构合同；当前进度看 PCore README |
| [A 侧加载 V1](Pcore/A侧矩阵加载方案_V1.md) | 三行输入、三槽 A queue、QOZ/PBUF 三 row bank |
| [B 侧加载 V1](Pcore/B侧矩阵加载方案_V1.md) | HBM 双 PC、KVB512、八槽 B queue、四列/拍 |
| [Attention 调度 V1](Pcore/Attention调度方案_V1.md) | 110 子 Job、SCALE 隐藏、PV53→PV54 和 AFIN 尾部 |
| [动态 Reduce](Reduce/README.md) | 八路 FP512 输入、固定树、动态结果 Tile、独立仿真 |
| [老设计复用分析](Pcore/老设计复用方案_V1.md) | 旧 DEA8 调查，不等于逐文件复制要求 |

## 动态行语义

`A[M,16]×B[16,16]`，M=0..51。K/V projection 固定 51 行，其余五种 Job 使用 M。

算术、存储和传输只使用 compact row `0..M-1`。原始行序只在 profile、RoPE/mask 服务和外部映射中解释，不随每个 PE/流水结果传递。

DEA8 可跨 18 层复用同一 profile；PCore 只处理外部 Job，不理解层数和十步去噪循环。profile 在存储/输出仍存活时不能改写。M 变小只缩短有效范围和工作量，不改变算术 lane 速率或最大 RAM 容量。

旧动态尝试中的 2-beat B 加载、original row_id 贯穿算术不再是当前基线。旧日志、旧综合报告不能替代当前 dynamic 源码的验证。

