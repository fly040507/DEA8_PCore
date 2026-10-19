# 服务器仿真与综合说明

更新：2026-10-19。**设计与RTL由本地负责；服务器先完成仿真，再分别综合官方IP的GCore与单个完整PCore测资源，不在服务器重写RTL。** 本地不执行综合，完整八核不在本机展开/长跑。本阶段不综合八核，不做opt/place/route或频率签核；用户看过单模块资源后再决定是否综合八核。

## 1. 交付与环境

- 拷贝整个 `DEA8`，包含RTL、`.f`、`units/rom`、TB、参考模型、IP Tcl；不要只传SV
- Vivado **2022.2**，器件 `xcu50-fsvh2104-2-e`；Python3.10+、NumPy（本机3.12.14/2.3.5）
- 服务器设置 `VIVADO_ROOT` 为其安装目录，以下以 `python` 为正确解释器示例
- Windows运行PowerShell；Linux用相同Python入口，路径使用本机实际路径
- 不拷贝旧 `xsim.dir/.Xil` 当新证据；不递归编译整个VLA或DEA8_zhao
- 所有测试串行启动；相同工作目录不能同时重编译/重新生成IP

当前FP配置：ADD11、MUL8、EXP21、RECIP29、RSQRT32；FP32 ADD/MUL各2DSP，特殊函数单列。IP生成只产生仿真/综合产品，不运行综合。

本地最新完整单核7Job已通过：279571拍、265408 issue、94.93%；[实测图](reports/seven_job_native/seven_job_native.png)、[CSV](reports/seven_job_native/metrics.csv)、[hash/数值计数](reports/seven_job_native/metrics.json)。该时间只按4ns换算，不是板级实测。八核代表层仍待服务器执行。

## 2. 生成输入与官方IP

在 `DEA8/Pcore`：

```text
python tools/prepare_compute_vectors.py --position 816
python tools/prepare_seven_job.py
```

在 `DEA8`：

```text
python run_dea8.py vectors
python run_dea8.py ip
```

Mask/RoPE默认profile：有效prefix816、suffix51、pi05=False、position816。若改变Mask洞/有效数，需同步系数ROM和top配置，不可只改Mask文件。`prepare_compute_vectors.py` 在VLA下存在冻结openpi源码时执行官方AST对照；配置JSON的official_mask_cases应为102。服务器缺源码时保留本机带hash的Mask核实证据，不能把cases=0说成服务器再次核实。

完整层参考由 `tools/generate_layer_vectors.py` 独立NumPy生成，包含不同core/feature/K分片。仅RESID及prefix KV允许time0预置，其他gold文件只供被动监视器。第9/18层是独立checkpoint，不宣称运行过前面层。

HBM提供的γ是实际乘数，不是凭同名张量直接拷贝。当前官方pi0非自适应RMSNorm的导出应对应 `gamma = 1 + checkpoint.scale`；该静态参数转换在导出时完成，不是把γ折叠进矩阵权重。GCore执行真实 `X*inv*gamma` 两次FP32乘法。

## 3. 本地负责的验证

| 项目 | 入口 | 范围 |
|---|---|---|
| 真单核7Job | Pcore/run_compute.py test --top tb_pcore_seven_native | 内部Matrix/VPU/SFU/RAM/Mask/RoPE真实RTL；Q到Attention到O、GU到Down不注入中间结果 |
| SFU算术/背压 | Pcore/run_compute.py test --top tb_compute_sfu | 官方exp/recip/GELU及真实workspace |
| GCore冷Norm | run_dea8.py test --top tb_gcore_norm_native | 真实平方和/mean/epsilon/rsqrt/双乘/量化，3264向量 |
| GCore正式import | 上一入口加 --arg IMPORT_FIRST | 不预置内部RESID，正式import3264向量后再真实Norm，覆盖联合恢复所用入口 |
| GCore原生FP | Gcore/run_gcore_xsim.ps1 -Test arithmetic | 4096ADD+4096MUL、特殊值/CE、BF16与量化 |
| 单核取消/恢复 | run_dea8.py test --top tb_pcore_cancel_native | 缺context拒绝、RoPE在途取消、无旧代写回、重配后K全部102行逐位匹配 |
| Mask/QK边界 | run_dea8.py test --top tb_mask_profile / tb_qk_special_rows | 空/满/随机洞、位置校验、全mask/首非空/row50 |
| 隐藏定向诊断 | run_dea8.py test --top tb_attention_history --arg HIDING_AUDIT | 正式管理口提供Q fixture；只用于短程诊断，不替代完整7Job |

PCore日志 `Pcore/reports/compute/`；联合入口日志 `reports/layer_native/`。明确PASS、源码前后hash一致才通过；退出码0不够。仿真表格用 `tools/render_seven_job_metrics.py` 从完整7Job PASS日志生成。

## 4. 服务器先做的准入检查

1. 复跑本地短程及单核7Job；确认同配置、有限数值逐位、量化scale/tag/坐标严格匹配
2. 查看隐藏审计：稳态非矩阵等待应单列；目前已知单VPU命令槽有约16拍/交替段尾巴，不能写“完全隐藏”
3. 单核通过后再展开八核；本地只做了全清单xvlog编译，八核完整展开尚待服务器确认
4. 不以删检查、改gold为DUT输出、内部force结果或拉长每个矩阵slot换PASS/占比

## 5. 八核第1/9/18层

工作目录 `DEA8`，先跑1层；同一未变源码/配置可复用展开快照：

```text
python run_dea8.py test --top tb_dea8_layers_native --server-heavy --arg LAYER=1
python run_dea8.py simulate --top tb_dea8_layers_native --server-heavy --arg LAYER=9
python run_dea8.py simulate --top tb_dea8_layers_native --server-heavy --arg LAYER=18
```

改RTL/TB/配置/gold后必须重编译并展开。runner拒绝源码与编译hash不符，且拒绝使用另一编译对应的陈旧快照。

TB只模拟：DEA8策略、8路HBM权重、γ和最终接收；真实GCore广播XBC/KVB、接KV/FP32、回commit；真实8PCore自己触发全部非矩阵计算。禁止TB代答SFU/VPU/done或计算中改内部RAM。

每核必查：7个完成、265408矩阵issue、55QK+55PV、43264次XBC、14080次KVB、13418次tx256、Q/O/Z双行写1664、P双行写1430。八核共享：32KV commit、128FP Tile退休、6528次BF16 Residual写回。第18层final3264个512bit向量，不能请求第19层参数。

除计数外，检查每核Q/O/Z/P/Score、K/V坐标和量化轴、O/Down FP32包、GCore XHAT/Residual/final。core/head必须有不同输入/权重，不能复制单核答案。

## 6. 压力与取消（服务器任务）

```text
python run_dea8.py simulate --top tb_dea8_layers_native --server-heavy --arg LAYER=9 --arg STRESS
python run_dea8.py simulate --top tb_dea8_layers_native --server-heavy --arg LAYER=18 --arg STRESS
python run_dea8.py simulate --top tb_dea8_layers_native --server-heavy --arg LAYER=1 --arg CANCEL_AT=Attention
python run_dea8.py simulate --top tb_dea8_layers_native --server-heavy --arg LAYER=1 --arg CANCEL_AT=GU
python run_dea8.py simulate --top tb_dea8_layers_native --server-heavy --arg LAYER=1 --arg CANCEL_AT=O
python run_dea8.py simulate --top tb_dea8_layers_native --server-heavy --arg LAYER=1 --arg CANCEL_AT=O --arg RECOVER
```

也支持 `CANCEL_AT=K/Q/SCALE/Down`，末层支持 `LAYER=18` + `CANCEL_AT=Final`。按真实算术/传输事件触发，不是固定120拍假定已进入指定阶段。

外部HBM在flush时撤销旧返回，延迟确认drain；内部ack只能来自真实RTL。排空后再观察100拍，检查PCore Matrix/ACC/QOZ/workspace及tx无旧代写回、GCore无迟到Residual写。

不带RECOVER是停止/排空测试。带 **RECOVER** 则停止旧供数任务，重新配置generation3/PCore epoch4/transfer epoch10，保留未被修改的相同prefix，用GCore正式 `GC_IMPORT_RESID` 接口重装3264个RESID向量，再完整重跑七Job；TB不在time0之后改内部RAM。重跑的数值/计数检查与普通基线一致。8核恢复已写TB、尚未运行，不预报PASS。

PCore单核的正式取消/重启已在本地通过。完整组故障注入矩阵仍是本地后续设计项，服务器只执行已有测试，不应擅自放宽数值/完成条件或代写RTL。

## 7. 仿真全部优先，之后只测两个模块的综合资源

先完成第3～6节的现有测试。短程定向检查和单核七Job通过后，完成真实八核的第1/9/18层、两项STRESS、三项取消及一项恢复；不要为了早看面积跳过功能验收。

综合入口会强制核对以下10份PASS及其日志、当前输入哈希：

| 必需证据 | 场景 |
|---|---|
| 完整单核 | `tb_pcore_seven_native`，内部无TB模型 |
| 八核基线 | `LAYER=1`、`LAYER=9`、`LAYER=18` |
| 八核背压 | `LAYER=9 STRESS`、`LAYER=18 STRESS` |
| 八核取消 | `LAYER=1 CANCEL_AT=Attention/GU/O`，三次分别执行 |
| 八核恢复 | `LAYER=1 CANCEL_AT=O RECOVER`，正式import后完整重跑 |

参数按第5～6节的顺序传入，runner按参数生成报告名。改源码、runner、配置、ROM或gold后先重编译/展开并复跑；仅拷贝本机旧PASS不能通过准入。其他已实现的取消点可补跑，不替代上述必需场景。任一仿真失败先定位，不启动本阶段综合。

全部通过后，从DEA8运行：

```text
python run_dea8.py synth --target gcore --server-heavy
python run_dea8.py synth --target pcore --server-heavy
```

目标分别是完整 `dea8_gcore` 和 `dea8_pcore_top`，后者含Matrix、VPU/SFU、Mask/RoPE、RAM、本核控制与外发；不能只综合Matrix/DEQACC再当完整PCore资源。

新脚本 `tools/synth_resource.tcl` 使用当前生产清单和官方XCI；将XCI复制到各目标报告目录的 `ip_work/` 生成综合产品，不改验证用原始IP文件。关闭依赖缺失OOC DCP的黑盒模式，检查 `IS_BLACKBOX=0`。从Pcore目录解析其默认Mask/RoPE ROM路径，避免资源测试漏掉ROM或读取错误路径。

综合前仍读取4.000ns约束，以固定测量条件；只执行 `synth_design -mode out_of_context`，不做opt/place/route，也不进行4ns时序签核。当前预算超出109/500DSP时照实交回，不为凑预算裁掉逻辑。若存在blackbox则资源不可验收。

| 输出 | GCore | 单PCore |
|---|---|---|
| 目录 | `reports/resource_synth/gcore/` | `reports/resource_synth/pcore/` |
| 资源 | `utilization.rpt`、`utilization_hier.rpt`、`ram.rpt`、`primitives.tsv` | 同左 |
| 可追溯证据 | `synth.log`、`inputs_sha256.json`、`scope.txt`、`PASS.json`、综合DCP | 同左 |

重点看LUT/FF、DSP、RAMB36/RAMB18等效BRAM36、URAM，以及VPU/SFU/ACC/RoPE、GCore KV/FIFO的层次占比。浅宽RAM按真实原语统计；不要只看逻辑bit或DSP。

先用实测 `GCore + 8×PCore` 做资源外推，单列全局控制、互连/扇出、HBM/PCIe、平台shell和调试余量。外推不是八核综合，也不能保证SLR可放下；由用户看完结果后再决定是否综合八核。

**不要运行旧 `run_pcore_ooc.ps1`、`check_gcore_synth.tcl`、`synth_layer.tcl` 或 `implement_layer.tcl` 作为本阶段验收。** 旧GCore完整综合入口已停用，避免覆盖唯一历史报告/DCP；旧裸基核工具只作历史/叶级参考。runner拒绝不指定target的综合和place-route。

## 8. 失败与交回内容

- xelab崩溃：保留日志、top、优化级别；先试 `--opt 0` 或已知O3，mt off；不替换真实算术
- 超时：记录GCore/8核活动Job、phase、VPU/SFU状态、A/B信用、tx/RX/commit阻塞；不能超时视为成功
- 数值失败：保留第一个core/layer/job/tile/row/lane、actual/gold和IP配置；不改成宽泛相对容差
- 先交回仿真日志、逐场景PASS JSON、compile/snapshot SHA及失败定位；通过后再交两个目标的完整综合资源目录、XCI/配置/Tcl/ROM/gold哈希；不要只发截图

当前未做：真实HBM/PCIe/DEA8策略RTL、连续18层/10步、动态M、板级测试。八核联合功能、压力恢复及两个模块当前面积待服务器结果，不预先签核。八核综合、布局布线和4ns签核不属于本阶段任务。
