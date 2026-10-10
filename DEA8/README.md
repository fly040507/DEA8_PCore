# DEA8 工程

当前工程按物理职责组织，不再使用旧的版本目录名或集中式外发目录名：

```text
DEA8/
  Pcore/    单核矩阵计算、DEQACC、QOZ、PCore 控制和 K/V/O/Down 外发
  Gcore/    八核拼接、跨核数据路由和 DEA8/Gcore 对接占位
  reduce/   八核 O/Down FP32 归约
  control/  DEA8 总控接口和十步/层级调度占位
  HBM/      HBM 控制器、地址映射和仿真数据源占位
```

`pcore/` 是保留的旧单 INT8 设计，不属于当前 DEA8 目录，便于与双行 INT8 方案对照。当前只迁移和验证了 PCore 与 Reduce；Gcore、DEA8 control、HBM 的真实 RTL 由后续模块负责人接入。

## 当前验证入口

- PCore：`DEA8\Pcore\run_pcore_xsim.ps1`
- Reduce：`DEA8\reduce\run_reduce.ps1`

两套脚本都检查 Vivado 返回码、Fatal/Error 文本和 TB 的 `PASS` 标记。
