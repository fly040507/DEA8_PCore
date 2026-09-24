# PCore 2.0 2-Row MXU

本目录是独立重构版本，不能覆盖或替代旧版 `pcore`。当前依据为桌面 `README_2ROW.docx`；`AI工具意见.docx` 只作为评审输入，尚未把其中未经验证的资源/时序结论当成事实。

## 当前目标

- U50 / XCU50，目标时钟250 MHz；
- 16×16 stationary-B MXU；
- 256个PE，每个PE用一个DSP48E2打包两个共享B的signed INT8乘法；
- 每拍输入两行A，每个Tile由51行变成26个row-pair周期；
- 7级MXU：S0输入、S1 DSP、S2解包、S3-S6双归约树；
- 统一288-bit×64的atomic A2 FIFO；
- W Tile双Bank，HBM填充和16列排空重叠。

## 重要实现边界

1. `dea8_pe_2row.sv` 显式实例化DSP48E2，先验证DSP打包结果，不能用普通 `a*b` 代替验收。
2. `dea8_mxu_2row.sv` 输出两组16-lane Psum；本阶段不接旧版单行DEQACC。
3. `dea8_a2_fifo.sv` 只有在收到完整26-entry Tile后才允许reserve；Tile内部预期连续pop。
4. `dea8_w_tile_assembler_pp.sv` 接受8个256-bit数据beat和1个scale beat，输出16个128-bit列entry。
5. 新增 XBC 校验器、QOZ/PBUF 奇偶存储、自动读控制器、B 列加载器和集成顶层 `dea8_matrix_engine_2row`；旧版代码保持不变。
6. `dea8_matrix_engine_2row` 是本阶段矩阵前端顶层，不是完整 PCore。输出止于双行整数 Psum；未连接双行 DEQACC、FP32 累加和 Attention softmax。
7. `job.init_dest` 明确控制目标累加器是否初始化：它只决定本 job 的首个逻辑累加片段清零，`along_n` 仅表示 Tile 的坐标推进方向，不能再被当作清零条件。
8. QOZ/PBUF 写入采用 `begin_bank -> writes -> commit_bank` 生命周期；控制描述包含 `epoch + tile_base + tile_count`，读端必须匹配 `epoch` 且只读已 commit 的有效 Region。

## 当前未冻结的事项

- U50布局布线后的4 ns时序和拥塞；综合前端时序不能代替实现签核；
- 两行Psum后端的DEQACC/Accumulator接口；
- GCore 与 HBM 控制器真实协议的适配，PBUF producer/consumer 的 block 级所有权；
- QOZ/PBUF 对外地址规划及 buffer 生命周期管理。

## 验证

Vivado 2022.2：

```powershell
powershell -ExecutionPolicy Bypass -File .\run_xsim.ps1
```

## 2026-09-24 已完成验证

Vivado 2022.2 / XSim，使用实际 DSP48E2 UNISIM 模型，不用行为乘法替换 DUT 内的 DSP。

| 测试 | 结果与覆盖 |
| --- | --- |
| `tb_dea8_pe_2row` | PASS；524,290 组输入，1,048,580 个乘积。七种 a0 边界各遍历全部 256×256 个 (a1,b)，另外一轮 a0 变化扫描，包含双 Bank、气泡与 clear |
| `tb_dea8_mxu_2row` | PASS；208 个 row-pair、6,656 个 Psum；双行 signed 数值、尾行 mask、E_STREAM/E_STAT、tag/dest、固定延迟 |
| `tb_dea8_a2_fifo` | PASS；312 个 entry，完整 Tile 预留、满载、同时 push/pop、地址回绕及 clear |
| `tb_dea8_w_tile_assembler_pp` | PASS；12 个 Tile、192 列，逐元素转置与 scale、填充排空重叠、反压保持；前四个 Tile 的列输出无气泡 |
| `tb_dea8_a_pair_buffer` | PASS；32 Tile 完整 Region、Z→Q 的 32→16 复用、旧 epoch 拒绝、非零 `tile_base`、Region 外 Tile 不可读和 Region 外写错误；并覆盖未写完整 commit、错误 epoch/count/base、commit 无 begin、open Bank 重复 begin、begin+commit 同周期、重复写 |
| `tb_dea8_matrix_frontend_2row` | PASS；实际实例化 engine 顶层，共99个完整Tile、2,574个row-pair、82,368个Psum；XBC/HBM、QOZ/KV、PBUF/KV，未提交 Region 等待、`along_n=0/1` 下的 `init_dest=0` 累加标志、自动RAM读，加载计算重叠，错误epoch拒绝，运行中clear，重新加载后重启，以及1/64 Tile边界 |

以上 PE 覆盖不是全部 256³ 种三元组穷举，也不是形式化证明。矩阵集成测试验证 Tile 级整数计算，不等同于完整 Projection/Attention 数值验证。

测试脚本会检查进程退出码、Fatal/Error 和每个 testbench 的 PASS 标记，不能仅凭 XSim 退出码判断成功。日志位于 `reports/*.txt`，本轮 RTL/TB SHA256 清单为 `reports/simulation_sources_sha256.csv`。每轮开始先清除旧PASS状态；若运行期间RTL/TB发生变化，则拒绝记录通过。

供数充足的QOZ/PBUF路径已用断言检查：相邻Tile输入起点间隔27拍，即26拍输入加1拍交接。8个Tile的输入观察窗口为215拍，其中208拍有效、7拍交接，输入有效拍占比96.74%；这里不包含启动等待和输出冲刷，也不是完整VLA端到端利用率。XBC用例故意插入供数气泡，外部等待不应算成硬件固有Tile交接开销。

## 已确认的 MXU 综合

目标器件：`xcu50-fsvh2104-2-e`，时钟约束在综合前设置为4 ns。

| 项目 | 单个 MXU 的综合结果 |
| --- | ---: |
| DSP48E2 | 256 |
| CLB LUT | 9,488 |
| CLB FF | 22,982 |
| LUT as Memory | 0 |
| 综合估计 setup WNS | +2.024 ns |

PE 的两个权重 Bank 显式要求寄存器实现。上述资源只对应 MXU，不包括整个加载顶层、QOZ/PBUF 或后端。

**这些是 OOC 综合结果，不是布局布线或上板结论。** 外部输入/输出延迟尚未约束，OOC 时钟树也不代表最终实现，不能据此宣称整机250 MHz已经达标。

包含默认32-Tile QOZ、PBUF、A/B加载器和MXU的 `dea8_matrix_engine_2row` 的本轮源码已完成同器件、4 ns约束的OOC综合展开，并生成了资源和时序报告：

| 项目 | 集成矩阵前端 |
| --- | ---: |
| DSP48E2 | 256 |
| CLB LUT | 14,593 |
| CLB FF | 29,748 |
| RAMB36E2 / RAMB18E2 | 20 / 4 |
| Block RAM Tile等效数量 | 22 |
| 综合估计 setup WNS | +0.668 ns |

地址生成已改为逐pair步进累加，Region计数采用移位加法，控制层不再额外消耗DSP；本轮资源报告仍为256个DSP。此表仍不包含DEQACC、FP32累加器、SFU/VPU或HBM控制器。

本轮加入 `dea8_a_source_stage`、QOZ/PBUF begin/commit 状态和有效 Region 校验后，RTL 仿真已重新通过；Vivado 在 RTL 优化结束时仍触发 `.Xil/.../realtime/tmp` 清理异常并返回失败码，但在异常前已经生成本轮的 utilization、timing summary 和 checkpoint。上表是本轮综合报告中的结果，只能作为 OOC 综合估计，不能替代布局布线签核；需要在可正常清理 Vivado 临时目录的环境中复跑确认。

```powershell
powershell -ExecutionPolicy Bypass -File .\run_synth.ps1 -Top dea8_mxu_2row
powershell -ExecutionPolicy Bypass -File .\run_synth.ps1 -Top dea8_matrix_engine_2row
```

## 阅读入口

- `docs/矩阵前端实现与接口.md`：结构、存储、接口约定、时序与未完成边界。
- `rtl/dea8_matrix_engine_2row.sv`：本阶段可综合集成顶层。
- `rtl/dea8_matrix_frontend_2row.sv`：job锁存、A/B供数、Tile匹配、双Bank调度。
- `rtl/dea8_mxu_2row.sv` / `rtl/dea8_pe_2row.sv`：算术核心。

本目录的 RTL、测试和说明将作为独立的 `PCore_2.0` 版本维护；旧版 `pcore` 与旧版发布快照不修改。
