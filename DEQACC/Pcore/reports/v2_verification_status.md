# DEQACC V2 验证结果

更新时间：2026-10-13，V2 控制/局部约束收尾。scale 和 forward 每行 `1→4→16`，add_old/valid/flush `1→4→32`；ACC 读掩码也分级分发，RAM 保持完整。短套件三个正例、三个 RAW 负例全部 PASS。四个同行 8-lane 硬 Pblock 的脚本已提供，器件/Tcl API 自检通过；尚未应用到当前综合网表。本轮没有七 Job、独立 V1 lockstep、当前源码综合/P&R 或 4 ns 时序结论。

模块和脚本保留 V1 兼容名，不按文件名判断版本。本轮入口：[v2_same_row_simulation_summary.txt](v2_same_row_simulation_summary.txt)，对应源码/TB：[v2_same_row_sources_sha256.csv](v2_same_row_sources_sha256.csv)。旧 `v2_simulation_summary.txt`、`v2_sources_sha256.csv` 属于 11:53 的混合行结构，不能证明当前源码。

## 1. 本轮落实的结构

| 项目 | 当前实现 |
| --- | --- |
| scale ingress | 全局一份；只计算两个 row_bias root，各分成四个独立组合分支，每分支四个 base 加法器；每笔 Q0 捕获 |
| Qlane 输入 | Psum/base/bad_scale/valid；不接 Ea/Eb/fold/key |
| 逻辑控制 | 唯一 metadata spine；keys 是流水 metadata 的视图；RAW 与 A3/C compare 各只有中心一套 |
| 同行位置组 | 删除 cluster wrapper；四个 generate 位置标签，依次 row0 0–7/8–15、row1 0–7/8–15，各八 lane |
| 分支端点 | 两行各四个独立 LUT1 buffer 分支，含 12-bit row_bias 和 bad_Ea；104 个显式 LUT1，不增加寄存器 |
| forward | 每行 use_a3/use_c 根只驱动四个分支，每分支四个 lane leaf；80 个显式 LUT1 |
| common control | add_old/Q0-valid/A0-valid/flush 各 `1→4→32`；144 个显式 LUT1；没有新增 Job 配置字段 |
| ACC read mask | old/external read 各按行生成三位 root，再 `1→4→16`；240 个显式 LUT1；不再用全行初始化位遮罩 512 bit |
| bank 控制 | 原 bank/parity 内 matrix_wr/rd_en/wr_en/读写地址/bank_flush 加 MAX_FANOUT=32，允许复制控制驱动，不复制 RAM |
| Psum/base | Psum 从 rsp 直达 Qlane；外部 base 加法器结果与 Psum/bad_scale/valid 同拍捕获 |
| ACC | 一个完整 16 列 FACC_A/FACC_B/OACC；按原 `[2][16]` 静态读写，没有四份 ACC 或中转 Buffer |
| FPADD | FAR/CLOSE 独立 A1 raw 与 A2 candidates，CLOSE operand-only LZA + 一位精确修正，A3 选择路径/舍入候选并打包 |
| 舍入 | A2 同时生成 mantissa+0/+1 及两份指数；round predicate 不在尾端驱动串行 incrementer |
| 延迟 | Q=2、FPADD=4、C=1，总计七级；II=1、Delta>=4，外部接口不变 |

保留此前两项修复：ACC read 由已寄存 Q0 key 驱动，在 Q1 返回；shift=32 的 sticky 不包含 guard bit31。本轮没有提前 ACC read 或改变累加次序。

分发树合计 568 个显式 LUT1，比上一轮增加 464 个组合 buffer；没有新增寄存器。局部 DONT_TOUCH 只保护这些端点，不锁住整个 ingress/lane/ACC。Q/FPADD/base-adder/fanout 使用软层次，C 寄存器命名在 lane 内。RTL 实例数不等于综合利用率；逻辑延迟和 route 收益尚未测量。

约束文件：[deqacc_v2_locality.tcl](../deqacc_v2_locality.tcl)。每组八个同行 lane 与其 scale/forward/common/read-mask 本地端点进入一个硬 Pblock，ACC RAM 排除。初始粒度为四个相邻 clock region，同一 SLR；仍需当前综合网表成员、区域容量和布局验证。

## 2. 新算法验证

| 测试 | 当前结果 | 日志 |
| --- | --- | --- |
| Dequant/FPADD | 各 212,166 笔，逐位匹配冻结 golden；Q=2、A=4、II=1 | [算术](v2_same_row_tb_deqacc_v1_arithmetic.log) |
| Full dual-path | CLOSE 27,319；FAR 异号 90,731；bypass 5,959；LZA 一位修正 5,835、无需修正 13,943；round up/down 均命中；USE_LZA=0/1 同拍结果一致 | [算术](v2_same_row_tb_deqacc_v1_arithmetic.log) |
| 32-lane stream | 10,486 commit；5,000 笔旧 A11 对照；Delta=4/5/6/7；A3=276、C=271 命中；外部 read-first/反压/clear/全 ACC 模型通过 | [stream](v2_same_row_tb_deqacc_v1_stream.log) |
| scale ingress | 335,584 次 lane base/bad_scale 检查；两 root、八分支、四个同行位置组均覆盖；bad_Ea 同拍一致 | [stream](v2_same_row_tb_deqacc_v1_stream.log) |
| 控制树 | 335,584 次 lane 检查；forward/common/flush/ACC mask leaf 逐拍等于 root；add_old 与 A0 bypass 对齐 | [stream](v2_same_row_tb_deqacc_v1_stream.log) |
| 动态 M / 真 MXU | `[M,256]×[256,16]`；M=1/2/3/4/7/8/16/31/32/50/51，合计 1,680 commit；变化的行/列/Tile scale，最终 ACC 和所有未使用行通过 | [动态 M](v2_same_row_tb_deqacc_v1_dynamic_matrix.log) |
| RAW 负例 | Delta=1/2/3 各恰好触发指定 DUT assertion，无其他错误 | [Delta1](v2_same_row_BAD_RAW.log)、[Delta2](v2_same_row_BAD_RAW_2.log)、[Delta3](v2_same_row_BAD_RAW_3.log) |
| 约束器件/API | 在旧 U50 checkpoint 的临时内存设计上，验证几何、硬 Pblock/八个 proxy register 成员、非法目标拒绝；不代表当前 V2 网表匹配或放置 | [Tcl/device](v2_locality_device_check.log) |

新增定向例：所有 23 个尾数抵消深度、正负两种方向、exponent=1/2/127/254；FAR halfway-even/odd、舍入进位、exponent difference=1 的严重抵消。沿用 base=-298..273 和 shift32/33 边界。随机/定向覆盖不是全域形式等价证明。

V1 参考来自发布提交 `af6263595efe13b200101d3774bc1df604f288fb`。`tb/reference/` 保留独立冻结副本，本轮仍校验依赖 hash，但没有运行独立 V1 lockstep。stream 中 5,000 笔旧 A11 数值对照仍保留，没有降低既有检查。

### 历史七 Job 周期（11:53 混合行结构）

以下仅是上一轮记录，不是当前同行源码的验证。FUNCTIONAL 模式、TB 时钟周期 4 ns，包含人工反压；完整七 Job 和独立 V1 lockstep 当时 PASS。本轮按要求不重跑。

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

此前沙箱内 xelab 出现 `XSIM 43-3409`（生成 C 编译失败），相同标准 launcher 在正常宿主权限下成功。本轮直接使用正常宿主权限运行标准 launcher，编译、展开和短仿真通过；没有修补 Vivado 安装。

普通测试要求返回码 0、无 Fatal/Error 且有对应 PASS。RAW 负例精确匹配指定 Fatal 的数量/消息，不接受任意失败。长七 Job 前台执行，通过日志进度判断运行状态，不因几分钟未结束而终止。

## 4. 复现与后续

在 `DEQACC/Pcore` 运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_deqacc_v1.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_deqacc_v1.ps1 -SevenJobs
```

本轮实际执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_deqacc_v1.ps1 -Focused
```

`-Focused` 使用独立 `v2_same_row_suite` 编译库和 `v2_same_row_*` 报告，不运行重复 Matrix TB、独立 V1 lockstep 或七 Job；不能与 `-SevenJobs` 同时使用。默认入口保留更完整的短回归和 lockstep 能力。

源码修改后重新编译和展开，再跑新 snapshot。完整套件需给足时间；七 Job 中 VPU/SFU 与外部数据仍由 TB 模拟，不是八核实体联调或真实外部吞吐验证。

约束自检还修复了属性顺序问题：设置 EXCLUDE_PLACEMENT/CONTAIN_ROUTING 后再设 IS_SOFT=FALSE，并回读验证；早先的相反顺序在 Vivado 2022.2 中留下软 Pblock。自检仅临时修改旧 checkpoint 的内存对象，没有写回 checkpoint 或启动 place/route。默认器件几何选择为 X3Y1/X4Y1/X3Y2/X4Y2，不作为八核最终分配。

没有修改 `DEA8/`、V1 历史报告或 GitHub 发布仓库。下一阶段需单独授权物理验证：在当前源码综合网表上应用 Pblock，核对 32 lane/端点成员、实际 fanout、区域容量和路由时序。ACC 分区不是当前结构，不自动加入。
