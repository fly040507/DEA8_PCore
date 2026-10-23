# 接入与交接

更新：2026-10-23。先读[首页](../README.md)、[PCore接口](../Pcore/README.md)和[GCore接口](../Gcore/README.md)。

## 当前停点

- 无代价优化后完整单PCore七Job通过，285942拍，七个Job周期逐项与优化前相同；[结果与哈希](../Pcore/reports/compute/nocost_final7/Summary.md)
- RTL保持在该验证版本；SFU/VPU/宽MUX/FF转置/QK/DEQACC外围优化已实施
- 当前单核104422 LUT、142551 FF、398 DSP、71.5 BRAM36等效、40 URAM；LUT净降11848（10.19%）
- 八核第1/9/18层、压力与组级恢复未验收；当前系统LUT外推99.25%，本轮不强求70%

## 固定架构与精度

- `M=51`、hidden1024、8 PCore；51行按26pair处理，尾pair仅row50有效
- 单套Matrix共享Projection/Attention/G-U，MXU7级、INT20精确求和；DEQACC16级
- 官方FP32 ADD/SUB11拍、MUL8拍，各2DSP；EXP21、RECIP29、RSQRT32
- VPU MUL16/ADD16、quant16；SFU EXP4、单条II1 GELU、RECIP1
- MXINT8-B16量化保持RNE/饱和/scale约定，Score、统计、OACC、RoPE/GELU为FP32
- Mask按官方pi0非pi0.5；state不看action，action间双向可见

## 启动、身份与完成

1. reset后顺序预载1632个256bit RoPE beat，address=0..1631，末拍last=1。
2. `rope_loaded=1`且context、Mask/RoPE版本、position匹配后，PCore才configured。
3. 外部只发K/V/Q/Attention/O/G-U/Down七种Job，内部根据真实依赖触发非矩阵命令。
4. done等待全部结果、写回、读响应和子命令退休；最后一次issue或payload入队不等于完成。

层级端口为`pc_rope_load_*`：每核独立valid/ready/loaded，共享address/data/last。广播端按每核握手撤销valid；普通clear/flush保留已预载系数。

## 数据与存储边界

- XBC：四行量化包；HBM/KVB：`b2_t`，不是原始HBM AXI beat
- Q/O/Z复用单份QOZ：Q→Attention→O→G-U→Down按owner/epoch/context管理生命周期
- M2V四slot：Score、GU和RoPE结果分阶段复用；单向量读/写，禁止静默覆盖
- OACC：scaled单代、raw双页；`α_b × O_(b-1)`，scaled valid在Matrix读请求接受时消费一次
- VPU前台、后台scale、SFU与Matrix可并行；PV逐Tile等待scaled有效
- K/V经每核独立tx256送GCore，实际落KV后commit；O/Down送FP32 partial，归约/残差在GCore

当前算术与RAM实测组织见[非矩阵说明](NonMatrix.md)。

## 取消与恢复

- clear触发真实flush，等待Matrix、VPU/SFU、系数服务及外部源流排空
- HBM/XBC/KVB旧返回必须撤销；没有顶层generation的源流不能仅靠本核辨别旧数据
- 取消不回滚已写入的RAM/RESID；恢复需合法版本与输入，GCore通过正式import重装残差
- 单核取消后重启K曾通过；八核联合恢复仍待服务器执行，不能据单核结果宣称组级恢复完成

## 构建与证据

使用[验证说明](Verification.md)中的Python/Vivado入口。修改RTL、IP配置、runner、ROM或gold后必须重编译/展开，不复用旧PASS。当前保留的原始manifest和PASS不为清理后的路径重新签发。
