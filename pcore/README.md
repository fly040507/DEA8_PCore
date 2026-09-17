# DEA-8 PCore / Attention

当前增量：[Q Projection端到端实现](docs/Projection_Q端到端实现_20260917.md)。
新增真实`[51,1024]×[1024,256]`执行入口，经VPU量化行为模型写入实际QOZ数据/scale存储。
Projection与Attention目前分别验证，尚未物理合并为共用阵列的完整PCore Top；本轮Projection不含RoPE。
本轮77模式全量回归、25项Python测试及完整W_Loader综合结果见 [验收记录](docs/Projection与Attention验收记录_20260917.md)。

最新B侧实现：[B侧统一列流与接口契约](docs/B侧统一列流与接口契约_20260917.md)。
W与KV使用两个独立的64×136bit同步读FIFO，数据与scale按列配对；HBM仍为8+1beat，内部单Tile重排。
本增量覆盖旧256项KVFIFO与HBM双WFIFO的描述，未改真实GCore/VPU/SFU。

最新增量：[完整Attention联调与尾部828拍时隙](docs/Attention_完整联调与尾部时隙_20260917.md)。
PV53与PV54之间保留独立SCALE槽；真实矩阵RTL配合SFU/VPU数学行为模型跑通55个Block。
含该时隙的矩阵完成实测91924拍，不再把纯矩阵基准91096当作集成总周期。

当前依据：用户最新桌面 README.docx，第六轮改动见 [R6进度](docs/R6_进度与接口边界.md)。
Attention 矩阵侧现以 2026-09-17 用户连续流方案覆盖旧条款，见
[连续矩阵调度与周期说明](docs/Attention_连续矩阵调度_20260917.md)。
已实现一次 Top Job、内部 110 个 Block Job、64 项配对 KVFIFO、直接列加载与跨 Job 预加载。
Attention Core 已接共用 QK/PV 矩阵、标量 RF、P 流和独立 VPU/SFU 仿真壳。
09-14 新增 KVB/XBC 前端及 KV_MASK，详见 [Frontend 接口与验证](docs/R6_Frontend_接口与验证.md)。
接口及限制见 [标量状态与壳接口](docs/R6_标量状态与壳接口.md)。
第五轮 QK 基线记录见 [QK Job接口与验证](docs/QK_Job接口与验证.md)：58bit Tag、13bit Dest、同步QOZ读取与最后commit屏障。
实现状态见 [状态清单](docs/IMPLEMENTATION_STATUS.md)。本工程不是完整Attention签核版本。

## 当前已实现并仿真的通路

HBM -> 单Tile Assembler -> W B-FIFO -> 列加载器/Bank状态机 -> dea8_mxu -> Psum + sideband[5]。

dea8_qk_engine 保留为 QK standalone 回归入口；新版 dea8_matrix_engine 已支持 QK/PV，
并由 dea8_attention_core 连接真实同步 QOZ、PBUF、DEQACC 和累加存储。
设置 USE_KVB 使用连续 KVB 前端；K/V 均按 B-column 格式传输，key_lane 表示列号。
正式 GCore 需遵守新列协议，完整 PCore Top 尚未完成。
Projection测试源还要求按nt重放XHAT，详见新接口说明；尚未与真实GCore联合签核。
接线、时序和运行方式见 [DEQACC接入说明](docs/DEQACC_RTL接入说明.md)。

- 256bit HBM、8数据beat+1低128bit有效scale beat。
- HBM路径完整Tile预留后16拍装载，每拍同步写一列数据与该列scale；不再首拍写整组scale。
- HBM 的 Stationary Loader 与 Attention 的 Matrix Sequencer 分别拥有各自路径的 Bank 状态；不同时驱动同一阵列。
- Q_ACT_REG / E_STREAM_REG / ACT_TAG_REG / ACT_VALID_REG输入边界。
- E_STAT_ACTIVE_REG只在激活bank时更新，每个乘法沿复制到pipe[1]。
- 六个逻辑阶段，旁带只保留[1:5]；Tile内51拍连续执行。
- Attention 由内部 Sequencer 在 tile15 预加载下一 Job tile0，矩阵就绪场景下稳态 Done 间隔 828 拍；旧 HBM 测试仍检查 832 拍 Load+Compute 窗口。

已删除旧dea8_weight_loader.sv和dea8_mcu_weight_path.sv，filelist已更新。
历史PDF v3/v4与旧PPT不再作为当前MXU接口依据。

## 验证

在VLA根目录：python -m unittest discover -s pcore/tests -v

Vivado默认路径D:/Xilinx/Vivado/2022.2：
powershell -ExecutionPolicy Bypass -File pcore/rtl/run_xsim.ps1 -Test all

脚本默认调用python生成DEQACC向量；使用其他Python路径时传 -PythonExecutable。生成的test_vectors目录不提交Git。

主MXU测试实际连接W_Loader、FIFO和PE；验证2个block、32个Tile、1632行和26112个输出lane，
包含负数/极值、逐lane scale、完整tag、首拍启动、READY保持、中间切换、block间16拍加载。
额外测试流式HBM及延迟scale、Tile内断流必须报错。

新增 `run_xsim.ps1 -Test bside` 检查同步读FIFO、HBM重排与KVB跨Job接收。
`-Test projection`运行全尺寸Q投影、QOZ读回及重启/错误注入；`-Test all`包含Projection和Attention两条链。
Python旧Loader测试保留为历史参考，不代表新B侧逐拍实现；新路径由RTL测试覆盖。
单FIFO的BRAM综合检查可运行 `check_b_fifo_synth.tcl`，不等于整个PCore时序签核。
本次67模式全量回归、20项Python测试与单FIFO综合结果见 [B侧验证记录](docs/B侧统一列流验证记录_20260917.md)。

DEQACC及Attention矩阵调度已通过RTL仿真，并完成VPU/SFU数学行为模型联调。
VPU/SFU正式RTL与目标器件综合时序签核仍未完成；行为模型PASS不代替正式算术精度验证。
