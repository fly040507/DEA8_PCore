# DEA8 Dynamic

本目录用于设计支持动态动作 Token 数量和非连续 Token 行号的 DEA8 优化方案。

## 当前状态

- 本目录是独立设计目录。
- 当前只冻结方案和接口，不修改既有 `DEA8/`、旧版 `pcore/` 或其它发布目录。
- 后续 RTL、Testbench 和验证报告均放在本目录内。
- 现有设计的 51 行固定方案仍作为兼容基线，不在本目录外修改。
- 动态基础链路已经建立：Profile → A 双行打包 → B tile 2-beat 加载 → 双行 MXU → 按 `row_id` 拆分写回 → 动态 QOZ 行寻址存储。

## 优化目标

支持以下形式的矩阵 Tile：

```text
A[R, 16] × B[16, 16]
```

其中：

- `R` 为当前去噪步需要计算的有效 Token 数量，范围为 `0..MAX_ROWS`。
- 当前基线默认 `MAX_ROWS=51`，对应 `row_id=0..50`。
- 有效 Token 可以不连续。
- 同一个去噪步内的 18 层复用同一个 Token Profile。
- Matrix、QOZ、FACC、OACC、VPU、SFU 和输出链路必须保留真实 `row_id`。

## 设计文档

- [动态动作 Token 矩阵优化方案](docs/动态动作Token矩阵优化方案.md)

## 当前仿真证据

从 `DEA8_dynamic/Pcore` 执行 `run_dynamic_foundation.ps1`，Vivado 2022.2 XSIM 已通过以下 6 个测试：

- `tb_dynamic_profile`：7 个非连续行和空 profile
- `tb_dynamic_a_pair_packer`：7 行打成 4 个 pair，尾 pair 为单行
- `tb_dynamic_b_tile_loader`：一个 16×16 B tile 用 2 个 beat 接收数据与 scale
- `tb_dynamic_mxu_2row`：双行 Psum、row_id、激活 scale、权重 scale 对齐
- `tb_dynamic_frontend_mxu`：以上模块端到端连接，4 个 pair 返回正确结果
- `tb_dynamic_qoz_store`：非连续 row_id 的双 lane 写入、读取和 QOZ 区域释放

最新证据见 `Pcore/reports/dynamic_foundation/summary.txt`。目前是行为仿真，尚未进行综合，也尚未接入动态 QOZ/FACC、完整七种 Job 调度和 DEA8 总控。

## 后续目录约定

```text
DEA8_dynamic/
  README.md
  docs/       方案、接口和周期说明
  rtl/        动态方案 RTL，不复制旧版无关代码
  tb/         动态行集合、Projection、Attention 验证
  reports/    仿真结果和周期证据
```

