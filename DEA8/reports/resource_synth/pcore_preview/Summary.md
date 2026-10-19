# 单个完整 PCore：RoPE 修复后的综合资源

2026-10-19，14:45完成。顶层 `dea8_pcore_top`，Vivado 2022.2，器件 `xcu50-fsvh2104-2-e`。包含共享 Matrix、真实 VPU/SFU、Mask/RoPE、存储、本核控制和外发。

**OOC综合完成，黑盒0、错误0、严重警告0。只测综合面积，未运行opt/place/route；4ns约束不代表250MHz签核。** 本机面积预览不代表八核功能准入通过。

## 单核实测

| 资源 | 使用量 | U50容量 | 占比 |
|---|---:|---:|---:|
| LUT | 104,573 | 871,680 | 12.00% |
| FF | 103,264 | 1,743,360 | 5.92% |
| DSP48E2 | 500 | 5,952 | 8.40% |
| BRAM36等效 | 128 | 1,344 | 9.52% |
| URAM | 51 | 640 | 7.97% |

BRAM原语：122 RAMB36E2 + 12 RAMB18E2。LUT包含99,543 Logic LUT、2,048 LUTRAM和2,982 SRL；这些子项不再额外相加。

## 一级模块开销

| 模块 | LUT | FF | DSP | BRAM36等效 | URAM |
|---|---:|---:|---:|---:|---:|
| control：Matrix、调度、缓存、外发 | 56,977 | 58,983 | 320 | 72.5 | 36 |
| VPU | 34,547 | 34,405 | 132 | 19.5 | 15 |
| SFU，含修复后的RoPE | 12,894 | 9,568 | 48 | 35.5 | 0 |
| 顶层与Mask | 155 | 308 | 0 | 0.5 | 0 |

Matrix内部MXU占11,612 LUT、256 DSP；DEQACC占21,992 LUT、64 DSP、15 BRAM36等效、32 URAM。两者已包含在control内，不能重复计入总量。

## RoPE 故障、修复与验证

- 原因：`$readmemh`读取原256-bit文件成功，但Vivado忽略了`initial`中从临时数组搬运到1024-bit系数数组的赋值（`Synth 8-311`），使`coefficients`无驱动并被裁掉。
- 修复：`Pcore/tools/pack_rope_rom.py`将原四字拼成一个1024-bit字，生成`rope_wide.mem`；RTL直接初始化最终ROM。`prepare_compute_vectors.py`同步生成两种格式。
- 原始`rope.mem`的1632个字保持不变；新408字文件逐bit逆映射核对通过。定制`ROPE_FILE`现在须提供1024-bit格式，不能直接传原256-bit文件。
- 资源：RoPE在整核中保留12 RAMB36E2 + 1 RAMB18E2，等效12.5块BRAM36。恒定位优化后有效宽度888bit，因此比先前14～15块的估算小。
- RTL与综合后真实RAM原语网表均PASS：全408地址、13,120次FP32系数比较、813个输出保持周期，覆盖flush及非法position恢复。
- 完整七Job未在本次RoPE修改后重跑；旧七Job日志属于修复前RTL，不冒充当前全核功能验收。

对比[修复前记录](Before_RoPE_Fix.md)：BRAM增加12.5、FF增加906、DSP/URAM不变，LUT减少69。LUT变化包含重新综合的映射差异，不能当作独立面积优化收益。[13:45分析](Analysis_20261019_1345.md)保留旧快照的热点分析。

## 八核加 GCore：线性外推

使用[当前GCore实测](../gcore_preview/Summary.md)：31,594 LUT、29,574 FF、109 DSP、211 BRAM36等效、4 URAM。

| 资源 | 8×PCore + GCore | U50占比 | 剩余 |
|---|---:|---:|---:|
| LUT | 868,178 | 99.60% | 3,502 |
| FF | 855,686 | 49.08% | 887,674 |
| DSP | 4,109 | 69.04% | 1,843 |
| BRAM36等效 | 1,235 | 91.89% | 109 |
| URAM | 412 | 64.38% | 228 |

**LUT已几乎耗尽，BRAM也偏紧。** 此处没有八核联合综合，也未计入跨核互连/缓冲、全局控制、HBM/PCIe和平台shell；不能据此判断系统可装入或可布通。下一步优先定位control/VPU/SFU的LUT热点并评估可用平台余量。

## 原始证据

- `utilization.rpt`、`utilization_hier.rpt`、`ram.rpt`、`primitives.tsv`
- `synth.log`、`scope.txt`
- `inputs_sha256.json`、`PASS.json`：记录85项综合时输入；manifest SHA256为`ed675a8003aaeddd47699c94e9eee31d78e3a8e7aa0615604ba3e0e9af701dce`。本目录是RAM改造前历史基线，不能作为当前源码的功能或面积验收
- `../rope_before.log`：独立旧实现失败复现；`../rope_after.log`及`../rope_after/`：修复后独立综合、RTL/网表仿真日志
- 回归TB：`Pcore/tb/compute/tb_rope_rom_native.sv`，SHA256为`32727a8af2367698f3f1beb939ad336dc47657ccbe40eab762e2bfd8b9659d1d`

本目录的旧检查点 `dea8_pcore_top_synth.dcp` 和重复 `ip_work/` 已于2026-10-19清理，报告、哈希及日志保留；当前检查点见 [RAM重映射结果](../pcore_ram_remap_20261019/Summary.md)。旧RoPE失败网表已删除，失败复现日志仍保留。

从DEA8目录复跑面积预览：`python run_dea8.py synth --target pcore --resource-preview`。Windows工具入口仍须加载Vivado `settings64.bat`。
