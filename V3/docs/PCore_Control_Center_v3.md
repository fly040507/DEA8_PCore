# PCore 控制中心 V3

## 1. 边界

PCore 一次接收一个 DEA8 逻辑 Job，负责选择矩阵适配器、启动矩阵、调度
VPU/SFU、管理 QOZ 生命周期，并在外部后处理、拼接或归约事务完成后返回
Job 完成。DEA8 总控仍负责 18 层、10 步去噪、层间依赖和全局清除。

PCore 不实现：

- VPU/SFU 内部算术；
- K/V 八核拼接树；
- O/Down 八核归约树；
- 18 层和 10 步计数器。

## 2. 七种 Job 与物理所有权

```text
OP_K_PROJ    -> Projection Adapter -> XBC + HBM -> VPU(S RoPE/quant) -> KV concat
OP_V_PROJ    -> Projection Adapter -> XBC + HBM -> VPU(quant)          -> KV concat
OP_Q_PROJ    -> Projection Adapter -> XBC + HBM -> VPU(RoPE/quant)     -> QOZ_Q
OP_ATTENTION -> Attention Adapter  -> QOZ_Q + KVB -> VPU/SFU           -> QOZ_O
OP_O_PROJ    -> Projection Adapter -> QOZ_O + HBM -> external reduce
OP_GU        -> G-U Adapter       -> XBC + HBM -> SFU/VPU/quant       -> QOZ_Z
OP_DOWN_PROJ -> Projection Adapter -> QOZ_Z + HBM -> external reduce
```

上层七种 opcode 映射到三种已经冻结的物理 Matrix Mode：Projection、
Attention、G-U。这里的“三种”只表示复用哪套矩阵适配器，不限制后处理。

## 3. DEA8 与 PCore 接口

```text
job_valid / job_ready
job = {header.job_id, header.epoch, header.head, header.op,
       user_tag, core_id, position_base}

done_valid / done_ready
done = {原始 control_job_t, status}
```

`user_tag/core_id/position_base` 对 PCore 是不透明上下文；PCore 只保存并
原样返回，不解释 18 层和去噪步。`done_valid` 必须保持到 `done_ready`。
reset/clear 会取消当前 generation，DEA8 不应继续使用被取消 Job 的结果。

## 4. 后处理与外部集体单元接口

### 4.1 VPU/SFU 后处理口

```text
post_valid / post_ready / post_job
post_data_valid / post_data_ready / post_data
post_done_valid / post_done_ready / post_done
post_result_valid / post_result_ready / post_result
```

`post_job` 是每个输出 tile 的启动令牌，`post_data` 是该 tile 的 FP32
矩阵结果。外部 VPU/SFU 必须保持 `valid && !ready` 时的全部字段不变，
并在对应结果真正被接收后再发 `post_done`。`post_done.header` 和 `n` 必须
与启动令牌一致。

### 4.2 拼接/归约边界

PCore 不实现拼接树和归约树，只提供以下边界：

```text
collective_cmd_valid / collective_cmd_ready
collective_cmd

collective_data_valid / collective_data_ready
collective_data

collective_result_valid / collective_result_ready
collective_result

collective_done_valid / collective_done_ready
collective_done
```

含义如下：

| 信号 | K/V | O/Down |
|---|---|---|
| `collective_cmd` | 一个 K/V 输出 tile 的拼接上下文 | 一个本核 partial tile 的归约上下文 |
| `collective_data` | 不使用 | `post_data` 的 FP32 partial，按 `n,row,last` 发送 |
| `collective_result` | VPU/SFU 量化后的 K/V `post_result` | 不使用 |
| `collective_done` | 不使用 | 归约树完成该 tile/group 后返回同一 `header,n` |

K/V 的 `post_valid` 与 `collective_cmd_valid` 是同一个 tile 的双重握手：
只有 VPU/SFU 和拼接端同时 ready，PCore 才接受该 tile 启动。VPU/SFU 返回
的 `post_result` 只有在 `collective_result_ready` 为 1 时才会被 PCore 接收，
因此结果不会在拼接端背压时丢失。VPU/SFU 必须保持结果直到
`post_result_valid && post_result_ready`。

O/Down 的 `post_valid/post_data/post_done` 在顶层被切换到
`collective_*`，外部归约模块直接驱动 `collective_done`。最后一个 partial
被接受并且 `collective_done` 完成后，PCore 才结束 Job。

## 5. 各 Job 的启动条件

### Q Projection

1. `job_valid && job_ready` 接收 `OP_Q_PROJ`；QOZ 管理器先接受 `QOZ_Q`
   region。
2. 每个输出 tile 的 final-K 矩阵结果产生 `post_valid/post_job`。
3. 外部 VPU/SFU 接收 `post_data` 后完成 RoPE 和量化，返回 `post_result`。
4. QOZ 写入握手并完成全部 16 个 tile；QOZ region complete 后 Job done。

Q/K 的 RoPE 列布局由外部 VPU 使用：每个 32 列私有核配对
`[16*c+i, 128+16*c+i]`。Q 的 `2^-4` 仍由 QK 的 `exp_fold` 完成，不能在
Q 后处理再次缩放。

### K/V Projection

矩阵 final-K 触发一个 tile 的 `post_job`。K 的顺序是 RoPE 后量化，V 只
量化。VPU/SFU 完成后通过 `collective_result` 送外部拼接端。拼接端的
`collective_cmd_ready` 和 `collective_result_ready` 是 Job 继续的必要条件。

### Attention

QOZ_Q region complete 且 Q/KVB 上下文匹配后，Attention scheduler 启动。
QK/PV matrix commit 事件分别触发已有的 `vpu_*`/`sfu_*` 命令；PCore 不
假设它们的内部延迟，只等待带同一 `epoch/head/block_id` 的 done。AFIN 完成
后写出 QOZ_O，释放 Q region，所有必要的 VPU/SFU 和 accumulator 事务完成
后返回 Job done。

### O/Down Projection

先等待对应 QOZ_O/QOZ_Z region complete，再启动矩阵。每个 final-K tile
立即产生一个 `collective_cmd`，随后按 `collective_data` 发送本核 partial。
归约树可以背压；PCore 保持当前数据并等待 ready。最后一项 partial 被接收
后还必须等待 `collective_done`，不能仅凭矩阵 done 返回 Job done。

### G-U

Gate/Up pair 的矩阵结果产生 `post_job/post_data`。外部 SFU 负责 GELU，
外部 VPU 负责 GELU 与 Up 的逐元素乘，随后完成量化；结果通过
`post_result` 写入 QOZ_Z。Gate/Up 的配对、`row_valid`、`last` 和原始
Job header 必须保持一致。G-U 在 PCore 侧是一个逻辑 Job，不拆成两个
DEA8 Job。

## 6. 完成与错误条件

- 所有跨模块返回都检查 `job_id/epoch/head`；tile 返回检查 `n`。
- `valid && !ready` 时 payload 和上下文保持稳定。
- 非目标 Adapter 的 done、错误 context、错误 QOZ owner 或乱序写入进入
  FAULT；`clear` 后才允许接收新 Job。
- PCore 只允许一个逻辑 Job 在执行，避免 QOZ 和共享 Matrix 被并发占用。

## 7. 验证入口

```text
tb_v3_pcore_control_v3
tb_v3_pcore_three_job_chain -testplusarg SEVEN_JOBS
```

前者验证 DEA8 上下文、七种 opcode 路由和集体接口存在；后者用 TB 模拟
XBC/HBM/KVB、VPU/SFU、QOZ 以及外部拼接/归约握手，验证七种 Job 的完整
串行执行。VPU/SFU 算术实现仍不属于本 RTL，TB 模型是功能和握手替身。
