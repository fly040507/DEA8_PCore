# π0 Action Expert 结构与数据 Shape 拆解

## 1. 分析对象

本文基于 OpenPI 源码，对 π0 的 Action Expert 进行静态结构拆解，重点分析网络配置、输入构造、注意力、前馈网络、训练和推理过程，以及 π0 与 π0.5 的差异。

分析涉及：

- `src/openpi/models/pi0_config.py`
- `src/openpi/models/pi0.py`
- `src/openpi/models/gemma.py`
- `src/openpi/models_pytorch/pi0_pytorch.py`
- `src/openpi/models_pytorch/gemma_pytorch.py`

## 2. 基本配置

| 参数 | 数值 |
|---|---:|
| Action Expert | `gemma_300m` |
| 参数量 | 约 311M |
| 隐藏维度 | 1024 |
| Transformer 层数 | 18 |
| 前馈网络维度 | 4096 |
| Query Head 数量 | 8 |
| KV Head 数量 | 1 |
| Head Dimension | 256 |
| 动作维度 | 32 |
| 动作长度 | 50 |
| 默认精度 | bfloat16 |

Action Expert 使用分组查询注意力。8 个 Query Head 共享 1 组 Key 和 Value。

## 3. Prefix

默认有 3 个相机输入：

- `base_0_rgb`
- `left_wrist_0_rgb`
- `right_wrist_0_rgb`

每张图像尺寸为 224×224。SigLIP 使用 14×14 图像块，因此每张图像产生 16×16=256 个图像 Token。3 张图像共 768 个图像 Token。

图像特征：

```text
[B,768,2048]
```

π0 的语言最大长度为 48：

```text
[B,48,2048]
```

最大 Prefix：

```text
[B,816,2048]
```

## 4. Suffix 输入构造

### 4.1 状态

```text
obs.state: [B,32]
Linear(32→1024)
[B,1024]
Unsqueeze
[B,1,1024]
```

### 4.2 带噪动作

```text
noisy_actions: [B,50,32]
Linear(32→1024)
[B,50,1024]
```

### 4.3 时间编码

```text
timestep: [B]
Sin/Cos embedding
[B,1024]
Repeat to 50 positions
[B,50,1024]
```

### 4.4 动作与时间融合

```text
action_tokens: [B,50,1024]
time_tokens:   [B,50,1024]
Concatenate
[B,50,2048]
Linear(2048→1024)
SiLU
Linear(1024→1024)
[B,50,1024]
```

### 4.5 最终 Suffix

```text
state token:  [B,1,1024]
action token: [B,50,1024]
Concatenate
[B,51,1024]
```

## 5. 单层 Transformer Block

每层结构：

```text
RMSNorm
→ Grouped-Query Attention
→ Residual Add
→ RMSNorm
→ Gated FeedForward
→ Residual Add
```

Action Expert 共 18 层，外部 Shape 始终为：

```text
[B,51,1024]
```

## 6. RMSNorm

输入：

```text
[B,51,1024]
```

计算：

```text
var = mean(x², axis=-1, keepdims=True)
```

得到：

```text
[B,51,1]
```

归一化：

```text
x / sqrt(mean(x²)+1e-6)
```

再乘可学习缩放参数：

```text
scale: [1024]
output = normalized × (1+scale)
```

输出：

```text
[B,51,1024]
```

## 7. QKV 投影

### Query

权重：

```text
[8,1024,256]
```

理论输出：

```text
[B,51,8,256]
```

PyTorch Hook 在线性层处会看到：

```text
[B,51,2048]
```

### Key

权重：

```text
[1,1024,256]
```

理论输出：

```text
[B,51,1,256]
```

PyTorch Hook 会看到：

```text
[B,51,256]
```

### Value

理论输出：

```text
[B,51,1,256]
```

PyTorch Hook 会看到：

```text
[B,51,256]
```

## 8. 联合注意力

VLM 和 Action Expert 使用独立参数，但每层 Q/K/V 沿 Token 维拼接。

设 Prefix 长度为 P：

```text
Q_vlm:    [B,P,8,256]
K_vlm:    [B,P,1,256]
V_vlm:    [B,P,1,256]

Q_action: [B,51,8,256]
K_action: [B,51,1,256]
V_action: [B,51,1,256]
```

拼接后：

```text
Q: [B,P+51,8,256]
K: [B,P+51,1,256]
V: [B,P+51,1,256]
```

PyTorch 中通常转为：

```text
Q: [B,8,P+51,256]
K: [B,1,P+51,256]
V: [B,1,P+51,256]
```

## 9. RoPE 与注意力矩阵

Q 和 K 使用 RoPE，Shape 不变。Q 乘以：

```text
1/sqrt(256)=1/16
```

Action Expert 查询长度为 51，完整 K/V 长度为 P+51，因此注意力分数为：

```text
[B,1,8,51,P+51]
```

去掉大小为 1 的维度可理解为：

```text
[B,8,51,P+51]
```

最大 Prefix P=816 时：

```text
[B,8,51,867]
```

## 10. 注意力输出

概率与 Value 相乘后：

```text
[B,51,8,256]
```

展平：

```text
[B,51,2048]
```

再通过输出投影：

```text
Linear(2048→1024)
```

得到：

```text
[B,51,1024]
```

然后与原输入残差相加。

## 11. 门控前馈网络

输入：

```text
[B,51,1024]
```

Gate 分支：

```text
Linear(1024→4096)
GELU
[B,51,4096]
```

Up 分支：

```text
Linear(1024→4096)
[B,51,4096]
```

逐元素相乘：

```text
GELU(Gate(x)) × Up(x)
[B,51,4096]
```

Down 投影：

```text
Linear(4096→1024)
[B,51,1024]
```

再与输入进行残差相加。

## 12. 单层参数量

注意力：

```text
Q: 8×1024×256 = 2,097,152
K: 1×1024×256 =   262,144
V: 1×1024×256 =   262,144
O: 8×256×1024 = 2,097,152
合计约 4.72M
```

前馈网络：

```text
Gate: 1024×4096 = 4,194,304
Up:   1024×4096 = 4,194,304
Down: 4096×1024 = 4,194,304
合计约 12.58M
```

单层约：

```text
17.30M
```

18 层约：

```text
311M
```

前馈网络参数量约为注意力部分的 2.67 倍，是主要计算热点。

## 13. 输出层

18 层后：

```text
[B,51,1024]
```

只保留最后 50 个动作 Token：

```text
[B,50,1024]
```

动作输出层：

```text
Linear(1024→32)
```

得到速度场：

```text
v_t: [B,50,32]
```

## 14. 训练过程

真实动作：

```text
actions: [B,50,32]
```

随机噪声：

```text
noise: [B,50,32]
```

时间：

```text
time: [B]
```

构造：

```text
x_t = t×noise + (1-t)×actions
u_t = noise - actions
```

得到：

```text
x_t: [B,50,32]
u_t: [B,50,32]
```

模型预测：

```text
v_t: [B,50,32]
```

PyTorch 使用：

```text
MSE(u_t,v_t,reduction="none")
```

所以返回：

```text
loss: [B,50,32]
```

## 15. 推理过程

初始噪声：

```text
x_t: [B,50,32]
```

默认：

```text
num_steps=10
dt=-0.1
```

每一步：

```text
v_t = ActionExpert(x_t,t)
x_t = x_t + dt×v_t
```

Shape 始终为：

```text
[B,50,32]
```

最终输出连续动作序列：

```text
[B,50,32]
```

## 16. KV Cache

推理时 Prefix 先单独计算一次：

```text
inputs_embeds=[prefix_embs,None]
use_cache=True
```

每层缓存可表示为：

```text
K: [B,1,P,256]
V: [B,1,P,256]
```

随后每次去噪只计算 Suffix：

```text
inputs_embeds=[None,suffix_embs]
past_key_values=prefix_cache
```

因此：

```text
Prefix 计算 1 次
Action Expert 默认计算约 10 次
```

## 17. π0 与 π0.5

π0：

- 连续状态位于 Suffix；
- Suffix 长度为 51；
- 时间与动作特征拼接；
- 使用普通 RMSNorm；
- 残差为 `x+y`。

π0.5：

- 状态离散化后进入 Prefix；
- Suffix 长度为 50；
- 时间通过 MLP 得到条件；
- 每层使用 AdaRMSNorm；
- 残差为 `x+y×gate`。

AdaRMSNorm：

```text
cond: [B,1024]
Linear(1024→3072)
scale: [B,1,1024]
shift: [B,1,1024]
gate:  [B,1,1024]
```

每层有两套调制模块，18 层共 36 套。

## 18. PyTorch Hook 模块路径

Action Expert：

```text
model.paligemma_with_expert.gemma_expert.model
```

第 0 层：

```text
model.paligemma_with_expert.gemma_expert.model.layers[0]
```

需要挂 Hook 的模块：

```text
input_layernorm
self_attn.q_proj
self_attn.k_proj
self_attn.v_proj
self_attn.o_proj
post_attention_layernorm
mlp.gate_proj
mlp.up_proj
mlp.down_proj
```

顶层模块：

```text
state_proj
action_in_proj
action_time_mlp_in
action_time_mlp_out
action_out_proj
```

## 19. Hook 预期输出

```text
state_proj:
[B,32] → [B,1024]

action_in_proj:
[B,50,32] → [B,50,1024]

action_time_mlp_in:
[B,50,2048] → [B,50,1024]

q_proj:
[B,51,1024] → [B,51,2048]

k_proj:
[B,51,1024] → [B,51,256]

v_proj:
[B,51,1024] → [B,51,256]

o_proj:
[B,51,2048] → [B,51,1024]

gate_proj:
[B,51,1024] → [B,51,4096]

up_proj:
[B,51,1024] → [B,51,4096]

down_proj:
[B,51,4096] → [B,51,1024]

action_out_proj:
[B,50,1024] → [B,50,32]
```

## 20. 当前结论

1. Action Expert 是完整的 18 层 Gemma Transformer，而不是简单动作头。
2. 隐藏维度为 1024，前馈网络中间维度为 4096。
3. Suffix 包含 1 个状态 Token 和 50 个动作 Token。
4. 模型使用 8 个 Query Head 和 1 个 KV Head 的 GQA。
5. VLM 与 Action Expert 使用独立参数，但每层进行联合注意力。
6. 50 个动作 Token 可以并行处理，不是自回归逐个生成。
7. 前馈网络是主要参数和矩阵乘法热点。
8. 训练时 Prefix 和 Suffix 联合计算，不使用 KV Cache。
9. 推理时 Prefix 只算一次，Action Expert 默认重复约 10 次。
10. 后续需要在服务器上用 Hook 验证真实运行 Shape。
