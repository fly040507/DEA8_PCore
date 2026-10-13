# DEQACC V2 验证结果

更新时间：2026-10-13 11:53。当前源码已完成 scale ingress、flat control 和 Full dual-path FPADD。最终 `run_deqacc_v1.ps1 -SevenJobs` 返回码 0；短套件、独立发布 V1/V2 同拍对照和七 Job 全部 PASS。本轮只做行为仿真，没有综合/P&R 或 4 ns 时序结论。

模块和脚本保留 V1 兼容名，不按文件名判断版本。最终入口：[v2_simulation_summary.txt](v2_simulation_summary.txt)，对应源码/TB：[v2_sources_sha256.csv](v2_sources_sha256.csv)。两文件均由本轮最终回归在 11:53:45 生成，不使用旧日志代替。

## 1. 本轮落实的结构

| 项目 | 当前实现 |
| --- | --- |
| scale ingress | 每个 physical cluster 一份 ingress；Ea/fold -> 两份 row_bias -> 本地四列 base；每笔 Q0 捕获，不是 Job 常量 |
| Qlane 输入 | Psum/base/bad_scale/valid；不接 Ea/Eb/fold/key |
| 逻辑控制 | 唯一 metadata spine；keys 是流水 metadata 的视图；RAW 与 A3/C compare 各只有中心一套 |
| 物理 cluster | 四个 soft hierarchy，每个两行四列、八 lane；只含 scale/Q/FPADD/本地旧值 mux/C 数据，不含 ACC 和 key pipeline |
| ACC | 一个完整 16 列 FACC_A/FACC_B/OACC，四个 256 bit bundle 静态拼接；没有四份 ACC |
| FPADD | FAR/CLOSE 独立 A1 raw 与 A2 candidates，CLOSE operand-only LZA + 一位精确修正，A3 选择路径/舍入候选并打包 |
| 舍入 | A2 同时生成 mantissa+0/+1 及两份指数；round predicate 不在尾端驱动串行 incrementer |
| 延迟 | Q=2、FPADD=4、C=1，总计七级；II=1、Delta>=4，外部接口不变 |

保留此前两项修复：ACC read 由已寄存 Q0 key 驱动，在 Q1 返回；shift=32 的 sticky 不包含 guard bit31。本轮没有提前 ACC read 或改变累加次序。

物理 cluster 是 RTL 层次和布线意图，不代表已经验证放置邻近、routing 降低或 250 MHz。

## 2. 新算法验证

| 测试 | 当前结果 | 日志 |
| --- | --- | --- |
| Dequant/FPADD | 各 212,166 笔，逐位匹配冻结 golden；Q=2、A=4、II=1 | [算术](v2_tb_deqacc_v1_arithmetic.log) |
| Full dual-path | CLOSE 27,319；FAR 异号 90,731；bypass 5,959；LZA 一位修正 5,835、无需修正 13,943；round up/down 均命中；USE_LZA=0/1 同拍结果一致 | [算术](v2_tb_deqacc_v1_arithmetic.log) |
| 32-lane stream | 10,486 commit；5,000 笔旧 A11 对照；Delta=4/5/6/7；A3=276、C=271 命中；外部 read-first/反压/clear/全 ACC 模型通过 | [stream](v2_tb_deqacc_v1_stream.log) |
| scale ingress | 335,584 lane base/bad_scale 逐事务检查；两行、四 cluster、各边界列均覆盖 | [stream](v2_tb_deqacc_v1_stream.log) |
| 动态 M / 真 MXU | M=1/2/3/7/16/31/51，逐笔数值和 mask 通过 | [动态 M](v2_tb_deqacc_v1_dynamic_matrix.log) |
| Matrix | 64 tile、1,664 issues/commits、max issue gap=1 | [Matrix](v2_tb_matrix.log) |
| RAW 负例 | Delta=1/2/3 各恰好触发指定 DUT assertion，无其他错误 | [Delta1](v2_BAD_RAW.log)、[Delta2](v2_BAD_RAW_2.log)、[Delta3](v2_BAD_RAW_3.log) |
| V1/V2 单 lane | 212,166 笔 Q0 字段/Q1 逐位一致；FPADD 与独立冻结的 V1 加法器逐拍一致 | [lane lockstep](v2_lockstep_tb_deqacc_v1_arithmetic.log) |
| V1/V2 完整流 | 10,486 commit；七级 key/valid、Q1/A3/C、每个 parity 的前递选择/old data、meta、external response、全 ACC 一致 | [stream lockstep](v2_lockstep_tb_deqacc_v1_stream.log) |
| 完整七 Job | K/V/Q/Attention/O/G-U/Down 完成；265,408 issue；55 QK + 55 PV；RoPE/GELU/softmax、全掩码行、Q/O/Z 数据链、外发反压检查通过 | [七 Job](v2_tb_pcore_control.log) |

新增定向例：所有 23 个尾数抵消深度、正负两种方向、exponent=1/2/127/254；FAR halfway-even/odd、舍入进位、exponent difference=1 的严重抵消。沿用 base=-298..273 和 shift32/33 边界。随机/定向覆盖不是全域形式等价证明。

V1 参考来自发布提交 `af6263595efe13b200101d3774bc1df604f288fb`。原共享 FPADD/control 在本轮改动前冻结到 `tb/reference/`，恢复模块原名后 SHA256 与发布文件完全一致。新实现没有同时充当参考；共享未变依赖和新增冻结副本由脚本校验 hash。

### 七 Job 周期

FUNCTIONAL 模式，TB 时钟周期 4 ns，包含人工反压。各 Job 周期与此前完整 ACC + fixed Q1 功能基线一致；新算法没有增加接口流水延迟。

| Job | 周期 | Matrix issues |
| --- | ---: | ---: |
| K | 3,783 | 3,328 |
| V | 3,651 | 3,328 |
| Q | 27,079 | 26,624 |
| Attention | 49,025 | 45,760 |
| O | 28,021 | 26,624 |
| G-U | 107,320 | 106,496 |
| Down | 54,645 | 53,248 |
| 合计 | 273,524 | 265,408 |

合计是各 Job 周期相加，不包含 Job 间握手等待；不是实测 FPGA 时间。Attention 稳态间隔平均 436/max 438，AFIN=427。七 Job 主机仿真耗时约 21 分 15 秒，长时间运行不是卡死。

## 3. 仿真方法与权限

每次调用在一个 cmd 内先 call settings64.bat，再 call xvlog.bat/xelab.bat/xsim.bat，明确工作目录和编译库。没有改 PATH/RDI/TCL_LIBRARY，没有 shadow 目录、替换 GCC、直接 unwrapped 或更改 Vivado 安装。

本轮沙箱内的 xelab 出现 `XSIM 43-3409`（生成 C 编译失败）。相同标准 launcher 在正常宿主权限下成功编译 snapshot 并运行 TB；不能把沙箱内这次失败写成“本机不能仿真”。

普通测试要求返回码 0、无 Fatal/Error 且有对应 PASS。RAW 负例精确匹配指定 Fatal 的数量/消息，不接受任意失败。长七 Job 前台执行，通过日志进度判断运行状态，不因几分钟未结束而终止。

## 4. 复现与后续

在 `DEQACC/Pcore` 运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_deqacc_v1.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_deqacc_v1.ps1 -SevenJobs
```

源码修改后重新编译和展开，再跑新 snapshot。完整套件需给足时间；七 Job 中 VPU/SFU 与外部数据仍由 TB 模拟，不是八核实体联调或真实外部吞吐验证。

没有修改 `DEA8/`、V1 历史报告或 GitHub 发布仓库。下一阶段是获准后的资源/时序/route 比较；ACC 分区不是本轮结构，不自动加入。物理实验再判断完整 ACC 与四 cluster 的实际 fanout、局部化收益和 FAR/CLOSE 两路资源开销。
