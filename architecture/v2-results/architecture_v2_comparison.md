# pi0 Action Expert FPGA V2 analytic comparison

> Analytic array/interconnect estimate. It excludes RMSNorm, RoPE,
> GeGLU, residual, host overhead, and timing closure effects.

## Fixed model

- Tokens: 51
- Hidden / FFN: 1024 / 4096
- Q heads / KV heads / head dimension: 8 / 1 / 256
- Prefix / full KV tokens: 816 / 867
- Layers / denoise steps: 18 / 10

## Operator mapping

| Operator | GEMM | Split | Cross-core merge | MMAC |
| --- | --- | --- | --- | --- |
| Q | [51,1024] x [1024,2048] | N / query-head | disjoint write | 106.955 |
| K | [51,1024] x [1024,256] | shared | broadcast | 13.369 |
| V | [51,1024] x [1024,256] | shared | broadcast | 13.369 |
| O | [51,2048] x [2048,1024] | K / query-head | sum reduction | 106.955 |
| Gate | [51,1024] x [1024,4096] | N | disjoint write | 213.910 |
| Up | [51,1024] x [1024,4096] | N | disjoint write | 213.910 |
| Down | [51,4096] x [4096,1024] | K | sum reduction | 213.910 |

## Fixed aggregate private-DSP comparison

| Cores | Array/core | Private DSP | Main MAC DSP | DSP margin | Heads/core | Reduction depth | Head-split ms | Layer ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 4 | 32x32 | 4096 | 4608 | 22.6% | 2 | 2 | 0.000 | 1.877 |
| 8 | 8x64 | 4096 | 4608 | 22.6% | 1 | 3 | 0.000 | 1.783 |
| 16 | 8x32 | 4096 | 4608 | 22.6% | 0.5 | 4 | 0.044 | 1.784 |

## Stage latency

| Cores | Q | Shared K/V | KV bcast | Attention | O | Gate | Up | Down | O+Down reduce |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 4 | 0.163 | 0.292 | 0.055 | 0.285 | 0.163 | 0.326 | 0.326 | 0.326 | 0.104 |
| 8 | 0.146 | 0.292 | 0.055 | 0.256 | 0.146 | 0.292 | 0.292 | 0.292 | 0.157 |
| 16 | 0.132 | 0.292 | 0.055 | 0.288 | 0.149 | 0.263 | 0.263 | 0.263 | 0.209 |

Q and shared K/V overlap, so the layer total uses their maximum.

## Identical 8x64 core comparison

| Cores | Array/core | Private DSP | Main MAC DSP | Fits U50 | Layer ms |
| --- | --- | --- | --- | --- | --- |
| 4 | 8x64 | 2048 | 2560 | yes | 2.973 |
| 8 | 8x64 | 4096 | 4608 | yes | 1.783 |
| 16 | 8x64 | 8192 | 8704 | no | 1.269 |

## Frozen V1 tile

- 8 cores, one complete query head per core.
- Private array/core: 8x64 PEs, K tile 256.
- Shared K/V array: 8x64 PEs.
- Main MAC DSPs: 8x512 + 512 = 4608.
- DSP margin: 1344 / 5952.
- One INT8 MAC per DSP is assumed until packing is synthesized.
