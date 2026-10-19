# DEA8 PCore：当前设计与VPU/SFU接入

## 2026-10-19 当前入口

固定 `M=51`、双行 INT8、目标 U50。**完整顶层是 `rtl/dea8_pcore_top.sv`，真实 VPU/SFU 已在内部实例化。** `dea8_pcore_control` 是内部调度层，不再把内部非矩阵服务交给最终 TB。

- 正式清单：`pcore_rtl.f`；生产单位源码：`units/vpu`、`units/sfu`，来源记录见 `units`
- MXU精确INT20；DEQACC **16级**，含11拍官方ADD；旧11级不再是当前配置
- ADD/SUB官方Full_Usage、11拍、2DSP；MUL官方Full_Usage、**8拍、2DSP**；EXP21、RECIP29
- VPU32 lane；SFU exp4、两条交错GELU链、一个共享倒数IP；资源最终以服务器综合为准
- Mask按官方pi0（非pi0.5）：state不看action，action间双向可见；不是三角action Mask
- RoPE前后128配对，position来自有效prefix数。ROM的position_base/rope_version必须与配置一致
- 活动payload放BRAM/URAM；RAM不整片复位；valid/tag与官方IP延迟、CE一起推进
- 本地验收：`python run_compute.py test --top tb_pcore_seven_native`，DUT内部无TB算术/结果注入
- 八核入口和生成步骤见 [服务器说明](../Server_Verification.md)

当前2DSP/8拍MUL完整七Job已PASS：279571总拍、265408 issue、94.93%；55QK/55PV，6299量化+157743FP检查。图片与CSV见 `../reports/seven_job_native`，原始PASS/hash在 `reports/compute`。RoPE在途取消→无旧代写回→重配后完整K也已通过。八核完整联合层仍待服务器，当前没有综合/4ns签核。

## 1. 顶层与共享计算

完整PCore在内部实例化control、VPU和SFU。外部只提供DEA8命令/配置、XBC、HBM/KVB供数、commit与下游接收；内部单元接口不是最终TB边界。旧 `tb_pcore_control`服务模型只用于兼容控制测试。

## 2. 当前数据路径

```text
DEA8 job -> dea8_pcore_top（context / Mask / 错误 / flush）
                -> dea8_pcore_control
                     exec -> 三种adapter -> 一个共享Matrix
XBC / QOZ / PBUF -> 双行MXU -> 16级DEQACC -> FACC-A/B、OACC
                     Post / workspace <-> 内部真实VPU、SFU
                     量化Q/O/Z -> 共享QOZ
                     内部output -> tx256 -> GCore
```

MXU为7级，树输出INT20，scale/tag不进入PE。DEQACC为D0..D15，`DEQACC_PIPE_STAGES=4+11+1`；Matrix done等待最终写回，不是最后一次issue。三种策略只共享一套物理Matrix。

PCore不承担全hidden RMSNorm/Residual、跨核归约、KV全局管理或层/步循环；这些由GCore及外部DEA8总控负责。文件名中的_v4等是历史内部名，不表示另立工程版本。

## 3. 外部七Job

DEA8发送control_job_t，一次一个完整Job；PCore按内部事件配置单元。**外部不另发RoPE/GELU/Softmax Job，不按固定拍数自行启动VPU/SFU。**

| Job | 本核矩阵、A/B来源 | 非矩阵参与 | 去向与完成 |
|---|---|---|---|
| K | [51,1024]x[1024,32]，XBC+HBM | VPU RoPE/feature-B16量化；SFU供系数 | 2 Tile发出并收到GCore commit |
| V | [51,1024]x[1024,32]，XBC+HBM | VPU token-B16量化、转置布局 | 2 Tile发出并收到commit |
| Q | [51,1024]x[1024,256]，XBC+HBM | VPU RoPE/量化；SFU供系数 | QOZ_Q完整16 Tile |
| Attention | 55 QK [51,256]x[256,16]，55 PV [51,16]x[16,256]；QOZ/PBUF+KVB | Softmax、缩放、倒数、A_FIN量化 | QOZ_O完整16 Tile，子命令退休 |
| O | [51,256]x[256,1024]，QOZ_O+HBM | 本Job无VPU/SFU后处理 | 本核FP32 partial全部送出，释放O |
| G-U | Gate/Up各[51,1024]x[1024,512]，XBC+HBM | SFU GELU，VPU乘U、量化 | QOZ_Z完整32 Tile |
| Down | [51,512]x[512,1024]，QOZ_Z+HBM | 本Job无VPU/SFU后处理 | partial全部送出，释放Z |

O/Down的GCore归约/Residual尚未结束时，PCore也可能已done；DEA8必须另等GCore服务done。

QOZ是一份32 Tile物理区：Q -> Attention释放Q、写O -> O释放O -> G-U写Z -> Down释放Z。输入owner/head/epoch/data_context必须匹配；Q/G-U生产者要求空区。外部QOZ fixture口仅用于空闲预置，不是另一条正常路径。

hbm_entry和kv_entry均为288-bit b2_t：两个INT8列向量、scale及坐标。**不是原始HBM AXI beat**；原始8+1beat权重/scale存储布局由外部适配器拆包，不能直接接此口。XBC为563-bit xbc4_t，一次四行，尾group的row_valid=0111。

## 4. 内部VPU/SFU接线表

方向以内部control/存储边界为参考；这些端口已连接真实单元，不再暴露给最终验收TB。使用package类型，跨语言边界用 `$bits(type)` 生成宽度，不手抄字段顺序。

| 端口组 | 方向与类型 | 用途 |
|---|---|---|
| vector_valid/ready/cmd、vector_done_* | 发control_command_t，收control_unit_done_t | VPU独立命令/完成 |
| function_valid/ready/cmd、function_done_* | 同上 | SFU独立命令/完成 |
| vector_data_* | PCore -> VPU，control_fp_data_t | 两组16xFP32及身份；RoPE、V、GU或P |
| function_data_* | PCore -> SFU，同上 | Gate行，不是全部SFU功能的统一数据口 |
| function_result_* | SFU -> PCore，同上 | GELU或P_EXP的FP32返回 |
| vector_result_* | VPU -> PCore，control_quant_result_t | 两组16xINT8+scale、轴/坐标/mask；PCore写存储或发出 |
| acc_rd_* / acc_token / acc_data_* | VPU请求、PCore返回 | FACC/OACC；sel2、addr10、token；even/odd各512bit，信用4项 |
| acc_wr_* | VPU -> PCore，acc_write_t | 仅获授权的OACC写回 |
| vector_mem_*、function_mem_* | 单元请求、PCore响应，control_memory_req_t/rsp_t | Score和行统计访问，各自独立保持响应 |
| rope_req_* / rope_out_* | VPU请求、VPU接收系数 | control_rope_req_t/rsp_t |
| rope_sfu_* / rope_sfu_out_* | PCore转发、SFU返回系数 | 16对FP32 cos/sin，最多8项顺序在途 |
| flush_valid、vpu_flush_ack/sfu_flush_ack | 通知、分别确认 | 取消/排空两个单元及系数服务 |

类型见 [pcore_control_pkg.sv](rtl/pcore_control_pkg.sv)、[pcore_pkg.sv](rtl/pcore_pkg.sv)，完整端口见 [dea8_pcore_control.sv](rtl/dea8_pcore_control.sv)。枚举含历史预留值，不按枚举长度猜实际命令。

当前默认参数下已通过Vivado接口小测试：Job/完成为199/203bit，单元command/done为318/319bit，FP32流1286bit，量化返回340bit，workspace请求/响应572/560bit，RoPE请求/响应62/1086bit。参数或package变化后重新用$bits核对，不将这些数字写死为永久协议。

## 5. 启动条件与实际功能

| function_id | 单元 | PCore何时发出 | 单元必须完成 |
|---|---|---|---|
| VECTOR_ROPE_QUANT | VPU | K/Q两半Tile已捕获 | 51行配对、请求系数、RoPE/量化；两Tile共52对结果 |
| VECTOR_V_QUANT | VPU | V的51x16 Tile已捕获 | 32组双feature跨token输入，返回32组量化 |
| VECTOR_GU_POST | VPU | G/U Tile可用，先配置消费者 | 收GELU(G)/U配对、FP32乘法、量化，返回26对 |
| FUNCTION_GELU | SFU | VPU已配置且G-U输出可读 | 收51行Gate，返回51行GELU |
| VECTOR_QK_POST | VPU | QK最终DEQACC提交，共享统计无冲突 | ACC读FACC，加mask，更新m，写齐Score/m/aa |
| FUNCTION_ALPHA_EXP | SFU | QK_POST done，旧alpha bank可复用 | 读aa，exp，写51个alpha |
| VECTOR_P_POST | VPU | alpha完成，先配置P消费者 | 行求和、l=alpha*l_old+sum(P)、量化；写51个l、返回26对P |
| FUNCTION_P_EXP | SFU | alpha完成且P_POST已被VPU接受 | mem读Score/m，exp(S-m)，function_result返回26对P |
| VECTOR_OACC_SCALE | VPU | alpha(b)完成、PV(b-1)提交，b>=1 | 读OACC乘alpha(b)，顺序写回416项 |
| FUNCTION_RECIP | SFU | PV54最终提交 | 读l，计算倒数，写51个recip |
| VECTOR_AFIN_QUANT | VPU | RECIP done | 读OACC/recip，FP32乘法后量化，16 Tile共416对 |

elements为有效标量数：RoPE=1632；V_QUANT/GU_POST/QK_POST/P_POST/GELU/P_EXP=816；SCALE/AFIN=13056；ALPHA/RECIP=51。不能忽略tile/tiles和bank字段只看function_id。

RoPE系数走独立请求服务，当前不另发FUNCTION_ROPE_COEFF命令。SFU可用ROM/缓存，不要求实时三角函数；VPU负责RoPE乘加。K配对由rope_pair_base指定，Q内部Tile顺序0,8,1,9,...,7,15。

G-U保留51行接口，当前由 `dea8_gu_post_window` 提供4项行信用窗口，按行身份保持Gate/Up、GELU返回及VPU输入配对。不再是旧的一行GELU等待模型，也不复制整块G/U到各单元；窗口深度由 `GU_CREDITS` 配置。

## 6. 数据含义、精度与尾部

| 场景 | first | second | 标记 |
|---|---|---|---|
| RoPE vector_data | 同一行前半16特征 | 对应后半16特征 | 51行，两half都用 |
| V_QUANT vector_data | 一个feature跨16 token | 相邻feature跨16 token | 两列；尾group token_mask=0007 |
| GELU function_data/result | Gate / GELU(G) | 未使用 | vector_valid=01，index=0..50 |
| GU_POST vector_data | GELU(G) | **同一行U** | 01表示一行配对，不能丢second |
| P_EXP function_result | 偶数行P[16] | 奇数行P[16] | 26对，末对01 |
| vector_result | 两个qvec16 | 每个含data128+scale8 | feature轴两行，token轴两feature |

矩阵输入/量化输出为MXINT8-B16，Psum INT20（16个INT8乘积的精确和）；DEQACC、RoPE/GELU接口、Score/P、统计、OACC、GU乘法均FP32。8bit scale是块指数，不是任意FP32比例，沿用RNE/饱和/scale规则。

feature-B16结果每Tile index=0..25，末对row50有效、vector_valid=01；last表示当前Tile最后一对。RoPE先返回第一个canonical Tile的26对，再返回第二个：Q为j/j+8，K为本地0/1。

token-B16结果每Tile为4 token group x8双feature包，index=0..31，vector_valid=11；最后8包token_mask=0007，无效数据零填充。V的量化轴不能照搬K/Q。

SFU回显自身命令token；P流经PCore匹配block后改为VPU token转发。不要跨单元自行复用token。

## 7. Attention存储与并行

顺序：`QK0,QK1,PV0,QK2,PV1,...,QK54,PV53,尾部缩放时隙,PV54`，共110子任务。不是QK0/PV0直接交替。生产adapter使用dea8_attention_scheduler_v4并启用STREAM_P_POST。

~~~text
QK(b)最终提交 -> VPU QK_POST -> SFU ALPHA_EXP
                                  |
                    +-------------+----------------+
                    |                              |
             配置VPU P_POST                等PV(b-1)提交
                    |                              |
             SFU P_EXP流 -> PBUF            VPU OACC_SCALE(b)
                    +------ P就绪且缩放完成 --------+
                                   -> PV(b)
PV54最终提交 -> SFU RECIP -> VPU AFIN_QUANT -> QOZ_O完整
~~~

两单元各一条命令在途，但彼此及Matrix可以并行。下一QK_POST等前代P_EXP读完单代m/aa；alpha两代复用等旧P_POST和SCALE退出。尾部PV54同时等保护时隙、P就绪及缩放就绪；慢单元通过done延长等待，不伪造固定拍done。

| 存储 | 逻辑容量 | VPU | SFU |
|---|---|---|---|
| FACC-A/B | 各51x16 FP32 | QK_POST经ACC读 | 无 |
| OACC | 51x256 FP32 | SCALE读写，AFIN读 | 无 |
| Score/SBUF | 两bank，各51x16 FP32 | 写**加mask后的Score** | P_EXP读 |
| m、aa | 各51 FP32，单代 | QK_POST更新，aa=m_old-m_new | ALPHA读aa，P_EXP读m |
| l | 51 FP32 | P_POST读写 | RECIP读 |
| alpha | 两bank，各51 FP32 | P_POST/SCALE读 | ALPHA写 |
| recip | 51 FP32 | AFIN读 | RECIP写 |
| PBUF | 两bank，各51x16量化P | vector_result提交，PCore管理 | 不直接写 |

- ACC单独选FACC/OACC，顺序响应、信用4；返回没有token，VPU自行按请求顺序配对
- VPU访问OACC的逻辑地址为tile*26+pair；控制边界转换为内部pair*16+tile，不绕过边界
- workspace Score的index为行、整16列，写mask=ffff；统计index为首行，一次最多连续16行，尾mask只选合法行
- Score/alpha bank等于当前命令tile奇偶；m/aa/l/recip bank=0；越权或重复写会报错
- QK的1/sqrt(256)=1/16已由exp_fold=-4折入，VPU不要再缩放一次
- 全mask行按实际RTL边界处理：避免-inf-(-inf)，P/l/O为零，l=0时RECIP返回零

## 8. 握手、完成和取消

1. valid与ready同拍才接受；等待时完整内容保持，ready不是命令触发脉冲。
2. 接受后保存完整command，token=generation16+command_id16，命令号低位区分单元；done回显完整command并带error。
3. 全部输入、结果、写回、读响应及系数响应处理完才提供done；**最后数据握手和done不能在同一接收沿完成**。
4. QK_POST写齐Score/m/aa；P_POST写齐l且PBUF提交；ALPHA/RECIP各51项；SCALE顺序416项。最后请求发出不等于完成。
5. 错token、数量、坐标、mask、last、越权或过早done会FAULT，不是普通背压，不能等它自动变合法。
6. clear触发flush，VPU/SFU分别确认全部在途已取消/排空，含系数服务；两ack都到齐才接新Job，之后不能再送旧代返回。

reset为同步契约。普通Job完成不清掉后续消费者的QOZ。XBC/HBM/KVB没有顶层generation，DEA8必须撤销旧源流，PCore不能单独辨别flush后的旧输入。

## 9. 到GCore的新256-bit输出

八个PCore各一条tx256，不是共享一条总线。首拍header的last=0，最后payload的last=1；背压期间数据和半行选择保持。

| 类型 | 每Tile包长 | 本核Tile数 | 编码、结束 |
|---|---|---:|---|
| K | 1 header+51 payload | 2 | 低136=data128+scale8，其余零；等GCore commit |
| V | 1 header+64 payload | 2 | 同为136bit有效、token轴、尾填零；等commit |
| O/Down | 1 header+102 payload | 各64 | 每行先低8FP32再高8FP32；最后payload握手后本核可完成 |

header低128有效、高128零，用encode_packet_header填入版本/长度/dtype/scale轴。K核c的column_base为16*c和16*c+128；V为32*c和32*c+16；O/Down为16*tile，八核坐标相同、source_id不同。

KV保留反向kv_commit，须实际落RAM后回显身份。O/Down不增加逐核commit，GCore入口ready和全局服务done控制退休。内部64x136 KV sender及两行FP32 holding保留，不新增完整FP32结果Tile。

## 10. 运行与验收

从Pcore目录运行，Vivado2022.2：

```text
python tools/prepare_compute_vectors.py --position 816
python tools/prepare_seven_job.py
python run_compute.py ip
python run_compute.py test --top tb_pcore_seven_native
```

默认展开O3、mt off；只有已记录的工具问题才尝试 `--opt 0`，不能删检查或替换真实IP。显式PASS、数值/计数满足且前后输入哈希一致才通过，退出码0不够。完整日志/manifest在 `reports/compute/`；图表生成器不接受旧源码或不完整PASS。

当前完整七Job：279571拍、265408 issues、55QK/55PV、6299量化+157743FP检查。DUT内部无TB算术，TB只模拟单核外部数据、命令与接收。八核联合第1/9/18层及压力/恢复仍待服务器执行。

服务器先完成仿真，再综合一个完整PCore及GCore测资源，不综合八核、不布局布线。入口为DEA8目录的 `run_dea8.py synth --target pcore --server-heavy`；先看新资源结果，再决定八核综合。见 [服务器说明](../Server_Verification.md)。

## 11. 文件入口与历史工具

- 完整顶层：`rtl/dea8_pcore_top.sv`；内部控制：`rtl/dea8_pcore_control.sv`。
- 命令与类型：`rtl/pcore_control_pkg.sv`、`rtl/pcore_pkg.sv`。
- 单元：`units/vpu`、`units/sfu`；来源记录：[SOURCE.md](units/SOURCE.md)。
- Post/G-U窗口/共享统计：`dea8_pcore_post`、`dea8_gu_post_window`、`dea8_pcore_workspace`。
- Attention：`dea8_attention_scheduler_v4`、`dea8_attention_job_adapter`。
- 外发与协议：`dea8_pcore_output`、`dea8_tile_link_pkg`。
- 生产RTL清单：`pcore_rtl.f`；单核验收：`tb/compute/tb_pcore_seven_native.sv`。
- 共享侧：[GCore](../Gcore/README.md)，八核/层级互连：[control](../control/README.md)。

`pcore_all.f`、`run_control*`、旧DEQACC时序/裸基核综合脚本保留历史和兼容用途，不是完整官方IP PCore的验收或面积入口。旧TB模拟版周期/接口说明已撤下，不能以旧11级DEQACC、独立Reduce、单行GELU信用或外部VPU/SFU服务模型接入当前工程。
