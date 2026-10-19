# 官方FP与存储资源映射

更新：2026-10-19。适用当前 `DEA8`；替代旧方案中“FP32 MUL按3DSP”“GCore自研加乘”的预算。**下述为结构计数/估算，不是本轮综合结果。**

## 1. 算术配置

| 运算 | 官方核/配置 | 延迟 | DSP/实例 |
|---|---|---:|---:|
| DEQ FP32 ADD | pcore_fpadd_ip，Full_Usage，NonBlocking | 11 | 2 |
| VPU/SFU/GCore ADD/SUB | dea8_fpadd_ip，Full_Usage，CE | 11 | 2 |
| FP32 MUL | dea8_fpmul_ip，Full_Usage，CE | **8** | **2** |
| EXP | dea8_fpexp_ip，BRAM Full_Usage | 21 | 约1，待综合 |
| RECIP | dea8_fprecip_ip | 29 | 约8，待综合 |
| RSQRT | gcore_rsqrt_ip | 32 | 约9，待综合 |

`ip/generate_compute_ip.tcl` 从实际生成IP读延迟，写入 `dea8_compute_config_pkg`；不能把旧6拍MUL硬编码回来。GCore引用同一配置包。2DSP乘法并不意味着2拍延迟。

SUB使用同一ADD核，操作数B翻转符号；MAX/比较/Mask、BF16 RNE、MXINT指数生成/移位/RNE是比较和位逻辑，不强行实例化FP算术IP。rsqrt前后指数归一化同样是格式处理。

GCore的 `sq/1024` 复用MUL0；`X*inv*gamma` 是两次独立FP32舍入，不能默认离线折叠γ。FP32加乘参考遵守PG060的DAZ/FTZ：包含**舍入前下溢冲零**。极小值测试保留旧渐进下溢向量，另生成native参考，不通过放宽有限结果容差来适配。

PG060依据：[官方Floating-Point Operator说明](https://docs.amd.com/api/khub/documents/4O72wuOIKLc8gzcZogZgeg/content)。当前以Vivado2022.2生成模型实测语义为准；特殊函数误差独立验收。

## 2. DSP结构预算

### 单PCore

| 部分 | 结构 | DSP预算 |
|---|---|---:|
| 基核 | MXU256 + DEQ32个FPADD×2 | 320 |
| VPU | 32MUL×2 + 32ADD×2 + 2QK差值ADD×2 | 132 |
| SFU | 10MUL×2 + 4GELU ADD×2 + 4P SUB×2 + exp4×约1 + recip1×约8 | 48 |
| **合计** | 含真实非矩阵单元 | **约500** |

两条GELU链交错使用一个物理倒数核；完整GELU承诺为1 scalar/cycle，不是2 scalar/cycle。RoPE复用VPU乘法器和P行和加法树；SCALE/AFIN/GU乘法也复用，不重复计32路。

### GCore

| 部分 | 数量 | DSP预算 |
|---|---:|---:|
| 四棵8输入ADD树 | 28 | 56 |
| Residual ADD | 4 | 8 |
| SQ_ACC / epsilon ADD | 2 | 4 |
| 共享MUL | 16 | 32 |
| 单路rsqrt | 1 | 约9 |
| **合计** | 34ADD + 16MUL + rsqrt | **约109** |

平方、mean、归一化分时使用16个MUL；没有额外mean乘法器。四棵树分时处理核间归约、SUM8、SUM64。

8PCore约4000DSP，另加GCore约109DSP，即 **4109/5952 = 69.04% U50 DSP**。不包含平台shell/HBM/未来DEA8总控；综合可能有实现相关差异。官方特殊函数不能按“每个2DSP”强行记账。

## 3. 存储实现要求

| 对象 | 当前方向 |
|---|---|
| FACC-A | 分bank同步BRAM；FP32向量保持原布局 |
| FACC-B / OACC | 各16URAM/核；原有容量保留 |
| QOZ | 原4URAM/核，Q/O/Z复用，不增独立ZBUF |
| Post/GU/workspace vector RAM | 共用16bank BRAM，不能另算一整片重复Tile |
| VPU Score/SCALE结果暂存 | 一个1024×32 URAM流存储，读3拍且可停顿；不是13级宽Score移位寄存器 |
| VPU量化结果 | 272×32同步BRAM |
| VPU RoPE/GU行暂存 | 512×128 TDP BRAM |
| SFU | 当前结果FIFO为128bit×64逻辑组；512bit×4统计和Score缓存、32bit对齐延迟RAM，均优先BRAM；宽端口由原语分片，不声称单个64bit FIFO |
| RoPE | 宽读同步ROM；16组cos/sin一次返回，不在TB里实时算系数 |
| Mask | 59个有效16bit字，物理64×16 BRAM；不展开51×880大表 |
| GCore RX/FIFO | 每核256×4，以及计算反馈/读响应FIFO，全部同步BRAM+小head cache |
| GCore RESID/XHAT/KV/γ/统计 | 保留当前BRAM/URAM组织；不保存8份FP32输入Tile或独立归约结果Tile |
| tag/valid/owner、51行统计cache | 小寄存器/计数器；数据RAM不整体reset |

物理RAM按bank/端口/宽深约束计数，不能用总bit除36Kb后四舍五入。例如很浅但1024bit宽的URAM仍会按宽度并行占用多块；这也是待服务器重点核查的项目。

## 4. LUT/BRAM风险

只读移植基数：zhao旧OOC的单基核62029 LUT、58373 FF、320 DSP、71.5 BRAM36、36URAM；不含VPU/SFU。它不是本轮官方IP完整核的综合结果。

新增VPU/SFU/顶层的LUT/FF仍保留宽工程区间：单完整核约82.5k~92.5k LUT、72.4k~84.4k FF、51~59URAM。2DSP替代3DSP不保证LUT同比下降；供应商实现、ROM宽读及RAM输出寄存器可能改变这些数值。

**不能继续沿用旧108~123.5 BRAM36/核区间。** 当前显式BRAM化产生浅宽碎片：SFU两个512×4缓存分别至少约8块BRAM36；128bit结果FIFO约2块；RoPE宽ROM约15~29块（映射模式待测），另有delay/IP表；仅SFU支持存储约35~55块。VPU约20~26块，叠加基核71.5及新GU/Mask，单完整核暂按 **128~154 BRAM36** 保守排查。

GCore原152.5块的历史数值也不是新预算：RX、KV、读响应和双乘反馈FIFO由distributed改同步BRAM后，按端口宽度约新增60~80块，暂按 **210~240 BRAM36** 排查。新版本优先RAM确实降低LUT需求，但不保证总RAM更省。

八核+GCore约 **1234~1472/1344 BRAM36（91.8%~109.5%）**，尚未加shell；可能超预算。LUT仍约698k~803k、URAM约412~480。**这是结构风险估算，不是综合超限结论；不能仅凭DSP69%断言能上U50。** 服务器首先核实真实RAM原语，再决定将浅宽缓存改成窄流/端口序列化、或在容量余裕的URAM与BRAM间重新分配。不要只把RAM位数相加后声称放得下。

本阶段服务器先完成仿真，再分别输出完整单PCore与GCore的utilization、hierarchical utilization、RAM明细、DSP/RAM原语计数及blackbox检查。仅综合资源，不做八核综合、布局布线或4ns签核。先以两个模块实测结果外推八核预算，由用户决定后续是否综合八核；不得将外推、历史OOC或仿真周期当成当前系统资源/频率签核。
