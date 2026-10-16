# DEA8 PCore：当前设计与VPU/SFU接入

更新：2026-10-17。固定 `M=51`、双行INT8、目标U50。**接入顶层是dea8_pcore_control；VPU/SFU算术由外部负责人实现。DEQACC仍保留11级，本次不改。**

新256-bit输出下七Job功能链通过；Matrix、DSP、QOZ、workspace、外发是真实RTL，VPU/SFU/HBM及GCore响应由TB模拟。当前归约在GCore内部，独立Reduce已废弃。

## 1. 相对旧GitHub的变化

比较基线为本次推送前远端 `main=e12af5b`。

| 项目 | 旧GitHub | 当前上传 |
|---|---|---|
| 外发端口 | KV独立header+136-bit流；O/Down独立header+512-bit流 | **统一tx_valid/ready/data[255:0]/last**，带内header |
| 外发实现 | PCore内部sender与FP32 holding | 保留；增加header编码、FP32低/高半发送，不在核外加桥 |
| 归约 | 独立Reduce，GCore为占位 | 八核包链路直连GCore，内部归约/Residual |
| 包信息 | tile_header_t.reserved为零 | 编码版本、长度、dtype、scale轴；使用encode_packet_header，不能全清零 |
| 输出计数 | 旧载荷握手 | kv_word_sent/fp_row_sent，FP32两半送完才计一行 |
| TB | 旧流接收器 | 新tb_packet_decode，迁移控制/七JobTB，另加真实外发到GCore RX联调 |
| **VPU/SFU接口** | command/data/result/done、ACC、workspace、RoPE | **未改类型及顶层端口** |
| **计算核心** | 双行MXU、11级DEQACC、三种策略、QOZ | **未替换**；Matrix/MXU/DEQACC/Attention/G-U算法RTL未改 |

PCore变更文件：`rtl/dea8_pcore_control.sv`、`rtl/dea8_pcore_output.sv`、`rtl/dea8_tile_link_pkg.sv`、`pcore_all.f`、两份控制TB及新增 `tb/tb_packet_decode.sv`。pcore_pkg、pcore_control_pkg、核心计算文件与上述基线相同。

**VPU/SFU不需要改成256-bit算术接口**，256-bit变化只在PCore外发边界。旧文档的独立输出、单请求RoPE和串行服务模型不能当当前合同。

## 2. 数据流与边界

~~~text
DEA8 job -> dea8_pcore_control
                |
                +-> exec -> Projection / Attention / G-U adapter
                |                       |
XBC / QOZ / PBUF ------------> 一个共享dea8_matrix <-- HBM / KVB
                                 16x16双行MXU，驻留B
                                         |
                                  11级DEQACC
                                         |
                                 FACC-A/B、OACC
                                         |
                +-> Post / workspace <-> 外部VPU、SFU
                |       +-> 量化Q/O/Z -> 共享QOZ
                +-> 内部output -> tx256 -> GCore
~~~

- 每PE一个DSP算两行INT8乘积，共256PE；一次矩阵发射对应两行x16个输出
- MXU为7级，含双行解包/修正；scale/tag不进入PE，随Psum对齐
- `DEQACC_PIPE_STAGES=11`，实例是DEQACC_3_3ns，D0..D10；Matrix done等最终写回，不是最后一次发射
- 三类矩阵策略共享一套硬件；文件名_v4是历史内部名，不表示本次另立V4设计
- PCore不承担整hidden RMSNorm、Residual、跨核归约、KV全局管理或十步/十八层循环

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

## 4. VPU/SFU接线表

方向以PCore为参考。使用package类型，跨语言边界用 `$bits(type)` 生成宽度，不手抄字段顺序。

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

G-U基础实现保留51行接口、最多一行GELU在途：PCore保存当前Up，Gate交SFU，GELU返回后配对给VPU。不复制整块G/U到各单元，也不能把51行输入直接改成26对而不适配。

## 6. 数据含义、精度与尾部

| 场景 | first | second | 标记 |
|---|---|---|---|
| RoPE vector_data | 同一行前半16特征 | 对应后半16特征 | 51行，两half都用 |
| V_QUANT vector_data | 一个feature跨16 token | 相邻feature跨16 token | 两列；尾group token_mask=0007 |
| GELU function_data/result | Gate / GELU(G) | 未使用 | vector_valid=01，index=0..50 |
| GU_POST vector_data | GELU(G) | **同一行U** | 01表示一行配对，不能丢second |
| P_EXP function_result | 偶数行P[16] | 奇数行P[16] | 26对，末对01 |
| vector_result | 两个qvec16 | 每个含data128+scale8 | feature轴两行，token轴两feature |

矩阵输入/量化输出为MXINT8-B16，Psum INT32；DEQACC、RoPE/GELU接口、Score/P、统计、OACC、GU乘法均FP32。8bit scale是块指数，不是任意FP32比例，沿用RNE/饱和/scale规则。

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
- 全mask行按TB合同处理：避免-inf-(-inf)，P/l/O为零，l=0时RECIP返回零

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

Vivado固定2022.2；先加载官方环境。数值TB使用O0规避已记录的XSim O2内部断言，不删除检查。以下从本目录执行：

~~~powershell
cmd /d /c 'call "D:\Xilinx\Vivado\2022.2\settings64.bat" && call "D:\Xilinx\Vivado\2022.2\bin\xvlog.bat" -sv -f pcore_all.f "D:\Xilinx\Vivado\2022.2\data\verilog\src\glbl.v"'
cmd /d /c 'call "D:\Xilinx\Vivado\2022.2\settings64.bat" && call "D:\Xilinx\Vivado\2022.2\bin\xelab.bat" tb_pcore_control glbl -s pcore_7job --O0 --debug typical --mt off -timescale 1ns/1ps -L unisims_ver'
cmd /d /c 'call "D:\Xilinx\Vivado\2022.2\settings64.bat" && call "D:\Xilinx\Vivado\2022.2\bin\xsim.bat" pcore_7job -runall -log reports/pcore_7job.log'
~~~

每步先检查退出码及Fatal/Error再执行下一步；最终要求tb_pcore_control PASS。默认FUNCTIONAL；PERFORMANCE/STRESS通过XSim options文件传入 `-testplusarg MODE=PERFORMANCE` 等，避免Windows等号拆参。TB的VPU32/SFU4是吞吐模型，不强制单元内部相同lane，接入后应测真实延迟。

现有[七Job摘要](reports/packet_7job_summary.txt)、[数值日志](reports/packet_7job_baseline.log)、[源码哈希](reports/packet_7job_sources_sha256.csv)对应新包接口：

| Job | FUNCTIONAL总周期 | Matrix issues |
|---|---:|---:|
| K | 3791 | 3328 |
| V | 3659 | 3328 |
| Q | 27143 | 26624 |
| Attention | 49257 | 45760 |
| O | 28318 | 26624 |
| G-U | 107448 | 106496 |
| Down | 54942 | 53248 |

共265408 issues、110 Attention子任务。含人工背压和TB算术，不是全系统PERFORMANCE。旧25项控制签核不能代替新接口重跑。GCore[十五场景](../Gcore/README.md#仿真与证据)含真实外发/RX联调，但没有八个完整PCore。

建议依次替换RoPE/V量化、GELU/GU_POST、Attention命令链，保留golden、尾mask、背压和取消检查，再测隐藏窗口；不要用ready/done常高冒充单元实现。

## 11. 文件入口与旧文档

- 顶层：`rtl/dea8_pcore_control.sv`；类型：`rtl/pcore_control_pkg.sv`、`rtl/pcore_pkg.sv`
- Post/共享统计：`rtl/dea8_pcore_post.sv`、`rtl/dea8_pcore_workspace.sv`
- Attention依赖：`rtl/dea8_attention_scheduler_v4.sv`、`rtl/dea8_attention_job_adapter.sv`
- 外发协议：`rtl/dea8_pcore_output.sv`、`rtl/dea8_tile_link_pkg.sv`
- 可执行并行服务示例：`tb/tb_pcore_control.sv`；包接收示例：`tb/tb_packet_decode.sv`
- 编译入口：`pcore_all.f`；共享侧：[GCore](../Gcore/README.md)

旧专项文档的52/64个“包”、独立Reduce端口、单请求RoPE或273292拍Attention是历史口径，不用于本次接线。资源方案不等于已实施；当前RTL、对应hash和验证摘要是依据。
