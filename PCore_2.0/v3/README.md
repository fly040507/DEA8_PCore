# PCore 2.0 v3 数据面

## 当前状态：DEQACC_3.3ns

2026-09-30：Matrix 已接入 `rtl/DEQACC_3.3ns.sv`，模块标识符为 `DEQACC_3_3ns`。本轮完成 DEQACC 物理结构优化，17 项 XSim 回归通过，registered timing shell 的 post-route 250 MHz 时序通过。旧版源码与 `reports/ooc_*v4/`、`reports/ooc_*v5/` 是历史证据，不代表当前实现。

### 改动与固定契约

- 11 级 D0..D10，输入采样到 commit 的 edge delta=10；32 lanes，每拍一个 row-pair，II=1。
- D0 abs/lead；D1 normalize/exponent；D2 partial prepare 与 ACC read；D3 partial finish 与对应 RAM response；D4 order；D5 align；D6 add/coarse LZC；D7 shift control；D8 normalize；D9 round/pack；D10 physical write/commit。
- ACC 内部读取使用 raw data + even/odd word valid，零值选择在 DEQACC lane 输入附近完成；外部 Result/VPU 接口保留 invalid→0 语义。
- arithmetic、metadata payload 和 lane result 不复位；reset/clear 清 valid、done/commit 和 RAM valid bitmap。invalid 时 payload 不保证为零。
- `add_old=0/1` 延迟一致；前者 old 输入置零且最终保留 partial 原值。保留 RAM response、lane/context 对齐和未提交同地址 RAW hazard 检查。
- FP32 算术规则与 frozen reference 一致，本轮未引入 close/far 算法或修改特殊值处理。

## 实际时序证据

Vivado 2022.2，`xcu50-fsvh2104-2-e`。输入和输出在 `DEQACC_3.3ns_timing_shell.sv` 中注册，shell 寄存器不计入正式11级延迟。先在4ns下综合、布局布线，再以更严格的3.3ns目标执行物理优化，最后在同一个 routed netlist 上恢复4ns出验收报告。

最终报告：`reports/DEQACC_3.3ns/refined_250MHz_timing.rpt`

| 指标 | 最终结果 |
| --- | ---: |
| 时钟周期 | 4.000 ns / 250 MHz |
| Setup WNS / TNS | +0.700 ns / 0 |
| Hold WHS / THS | +0.019 ns / 0 |
| 无时钟 / 内部未约束端点 / 组合环 | 0 / 0 / 0 |
| Failed / unrouted nets | 0 / 0 |

逐级 post-route Data Path Delay（logic + route）：

| 阶段 | Logic ns | Route ns | Total ns |
| --- | ---: | ---: | ---: |
| D0 abs/lead | 1.053 | 1.632 | 2.685 |
| D1 normalize/exponent | 0.802 | 2.330 | 3.132 |
| D2 partial prepare | 0.809 | 2.236 | 3.045 |
| D3 partial/RAM response | 0.266 | 2.884 | **3.150** |
| D4 order | 0.643 | 2.379 | 3.022 |
| D5 align | 0.677 | 2.209 | 2.886 |
| D6 add/coarse LZC | 0.698 | 1.590 | 2.288 |
| D7 shift control | 1.118 | 1.853 | 2.971 |
| D8 normalize | 0.397 | 2.029 | 2.426 |
| D9 round/pack | 0.726 | 1.965 | 2.691 |
| ACC storage 路径组 | 0.479 | 2.586 | 3.065 |

来源：`refined_stages.csv` 与对应 `refined_*.rpt`。路径按目的寄存器组统计，SRL 推断可能让部分路径跨逻辑字段边界；ACC storage 组包含读写控制，不等同于单独 D10 算术级。主要路径均≤3.3ns，多数≤3ns；尚不宣称全部≤3ns。

首次 route 的 core 层资源：33532 LUT、20552 FF、1184 LUTRAM、1523 SRL、14 RAMB36+2 RAMB18；包含 shell 的总资源为33812 LUT、23872 FF。来源 `routed_utilization.rpt`，属于 refinement 前资源统计，不混称最终物理优化资源。

**适用范围**：这是带真实 launch/capture FF 的独立模块 OOC 物理时序验证，不是整机上板验证。OOC 外部端口未绑定板级 pin，时钟源位置未指定；完整 PCore 的时钟树、外部接口及集成拥塞仍需重新实现验证。没有 false-path/multicycle 豁免内部算术路径，也没有降低目标频率。

复现（在本目录）：

```powershell
powershell -ExecutionPolicy Bypass -File .\run_DEQACC_3.3ns.ps1
powershell -ExecutionPolicy Bypass -File .\run_v3_xsim.ps1
```

`run_DEQACC_3.3ns.ps1` 串联 `DEQACC_3.3ns.tcl` 和 `DEQACC_3.3ns_refine.tcl`，新运行保存并核对源码哈希。本次实际执行为直接调用这两个 Tcl；最终 checkpoint 为 `reports/DEQACC_3.3ns/final_250MHz.dcp`。

## 数值与协议验证

`reports/v3_simulation_summary.txt`：17项通过；源码对应 `reports/v3_sources_sha256.csv`。

- lane frozen reference：1000000笔连续事务，加 clear 中断及16笔重启；共1000016笔输出检查通过。
- 32-lane：5000组连续 pair，轮换 FACC-A/FACC-B/OACC、地址、scale、符号、add_old、row mask；固定11级及metadata检查通过。
- 独立FP函数：400256次加法、76928次pack对拍。frozen reference 独立于本轮改动，但不是第三方IEEE全覆盖模型。
- Matrix64：1664次issue/commit，max_gap=1。
- Projection：`[51,1024]×[1024,256]`，完整数值、尾行及输出背压保持检查通过。
- Attention55：55 QK+55 PV，13056个最终OACC值全部匹配。request→最终commit最大441拍，整个TB54847拍；日志中的旧字段名D4实际指最终commit。调度本轮未优化。
- 其余检查：XBC M51/M50尾部、BFIFO连续流、pair-store region、跨bank ACC并发、PBUF身份和乱序保护。

历史命名的 `tb_fp32_acc_lane_v5`、`tb_deqacc32_v5_stream` 当前测试对象已是 `DEQACC_3_3ns`，名称保留以便对应既有回归入口。

## 数据面与接口边界

- 双行 MXU：16×16、256 DSP48E2，7级；51行转26个row-pair。
- Projection A：XBC4→2×A2→AFIFO；Attention A：QOZ/PBUF同步reader→A2→AFIFO。本地committed源使用4-entry streaming credit，外部XBC仍要求完整Tile。
- B：HBM/KVB B2→BFIFO→B1 serializer→双stationary bank；Job内锁存B源，本地模式允许Job间预取。
- QOZ：16 Tile、单head region、epoch/head一致；最后A2自动commit，全局clear后替换。Projection真实FP32→INT8量化尚未接入。
- PBUF：单Tile、双bank，slot=block_id[0]；26个顺序A2自动commit。block/epoch/head必须匹配，PV最终commit后release。错误顺序、mask、slot、active/full bank写入置sticky error。
- FACC-A/B/OACC各自独立1R1W，Matrix整个Job占用目标bank，VPU可访问其他bank。读请求valid&&ready接受，响应一拍且无响应背压；VPU写接口为`acc_write_t`。
- FACC保持LUTRAM；OACC保持14 RAMB36+2 RAMB18；AFIFO/BFIFO/PBUF/QOZ继续使用前轮BRAM结构。dbg口仅用于RTL仿真。
- Projection输出必须连接`qoz_wr_ready`，停顿时保持数据与tile/pair标记。
- 逻辑10-bit source ID与FIFO transport ID分离。实际HBM AXI/KVB寻址控制器、真实Mask/Softmax/EXP/reciprocal未在本目录完成。
- VPU/SFU算术仍为TB模型，恒等OACC scale和正式存储端口可验证并发，但不是完整Attention算法签核。
- Projection与Attention仍是独立wrapper；Top、G-U、VPU/SFU行级调度不属于本轮范围。
