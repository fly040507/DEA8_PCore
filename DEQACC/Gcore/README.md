# DEA8 Gcore

Gcore 是 DEA8 的八核拼接、路由和外部接口区域。本阶段先保留目录和接口边界，后续接入：

- K/V：接收 8 个 PCore 的带 Tile header 的 `136-bit` 流；
- O/Down：接收 Reduce 的单路 `512-bit` FP32 Tile 流；
- 根据 header 的 `destination`、`column_base`、`tile_seq` 和 `transfer_id` 写入上层结果。

真实 Gcore RTL 尚未迁入，不能把本占位目录当作已完成实现。
