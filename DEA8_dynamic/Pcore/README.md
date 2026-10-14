# 动态 PCore：七 Job、三种矩阵模式

单核动态行数重构实现。顶层已接入 K、V、Q、Attention、O、G-U、Down，共用一条双行 MXU / 七级 DEQACC 链路。矩阵、存储、控制和外发为真实 RTL；VPU/SFU 算术、外部供数和目标接收由 TB 模拟。

仅修改 `DEA8_dynamic`。旧 `DEA8/`、独立 `DEQACC/` 只读；未综合、未布局布线、未上传。**4 ns 仿真时钟不代表 250 MHz 物理时序达标。**

## 1. 当前能力与边界

- 保留七种外部 Job、Projection / Attention / G-U 三种矩阵模式
- 一次接受一个外部 Job，completion 保持到 DEA8 接受；内部允许 active + prepared
- K/V 固定 51 行；其它五种 Job 使用已提交 profile 的 M，范围 0..51
- 同一 PCore 已验证无 clear 的七 Job 串联，Q → Attention → O、G-U → Down 使用实际 QOZ 结果，不重填 fixture
- 独立动态 Reduce 已实现并验证；尚未联接八个真实动态 PCore
- `Control/`、`Gcore/`、`HBM/` 尚不是 DEA8 总控、GCore 或物理 HBM 控制器实现

实现合同：[整体重构 V1](PCore整体重构方案_V1.md)、[A 加载 V1](A侧矩阵加载方案_V1.md)、[B 加载 V1](B侧矩阵加载方案_V1.md)、[Attention 调度 V1](Attention调度方案_V1.md)。这些方案记录了实施前状态；**当前完成度和验证入口以本页为准**，不要把方案末尾的“待实现”当作现状。

## 2. 七种完整 Job

令 E 为有效行数，P=ceil(E/2)。下表的提交数是一组最多 32 个 FP32 的 bundle，不是标量数。

| Job | 单核矩阵 / 数据来源 | 后处理与去向 | Psum / C 提交数 |
|---|---|---|---:|
| K | [51,1024]×[1024,32]，XBC/HBM | RoPE、MXINT8-B16；内部 sender → GCore，等待两个 Tile commit | 3328 |
| V | [51,1024]×[1024,32]，XBC/HBM | token-B16 量化；内部 sender → GCore，等待两个 Tile commit | 3328 |
| Q | [M,1024]×[1024,256]，XBC/HBM | RoPE、量化 → QOZ_Q | 1024P |
| Attention | 55 QK + 55 PV，QOZ/KVB；每 Block 16 Tile | 在线 softmax、OACC_SCALE、RECIP、AFIN/量化 → QOZ_O | 1760P |
| O | [M,256]×[256,1024]，QOZ_O/HBM | 每 NTile 最终 FP32 partial → Reduce | 1024P |
| G-U | 两个 [M,1024]×[1024,512]，XBC/HBM | GELU(G)×U、量化 → QOZ_Z | 4096P |
| Down | [M,512]×[512,1024]，QOZ_Z/HBM | 每 NTile 最终 FP32 partial → Reduce | 2048P |

M=0 时，K/V 仍正常处理 51 行，其余 Job 返回 empty completion，不加载、不启动算术、不 acquire 零行对象。七 Job 合计 `6656+9952P`；M=11 为 66,368，M=51 为 265,408。

Q 使用 canonical 列顺序 `0,8,1,9,...,7,15`，FACC owner 按 work 奇偶而不是 canonical nt 奇偶选择。K 的两块列必须 RoPE 可配对：base0<128、base1=base0+128；V 为相邻两个 16 列块。两者都要求 16 对齐。

PCore 不理解十步去噪/18 层循环，不做全 hidden 维度 RMSNorm、Residual、全局 KV 管理或跨核归约。

## 3. 计算、加载和精度

算术、RAM 地址和传输使用 compact row `0..E-1`。原始行号只在 profile、RoPE/mask 服务及外部 transfer context 中解释，不进入 PE。

| MXU 级 | 工作 |
|---|---|
| S0 | 两行 INT8 进入唯一 Q_ACT_REG；两 A scale、16 B scale、mask/tag 同沿进入旁带 0 |
| S1 | 每个 DSP48E2 共享 B 计算两个 INT8×INT8 |
| S2 | packed product 拆包与高半符号修正，恢复两个 INT16 乘积 |
| S3 / S4 / S5 | 加法树 16→8、8→4、4→2 |
| S6 | 2→1 直接写 Psum 输出寄存器；旁带 6 同时输出 |

256 PE 保留两个 INT8 weight bank。scale/tag 不进入 PE；INT32 Psum、两路 A scale、B scale 向量和 metadata 直接进入 DEQACC，无额外输出 FIFO 或第二个 Psum 寄存级。

| DEQACC 级 | 工作 |
|---|---|
| Q0 | Psum / scale / key 捕获，幅值、lead、指数基值 |
| Q1 | 形成 FP32 partial；同步 ACC 读取 |
| A0 | old 选择：A3 前递、C 前递、RAM，或首 KTile 的零值 |
| A1 | FP32 对齐、加减 |
| A2 | 精确 LZD、规格化 |
| A3 | RNE 舍入、指数和特殊值 |
| C | 实际 ACC 写回、commit/data/metadata |

32 lane，每拍最多处理两行×16 个结果。S0 接受沿为 t，Psum 为 t+6，C 为 t+13。同地址依赖最小间隔四拍：Δ4 用 A3，Δ5 用 C，Δ6 及以后读 RAM。奇数 E 的末 pair mask=01，odd 行不写。

矩阵 work 支持一个 active + 一个 prepared。最后 C 的 `retire_valid` 预测真实写沿，允许已准备好的下一 work 首 S0 与旧 work 最后 C 同沿；`done_work` 始终回显旧 work 身份，不随下一 feed context 改写。

B 每拍四列，四拍填满一个驻留 bank；group0 同时写完整 128-bit E_STAT。最后 B 写沿可以接受首 S0，下一沿 S1 才使用新权重；旧 bank 必须等最后 S1 后释放。

| 加载部分 | 当前实现 |
|---|---|
| XBC A | 三行/beat，每行含 INT8 向量和 scale；三 slot，完整 E 行后连续输出 P pair |
| Local A | QOZ/PBUF 三 row bank 同步读；两项命令/返回信用，不复制完整 A Tile |
| A replay | G/U 共用一次 A 填充、重放两次；PV 的一个 P Tile 重放 16 次 |
| HBM B | 两个 256-bit PC 配对为 512 bit；各有深度 2 elastic FIFO，检查 beat 身份 |
| B queue | 八 slot；HBM 四 Tile/17 beat，KVB 两 Tile/9 beat；完整 data/scale 后 READY |
| KVB | 512-bit 数据；首 beat 低 256 bit 为两个 scale 向量，高 256 bit 校验归一化 descriptor |

理想内部 Tile 间隔 `R=max(4,P)`。HBM 连续服务平均每 Tile 4.25 拍、KVB 为 4.5 拍；外部断供可以延长运行。当前不是 HBM AXI/segment 地址控制器，也未实现八核原子 KVB 广播。

## 4. 存储与所有权

容量按最大 51 行保留，M 只限制有效行、读写次数和传输长度。下表是 payload/声明容量，不含 validity、metadata、返回 FIFO、流水寄存器和物理 RAM 补齐。

| 物理存储 | 容量 | 用途 |
|---|---:|---|
| PE weight A/B | 512 B | 每 PE 两个 INT8 |
| Q_ACT_REG / E_STAT A/B | 各 32 B | PE 外的激活寄存器 / 驻留权重 scale |
| A queue / B queue | 2601 / 2176 B | 3 个 A slot / 8 个 B slot |
| 双 PC elastic FIFO | 128 B | 各深度 2 |
| FACC-A / FACC-B | 各 3264 B | 每套 even26×512、odd25×512 |
| OACC | 52224 B | even416×512、odd400×512，地址 pair*16+nt |
| QOZ | 27744 B | 一份 32×51×136-bit payload |
| PBUF | 1734 B | 两代，各 51×136 bit |
| 共享 Pair BUF | 8192 B 声明容量 | 2 half×16 row bank×4×512 bit |
| 两代 SCORE | 6528 B | masked FP32 S，各 51×16 |
| m / aa / l / reciprocal | 合计 816 B | 各 51 个 FP32，一代 |
| alpha 两代 | 408 B | 各 51 个 FP32 |
| K/V sender | 1088 B | 64×136 bit |
| FP output holding | 128 B | 两行 serializer，不加完整 FP32 Tile 副本 |

QOZ 只有一个活动 owner：Q 物理 Tile0..15，O 为16..31，Z 为0..31，**不是三份并存的矩阵 RAM**。Q/O/Z 生命周期为：

```text
Q production → Attention Q consumer → 释放 Q → AFIN 产生 O
→ O projection 消费/释放 O → G-U 产生 Z → Down 消费/释放 Z
```

每 Tile 前 E 行 data/scale 全部写入才完整；bind 精确匹配 kind/version/data/profile/head/E。读请求预留返回信用，消费返回才减少 read ref。小 M 到大 M 重新 acquire 后必须覆盖全部新有效行，不能借旧 payload 补齐。

PBUF 按 block parity 保存两代，消费 PV(b) 与生产 P(b+1) 不覆盖。源返回写完 A queue 只是 `source_read_closed`，还要等对应 PV 的真实 C 退休才释放 PBUF。Q 在 QK54 退休、读引用清零后释放，之后才能 acquire O；不能等整个 Attention done 才换 Q→O。

Pair BUF 是一套共享两 half RAM：RoPE 两组 feature、V 的 token-group、G/U 的两个 operand 互斥复用。两操作数不等于两行输出；GU 当前 32 个输入 FP32/拍只代表最多 16 个独立乘积/拍，TB 按此限速，没有虚称 32 个 Z 结果/拍。

## 5. Attention 调度与实际完成屏障

```text
QK0 → QK1 → PV0 → QK2 → PV1 → ... → QK54 → PV53
    → 空出一个 Block slot → PV54 → RECIP → AFIN/量化
```

稳态首 S0 间隔 `S=16*max(4,ceil(M/2))+12`；从真实 issue 计时，不从 descriptor 接受计时。QK0 可暴露首轮加载。PV53→PV54 至少 2S，尾部 RECIP/AFIN 不声称隐藏。

- QK 的最后 C → QK_POST：读 FACC、加 mask、更新 m/aa、写两代 SCORE
- QK_POST done → ALPHA_EXP；alpha/L 已准备后可提前准备 SCALE descriptor，但没有 go 不允许访问 OACC
- ALPHA_EXP → P_POST 与 P_EXP 流式配合：SFU4 输出 exp，VPU 更新 l、量化写当前 PBUF
- P 可用 fence 来自真实 PBUF 完整写入和 l 更新，不依赖 TB 定时器或 unit 自报 done
- SCALE 在前一个 PV 退休、对应 QK 实际启动后获准，按 pair-major 扫描 OACC；最后真实 RAM 写可在同沿放行下一 PV
- PV54 退休 → SFU 计算 reciprocal → VPU AFIN/量化；QOZ_O complete、所有 unit/返回结清才返回整体 completion

SFU/VPU 各支持一条 active + 一条 prepared 命令。实际近似算法和延迟由外部实现决定；接口依赖数据 fence，合法停顿只会延长周期，不应提前消费未提交数据。

## 6. G-U、Projection 和内部外发

Projection 共用一个 scheduler，按五种几何生成 NTile work。结果 reader 在 NTile 的最终 C 后才读 FACC，目标接受最后一个 capture bundle 才释放 bank；没有把“读请求发完”当成释放。

G-U 每 NTile 交替执行 64 个 Gate KTile 和 64 个 Up KTile。Gate 写 FACC-A、Up 写 FACC-B，两个 final Tile 的 C 直接 capture 到共享 Pair；Pair 不可用时只在安全边界等待。SFU GELU(G) 与 VPU×Up/量化通过真实流式握手汇合，32 个 Z Tile 全写齐及单元 done 后整体完成。没有 ZBUF。

`dea8_pcore_output` 位于 PCore 内部，分两种物理输出，不重新拼成 Collective：

| 路径 | Header / data | 完成规则 |
|---|---|---|
| K/V → GCore | 128 / 136 bit | sender 填完整 Tile，发数据，等待匹配 64-bit commit |
| O/Down → Reduce | 128 / 512 bit | 两行 holding 按行发送；末行真实接受后才释放 FACC |
| Reduce → GCore | 128 / 512 bit | Reduce 自己等匹配 commit，不属于 PCore 第八种 Job |

K 每 Tile51 word。V 每 Tile64 word，最后 token group 只有3个 token有效，其余清零。RAM/线路 word 为 `{scale[7:0],data[127:0]}`，与 `qvec16_t` 内部 `{data,scale}` 的 packed 次序不同。

O/Down 每 Tile E 个 FP512 word，column_base=16*nt。它们的 PCore completion 仅表示 partial 已交给 Reduce，**不表示八核归约已在 GCore 提交**。

Header 保留 transfer_id/epoch、destination_id、token_origin、column_base、rows、kind、layout、source_id、tile_seq。DEA8/GCore 必须在传输前绑定 `transfer context → profile/version/row_order`；非连续原始行表不随每个 row 重复发送。仍在途的 transfer key 不能被重新解释。

## 7. VPU/SFU 负责人接入入口

公共类型见 `rtl/pcore_pkg.sv`，顶层见 `rtl/pcore_top.sv`。不需要将完整外部 Job 复制到每条内部 command。

| 接口 | 规则 |
|---|---|
| cmd/ready | 绑定 token/function/rows/block/对象版本，仅 prepare，不授予内存访问 |
| armed | 回显已接受的 command token；表示控制及返回空间准备好 |
| go/ready | PCore 依赖满足后授权当前 command 执行 |
| done | 回显 token/function/status；所有必要输出及读返回已结清才可成功 |
| Pair read/reply | 两个 512-bit FP32 operand；两项返回信用、背压保持 |
| unit_profile | Q 查 compact→original，K identity；Attention QK_POST 可查询 mask 坐标 |
| ACC read/reply/write | 1024-bit 双行 FP32 + pair/nt/mask/token；Scale 写 OACC |
| VPU workspace | 1024-bit payload；SCORE 两行写，统计量 span/mask |
| SFU workspace | 128-bit payload，4 FP32；SCORE group 或统计量 span |
| GELU stream | Gate→SFU 与 GELU→join 为 512-bit 行向量，带 row/token/last |
| P_EXP stream | SFU→VPU 为 128-bit FP32，带 row/group/token/mask/last |
| quant write | INT8 向量与 scale 一起，验证坐标/版本/重复写；PCore 转换 unit token 为 producer token |
| flush/ack | source、VPU、SFU 三项 ack；必须保证旧流、active/prepared 和旧返回已撤销 |

ROPE_QUANT、V_QUANT、GU_MUL_QUANT、QK_POST、P_POST、OACC_SCALE、AFIN_QUANT 由 VPU 实现。GELU、ALPHA_EXP、P_EXP、RECIP 由 SFU 实现。RoPE 系数由外部服务/模型提供。

同拍退休与 prepared 的 cmd/armed 接受都必须保留，不能丢失或重发。非法 token、功能、坐标、mask、重复输出及 early done 在产生 RAM 副作用前拒绝并进入 fault。

正常 Job 结束不 clear 持久 Q/O/Z。cancel/clear 撤销 generation/validity/预约并等待三方 flush ack，不大范围清 payload RAM。已有 completion 不被迟到 fault 改写或重复返回。真实 GCore 的 transfer 取消需由 DEA8 协调，不能只清本核就复用旧 key。

## 8. 仿真与证据

入口遵循 `interaction/仿真说明.docx`：同一 cmd 中加载 `settings64.bat`，再调用官方 xvlog/xelab/xsim；独立库、新 snapshot、glbl、真实 DSP48E2。默认 O2，不修改 Vivado 安装或工具路径。

```powershell
# 23 个测试入口；含完整矩阵/后处理、故障恢复和默认 M=11 的七 Job 串联
& .\run_compute_xsim.ps1
# 最大行数七 Job
& .\run_compute_xsim.ps1 -Tests tb_dynamic_seven_jobs -TestPlusArgs 'M=51'
# 动态 Reduce 独立测试
& ..\Reduce\run_xsim.ps1
```

普通测试同时要求退出码 0、无 Fatal/Error/工具内部错误、明确 PASS。RAW Δ1/2/3 负例只允许精确指定的 DUT Fatal。脚本在运行前后比较所有 filelist 源码/脚本 SHA256，不能用旧日志替代当前源码结果。

当前证据分阶段记录，新增修复后的整套回归正在补齐；下列时间戳不合并成同一次运行：

| 证据 | 实际范围 |
|---|---|
| [Attention 完整仿真](reports/simulation_summary_20261014_211444.txt) / [源码](reports/sources_sha256_20261014_211444.csv) | M=0/1/11/51；每个非空 Job 55QK+55PV，全部 Psum/FP32 C、非单位 alpha、AFIN QOZ payload 位比较 |
| [七 Job 连续](reports/simulation_summary_20261014_212754.txt) / [源码](reports/sources_sha256_20261014_212754.csv) | M=11，66,368 笔 Psum/C；同一 PCore 无 clear，真实 Q→Attention→O、GU→Down |
| [零行七 Job](reports/simulation_summary_20261015_054106.txt) | M=0，6656 笔；K/V 仍 51 行，其余 empty |
| [单元交接修复](reports/simulation_summary_20261015_054359.txt) | 三种同拍交接、五项非法返回、prepare 无访问及 active/prepared 取消 |
| [Attention 故障恢复](reports/simulation_summary_20261015_055148.txt) | 真实 workspace 回复挂起时错误 token 拒绝、端口关闭、fault 保持、三方 flush；恢复后完整 110 子 Job / AFIN |
| [动态 Reduce](../Reduce/reports/summary_20261014_202359.txt) | 53 Tile、所有 M=1..51、1378 FP512 word；固定树位比较、背压、commit 和四项拒绝 |

Attention 独立测试中的首 S0 稳态间隔如下。周期来自 TB 的实际有限速率模型，不是器件实测：

| M | S | 稳态 min/max | PV53→PV54 | 接受 Job→completion | 最后 PV C→completion |
|---:|---:|---:|---:|---:|---:|
| 1 | 76 | 76 / 76 | 152 | 8499 | 47 |
| 11 | 108 | 108 / 108 | 216 | 12141 | 131 |
| 51 | 428 | 428 / 428 | 856 | 48014 | 480 |

TB 仅模拟外部数据与非矩阵处理，通过真实 command/armed/go、RAM、返回信用和背压交互。Golden 独立计算 INT8 点积并按冻结 FP32 顺序核对每次 C，**未向 DUT 注入 golden Psum/ACC**。VPU32/SFU4 用模型限速；GU 另按双操作数口的真实结果速率处理。mask/exp/GELU/RoPE 模型不是实际 pi0 精度或真实 VPU/SFU近似精度签核。

## 9. 当前尚未验证

- 真实 VPU/SFU、GCore/DEA8 总控接入；profile/transfer context 的跨核映射及取消
- 物理 HBM 地址/burst、八核 KVB 原子广播及实际持续带宽
- 八个真实动态 PCore 与 Reduce 联调、全局 commit 屏障
- 综合、布局布线、资源与 250 MHz 物理时序
- pi0 整模型量化误差、十步去噪正确性与端到端时延

以上均未用 TB 或旧 DEA8 报告冒充完成。旧设计算术/仿真仅作参考；dynamic 的实现和证据独立维护。
