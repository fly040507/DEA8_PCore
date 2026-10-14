# 动态 Reduce

独立八核 FP32 归约，不负责 K/V gather。仅新增在 `DEA8_dynamic/Reduce`，旧 `DEA8/reduce` 不改。

## 接口与存储

- 输入：8 路 512-bit data，各自 valid/ready/last；8 路 128-bit Tile header
- 输出：1 路 512-bit data、128-bit header、last；等待匹配的 64-bit commit 后释放 Tile
- `rows=1..51`；七 Job 的 M=0 不发零行 Tile，Reduce 拒绝零行 header
- 八路 header 除 `source_id` 外逐字段一致：transfer/epoch、目标对象、行数、布局、列坐标、kind、tile_seq、reserved
- 输出 `source_id=8`；O/Down 列坐标 `column_base=16*tile_seq`
- 数据按 compact row 顺序进入；每核一拍 16 个 FP32，严格检查末行 last

| 单元 | 声明容量 / 行为 |
|---|---|
| 8 个 ingress FIFO | 每路深度 8、宽度 512 bit；payload 共 4096 B |
| 固定 FP32 tree | 每列先 0+1、2+3、4+5、6+7，再两级合并；16 列并行、12 级、II=1 |
| 结果 Tile RAM | 51×512 bit，共 3264 B；只启用前 M 行 |
| 输出 holding | 512 bit；同步读取、背压保持；当前无背压时约三拍一行 |

没有八份输入 Tile RAM，没有 INT8 通路。固定 tree/FIFO/FPADD 从旧设计复用，控制和范围检查重新实现。后端较慢或 commit 延迟过长时，背压传回 PCore；不承诺任何接收速度下都能隐藏发送。

## 已验证

2026-10-14，官方 Vivado 2022.2、O2、新 snapshot：**53 个正常 Tile 通过**，覆盖所有 M=1..51，再验证大→小无 clear 切换；1378 个输出 word 按固定树顺序逐 FP32 位比较。

- 八路独立输入停顿、输出停顿、末行 last、header 保持
- commit 前保持 busy、不接下一个 Tile；匹配 commit 后正常重用
- 4 项拒绝：零行、reserved 非零、核间 rows 不一致、错误 last
- [测试汇总](C:/Users/fly04/Desktop/VLA/DEA8_dynamic/Reduce/reports/summary_20261014_202359.txt)
- [源码 SHA256](C:/Users/fly04/Desktop/VLA/DEA8_dynamic/Reduce/reports/sources_sha256_20261014_202359.csv)

入口：`run_xsim.ps1`。这是独立 Reduce 仿真；尚未验证八个真实动态 PCore 联接、真实 GCore 或物理 250 MHz 时序。本轮未综合、未布局布线。
