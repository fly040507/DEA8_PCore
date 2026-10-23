# 非矩阵计算与存储现状

更新：2026-10-23。本文替代迁入的416DSP渐进方案和旧RAM重映射计划，描述当前RTL；下一轮LUT方案尚未制定。

## 共享计算

| 资源 | 当前组织 | 生产入口 |
|---|---|---|
| FP32 MUL | 一套16路，pair相邻两拍；RoPE、GU、P、AFIN、后台scale复用 | `dea8_vpu_pair_mul16` |
| FP32 ADD | 一套16路；行和树与RoPE复用，前4支持SFU ADD/SUB | `dea8_vpu_p_pipe` |
| QK max/差值 | 单行16元素比较树，1个独立SUB，外层重组pair | `dea8_vpu_qk_row16` |
| 量化 | 一套16元素B16量化，pair相邻两拍，结果可背压 | `dea8_vpu_pair_quant16` |
| EXP/RECIP | 4 EXP、1 RECIP；单条II1 GELU复用共享MUL/ADD | `dea8_sfu_arithmetic` |

GELU模式下，MUL lanes0..4承载五级guest乘法，lanes8..15同时处理GU最终乘U，每向量分两拍8＋8；不是两套独立乘法阵列。

公开`dea8_vpu_top`位于`dea8_vpu_top_shared.sv`；旧文件`dea8_vpu_top.sv`内为前台`dea8_vpu_foreground`。后台OACC scale独立接收命令、维护token和完成，与前台共享MUL16。

## 当前存储

- M2V：四个逻辑slot，共16-bank row-major SDP；消除旋转crossbar。Score、GU和RoPE结果按生命周期复用slots2/3
- V转置：16×16 FP32 FF窗口；按固定行写入，每次移出相邻两列，尾group仅3个token有效
- 行状态：M/L/两代α以及AA/RECIP复用区采用固定lane FF银行，16row对齐chunk访问
- ACC响应：4×1024bit FF弹性FIFO；valid取真实出口，不能用占用计数代替
- 量化结果：8项缓存，读入信用同步限制在8项；量化metadata另有事务FIFO
- OACC：scaled单代16 URAM、raw双page16 URAM；raw按生产valid读，scaled按读请求消费valid
- RoPE：4个双端口URAM，reset后显式预载1632个256bit beat；不依赖`$readmemh`上电初始化
- KV sender：双Tile、128×144 SDP；允许边填边发，仍只允许一个未commit Tile

## Attention调度

```text
QK(b)提交 -> QK_POST -> ALPHA_EXP
                         +-> P_POST + P_EXP -> PBUF提交
                         +-> 后台SCALE：α_b × raw O_(b-1) -> scaled OACC
PV(b)：P就绪后发布描述符，每Tile等待scaled valid
PV54提交 -> RECIP -> A_FIN -> QOZ_O
```

保留55 QK/55 PV和尾部保护窗口。raw page按block奇偶复用；scaled读取只消费一次。缩放按地址等raw生产，不要求前代PV整Job先commit。

## 验证结果与剩余差异

[完整七Job](../Pcore/reports/compute/optimized7_banked/Summary.md)通过：285942拍，相比旧DEA8增加2.2788%。单命令最大时长不能相加当作暴露开销；首次填充、最终Tile、K尾RoPE及Attention尾部仍可能显露。

当前与参考目标仍有差异：ACC响应为4×1024bit而非4×512bit，aa保留51项而非4项；α×l复用MUL16、QK独立SUB。DSP总数已实测398，但不能据此认定所有参考拓扑逐项相同。LUT与这些存储/选择开销下一轮统一评估。
