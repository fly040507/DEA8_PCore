# DEA8 当前整体架构与单层流程

更新：2026-10-19。本文按当前RTL整理，不再使用旧独立Reduce、外部VPU/SFU模型或11级DEQACC说明。正式入口见 [工程README](../../README.md)。

## 系统边界

目标为服务器运行pi0其余部分、FPGA完成Action Expert去噪主体。当前验收范围是固定 `M=51`的第1/9/18层独立checkpoint，内部使用真实GCore与八个完整PCore。

DEA8层/步策略、HBM权重/γ及最终接收由TB模拟；允许预置初始RESID/prefix。PCore内部SFU/VPU、Mask、RoPE、矩阵和存储不能由TB代算。prefix DMA、action输出投影、Euler更新、连续18层/10步和板级通信不属于已验收功能。

## 拓扑与控制

```text
DEA8总控（本阶段外部TB）
    | GCore宏观命令、八核七Job、对象与屏障
    v
dea8_layer_top
    GCore  -- XBC/KVB + pending-mask --> PCore 0..7
       ^                                  |
       +------- 八条独立tx256 ------------+
       +------- KV commit返回 ------------+
```

GCore有局部服务控制，每核PCore有独立内部控制。全局控制不逐拍调PE；GCore不发布PCore Job。归约在GCore内部，`DEA8/reduce`仅历史源码，不接入拓扑。

## 固定形状与分核

hidden1024；8个Query head、每head256维；共享KV head256维；FFN4096维，分核512维。suffix为1 state+50 action，共51行；KV容量55×16=880槽，不能当成880个有效token。

| PCore Job | 每核矩阵 | A / B来源 | 本地后处理与去向 |
|---|---|---|---|
| K | [51,1024]×[1024,32] | XBC / HBM适配 | RoPE、feature-B16量化，送GCore KV |
| V | [51,1024]×[1024,32] | XBC / HBM适配 | token-B16量化/重排，送GCore KV |
| Q | [51,1024]×[1024,256] | XBC / HBM适配 | RoPE、量化，写QOZ_Q |
| Attention | 55QK与55PV | QOZ/PBUF / KVB | 在线Softmax、OACC缩放、AFIN，写QOZ_O |
| O | [51,256]×[256,1024] | QOZ_O / HBM适配 | FP32 partial边算边发GCore |
| G-U | Gate/Up各[51,1024]×[1024,512] | XBC / HBM适配 | GELU(G)×U，量化写QOZ_Z |
| Down | [51,512]×[512,1024] | QOZ_Z / HBM适配 | FP32 partial边算边发GCore |

只有三种Matrix调度策略，共享一套MXU/DEQACC，不是七套或三套计算阵列。Q/O/Z同用32Tile物理QOZ；跨Job按所有权提交/释放。

## 单层实际工作

### 1. Attention前Norm

GCore保留原始BF16残差R，计算：

```text
sq[r]  = 固定SUM8/SUM64顺序的FP32平方和
inv[r] = rsqrt(sq[r]/1024 + epsilon)
Y[r,c] = FP32(FP32(R[r,c]*inv[r])*gamma[c])
XHAT   = MXINT8-B16量化(Y)
```

γ由HBM加载实际乘数；官方pi0非自适应参数导出采用 `gamma=1+checkpoint.scale`，不是默认折叠到权重。两次FP32乘法共享16lane，量化8lane，两拍组为一个B16块。XHAT供K/V/Q，不能覆盖仍需做残差的R。

### 2. K/V/Q及KV存放

K/Q的RoPE配对在同核完成。K核c权重布局对应全局16c..16c+15与128+16c..143+16c；V核c对应连续32列。Q按0,8,1,9,...配对计算，仍写canonical地址。

K每Tile发送51个有效136bit字，V每Tile发送64个token-B16字；V末token组仅3项有效。GCore按坐标落存后回commit，不做K/V数值加法，也不经过独立gather/Reduce。

### 3. Attention

每核用本head Q与共享K/V：
- QK(b)：[51,256]×[256,16]，沿K切16Tile，最终Score归约到FACC。
- PV(b)：[51,16]×[16,256]，沿N切16Tile，累加到OACC。
- 双行阵列每block有效issue为26×16=416，不等于包含加载、流水和控制尾部的总耗时。

调度为 `QK0,QK1,PV0,...,QK54,PV53,尾部保护,PV54`。首block允许加载暴露；后续加载预取，非矩阵按真实依赖重叠。当前仍有约16拍命令槽等待，不能写完全隐藏。

DEQACC已折入1/sqrt(256)=1/16；VPU不重复缩放。VPU加Mask、更新m/aa、写Score，SFU算alpha/P，VPU更新l、量化P并缩放OACC。在线公式为：

```text
m_new = max(m_old, max(masked_score))
aa    = m_old - m_new
alpha = exp(aa)
P_b   = exp(masked_score - m_new)
l_new = alpha*l_old + sum(P_b)
O_new = alpha*O_old + quant(P_b)*V_b
A_FIN = O_final * reciprocal(l_final)
```

m/aa单代，alpha两代，Score/PBUF ping-pong。全mask行避免-inf相减产生NaN，P/l/O为零，l=0的reciprocal返回零。

Mask遵循官方pi0而不是三角action Mask：state不看action，action互相可见；有效prefix及padding由配置/ROM确定。RoPE位置、Mask/RoPE版本必须与context相符。

### 4. O归约、残差与FFN Norm

O的8个partial是同一[51,1024]元素的不同K分片贡献，GCore按固定三级八输入FP32树求和：
`R_mid = BF16_RNE(FP32(R)+sum_tree(partial_O))`。

四lane归约/残差逐流处理，不缓存完整归约结果Tile。每N-Tile残差写完，再扫描该Tile的51行统计；四棵树分时复用，不能同时给归约和平方和各算一份资源。已有统计可用于后续Norm，避免再次冷扫完整残差。

### 5. G-U、Down及下一层

G-U的Gate/Up由同一Matrix调度。SFU算GELU，VPU乘Up/量化，四信用窗口关联行身份；不要求整张G/U都算完才后处理。Z保留本核[51,512]，不集中拼成4096维缓存。

Down的8个partial再次按固定树求和，写 `R_next=BF16_RNE(R_mid+sum_tree(partial_Down))`并统计。非末层准备下一层XHAT；末层执行final norm输出FP32，不请求第19层参数。模型后续输出投影和动作积分不能自动归入这七个Job。

## 当前物理精度与接口

MXU为256PE/256DSP、双行INT8、7级流水；树输出INT20。DEQACC为16级，反量化和累加使用FP32。官方ADD/MUL各2DSP、11/8拍；特殊函数DSP/RAM单列。

XBC当前为563bit四行包，B入口为288bit两列包，均不是原始物理HBM通道。八核各有tx256，O/Down一Tile为1header+102payload；K为1+51，V为1+64。字段以package为准。

O/Down本核done仅代表本核发送结清；DEA8另等GCore归约/残差/统计/Norm或用途有效状态。正常完成、KV commit、GCore服务done不是同一事件。

## 已验证与下一步

当前真实单核七Job已PASS：279571拍、265408 issue、94.93%；真实八核联合代表层仍待服务器。GCore官方IP叶算术/冷Norm/import与定向服务回归已通过，不替代联合层。

当前单核七Job与单模块面积已完成；八核联合仍待服务器验收。不做八核综合、布局布线或频率签核。执行入口见[验证说明](../../docs/Verification.md)。
