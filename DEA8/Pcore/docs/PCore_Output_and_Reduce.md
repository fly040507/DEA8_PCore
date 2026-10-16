# PCore外发与GCore内置归约

更新：2026-10-17。保留文件名用于旧链接，**独立Reduce已废弃，当前归约位于GCore内部**。

接入入口：[PCore README](../README.md#9-到gcore的新256-bit输出)、[GCore README](../../Gcore/README.md)、[共线协议](../../Gcore/GCore_Reduce_Plan.md)。类型见[dea8_tile_link_pkg.sv](../rtl/dea8_tile_link_pkg.sv)。

dea8_pcore_output位于PCore内，接收量化K/V或FACC的O/Down，不在核外增加bridge。每核一组tx_valid/tx_ready/tx_data256/tx_last。

| 类型 | 每Tile包长 | 数据 | 退休 |
|---|---|---|---|
| K | 1 header+51 payload | 低136为data128+scale8，其余零 | GCore实际落RAM后KV commit |
| V | 1 header+64 payload | token-B16，末组无效token零填充 | 同上 |
| O/Down | 1 header+102 payload | 每行先低8FP32再高8FP32 | 本核等最后payload，全局另等GCore服务done |

header低128有效、高128零，包信息编码版本、长度、dtype和scale轴；用encode_packet_header，不将reserved全清零。仅最后payload的last=1。

内部保留64x136 KV sender及两行FP32 holding，不复制整块FP32 Tile。GCore每核RX深度4，K/V独立落存，O/Down八核对齐后四lane归约，再Residual写回和统计退休。

旧512-bit到独立Reduce的接口、独立结果Tile发送及旧报告，不属于当前拓扑。证据：[七Job](../reports/packet_7job_summary.txt)、[GCore十五场景](../../Gcore/reports/summary.txt)。真实八个完整PCore的整层联调未完成。
