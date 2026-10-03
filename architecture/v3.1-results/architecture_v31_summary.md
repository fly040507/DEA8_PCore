# pi0 Action Expert FPGA V3.1 analytic summary

> Frozen analytic baseline; synthesis and board tests are still required.

## Frozen decisions

- 8 homogeneous cores; each core has one 8x64 INT8 MAC array (512 DSP).
- QK and PV reuse the same array and therefore execute sequentially.
- Online attention uses 2 EXP lanes and 4 Scale/FMA state lanes per core.
- O/Down SUM trees stream with MAC output; only 3 tail cycles are added per reduction.

## DSP budget

- Main arrays: 4096 DSP.
- Non-matrix nominal: 257 DSP.
- Non-matrix planned: 288 DSP.
- Planned total: 4384 / 4920 DSP; margin 536.
- Hard-cap total: 4416 DSP; margin 504.

## Attention timing

- QK matrix total: 31948 cycles.
- PV matrix total: 32116 cycles.
- Matrix lower bound: 64064 cycles.
- Final O normalization tail: 512 cycles.
- Online attention: 64576 cycles = 0.258304 ms.

## RMSNorm and layer timing

- One RMSNorm: 6592 cycles.
- Two RMSNorms: 13184 cycles.
- One layer: 401990 cycles = 1.607960 ms plus stalls.
- 18-layer step: 28.943280 ms plus stalls.
- 10 denoise steps: 289.432800 ms plus stalls.

## Attention buffer

- Per core: 48 KiB.
- Eight cores: 384 KiB.
- BRAM36 engineering budget: 144 blocks.
