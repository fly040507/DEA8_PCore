# V3.2 physical architecture analytic summary

> Analytic estimate at 250 MHz; not a synthesis, timing, link, or board result.

## Resource totals

- DSP: 4384 / 4920, margin 536.
- BRAM36: 864 planned; nominal chip comparison 1344, margin 480.
- URAM: 360 / 544, margin 184.
- Per core: 534 nominal DSP, 96 BRAM36, 16 URAM.

## Timing

- One layer: 401990 cycles = 1.607960 ms plus stalls.
- 18 layers: 7235820 cycles = 28.943280 ms plus stalls.
- 10 denoise steps: 72358200 cycles = 289.432800 ms plus stalls.
- K/V prefetch: 16416 cycles inside Q's 36512 cycles; margin 20096.

## Important correction

- Shared BF16 activation storage is two complete 102 KiB banks (204 KiB total).
- A separate 51 KiB shared INT8 normalized-activation buffer lets Q/K/V and Gate/Up reuse one quantization result.
- The 401990-cycle timing scope is the Transformer body only; pre/post projections remain outside this baseline.
