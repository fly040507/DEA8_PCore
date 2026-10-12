# DEA8 Reduce：八核 O/Down FP32 归约

进度核对：2026-10-10。

Reduce 将 8 个 PCore 对同一输出 Tile 的 FP32 partial 逐元素求和，再提交给 GCore。**当前独立 RTL 与基本数值/传输仿真已通过，尚未完成真实八核 PCore 联调。**

当前模块只处理 O/Down。K/V 已由 [PCore](../Pcore/README.md) 内部 Tile sender 直接送往 GCore，不经过 Reduce。

## 1. 接口与数据路径

```text
8 × PCore 的 O/Down partial
    每路 128-bit header + 512-bit FP32 行流
                    |
          每路独立 FIFO，深度 8
                    |
          八路同序号行全部就绪
                    |
           16-lane 八输入 FP32 树
                    |
          51 × 512-bit 结果 Tile
                    |
       header → 51 行 data → 等待 commit
                    |
                  GCore
```

| 项目 | 当前约定 |
| --- | --- |
| 顶层 | `dea8_reduce_top` |
| 输入 | 8 路独立 valid/ready；每拍 16 个 FP32，512 bit |
| Tile | 51 行 × 16 列；支持 `TILE_O`、`TILE_DOWN`，布局 `LAYOUT_FP_ROWS` |
| Header | 每路 128 bit；必须对齐事务、epoch、目标、token 起点、列坐标、kind 和 Tile 序号 |
| 核身份 | 输入 `source_id=0..7`；归约输出 `source_id=8` |
| 输出 | 单路 128-bit header，随后 51 个 512-bit data beat，最后一拍 `last=1` |
| 完成 | GCore 返回匹配的 `tile_commit_t` 后释放当前 Tile |

行号由各路握手计数恢复，不随每拍单独传输。快核的数据可先进入 FIFO，持续领先超过缓存容量后受到反压；归约树只在八路都有当前行时接受数据。

## 2. 归约方式与完成边界

每个 FP32 lane 使用固定三级八输入树：

```text
第一级：(0+1)、(2+3)、(4+5)、(6+7)
第二级：(01+23)、(45+67)
第三级：(0123+4567)
```

16 个 lane 并行处理一行。FP32 加法有舍入，验证参考应遵循这棵固定树，不能任意改成串行加法顺序。

当前状态顺序：`COLLECT → SEND_HEADER → SEND_DATA → WAIT_COMMIT`。整个结果 Tile 收集完成后才外发；等待发送/commit 期间，不接收下一 Tile。当前没有多 Tile 双缓冲流水。

PCore 的 O/Down `done` 只表示本核最后一拍已交付。DEA8 总控仍需等待 Reduce 输出与 GCore commit，才能让下一阶段依赖全局结果。

## 3. 当前实现与验证进度

已实现：

- 八路独立输入 FIFO、逐路 header 与行计数
- 同 Tile 身份检查、核号检查、51 行边界与 `last` 检查
- 16-lane FP32 归约树与结果 Tile 存储
- header/data 输出握手、匹配 commit 后释放
- 错误状态保持，`reset/clear` 恢复

已验证：[reports/reduce_sim.log](reports/reduce_sim.log)，2026-10-10，包含 `tb_reduce PASS`；[结果摘要](reports/reduce_summary.txt) 为 `PASS`。

当前 `tb/tb_reduce.sv` 覆盖的基本场景：

- 八核 header 接收与完整 51 行输入
- 每核每个 lane 输入 `1.0`，逐行检查归约结果为 `8.0`
- 输出行数为 51，正常 commit 后 `busy` 清零且无协议错误

当前证据不覆盖真实八核 PCore 连接，也不构成多 Tile、随机输出背压、错误 header/commit 或广泛 FP32 边界值的完整签核。没有据此宣称综合、资源或布局布线时序已通过。

## 4. 文件与依赖

| 路径 | 用途 |
| --- | --- |
| `rtl/dea8_reduce_top.sv` | Tile 协议、八路输入、行计数、结果缓存和输出状态机 |
| `rtl/dea8_reduce_fifo.sv` | 输入缓存 |
| `rtl/dea8_reduce_tree.sv` | 16-lane 固定八输入树 |
| `rtl/dea8_reduce_fp_add.sv` | FP32 加法 |
| `tb/tb_reduce.sv` | 独立基本数值/传输 TB |
| `reduce.f` | 编译清单，包含所需公共依赖 |

公共 header/commit 定义位于 `../Pcore/rtl/dea8_tile_link_pkg.sv`。对接时以该文件和 [PCore 输出说明](../Pcore/docs/PCore_Output_and_Reduce.md) 为准。

## 5. 如何运行

从本目录执行：

```powershell
.\run_reduce.ps1
# Vivado 安装位置不同时
.\run_reduce.ps1 -VivadoRoot 'D:\Xilinx\Vivado\2022.2'
```

脚本编译 `reduce.f`、展开 `tb_reduce` 并运行仿真，检查返回码、Fatal/Error 和 `tb_reduce PASS`。结果写入 `reports/reduce_compile.log`、`reduce_elaborate.log`、`reduce_sim.log` 与 `reduce_summary.txt`。

## 6. 下一阶段

1. 接真实八核 PCore 的 O/Down 输出，验证连续 Tile、核间到达差异和 FIFO 反压
2. 接 GCore 的接收/commit 模型，核对输出背压和目标提交
3. 按联调需要补充事务错配、异常恢复与 FP32 数值边界场景
4. 与 DEA8 总控明确“本核完成、归约完成、目标提交”三个阶段的屏障
