# PCore V3 Matrix Stage

## 当前状态

**PCore V3 Matrix Stage — Matrix Baseline Freeze**。2026-10-06 **00:37:19 +08:00** 的报告对应 v3 Matrix 基线。其后新增 `dea8_pcore_control_v3` 和控制接口包；控制中心已完成全 RTL 编译、elaboration、七 Job 路由 smoke test，并把 K/V 拼接和 O/Down 归约明确为外部边界。

本目录是 PCore V3 的单核矩阵阶段。一个 dea8_matrix_v3 串行执行 7 种 PCore Job，内部只保留 3 种 Matrix mode：

    MAT_PROJECTION
    MAT_ATTENTION
    MAT_GU

VPU、SFU、Gcore、CNET 和真实 HBM 控制器不属于本阶段；非矩阵行为由 TB 模拟。当前只做功能仿真，不做综合和 P&R。

## PCore 控制中心 V3

`dea8_pcore_control_v3` 是 DEA8 与 PCore 的控制边界。DEA8 每次提交一个带 `job_id/epoch/head/user_tag` 的逻辑 Job；PCore 保留上下文，选择 Projection、Attention 或 G-U Adapter，并在对应矩阵、VPU/SFU、QOZ、拼接或归约事务全部完成后返回 `done`。`layer_id` 和 `denoise_step` 可编码在 `user_tag` 中，PCore 透传，不维护 18 层和 10 步循环。

PCore 的外部逻辑 Job 仍为 K、V、Q、Attention、O、G-U、Down 七种。VPU/SFU 使用 `valid/ready` 命令和完成握手，完成延迟由外部模块决定；Projection/G-U 后处理使用 `post_valid/post_data/post_done` 流接口，Attention 使用已有 `vpu_*`/`sfu_*` 命令接口。所有返回事务都必须带回原始 `job_id/epoch/head`。

`OP_GU` 在控制中心内部保持为一个逻辑任务，Gate/Up 结果通过同一个 tile/pair 上下文交给后处理。K/V 通过 `collective_cmd/result` 送外部拼接端；O/Down 通过 `collective_cmd/data/done` 送外部归约端。PCore 负责握手和等待完成，不实现八核拼接/归约树。

新增控制中心的路由 smoke test：

    tb_v3_pcore_control_v3 PASS jobs=7 context=opaque adapters=3 collective_boundary=1

详细接口与启动条件见 `docs/PCore_Control_Center_v3.md`。

## 七种 Job

正式执行顺序由上层发送方决定，本阶段验收顺序为：

    K -> V -> Q -> Attention -> O -> G-U -> Down

| Job | 单核矩阵 | K tiles | N tiles | A 来源 | B 来源 | 输出 |
|---|---:|---:|---:|---|---|---|
| OP_K_PROJ | [51,1024] x [1024,32] | 64 | 2 | XBC | HBM | `collective_result` -> 拼接 |
| OP_V_PROJ | [51,1024] x [1024,32] | 64 | 2 | XBC | HBM | `collective_result` -> 拼接 |
| OP_Q_PROJ | [51,1024] x [1024,256] | 64 | 16 | XBC | HBM | QOZ_Q |
| OP_ATTENTION | 55-block 固定调度 | Adapter 管理 | Adapter 管理 | QOZ/PBUF | KVB | VPU/SFU completion、A_FIN、Q release |
| OP_O_PROJ | [51,256] x [256,1024] | 16 | 64 | QOZ_O | HBM | `collective_data/done` -> 归约 |
| OP_GU | 两支 [51,1024] x [1024,512] | Adapter 管理 | Adapter 管理 | XBC -> Replay | HBM | QOZ_Z |
| OP_DOWN_PROJ | [51,512] x [512,1024] | 32 | 64 | QOZ_Z | HBM | `collective_data/done` -> 归约 |

K/V 是单核 32 维输出。未来 8 个 PCore 拼接为 256 维 KV head，但本目录不实现多核 gather，也不把 head 字段解释为 shard ID。

所有合法 opcode 在 operation_profile() 中显式配置。geometry_valid 仅对 Projection 置位，k_tiles/n_tiles 只对 Projection 有效；Attention 和 G-U 的内部几何由各自 Adapter 管理。非法 opcode 返回全零 invalid profile，Ctrl 返回 JOB_UNSUPPORTED。opcode 编码保持 Q=0、K=1、V=2、Attention=3、O=4、GU=5、Down=6，不因验收顺序而改变。

## 数据路径和 QOZ

    Q Projection -> QOZ_Q -> Attention
    Attention/external subsystem -> QOZ_O -> O Projection
    G-U -> QOZ_Z -> Down Projection

Projection 的物理地址和 transport ID 分离：

    physical_tile = k
    transport     = (n_tile * k_tiles + k) mod 64

O/Down 的 local-A reader 在 S_OVERLAP 期间继续供数；FACC 仍只有 A/B 两个物理 bank，按 logical N tile parity 选择。GU 正式路径为：

    XBC4 -> dea8_gu_xbc_frontend_v3 -> A2 -> GU Replay -> shared Matrix

正式 PCore 顶层不再保留旧 gu_a_* 入口。外部非矩阵 subsystem 写入测试阶段需要的 QOZ 数据时使用 ext_qoz_region_* 和 ext_qoz_wr_*。

QOZ 只有一个活动 region，生命周期为 acquire → 顺序写入 → region_complete → consumer 读取 → release。Q/O 各 16 tile，Z 为 32 tile。生产者与消费者 job_id 可以不同，epoch/head 必须匹配；完整生产者 header 校验写入，release 校验对应消费者操作。O 的 producer header 为 OP_ATTENTION，由外部 subsystem 写入；本阶段 TB 模拟该 producer。

POST_PROJ_QUANT 的 row 为 pair 0..25，first/second 为 even/odd FP32 行；尾 pair row_valid=01，其余为11，pair25 为 last。POST_GU 的 row 为0..50，first/second 为 Gate/Up，row_valid=01，row50 为 last。valid 停顿时保持完整 payload。Q/GU 必须等最后 QOZ pair 被接受后才允许 post_done；K/V/O/Down 由外部 post_done 完成，不产生 post_result，也不写 QOZ。

全局 Matrix/QOZ 错误和 active adapter 错误进入 FAULT，不发正常 completion、不接受新 Job、不自动释放 region；clear/reset 取消 generation，外部 subsystem 同步丢弃旧请求和结果。inactive adapter error 隔离检查通过。

## 验收指标

| Job | 最终实测结果（mismatch=0） |
|---|---:|
| K | 3328 issues，2 outputs，XBC 1664，HBM 1024 |
| V | 3328 issues，2 outputs，XBC 1664，HBM 1024 |
| Q | 26624 issues，16 outputs |
| Attention | 45760 issues，110 Matrix jobs |
| O | 26624 issues，64 outputs |
| G-U | 106496 issues，3328 issues/n |
| Down | 53248 issues，64 outputs |
| 合计 | 265408 Matrix issues |

Attention 保持 body=416、steady=434、PV53 -> PV54=867、final tail=439。G-U 保持 3328 issues/n、last-first=3327、steady=3346，稳态 A/B/slot stall 均为 0。

Projection TB 运行时打印 PROJ_PERF，记录 accept、first issue、last issue、done、issue count、N tile 间隔、Matrix span、Job span 和两种利用率。K/V 数值使用不同权重模式，避免 K/V 路径接反而仍通过全 1 golden。

### Projection 实测性能

下表均来自本轮七 Job TB；周期以该次 reset 后的计数为准。interval 为相邻 N tile 首 issue 的间隔；K/V 只有一次 N0→N1 间隔。

| Job | accept / first / last / done | interval | Matrix span | Job cycles | Matrix issue 利用率 | Job issue 利用率 |
|---|---|---:|---:|---:|---:|---:|
| K | 2 / 32 / 3378 / 3454 | 1683 | 3347 | 3452 | 99.432% | 96.408% |
| V | 3460 / 3490 / 6836 / 6912 | 1683 | 3347 | 3452 | 99.432% | 96.408% |
| Q | 6918 / 6948 / 33856 / 33933 | 1683..1683 | 26909 | 27015 | 98.941% | 98.553% |
| O | 83005 / 83035 / 111170 / 111247 | 440..440 | 28136 | 28242 | 94.626% | 94.271% |
| Down | 218484 / 218514 / 273273 / 273350 | 856..856 | 54760 | 54866 | 97.239% | 97.051% |

Matrix issue 利用率 = issues / (last−first+1)；Job issue 利用率 = issues / (done−accept)。这是当前 TB 的供数和 post 响应模型下的实测，不是整芯片利用率。逐 N 首 issue 见 `reports/tb_v3_pcore_seven_jobs.txt`，五条汇总见 `reports/v3_projection_performance.txt`。

GU slow-post 仍只在 G63 结果 slot 处停顿：276 拍，受影响间隔3623，其余稳态3346。正式 GU 改用 XBC 后冷启动 A/B 等待实测67/26，稳态指标不变。Attention port-stress 13056 个最终值通过，端口压力下 steady=434..501、尾间隔928、tail449；416/434/867/439 是 scheduling 模式验收值。

## 仿真入口

在 C:\Users\fly04\Desktop\VLA\V3 下执行：

    powershell -ExecutionPolicy Bypass -File .\run_v3_xsim.ps1

脚本必须同时检查 xvlog、xelab、xsim 退出码、明确 PASS 文本和非预期 Fatal/Error。七 Job 复用：

    tb_v3_pcore_three_job_chain_sim -testplusarg SEVEN_JOBS

本轮回归的最终证据：

    reports/v3_simulation_summary.txt
    reports/v3_sources_sha256.csv
    reports/tb_v3_pcore_seven_jobs.txt
    reports/v3_projection_performance.txt

仿真日志必须与对应的源码 SHA256 清单对照。上一轮 v3 Matrix 专项回归全部通过；控制中心最新长链 checkpoint 已覆盖 K/V/Q/Attention/O，Down-only 也已通过同一 collective 边界。完整七 Job 新长链的 G-U 数值段仍属于长时间回归，不能用旧日志替代。本轮 V3 控制中心证据见 `docs/PCore_Control_Center_v3.md`、`reports/pcore_control_v3_smoke.txt` 和 `reports/pcore_control_v3_long_latest.txt`。旧物理证据不作为当前 PCore 的综合/P&R 签核。

## 阶段边界

- 不修改 DEQACC 数值语义和 11 级延迟
- 不重做 Attention scheduler
- 不实现真实 VPU/SFU/Gcore/CNET/HBM
- 不实现 18-layer、10-step denoise 或多核 KV gather
- 旧单 INT8 设计保留在 VLA/pcore

本阶段完成后，Matrix 公共执行框架冻结，后续转入 Layer Sequencer 和真实 Job 数据依赖。
