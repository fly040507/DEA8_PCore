# 第六轮 Frontend 接口与验证

## 依据与边界

2026-09-14 依据桌面 `XBC与KVB.docx`、`设计方案.docx` 实现，`AI工具意见.docx` 用于确定实施优先级。
本次未修改 Matrix Engine、Stationary Loader、MXU、DEQACC 和 Attention Scheduler 的计算逻辑。
832 拍仍指供数充分时的 Bank Load + Matrix Compute，不包含外部传输、排空及最终完成握手。

## KVB 前端

`dea8_kvb_adapter.sv` 内实例化现有 `dea8_stream_fifo`，实例名 `kvfifo`，不再复制一份 FIFO 实现。
默认深度 512，逻辑字宽由 packed struct 的 `$bits` 推导，当前为 172 bit。
保存 q128、e8、kind1、block6、column4、tile4、mask16、last1、epoch4。
当前 FIFO 是数组加组合读出模型，不能将其逻辑容量直接当作最终 BRAM 数量。

入队只接收并保存原始事务，允许期望 Job 尚未开始以及跨 Block 预取。
`expect_valid/expect_ready/expect_job` 是 PCore 内部的上下文握手；不是新增的 GCore 接口。
上下文在握手后保持至第 256 条 B-column 被接收，不在 FIFO 入队时消耗计数。
本地 tile/column 计数只在 `b_valid && b_ready` 时推进。

出 FIFO 时检查 kind、block、epoch、tile、column、last 和 mask。错误会置位 sticky
`protocol_error`，阻止错误事务进入矩阵引擎；仿真同时执行 `$fatal`，需复位恢复。
FIFO 可能继续吸收有限数量的输入，错误恢复必须同时取消上游旧事务。

K 的每条数据是一个 key 的 16 feature；V 的每条是一个 feature 的 16 key。
二者均直接输出为 `b_data[127:0] + b_scale[7:0]`，不另做数学转置。
现有 `tile_columns` 继续负责列到 Bank Load 行布局的转换。

### V 字段尚待对接确认

V 沿 key 量化及其 Payload 含义已确定，但补充冻结文档仍以条件句描述 V 模式 `kvb_key_lane` 的编码。
所以 `V_KEY_LANE_IS_COLUMN` 默认是 0，V 数据会被保护性拒绝。
仅当 GCore 确认该字段表示 feature offset 0..15 时将它设为 1；测试使用此配置。
若外部旧编码不同，只修改 Adapter 中的字段解释，不能忽略外部字段只靠计数器推断。

## KV_MASK 与 Attention 接入

Adapter 内物理逻辑存储是 55×16-bit mask、55×4-bit epoch 和 55-bit valid。
在第一次有效消费时记录，后续同 epoch/block 的所有 K/V entry 都检查一致性。
查询接口由 block 与 epoch 索引，组合返回 `mask_valid/mask_data`。
block 54 的 padding 位必须为零；允许其他有效位进一步屏蔽，但不允许解除 padding。
整个系统必须按 epoch 隔离不同 Attention 运行，复位清除 valid；不能在同一运行中重用 epoch 来表示不同上下文。

`dea8_attention_core` 增加参数 `USE_KVB`，默认 0 保留原规范化列流测试入口。
置 1 后走 KVB 前端，旧 `b_*` 输入不再被消费。Matrix Job 接受沿同步提交内部期望上下文。
Stationary Bank 仍由原 Loader 独占，FIFO 预取不会启动下一 Block Bank Load。

VPU 接口增加 `vpu_key_mask_valid` 和 `vpu_key_mask[15:0]`，随 `VPU_QK_POST` 命令一起采样。
这不是 MXU Tag 扩展。VPU 必须在命令握手时锁存该 mask，不能在命令结束后继续依赖组合输出。
mask 查询的 epoch/block 来自当前 VPU 命令，不是可能已切换到 PV 的 Matrix current_job。
当前 VPU Stub 未实现真实 Mask/RowMax/EXP，集成测试只验证 mask 到达边界，不宣称 padding 数值计算已签核。

## XBC 前端

`dea8_xbc_adapter.sv` 内部 `xfifo` 存原始完整 beat，默认深度 32，可参数化。
数据 256 bit，连同两个 scale、row、block、mask、last、epoch 一起存放，当前逻辑字宽 321 bit。
slot0 输出低 128 bit、低 scale、低 16-bit mask，block 保持原值。
slot1 输出高 128 bit、高 scale、高 16-bit mask，block 加一。
row/epoch 不变，last 只在 slot1 输出；slot1 握手后才弹出原 beat。
背压时保持 slot 和对应数据，不能提前弹 FIFO，也不生成 Projection Job 或控制 Bank。
尚未连接通用 Projection Sequencer；不是已完成 Projection 计算链。

## 验证入口

在 VLA 根目录运行 `pcore/rtl/run_xsim.ps1 -Test frontend` 做独立前端测试。
使用 `-Test matrix` 做 QK/PV 数值回归与 Attention 集成；`-Test r6` 包含上述测试与既有 R6 回归。
若 PATH 没有 Python，传 `-PythonExecutable` 指定可执行文件。

KVB 单测检查预取、FIFO 满、输出背压、数据/scale 顺序、K/V mask 一致性、末 Block padding 和复位。
反例覆盖 kind、block、epoch、column、tile、last 提前/缺失、padding 解禁、K/V mask 改变。
Matrix 的 `KVB` 模式将原位精确输入通过正式 Adapter，保留 3264 个向量比较和 832 拍断言。
Attention Core 测试使用完整 KVB 接口发送 55 对 QK/PV，检查每次 QK_POST 的有效 key mask。
XBC 单测检查两个 slot 的数据、scale、row、block、mask、epoch、last 及背压。

### 2026-09-14 实测结果

- Vivado 2022.2 `-Test r6` 全部通过，包含旧规范化列流以及新增 KVB 模式的 3264 向量位精确比较。
- 保留的供数充分 832 拍断言通过，断供与复位测试通过。
- Attention Core 的 55 次 QK 和 55 次 PV、全部 QK_POST mask 边界检查通过。
- 最终 `-Test frontend` 复跑通过，使用 768 深度非二次幂 FIFO 预存三个 Job，覆盖同 Block K/V 和另一 Block 的 K。
- 10 类 KVB 错误注入按预期触发断言，含 V 模式列序错误；XBC 拆分测试通过。
- Python `unittest discover -s pcore/tests -v` 20 项通过。

这些结果不包含目标器件综合、时序以及真实 VPU/SFU 算法替换后的系统数值签核。

## 尚未完成

完整 PCore Top、Projection Sequencer、CNET 正式接线、HBM/KVB 统一资源调度尚未完成。
VPU/SFU 真实算术仍由相应同学实现，完整 Attention FP32 数值验证及 FPGA 综合时序签核仍待完成。
本次工作位于主开发目录，未自动同步发布快照或推送 GitHub。
