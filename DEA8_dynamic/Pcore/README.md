# 动态 M 的 MXU / PE / DEQACC

本阶段实现计算链路，不是完整动态 PCore。输入为已准备好的 A 双行 pair 和 B 四列加载 beat；HBM/KVB 接收、A/B queue、QOZ/PBUF 和七 Job 控制器尚未接入。

所有改动位于 `DEA8_dynamic/Pcore`。`DEA8`、独立 `DEQACC` 目录只读。

## 计算合同

- `M=0..51`，仅使用 compact row `0..M-1`；不接收 original token 序号
- `P=ceil(M/2)`；每个 Tile 发射 P 个双行 pair，奇数 M 的末 pair 为 `01`
- `M=0`：空任务完成，不加载 B、不启动 PE、不提交 ACC；不会把 0 改成 51
- PE 不增加 M、scale、tag；仍用一个 DSP48E2 计算共享 B 的两路 INT8 乘法
- 同一 K 归约链的首 Tile `add_old=0`，后续 Tile `add_old=1`；累加顺序不重排
- 切换 M 后，新增或重用的输出区域必须先覆盖，再累加；不能把旧任务残留视为新的初始值

## 模块与存储

| 模块 | 本阶段实现 |
|---|---|
| `dea8_pe_2row.sv` | 原实现直接复用：2 个 INT8 权重 bank、DSP multiply、拆包与高半修正 |
| `dea8_mxu_2row.sv` | 256 PE、双行广播、四列/拍写口、整向量 E_STAT 装载、七级旁带 |
| `DEQACC_V1.sv` | 当前七级实现；32 lane、四算术组、一套完整 ACC、A3/C 前递；增加动态行范围保护 |
| `dea8_compute_core.sv` | 当前计算边界的执行控制：Job、bank 身份/释放、A pair 计数、RAW 间隔、真实 commit 完成 |
| `pcore_pkg.sv` | 动态行数 helper、`b4_t`、`compute_job_t`、带 M 的事务 metadata |

最大存储容量不随 M 改变。M 只限制有效行、读写范围和传输次数。

| 物理数据存储 | 大小 / 位置 |
|---|---|
| PE 权重 bank A/B | 2×256×8 bit，共 512 B；每个 PE 的每个 bank 只有一个权重 |
| Q_ACT_REG | 2×16×8 bit，32 B；PE 外，两个激活行向 16 列广播 |
| E_STAT_BANK A/B | 2×16×8 bit，32 B；PE 外；group 0 写入目标 bank |
| MXU 中间结果 | PE 的两个 INT16 输出、三级中间加法树、第四级 Psum 输出寄存器 |
| MXU 旁带 `[0:6]` | 两个 A scale、16 个 B scale、mask、metadata，随有效事务推进 |
| FACC-A / FACC-B | 每套 even 26×512 bit、odd 25×512 bit；每套 3,264 B |
| OACC | even 416×512 bit、odd 400×512 bit；共 52,224 B |

ACC 总数据容量 58,752 B，不含 validity / 控制。四算术组各交换两行×四列数据，没有四份 FACC/OACC 副本。`dea8_acc_store.sv` 中当前只实例化基础 `dea8_acc_bank`，不实例化旧 store 顶层。

## 流水边界

| MXU | 工作 |
|---|---|
| S0 | A 写入 Q_ACT_REG；A scale、active B scale、mask/tag 同沿写旁带 0 |
| S1 | 共享 B 的 DSP packed multiply |
| S2 | 两个 INT16 乘积拆包，高半符号修正 |
| S3 | 16→8 加法树 |
| S4 | 8→4 加法树 |
| S5 | 4→2 加法树 |
| S6 | 2→1 直接写 Psum 输出寄存器；旁带 6 同时输出 |

Psum、两路 A scale、B scale 向量、mask/tag 直接接 DEQACC，不再加队列或额外 Psum 寄存级。

| DEQACC | 工作 |
|---|---|
| Q0 | 捕获 INT32 Psum / Ea / Eb / fold / key；幅值、lead、指数基值 |
| Q1 | 形成 FP32 partial；ACC 同步读由已寄存的 Q0 控制驱动 |
| A0 | old 选择：A3 最新前递、C 前递、RAM，或 `add_old=0` 的零值 |
| A1 | FP32 对齐、加减 |
| A2 | 精确 LZD 与规格化；不声称实现 LZA |
| A3 | RNE 舍入、指数与特殊值处理 |
| C | 写回 ACC，输出 commit / data / metadata / last |

若 S0 在边沿 t 接受，MXU response 在 t+6 出现，下一边沿进入 Q0，C 在 t+13 提交。核心的 `done_valid` 在最后 C 后一拍置位，并保持到 `done_ready`。这与“MXU 七级 + DEQACC 七级”一致。

## 四拍 B 加载与吞吐

`b4_t.data` 为 512 bit：四列，每列 16 个 INT8。group 0/1/2/3 分别写列 0..3 / 4..7 / 8..11 / 12..15。`b4_t.scales` 是额外的 128-bit loader 旁带，只有 group 0 有效，不等同于外部 HBM 的 512-bit beat 格式。

每拍 64 个 PE 向指定 weight bank 写一个字节。E_STAT 同 group 0 一次写完。四个 data group 完成才形成完整 bank。

- 最后 B 写拍可同沿接受下一 Tile 的首 S0；乘法在下一沿才使用新权重
- 旧 bank 在最后 S1 真实使用后释放，不能在最后 S0 就覆盖
- A queue 必须先确认整 Tile 完整；首 pair 用 `a_tile_available` / `a_tile_reserve` 预留
- Tile 内连续发射依赖预留后的 A 源连续供数；核心没有 DEQACC 逐 Tile 排空等待

理想供数、ACC 无外部占用时，验证目标和实际启动间隔为：

```text
I_tile = max(ceil(M/2), 4)
last_C - first_S0 = (tiles-1) * I_tile + (P-1) + 13
```

同地址、同 parity 的依赖事务最小间隔为四拍：Δ4 用 A3，Δ5 用 C，Δ6 及以后可读到正确 RAM 值。M≤6 时显式保底四拍；这与四拍 B loader 相容，不给每个 KTile 添加七拍排空。

此公式不是 HBM/KVB 全路径性能承诺。外部供数的 4.25/4.5 拍平均服务、同步 queue 读取、首拍准备等，应在后续加载链路联调中另计。

## Job 与外部接口

`compute_job_t` 是本阶段的计算 Job，不是 DEA8 总控七种 Job 的新替代协议：

| 控制方式 | 行为 |
|---|---|
| 普通 K 归约，`nt_per_tile=0` | 所有 Tile 写同一输出 NTile；首 Tile 覆盖/沿用初值，后续累加 |
| PV，`nt_per_tile=1` | 每 Tile 改变 nt；写 `OACC[pair*16+nt]`；是否加旧 OACC 由 Job 指定 |
| G-U，`mode=MAT_GU` | 偶 Tile Gate→FACC-A，奇 Tile Up→FACC-B；各自独立 K 归约 |

- A：`a_valid/a_ready`，288-bit `a2_t`，另带目标 B bank；计数器使用 8-bit总 Tile 序号，运输 `tile_idx` 保留低 6 bit 的顺序轮转
- B：`b_valid/b_ready`，`b4_t`；顺序、tile 身份、group、bank owner 检查
- 结果读取：一次同步返回 even/odd 两行各 16 个 FP32；超出 M 的地址不接收，奇数末行的 odd 数据返回零
- VPU 写入：相同 32-FP32 bundle，可按 parity 写；不能写当前 M 范围外的行
- `protocol_error` sticky：非法 M Job 以 error + done 结束；非法 A/B 阻止后续传输，必须 clear 后重试
- `clear`：取消在途计算、bank/context/validity；不清大数据 RAM

ACC 外部 ready 处理 DEQACC 当拍/在途的同 bank 冲突，不等同于“该 NTile 已完成 K 归约”。后续控制器必须依据 final_k 的实际 commit 与行计数释放结果。VPU 写口当前需要该 ACC 已建立的矩阵 M 上下文；更完整的 acquire / flush / job 身份协议属于后续控制接入。

## 仿真入口与证据

依据 `interaction/仿真说明.docx`：每次在同一个 cmd 内先加载 `settings64.bat`，再调用官方 xvlog / xelab / xsim。独立编译库、新 snapshot、统一时间单位，含 glbl 与真实 DSP48E2 模型。

```powershell
& .\run_compute_xsim.ps1
```

本机沙箱内启动 Vivado 自带 C 编译器失败；在获准的沙箱外通过同样的官方入口运行成功。没有替换工具、改 PATH/RDI/TCL 或修改 Vivado 安装。

普通测试必须同时满足退出码 0、无 Fatal/Error、明确 PASS。RAW 负例仅允许一次指定 DUT RAW Fatal，不能拿工具启动失败或 watchdog 当通过。脚本在运行前固定源码哈希，并在运行结束再次比对。

最终回归证据：

- [仿真汇总](reports/simulation_summary_20261013_110839.txt)
- [源码 SHA256](reports/sources_sha256_20261013_110839.csv)

| 测试 | 覆盖 |
|---|---|
| PE | 131,072 个有符号乘积；全 INT8 A0/B 组合、A1 扫描、双 bank、clear |
| Dequant / FPADD | 各 211,978 笔，FP32 特殊值、次正规数、RNE、极端指数、clear |
| DEQACC stream | 344 个 commit；32 lane II=1；Δ4/5/6/7、奇偶独立前递、OACC、clear |
| RAW 负例 | Δ1/2/3 精确触发指定 DUT 拒绝 |
| 真实计算链路 | 71 个正常 Job，M=0..51；64 KTile、128 Gate/Up 交错 Tile、PV 多 NTile与跨 Block累加；18,560 个 Psum / FP32 commit、1,412 次 ACC 读回 |
| 协议与取消 | 在途取消后无旧输出；M>51、非法 A mask、非法 B group 三种拒绝；供数气泡、小→大/大→小 M、奇数尾行保护 |

数据由 TB 生成，但乘法、加法树、反量化、累加、ACC 读写由实际 RTL 完成。golden 独立计算 INT8 点积并使用冻结的 FP32 reference，未向 DUT 注入预期结果。

## 尚未完成

- 三行 A 输入、A queue、QOZ/PBUF 三 row bank 的真实连接
- HBM 双 PC 配对、KVB 广播、8-slot B queue 到四列写口
- 七 Job adapters、Attention 55 Block 调度、VPU/SFU/外发完整链路的动态 M 接入
- 综合、布局布线和 250 MHz 签核；仿真中的 4 ns 时钟不证明物理时序达标

下一步先接真实 A/B queue，复用本轮点积/commit scoreboard，再验证供数、bank 释放和最小间隔的联合性能。
