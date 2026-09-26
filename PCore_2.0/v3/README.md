# PCore 2.0 v3 数据面

这一目录是按照 `AI工具意见.docx` 与 `设计方案.docx` 重构的新数据面，独立于旧版 `PCore_2.0/rtl`。本轮只做 RTL 仿真，不做综合，不修改旧版源码。

## 已实现

- `qvec16_t`：16 个 INT8 数据与 8-bit scale 绑定为一个传输原子。
- `a2_t/xbc4_t/b2_t`：数组维度采用 packed 维度前置写法，Vivado 可识别为完整 288-bit packed 接口；编译时仍检查 `$bits(a2_t)==288`、`$bits(b2_t)==288`。
- `XBC4 -> 2 x A2`：每拍输入 4 行，转换为两个 row-pair。
- `AFIFO`：64 x 288，支持 0/1/2 push 与 1 pop，完整 Tile reservation，尾行 `row_valid=01`。
- `HBM/KVB B2 -> BFIFO`：两列一个 B2，两个来源统一进入 64 x 288 BFIFO，并检查 tile/group/epoch 顺序。
- `B2 -> B1 serializer -> B Loader`：Tile 内部连续输出一列/拍，分别加载两个 stationary B bank；Tile 末列禁止跨 Tile 预取，避免破坏完整 Tile credit。
- `2-row MXU`：保留 16 x 16、256 个显式 DSP48E2、每拍两行 A、7 级 Psum 流水。
- `Pair Store`：QOZ/PBUF 使用偶数行/奇数行物理存储，data 与 scale 绑定，保留 begin/write/commit 语义。
- `DEQACC32`：32 lane、5 级流水，偶奇双物理路径，支持 FACC A/B 与 OACC，最终 commit 才产生 `done`。
- `dea8_matrix_v3`：把 XBC、A/B FIFO、B Loader、MXU 和 DEQACC 接成完整多 Tile 矩阵作业链路；支持 HBM/KVB 入口选择、显式 `job_start`、作业配置锁存、Tile 序列、bank 释放/重装、首 K Tile 全 26 pair 清零和最终 D4 commit 后结束。

## 仿真入口

在本目录执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\run_v3_xsim.ps1
```

脚本使用 Vivado 2022.2 XSim，检查编译、elaboration、Fatal/Error 和每个 testbench 的 PASS 标志，并生成 `reports/v3_sources_sha256.csv`。

当前回归覆盖：

| Testbench | 覆盖 |
| --- | --- |
| `tb_v3_ingress` | XBC4 到 26 个 A2，13 拍输入与尾行 mask |
| `tb_v3_bpath` | 8 个 B2 到 16 次 B1 加载，scale/data 绑定与 BFIFO 完整度 |
| `tb_v3_bfifo_stream` | 16 Tile、128 个 B2 的连续入队/出队，覆盖 `group7` 同拍 push/pop |
| `tb_v3_pair_store` | QOZ/PBUF 行偶奇存储、scale 原子性与尾行读取 |
| `tb_v3_pair_store_regions` | Q16、Z32 及 Z32→Q16 reuse，验证 odd row 计数 `25×Tile` |
| `tb_v3_deqacc32` | 5 级流水、FACC-A/FACC-B/OACC 三种选择及 OACC 读改写 |
| `tb_v3_matrix` | 单作业连续 64 Tile，A/B 并发灌入、AFIFO 边写边读、两 bank 循环复用、1664 个 pair commit；MXU issue=1664、`max_gap=1` |

## 边界说明

- `b2_t` 是 PCore 的逻辑 B2 接口，不是物理 HBM AXI beat。真实 256-bit HBM AXI 的 burst/repack 由 HBM Controller/GCore 完成。
- 当前顶层是矩阵数据面验证壳，尚未接入真实 HBM 控制器、SFU/VPU、Projection/Attention 全流程。
- 当前目标是先证明接口粒度、数据/scale 对齐、双行 MXU 算术、奇偶累加存储和最终 commit；综合、布局布线和 250 MHz 时序留到下一阶段。
