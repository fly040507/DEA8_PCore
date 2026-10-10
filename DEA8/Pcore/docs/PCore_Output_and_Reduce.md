# PCore 外发与 Reduce

`dea8_pcore_control` 内部实例化 `dea8_pcore_output`，因此 K/V/O/Down 的外发属于 PCore 结构，不再通过 PCore 外部 bridge 或旧 egress 模块。

## PCore 输出

- K/V：接收 VPU 的 `control_quant_result_t`，校验 Tile、pair、mask、scale axis 和 `last`，把每两个向量拆成两个 `136-bit` beat。KV Sender 内部为 `64×136-bit` 存储，K 使用 51 个 beat，V 使用 64 个 beat。
- O/Down：接收 FACC 的两个 FP32 行，依次发出两个 `512-bit` beat。PCore 不建立完整 FP32 Tile 副本，数据直接进入 Reduce 的对应输入 FIFO。
- K/V Tile 发送结束后，GCore 返回 `tile_commit_t`；PCore 只有在 Sender 清空后才允许 Job 完成。

## Reduce

Reduce 接收 8 个 PCore 的 512-bit 行流，每个输入独立 FIFO 深度 8。八个 FIFO 都有当前 row 后，16 个 lane 同时执行固定八输入 FP32 树：

```text
(0+1),(2+3),(4+5),(6+7)
(01+23),(45+67)
(0123+4567)
```

树输出写入一个 `51×512-bit` 结果 Tile，再由 Reduce 单路发送给 GCore。PCore 侧的 O/Down 完成由最后一个输出 beat 握手定义；Reduce 到 GCore 的提交由 Reduce 自己管理。

## 验证证据

- `../reports/pcore_output_full.log`：当前并行 VPU/SFU 模型下，七 Job 全链路 PASS。
- `../../reduce/reports/reduce_sim.log`：8 路 Reduce、51 行和 FP32 数值检查 PASS。
- `../reports/pcore_output_protocol.log`：新输出端口协议与错误保持 PASS。
