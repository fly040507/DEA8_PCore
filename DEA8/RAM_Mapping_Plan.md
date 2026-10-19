# DEA8 BRAM / URAM 重映射方案

日期：2026-10-19。适用固定 M=51、8 PCore、U50 `xcu50-fsvh2104-2-e`。

**状态：RTL已实施，完整GCore与单PCore综合已完成。** 两项BRAM/URAM实测均符合本文预算，见[实施与综合结果](reports/resource_synth/RAM_Remap_20261019.md)。用户在实施轮明确要求不重跑仿真，因此功能回归仍待执行，不能将面积通过视为功能通过。不更改算法、精度、矩阵并行度或设计版本名称，不开展LUT优化。

## 1. 推荐结论

| 对象 | 下一轮映射 | 主要理由 |
|---|---|---|
| GCore KV cache | 8 个 owner 银行，每银行 `4096×144`，合计 16 URAM | 合并 K/V、两个 feature 和奇偶地址；利用两个读端口，保留八路独立写入能力 |
| GCore XHAT | 2 个行奇偶银行，每银行预留 `2048×144`，合计 4 URAM | 两个端口分别读该银行的两行，仍一次输出四行 |
| GCore Residual | 保持 4 URAM | 已有约 70.83% 容量利用率 |
| PCore FACC-A / FACC-B | **两套独立、同构 BRAM**，各 15 BRAM36 等效 | 每套仅 `[51,16]FP32`；独占 16 URAM 时容量利用率只有 0.55% |
| PCore OACC、QOZ、VPU data RAM | 本轮保留现有 URAM | 端口带宽和整机 BRAM 余量约束；不把低容量利用率解释成高效映射 |
| 浅宽 FIFO、RoPE ROM、统计表等 | 保持现有 BRAM / 原有小状态结构 | 不按 `ram_style` 一键切换，不新增大型 LUTRAM |

按下文完整预算，GCore 预计 **79 BRAM36 等效、24 URAM**；单 PCore 预计 **143 BRAM36 等效、35 URAM**。八核加 GCore 预计 **1223 BRAM36 等效（91.00%）、304 URAM（47.50%）**。

这个结果消除了 FACC 的不对称映射，并提高了 GCore 大存储的 URAM 容量效率；**BRAM 仍偏紧，不能称为已解决整机资源装入问题**。后续须扣除平台 shell、HBM/PCIe、全局控制及互连资源。

## 2. 使用哪一版实测作为基线

采用当前官方 IP 完整顶层综合，不使用缺失 RoPE ROM 的旧 PCore 快照。

| 范围 | BRAM36 等效 | URAM | LUT | FF | DSP | 证据 |
|---|---:|---:|---:|---:|---:|---|
| GCore，10-19 12:22 完成 | 211 | 4 | 31594 | 29574 | 109 | [GCore Summary](reports/resource_synth/gcore_preview/Summary.md) |
| 单 PCore，10-19 14:45 完成，RoPE 修复后 | 128 | 51 | 104573 | 103264 | 500 | [PCore Summary](reports/resource_synth/pcore_preview/Summary.md) |
| GCore + 8 PCore，线性外推 | 1235 | 412 | 868178 | 855686 | 4109 | 不是八核综合 |

- BRAM36 等效 = `RAMB36E2 + RAMB18E2 / 2`
- U50 整器件分母：1344 BRAM36、640 URAM、871680 LUT、1743360 FF、5952 DSP
- 综合仅测面积；无布局布线，也没有 250 MHz 签核
- 新方案不预测 LUT / FF 的精确增减；银行译码、仲裁和流水会改变这些数值
- 改造前八核外推LUT为99.60%，本次为99.41%；本轮不开展LUT优化，但不能从部署风险中删掉

## 3. 映射判断规则

先确认端口与每拍吞吐，再比较物理容量，不只比较数组总 bit。

```text
URAM 数量 ≈ 银行数 × ceil(物理字宽 / 72) × ceil(地址深度 / 4096)
容量利用率 = 逻辑保留数据位数 / (URAM 数量 × 4096 × 72)
```

本方案以“不含物理补零、包含已有逻辑布局 padding”的位数计算主要容量利用率；另列真实有效行数有差别的 XHAT。

1. 较深、可合并地址空间且端口足够的大存储，优先 URAM。约三分之一以上可列入候选，接近或超过一半优先；这是工程筛选口径，不是器件限制。
2. 很浅、很宽的数组，优先 BRAM；不能用很小的 payload 占满一整排 URAM，却称为容量优化。
3. 必须同时访问的逻辑对象，不因“加起来能放下”就合成单银行。RAM 只有两个端口，不会因容量空闲而增加端口。
4. 为维持带宽且避免 BRAM 超预算，可以保留低容量利用率 URAM；必须单列为带宽 / 预算例外。
5. 不为了填满 RAM 人为增大 FIFO 深度、缓存无用副本，或把 tag/valid 一律塞进大 RAM。
6. 不复位 payload RAM。只复位 valid、计数、generation 和事务状态；取消后不得读出旧对象。

AMD UG573 明确：单块 URAM 为 `4096×72`，两个端口共用时钟，每个端口每拍只能执行一次读或一次写；不能在已有双读之外再附加一次写。[UltraRAM Summary](https://docs.amd.com/r/en-US/ug573-ultrascale-memory-resources/UltraRAM-Summary)、[BRAM / URAM 差异](https://docs.amd.com/r/en-US/ug573-ultrascale-memory-resources/Block-RAM-and-UltraRAM-Differences)。

## 4. GCore KV cache：64 个浅银行改为 8 个深银行

### 4.1 当前开销为何是 128 BRAM

当前 `Gcore/rtl/dea8_gcore_kv_store.sv` 按以下维度独立建 RAM：

```text
2 kind（K/V）× 16 feature tile × 2 parity = 64 银行
每银行：136bit × (408 prefix + 32 suffix) = 136bit × 440
每银行实测 2 BRAM36，合计 128 BRAM36
```

每字为 16 个 INT8 加一个 8bit scale。当前层 K/V 和 prefix/suffix 逻辑身份全部保留；不同时保存 18 层的全部 KV cache。

只把 64 个银行分别改为 URAM，会变成 128 URAM，容量利用率约 10.15%；**不采用**。

### 4.2 以 PCore owner 为物理银行

保留当前 K/V 列分配，不要求八个 PCore 改输出布局。

| 数据 | 物理 owner | owner 内的 local feature |
|---|---|---|
| K | `feature_tile % 8` | `feature_tile / 8` |
| V | `feature_tile / 2` | `feature_tile % 2` |

每个 owner 都有 K 的两个 feature、V 的两个 feature；每个 feature 又有两种 parity。

```text
逻辑分区：2 kind × 2 local feature × 2 parity = 8 分区
每分区有效地址：0..439
每分区保留 512 个地址，便于直接拼接地址位

physical_addr[11:0] = {kind, local_feature, parity, offset[8:0]}
offset = prefix ? prefix_address : 408 + suffix_address

每物理字：{8'b0, scale[7:0], data[127:0]} = 144bit
每 owner：4096×144，两个 4096×72 URAM 横向并联
8 owner：16 URAM，无深度级联
```

`offset=440..511` 为非法/保留地址，不能作为有效对象读取。prefix 的 408、suffix 的 32，以及 V 的原有布局 padding 均保留。新旧转换只改变物理地址。

容量计算：

```text
逻辑保留位数 = 64 × 440 × 136 = 3,829,760bit
物理位数     = 16 × 4096 × 72 = 4,718,592bit
容量利用率   = 81.16%
```

相比保留 64 银行后直接改 URAM：128 URAM 降为 16 URAM。不能把两者写成同一种映射方案。

### 4.3 两端口如何使用

| 场景 | 被访问 owner 的端口 A | 同一 owner 的端口 B | 其他 owner |
|---|---|---|---|
| K/V 接收 | 写一个 144bit 字 | 空闲 | 各自可同时写一个字，维持最多八路写入 |
| KVB 请求 | 读 parity=0 | 读 parity=1 | 若有合法写入，仍可独立接受 |
| 同 owner 双读与写竞争 | 接受 KVB 双读 | 接受 KVB 双读 | **该 owner 的 `wr_ready=0`**，不得丢写 |

两个 parity 读请求必须原子接受、一起返回；不允许一个 parity 前进而另一个停住。正常对象控制中 KV 接收和 KVB 读阶段不重叠；底层仍用 ready 仲裁保证异常重叠不会成为三端口访问。

读出两字后去掉补零，生成现有 `b2_t`，保留 tile/group/epoch、zero mask 的语义。K 尾行、V 尾组仍按现有规则处理，不能把未初始化 padding 作为有效量化数据。

### 4.4 实现边界

- 使用显式 `xpm_memory_tdpram`，`MEMORY_PRIMITIVE="ultra"`、common clock、两端口同宽 144bit、no ECC、整字写入
- UltraRAM 不是任意 BRAM TDP 语义。两端口明确设 `WRITE_MODE_A/B="no_change"`；不依赖同址读写结果或 read-first 转发，冲突由仲裁/对象规则排除。Vivado 2022.2 本地 XPM DRC 对 ultra TDP 也要求此设置
- RAM本体读延迟计划3拍，综合时核实寄存器吸收；响应FIFO/head缓存延迟另外计入，不能只改RAM延迟而不改有效位和响应credit
- prefix 仍是上层保证已预置的对象，本轮不新增 prefix DMA；仿真预置工具须按新地址映射加载
- URAM 不支持任意用户内容的配置初始化，不能把 TB 层次赋值或 `$readmemh` 当成板上 prefix 加载能力；部署时仍需真实前级写入
- 取消/错误只清对象和响应，不遍历清空整块 URAM

## 5. GCore XHAT：四个 SDP 银行折叠成两个双读银行

### 5.1 保留四行响应，不降低 XBC 带宽

当前四银行各 `832×136`，共 16 BRAM36；直接原样换 URAM 需 8 URAM，容量利用率约 19.18%。

推荐物理组织：

```text
bank = row % 2
group = row / 4
half = (row % 4) / 2
physical_addr[10:0] = {n_tile[5:0], group[3:0], half}

每 bank：144bit × 2048 预留地址
其中有效布局槽：64 tile × 13 group × 2 half = 1664
每 bank 2 URAM，两 bank 共 4 URAM
```

一次四行读取：

| 端口 | 对应行 | 地址 |
|---|---|---|
| bank0.A | `4*group+0` | `{tile,group,0}` |
| bank0.B | `4*group+2` | `{tile,group,1}` |
| bank1.A | `4*group+1` | `{tile,group,0}` |
| bank1.B | `4*group+3` | `{tile,group,1}` |

读出后重排回原有 `xbc4_t` 的 row0、row1、row2、row3 顺序。group=12 仅行48/49/50有效，row_valid 保持 `0111`，第四行输出零。

容量利用率：含布局尾行槽 `4×832×136 / (4×4096×72) = 38.37%`；只计51条有效行则为 `3264×136 / (4×4096×72) = 37.63%`。两种口径都比原样换8 URAM更合理。

### 5.2 写入与读出的限制必须显式化

- 量化写入仍是每拍一个136bit逻辑字；补零后写对应 bank 的一个端口
- 一次 XBC 四行读占满两银行的全部四个端口，不能同时再写 XHAT
- 正常任务中先完成 XHAT 对象，再启动 XBC；必须保持此依赖
- 底层若出现读写竞争，整组读或写通过 ready 延后；已接受事务不能被覆盖
- 不把此折叠方式机械搬到 PCore QOZ：QOZ 的并发双行读写要求不同，合并后可能需要四次访问，端口不够

## 6. GCore 读流水与响应缓冲

新增 URAM 后，外部包格式保持不变。RAM本体计划3拍，端到端响应还包含FIFO/head缓存，不承诺固定3拍。需要同步修改存储包装、KVB/XBC请求计数和取消闭环。

推荐先采用明确的 credit + 响应 FIFO，避免用复杂的 RAM CE 冻结技巧省几个寄存器。

| 响应 | 字宽 | FIFO 深度 | 预算 BRAM36 |
|---|---:|---:|---:|
| KV，完整 `b2_t` | 288bit | 8 | 4 |
| XHAT，完整 `xbc4_t` | 563bit | 8 | 8 |
| 合计 | | | **12** |

- credit 计数满足 `inflight + queued <= 8`，而不是只看当前 FIFO 是否已满
- 每个已接受读请求预占一个响应位置；响应入队不再临时申请可能不存在的空间
- 两端口返回数据与 tag、zero mask 等旁带一起排队，顺序不变，支持下游任意暂停
- 计数器宽度至少 `$clog2(MAX_OUTSTANDING+1)`，本方案为4bit；现有2bit计数不能直接表示8
- KVB 当前 `credits<2` 的限制改为统一的在途上限参数，计划支持8个在途，避免延长RAM延迟后产生供数气泡
- XBC 不能在新增多拍RAM后仍无限发读；应由包装层 `rd_ready` 和统一 credit 限流
- 目标：RAM 无冲突、响应端畅通时每拍可接受一条请求；不能把3拍延迟实现成每3拍才接一次请求
- clear/cancel 清除所有在途 valid、FIFO、multicast pending 和 owner；旧响应不能在下一代对象中重现

选择8项是为覆盖3拍RAM、FIFO读出/head缓存和credit返回的往返流水；4项不能在增加这些边界后直接保证连续发读。这不是为填满RAM而增加深度，深度4与8在这里也有相同的BRAM宽度下限。

12 BRAM是推荐保守预算，已计入最终总数。若后续证明确有可复用的弹性响应存储，可以减少；在实现和综合确认前不提前抵扣。

## 7. PCore：两个 FACC 统一 BRAM，保持物理独立

### 7.1 目前不合理的地方

改造前`Pcore/rtl/dea8_acc_store.sv`按`STYLE(b==0?"block":"ultra")`区分，造成：

| 对象 | 数据容量 | 现有映射 | 现有物理数量 |
|---|---:|---|---:|
| FACC-A | `[51,16]FP32`，26112bit | BRAM | 15 BRAM36 等效 |
| FACC-B | 同上 | URAM | 16 URAM |
| OACC | `[51,256]FP32`，417792bit | URAM | 16 URAM |

FACC-A/B 容量、角色和吞吐要求对称，不能继续采用不同 RAM 类型。

### 7.2 推荐结构

**两套 FACC 都用与当前 FACC-A 相同的 BRAM 实现。**

```text
FACC-A：even 512bit×26 + odd 512bit×25，两个独立 SDP 银行
FACC-B：even 512bit×26 + odd 512bit×25，两个独立 SDP 银行
每银行：一个读端口 + 一个写端口
每 FACC：15 BRAM36 等效
两 FACC：30 BRAM36 等效
```

- 每拍最多读两行，共32个FP32；同时可写两行
- 保留 Matrix 访问一套 FACC、VPU/SFU 后处理访问另一套的并行性
- 统一类型、端口、外部读延迟和 valid 规则；不把两个独立 FACC 合并成一个只有两端口的大数组
- 保持 `ACC_READ_LATENCY=3`：沿用现有 BRAM 输入地址寄存器加 RAM 读流水，不改变 DEQACC / VPU 对齐约定
- FACC 首次累加的 ZERO 由 valid/初始化语义决定，不依赖 RAM 上电内容
- FACC-A/B、even/odd 使用同一组 RAM 参数来源；禁止在任务模式下暗中更换 primitive

单 PCore 变化：`+15 BRAM36、-16 URAM`。八个 PCore 为 `+120 BRAM36、-128 URAM`，必须计入全局预算。

### 7.3 为什么不选两个 FACC 都用独占 URAM

一套 FACC 的容量利用率：

```text
26112 / (16 × 294912) = 0.55%
```

统一用 URAM 虽能减少 BRAM，却会为两个极浅缓存占用32 URAM/核。它符合“同一种RAM”的形式，但不符合本轮容量效率优先的方向，因此不是推荐实施方案。

也不能仅按容量把两个 FACC 或 FACC 与 OACC 叠入同一存储池：必须先证明所有矩阵/后处理组合下的同时读写不超过两个端口。本轮不引入这种尚无端口证明的跨模块别名复用。

## 8. PCore 其他 RAM 的本轮处理

| 对象 | 当前数量 | 本轮处理 | 原因 |
|---|---:|---|---|
| OACC | 16 URAM | 保持 | 需双行宽读写，避免再增加15 BRAM/核 |
| QOZ payload | 4 URAM | 保持 | 保留并发双行读写和既有生命周期 |
| VPU `data_ram`，1024×32 | 15 URAM | 保持，标记低效例外 | 当前1024bit流式读写需保持；全迁BRAM会挤压系统预算 |
| VPU `saved_ram`、量化缓存等 | 现有 BRAM | 保持 | 不改非矩阵计算及现有端口 |
| Matrix A/B FIFO、PBUF、G-U replay | 现有 BRAM | 保持 | 不能减少双Tile/完整Tile预留或改并行供数 |
| SFU score/stat cache、EXP表、RoPE ROM | 现有 BRAM | 保持 | 保留官方IP内部RAM和已验证RoPE初始化 |
| 外发 holding、ACC响应、workspace、Mask | 现有 BRAM / 原有小状态 | 保持 | 本轮不改包协议、FIFO深度或LUT结构 |

这里不是声称 OACC / VPU data RAM 的 URAM 利用率合理：OACC 约8.85%，VPU data RAM 约0.74%，都很低。它们是本轮为保持带宽和 BRAM 余量而保留的例外。

若在推荐方案上再将 OACC 全改 BRAM，系统会达到 **1343 BRAM36（99.93%）**；再改 VPU data RAM 将超过整器件上限。因此不能孤立追求每个 URAM 的容量利用率，必须同时看 BRAM 总预算。

单 PCore 保留35 URAM的组成：`OACC16 + QOZ4 + VPU data15`。两个 FACC 不在这35块中。

## 9. 新资源预算及取舍

### 9.1 GCore 逐项计算

| 分项 | 现有 BRAM36 | 计划 BRAM36 | 现有 URAM | 计划 URAM |
|---|---:|---:|---:|---:|
| KV store | 128 | 0 | 0 | 16 |
| XHAT store | 16 | 0 | 0 | 4 |
| Residual store | 0 | 0 | 4 | 4 |
| 两类新读响应FIFO | 0 | 12 | 0 | 0 |
| compute / packet RX / gamma / rsqrt等其余存储 | 67 | 67 | 0 | 0 |
| **GCore合计** | **211** | **79** | **4** | **24** |

这里没有预先将接收FIFO、统计表等假定合并。只移动已说明容量和端口组织的对象。

### 9.2 单核和八核预算

| 范围 | 基线 BRAM36 | 计划 BRAM36 | 整器件占比 | 基线 URAM | 计划 URAM | 整器件占比 |
|---|---:|---:|---:|---:|---:|---:|
| GCore | 211 | 79 | 5.88% | 4 | 24 | 3.75% |
| 单 PCore | 128 | 143 | 10.64% | 51 | 35 | 5.47% |
| 8 PCore | 1024 | 1144 | 85.12% | 408 | 280 | 43.75% |
| **GCore + 8 PCore** | **1235** | **1223** | **91.00%** | **412** | **304** | **47.50%** |
| 整器件剩余 | 109 | **121** | 9.00% | 228 | **336** | 52.50% |

公式：

```text
GCore BRAM = 211 - 128(KV) - 16(XHAT) + 12(response) = 79
GCore URAM = 4(Residual) + 16(KV) + 4(XHAT) = 24
PCore BRAM = 128 + 15(FACC-B) = 143
PCore URAM = 51 - 16(FACC-B) = 35
系统 BRAM  = 79 + 8×143 = 1223
系统 URAM  = 24 + 8×35 = 304
```

容量重组本体不计新响应FIFO时为1211 BRAM、304 URAM；加入12 BRAM响应预算后为1223。**对外采用包含响应FIFO的1223，不采用乐观下限。**

与基线相比：BRAM净减少12，URAM净减少108。GCore单独节省132 BRAM，但统一FACC会消耗其中120块，不能只展示GCore收益而漏掉八核代价。

DSP结构不变：GCore109、单PCore500、八核加GCore4109（69.04%）。LUT/FF不作为新方案实测或不变承诺；本轮不为降低它们改变计算结构。

### 9.3 不同选择的整机结果

以下都包含新增响应预算；仅用于解释取舍，不是同时实施的多个方案。

| 选择 | 系统 BRAM36 / 占比 | 系统 URAM / 占比 | 判断 |
|---|---|---|---|
| **推荐：KV/XHAT重组，双FACC BRAM** | **1223 / 91.00%** | **304 / 47.50%** | 容量效率和对称性优先；BRAM仍紧 |
| XHAT保留BRAM，仅KV重组、双FACC BRAM；只加KV响应FIFO | 1231 / 91.59% | 300 / 46.88% | 可作为XHAT端口改造的低风险回退 |
| KV/XHAT重组，双FACC都独占URAM | 983 / 73.14% | 560 / 87.50% | BRAM余量大，但FACC容量效率仅0.55%，不推荐 |
| 推荐方案再把OACC迁BRAM | 1343 / 99.93% | 176 / 27.50% | 几乎耗尽BRAM，不采用 |

本轮推荐方案不是“BRAM降到80%以下”的方案。若实际平台可用BRAM不足1223，需另立存储带宽/池化或FIFO重打包任务；不能把shell预算默认为零，也不能无证据地改用大量LUTRAM。

## 10. 实施边界与顺序

以下RTL、供数TB适配和独立综合目录已完成；原定功能回归按用户本轮要求跳过，不视为通过。

| 顺序 | 位置 | 要改什么 | 不改什么 |
|---|---|---|---|
| 1 | GCore KV store及RAM包装 | owner分银行、144bit双端口URAM、prefix物理地址转换、竞争ready | 外部256bit接收、K/V列归属、b2包格式 |
| 2 | GCore activation store | 两银行双读、四行重排、3拍读流水 | xbc4格式、row50尾部、完整对象依赖 |
| 3 | GCore KVB/XBC及响应包装 | credit、8深度响应、取消/错误清空、计数宽度 | 对外任务和对象版本语义 |
| 4 | PCore ACC store | FACC-A/B统一block实现；统一参数和3拍延迟 | OACC、矩阵/后处理并行访问、DEQACC算术 |
| 5 | TB预置与参考地址转换 | 新旧KV和XHAT坐标对照，取消后重启 | 不绕过读写仲裁、不注入正确答案替代计算 |
| 6 | 回归及面积综合脚本 | 独立新运行目录、输入哈希、RAM原语审计 | 不覆盖现有基线证据、不做八核综合/布局布线 |

资源数字应由参数和统一清单生成/核对；不要在多个模块分别写死 primitive、读延迟和 credit 深度。

## 11. 仿真和综合验收

### 11.1 RAM叶级先验收

- KV全部 `kind×feature×parity×prefix/suffix` 坐标映射；八核同时写，不同owner并发读写，同owner双读与写竞争
- prefix边界407、suffix边界0/31、offset439、保留地址440..511；非法请求不得误写合法位置
- 两parity原子返回，zero_mask和tag一致，下游连续暂停超过FIFO深度仍不丢、不重、不乱序
- XHAT全部3264有效字，四行重排、row50、最后组零填充；读写竞争按ready处理
- 3拍流水、连续读II=1、credit满/空、取消时仍有读在途、取消后新generation
- FACC-A/B同构映射及相同外部延迟，A写/B读和B写/A读的G-U交叠，even/odd尾行、valid控制首次ZERO

### 11.2 系统回归再验收

1. 单核真实内部七Job串行回归，核对矩阵及非矩阵结果；使用修复后的RoPE ROM
2. GCore真实Norm/量化、KV接收、XBC/KVB供数回归，外部TB负责上层供数和接收
3. 服务器执行1/9/18层八核联合长回归、随机反压、取消/错误重启；不把旧日志充作新映射验证
4. 对比改造前后的每Job周期、矩阵issue空洞和FIFO停顿；正常无竞争时不允许因RAM读延迟增加而周期性断供

### 11.3 最后仅综合 GCore 和一个完整 PCore

- 保留官方FP IP配置，不只综合裸Matrix；blackbox必须为0
- 分别输出 utilization、hierarchical utilization、RAM明细、原语清单、日志、DCP及输入SHA256
- KV主存目标16 URAM，XHAT目标4 URAM，Residual4 URAM；GCore约79 BRAM36 / 24 URAM
- FACC-A/B必须各为15 BRAM36等效、0 URAM；PCore约143 BRAM36 / 35 URAM
- 若综合发生拆分、复制或优化，先解释差异；不修改报告数字去匹配预算
- 两套结果齐全后再更新资源实测文档；8倍相加仍只叫线性外推
- 本阶段不做八核综合、opt/place/route，不以4ns综合约束宣称250MHz通过

## 12. 本轮核对范围

已核对当前两套完整综合报告、KV/XHAT/ACC源码接口和端口规则；对上述地址公式做了数学枚举：KV的28160个逻辑保留槽全部唯一，XHAT的3264个有效字全部唯一，无银行/地址别名。

地址枚举是静态数学检查。随后已完成RTL实施及两套新综合，并核实GCore 79 BRAM/24 URAM、PCore 143 BRAM/35 URAM；**没有执行新映射仿真**。端口仲裁、流水、取消和七Job功能仍需按第11节验收，详见[实测汇总](reports/resource_synth/RAM_Remap_20261019.md)。
