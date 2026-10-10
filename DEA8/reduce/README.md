# DEA8 Reduce

本目录只保留八核 FP32 归约。KV 外发已经放入 PCore 内部，由
`..\Pcore\rtl\dea8_pcore_output.sv` 和 `..\Pcore\rtl\dea8_kv_tile_sender.sv` 完成。

## 接口

- 输入：8 路独立 `512-bit`，每拍是 16 个 FP32；每路配一个 `128-bit` Tile header。
- 归约：8 路 FIFO 深度 8，16-lane、三级八输入 FP32 树。
- 输出：单路 `512-bit`，每个 Tile 51 行；header 之后连续输出 data，最后等待 commit。
- 描述符携带 `transfer_id`、`transfer_epoch`、目标、源核、Tile 序号和列基址；Tile 内行号由握手计数恢复。

## 验证

入口：

```powershell
Set-Location C:\Users\fly04\Desktop\VLA\DEA8\reduce
.\run_reduce.ps1
```

脚本检查编译、展开和仿真返回码，并要求日志出现 `tb_reduce PASS`，不能只依赖 XSim 的退出码。当前证据为 `reports/reduce_sim.log`。
