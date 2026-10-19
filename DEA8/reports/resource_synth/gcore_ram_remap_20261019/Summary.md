# GCore RAM重映射综合

2026-10-19 15:56完成，Vivado 2022.2，U50 `xcu50-fsvh2104-2-e`，完整顶层`dea8_gcore`，内部官方rsqrt启用。

**综合通过，黑盒0、错误0、严重警告0。按用户要求未重跑仿真；没有布局布线或250MHz签核。** 357条普通警告不能解释为零警告；主要需结合原始日志查看未使用字段等信息。

## 完整顶层资源

| 资源 | 使用 | 整器件占比 | 改造前 | 变化 |
|---|---:|---:|---:|---:|
| LUT | 29782 | 3.42% | 31594 | -1812 |
| FF | 33198 | 1.90% | 29574 | +3624 |
| DSP48E2 | 109 | 1.83% | 109 | 0 |
| BRAM36等效 | 79 | 5.88% | 211 | -132 |
| URAM | 24 | 3.75% | 4 | +20 |

BRAM为77 RAMB36E2 + 4 RAMB18E2。LUT包含28298逻辑LUT和1484 SRL；分布式RAM LUT为0、锁存器为0。LUT变化包含银行重组及重新映射，不是本轮开展了独立LUT优化。

## 存储映射核对

| 存储 | 本次实测 | 是否符合方案 |
|---|---|---|
| KV主存 | 8个owner银行，每个2 URAM，合计16 URAM | 是 |
| KV响应队列 | 288bit×8，4 BRAM36 | 是 |
| XHAT主存 | 2个双读银行，每个2 URAM，合计4 URAM | 是 |
| XHAT响应队列 | 563bit×8，8 BRAM36 | 是 |
| RESID | 4 URAM | 保持 |
| 其他存储 | 67 BRAM36等效 | 保持总数 |

KV声明4096×144、XHAT声明2048×144；高8bit补零被优化，报告端口有效宽度为136，物理URAM数量不变。KV逻辑保留容量利用率约81.16%；XHAT含尾行槽约38.37%，只计51行有效数据约37.63%。

两个读端口、写竞争ready、3拍RAM读流水、8项响应信用已在RTL实现，但本次综合不证明它们的运行时功能正确。prefix仍须上层预置；TB专用`preload_prefix`不构成硬件DMA。

## 证据和复现

- [资源总表](utilization.rpt)、[层次表](utilization_hier.rpt)、[RAM明细](ram.rpt)、[原语计数](primitives.tsv)
- [运行范围](scope.txt)、[输入哈希](inputs_sha256.json)、[成功记录](PASS.json)、[综合日志](synth.log)
- 输入manifest SHA256：`b62f7d63a9ae9559298192f1866b4b8b516331f22b9553224f40d5948dce382a`；运行前后输入一致
- 保留[改造前实测](../gcore_preview/Summary.md)，不覆盖原报告

在DEA8目录加载Vivado环境后执行：

```text
python run_dea8.py synth --target gcore --resource-preview --report-tag ram_remap_20261019
```

`simulation_gate_passed=false`明确表示本轮没有执行功能准入；新RAM映射的单核、GCore和八核功能回归仍待后续执行。
