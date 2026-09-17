# Attention 完整联调与尾部 828 拍时隙

本文件补充并修正前一版“连续矩阵”周期说明。用户要求：PV53 与 PV54 之间没有 QK55，因此必须留出最后一代 alpha54 对 OACC 的缩放时间。SFU/VPU 尚未完成，暂用仿真行为模型协助真实矩阵 RTL 跑通一次 Attention。

日志与逐任务时序见 [尾部联调验证记录](Attention_尾部联调验证记录_20260917.md)。

## 1. 正确的尾部流程

```text
QK54 + alpha53 * OACC
  |
PV53 + QK54后处理 / alpha54 / P54准备
  |
PV53 最后一笔 DEQACC 提交，完成握手
  |
单独的尾部 SCALE 时隙，至少 828 拍
  |-- VPU读取 OACC 和 alpha54
  |-- 816 个 16-lane FP32 向量做乘法并写回 OACC
  |-- 等待最后一次真实写入后的 VPU done
  |-- MXU不发射任何虚构的 QK55
  |
PV54：DEQACC读取已缩放的 OACC，累加 P54 * V54
  |
SFU计算1/l --> VPU计算A_FIN --> Attention done
```

最后一个 V Tile0 仍可在 PV53 的 tile15 内预加载，但“权重已就绪”不等于“可以开始 PV54”。PV54 的 A 为 P54，旧值为 alpha54 × OACC53，这两项必须全部就绪。

因此 110 个真实 Matrix Job 数量不变，只增加一个非矩阵 SCALE 时隙。
正常的 QK/PV 完成间隔为 828；尾部 PV53 完成至 PV54 完成是 `828 + 828 = 1656`。

## 2. 可综合 RTL 的修改

修改 `dea8_attention_scheduler.sv`，新增参数 `TAIL_SCALE_SLOT_CYCLES`，默认取 `MATRIX_STEADY_BUDGET=828`。

在接受 PV53 的 Matrix Done 时开始计时，PV54 启动需要同时满足：

1. 已经过完整的尾部时隙。
2. VPU 的 alpha54 × OACC 操作已经报告完成。
3. Matrix Engine 接受启动，资源许可和下一 Job 的描述符正确。

这不是用定时器假冒 VPU done。VPU 若需要超过 828 拍，必须继续等待实际完成。

另一个修改是消除普通 Block 交接中 Scheduler 的两个额外时钟：
前一 Matrix Job 的 Done 被接受时，若后处理依赖已经完成，可在同一个沿接受下一 Job。
Matrix Engine 在发出 Done 前已经处理完旧 Job 的所有 Commit，下一 Job 计算仍在之后开始，不存在两代计算流水重叠。
若下游不 ready，新命令仍保持有效，进入下一状态后继续等待握手，不能丢失任务。

## 3. 真实 RTL 与仿真替身的界限

| 部分 | 本次实现形式 |
| --- | --- |
| Top Job、Scheduler、两项队列、KVB FIFO、Bank控制 | 真实 RTL |
| PE双权重Bank、MXU、Psum和旁带 | 真实 RTL |
| DEQACC、FACC/OACC、QOZ/PBUF/SBUF | 真实 RTL |
| m/aa/l/alpha/recip物理状态及接口检查 | 真实 RTL |
| GCore的Q/K/V供数 | Testbench生成连续KVB事务 |
| Mask、RowMax、P行和、P量化、OACC缩放、A_FIN | VPU仿真行为模型 |
| EXP和倒数 | SFU仿真行为模型 |
| 最终预期值 | 独立Python FP32参考计算 |

VPU/SFU 模型经现有正式端口读写真实存储，没有直接改写内部 OACC，也没有跳过矩阵计算。
数学运算使用 SystemVerilog real 辅助函数，并在 FP32 运算边界做 RNE 舍入；这些文件位于 `tb/stubs`，不在可综合 `dea8_pcore.f` 中。

`SOFTMAX_MODEL=0` 保留旧的恒等搬运 fixture，供历史回归使用。
`SOFTMAX_MODEL=1` 才是本次有实际 Softmax、非恒等缩放的联合测试。
AFIN 当前由仿真 VPU 的 `final_result` 数组捕获，核对全部结果；这不表示已经定义或实现正式 VPU 的最终输出总线。

## 4. 行为模型做了哪些事

### VPU

- QK_POST：读取实际 FACC 和旧 m；加入 padding mask；更新 m；计算 aa=m_old-m_new；写 SBUF 和 m/aa。
- P_POST：接受实际 SFU P 流；读取旧 l 与当前代 alpha；计算 `l_new=alpha*l_old+sum(P)`；按行选择共享二进制 scale、RNE量化P并写 PBUF。
- OACC_SCALE：同步读取 OACC 和对应行 alpha，每拍处理一个16-lane向量，并将前一拍结果写回，连续816次写入。
- AFIN：读取最终 OACC 与 1/l，计算并保存816个结果向量。

P 的行和使用未量化 FP32 P，不能误用 INT8 P 的和更新 l。
行为模型的行内求和采用从左到右 FP32 加法；将来正式 VPU 使用归约树时需按实际归约顺序重新评估舍入差异。

### SFU

- ALPHA_EXP：经双通道 aa 读端口计算 `alpha=exp(aa)`，写入正在分配的 alpha Bank。
- P_EXP：读取 SBUF 和 m，计算 `P=exp(S-m)`；被掩码位置输出0；每个结果保留 row/pair/context，经 P 流送到 VPU。
- RECIP：读取 l，计算并写回 1/l。

本模型的 EXP 是仿真数学函数，不是未来 SFU 近似算法的精度或 Fmax 承诺。配对RF读写控制仍有额外拍，不能把模型尾部的倒数耗时当成最终SFU的26拍微架构。

## 5. 非恒等测试数据与独立对照

测试一个 head/epoch，51条查询、55个KV Block、256维，物理880个key，867个有效key。
采用 dense attention 加 padding mask，不把该用例宣称为所有pi0前缀/动作mask规则验证。

```text
Q_INT8[row,k] = 1 + row % 3，scale=133
K_INT8[block,n,k] = block + 1 + n % 3，scale=129
V_INT8[block,k,feature] = (3*block + 2*k + 5*feature) % 15 - 7，scale=133
```

QK 的实际 Score 为 `(1+row%3)*(block+1+n%3)`。
因此 P 不是全1，OACC 不是恒定累加；alpha1..54 分别为按行的 `exp(-1)`、`exp(-2)`、`exp(-3)`。
这些值都明显不等于1，省略尾部缩放一定会改变 PV54 的结果。
最后一个Block只保留前3个key，检验mask后P=0参与PV。

Python参考计算独立生成：

- 每次PV写回的44880个16-lane向量，共718080个FP32结果。
- 每行每Block的m、aa、alpha、l参考值；RTL测试显式比较alpha和l。
- 最终816个AFIN向量，共13056个FP32结果。

此外Testbench按闭式公式逐位检查44880个QK归约向量，确认中间16个K-tile均实际完成累加，而不只是最终Softmax结果相似。

PV与AFIN比较采用 `abs_error <= 2e-6 + 2e-6*abs(reference)`，容纳仿真EXP与Python数学库的微小差别；不是本用例逐位一致的承诺。
独立矩阵测试和DEQACC测试仍提供既有的位精确验证。

## 6. 周期结果与预算

理论预算应修正为：

```text
原连续矩阵预算：845 + 109*828 = 91097
增加尾部SCALE槽：                 +828
修正后预算：                    91925 拍
```

实际按Top Job接受沿T0计数，首块Done仍为T844，因此正常行为模型场景的矩阵最终Done是T91924。
与同口径的旧连续矩阵实测T91096相比，恰好增加828拍。

| 事件 | 实测时刻 |
| --- | ---: |
| PV53 Done | T90268 |
| VPU接受alpha54×OACC | T90269 |
| 第一笔缩放结果写回 | T90271 |
| 第816笔缩放结果写回 | T91086 |
| VPU SCALE Done被接受 | T91087 |
| PV54启动被接受 | T91096 |
| PV54 Done | T91924 |
| SFU RECIP开始/完成 | T91925 / T91978 |
| VPU AFIN开始/完成 | T91980 / T92798 |
| 整个仿真Attention Done | T92799 |

普通矩阵Done间隔：828。尾部PV53至PV54的Done间隔：1656。
缩放写入序列从T90271到T91086，含首尾共816拍；最后写入后才报告完成。
矩阵最终Done（91924）与归一化输出完成后的Attention Done（92799）必须分开报告。

## 7. 三种新增场景

1. SOFTMAX：55次QK、55次PV、54次实际OACC缩放、55次P生成、1次倒数和1次AFIN，全流程与参考结果比较。
2. TAIL_SLOW：尾部VPU延迟200拍报告Done。PV54必须延后到真正完成之后，矩阵Done变为T92116，不允许只等固定828拍就强行启动。
3. SKIP_TAIL_SCALE：故意将最后一代缩放改为恒等搬运。预期在PV54首个向量触发 `Softmax PV oracle mismatch`，证明测试能检测本次关键问题。

命令（在VLA目录）：

```powershell
powershell -ExecutionPolicy Bypass -File pcore/rtl/run_xsim.ps1 -Test fullattention -PythonExecutable python
```

全量回归仍用 `-Test all`。脚本自动生成Python参考向量。
`attention_full_cycles.csv` 记录各矩阵/VPU/SFU任务起止；TAIL_SLOW和反向测试使用各自独立CSV。

本次结果是“真实矩阵与存储RTL + 假设可用的SFU/VPU数学行为模型”的完整联调，不是已经完成SFU/VPU正式RTL或完整VLA模型，更不是FPGA板上时序签核。
