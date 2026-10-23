# PCore 当前控制中心

更新：2026-10-19。完整边界为 `dea8_pcore_top`；`dea8_pcore_control`是内部调度层，真实VPU/SFU已接入。旧TB服务版控制说明及control_signoff日志不作为当前验收依据。

## 控制层次

| 层次 | 责任 |
|---|---|
| 外部DEA8总控 | 层/步、权重/输入身份、七Job、八核与GCore屏障、取消源流 |
| PCore top | context/Mask/RoPE配置校验，内部control/VPU/SFU接线，错误及flush汇总 |
| PCore control | 一个完整Job的矩阵/后处理调度、存储权限、外发与完成 |
| Matrix dispatch | Projection/Attention/G-U策略共享一套Matrix/MXU/DEQACC |
| VPU/SFU局部控制 | 根据已接受命令处理真实输入、响应和写回，完成后回done |

每核一个本核控制，八核由cluster实例化。外部不逐Tile发RoPE/GELU/Softmax命令，不按固定拍数代答内部done。

## 七Job与启动条件

| Job | 矩阵后事件 | 内部动作及最终屏障 |
|---|---|---|
| K | 两个RoPE配对half可读 | VPU请求SFU ROM系数、RoPE、量化；两Tile发出并等KV commit |
| V | 当前FP32 Tile完整 | token-B16量化/转置；两Tile发出并等commit |
| Q | 配对half可读 | RoPE/feature-B16量化；QOZ_Q 16Tile完整 |
| Attention | QK/PV最终提交及各命令done | QK_POST、ALPHA、P_EXP/P_POST、OACC_SCALE、RECIP/AFIN；O完整 |
| O | 每个N-Tile最终累加完成 | 边算后续Tile边发FP32 partial；所有本核发送结束，释放O |
| G-U | Gate/Up成对可读，消费者可接收 | SFU GELU、VPU乘U/量化；四信用行窗口配对；Z 32Tile完整 |
| Down | 每个N-Tile最终累加完成 | 边算后续Tile边发FP32 partial；本核发送结束，释放Z |

O/Down本核done不代表GCore归约/残差/Norm已结束；外部必须另等GCore对象/服务屏障。

## 内部命令与并行

VPU/SFU各一条命令在途，彼此及Matrix可以并行。消费者先接收命令，再允许生产者发数据；如P_POST先配置，随后P_EXP流入。G-U通过有界窗口绑定Gate、Up、GELU返回与VPU输入，不能将某行GELU与另一行Up混用。

Attention顺序为 `QK0,QK1,PV0,...,QK54,PV53,尾部保护,PV54`，共55QK+55PV。调度等待真实数据/提交/done；不能把416次issue当完整block时长。当前仍有约16拍命令槽尾部等待，未宣称全部隐藏。

非矩阵接口的具体类型、端口、数据轴和数量见 [PCore README](../README.md)；字段以 `pcore_control_pkg.sv`为准。端口位宽用 `$bits(type)`核对，不从旧文档抄固定数。

## 存储与数据权限

- Q/O/Z复用32Tile物理QOZ；按owner/head/epoch/context取得、提交和释放。
- QK结果在FACC完成；VPU加Mask后写两代Score/SBUF。QK的1/16缩放已经在DEQACC折入。
- m/aa单代，l单代，alpha两代，recip单代；旧读者退出才能覆盖。
- PBUF ping-pong；OACC由PV累加、VPU缩放/AFIN读取或授权写回。
- DEQACC当前16级；Matrix done等最终写回，不等于最后MXU issue。
- ACC、workspace、ROM均为同步请求/响应和有限信用；RAM数据不整体复位。

## 握手、错误与取消

valid/ready同拍才转移，等待时数据及身份稳定。command完整锁存；结果、坐标、数量、mask、last、token与授权不符则报错，不当普通背压处理。

done必须在所有输入、输出、RAM写回、响应及ROM请求结清后产生并保持；不能在最后一次请求发出时提前结束。

取消停止新副作用并等待VPU/SFU真实flush ack；cluster还等待八核和外部HBM排空。源流无完整顶层generation，外部必须撤销旧返回。RAM部分写回不承诺回滚。

## 验收入口

`Pcore/run_compute.py test --top tb_pcore_seven_native`实例化完整PCore，内部无TB算术。当前PASS为279571拍、265408 issue；定向取消/恢复、Mask/QK、GCore相关结果另行记录。

旧 `run_control.ps1/run_control_signoff.ps1/pcore_all.f`保留兼容测试，不是完整PCore官方IP验收入口。当前单核七Job已通过，八核联合仍待服务器；不做八核综合/布局布线，见[验证说明](../../docs/Verification.md)。
