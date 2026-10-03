# pi0 Action Expert FPGA V3 analytic summary

> V3 uses eight time-shared 8x64 arrays.  It is an analytic architecture
> estimate, not a synthesis or board result.

## Frozen topology

- 8 cores, one complete 256-d query head per core.
- Each core: 8x64 INT8 MAC array, K tile 256, 512 DSP.
- K/V: eight cores jointly compute one 256-d KV head as eight 32-d slices.
- Dedicated K/V array: removed.
- Main array DSP: 4096.
- Physical-chip DSP margin: 1856 (31.18%).
- base_5 dynamic-region DSP margin: 824 (16.75%).

## Key cycle equations

```text
Q = 7 * 4 * 4 * (256 + 8 + 64 - 2)
  = 36512 cycles

K or V per core = 7 * 1 * 4 * (256 + 8 + 64 - 2)
                = 9128 cycles

Q then K then V = 54768 cycles
                = 0.219072 ms
```

The frozen schedule keeps the physical 64-column fill/drain term.  If RTL
can bypass the inactive upper 32 columns, K or V becomes
8232 cycles and Q+K+V becomes
52976 cycles
(0.211904 ms).  This is an optimization target,
not the baseline timing claim.

The V2 Q/shared-KV phase was 73024 cycles.
V3 saves 18256 cycles
(0.073024 ms) in that phase and saves 512 DSP.

For O/Down, the fully pipelined 8-input tree is:

```text
payload = 51 * 1024 / 8 INT32 lanes = 6528 cycles
depth   = log2(8) = 3 cycles
one reduction = 6528 + 3 = 6531 cycles
```

It is not `6528 * 3`; all three tree levels work concurrently after fill.

## Latency

| Stage | ms |
|---|---:|
| Q then distributed K/V | 0.219072 |
| KV multicast | 0.055488 |
| QK | 0.127792 |
| Three-pass Softmax | 0.072828 |
| SxV | 0.128464 |
| O | 0.146048 |
| Gate | 0.292096 |
| Up | 0.292096 |
| Down | 0.292096 |
| Two pipelined SUM reductions | 0.052248 |
| Array/interconnect lower bound | 1.605400 |
| Explicit vector-stage first order | 0.162624 |
| First-order layer total | 1.768024 |
| 18-layer denoise step | 31.824432 |
| 10 denoise steps | 318.244320 |

The vector estimate explicitly includes three-pass Softmax, two RMSNorms,
RoPE, GeGLU, two residual passes, and three MAX/scale-control operations.
Overlap and final timing closure are still pending.

## HBM allocation

| PC | MC | Data |
|---|---|---|
| PC0 | MC0 | Core 0 private weights |
| PC2 | MC1 | Core 1 private weights |
| PC4 | MC2 | Core 2 private weights |
| PC6 | MC3 | Core 3 private weights |
| PC8 | MC4 | Shared K/V weights |
| PC12 | MC6 | Input / initial activations |
| PC16 | MC8 | Core 4 private weights |
| PC18 | MC9 | Core 5 private weights |
| PC20 | MC10 | Core 6 private weights |
| PC22 | MC11 | Core 7 private weights |
| PC24 | MC12 | Prefix KV HBM backing |
| PC28 | MC14 | Final output / debug |

At 256 bits and 250 MHz, the design-side ceiling is:

```text
32 Byte/cycle * 250 MHz = 8.0 GB/s
```

Private-tile overlap check:

| Item | Load cycles | Compute reuse cycles | Hidden |
|---|---:|---:|---|
| 16 KiB private tile | 512 | 2282 | True |

K/V uses a full-layer prefetch during Q:

```text
K/V INT8 payload             = 512 KiB
K/V BF16 scale metadata      = 1 KiB
PC8 transfer                 = 513 KiB
transfer cycles              = 16416
Q compute window             = 36512
margin                       = 20096 cycles
PC8 occupancy in Q window    = 44.96%
```

The rejected per-tile alternative loads a 64 KiB tile in
2048 cycles.  With 32 active columns its
compute window is only 2058 cycles, so it
would require 99.51% sustained AXI
efficiency and has only 10 ideal cycles
of margin.

## Buffer and URAM

| Item | Capacity |
|---|---:|
| Shared BF16 activation | 102.00 KiB |
| Per-core private weight ping/pong | 32.00 KiB |
| Per-core K/V layer weight buffer | 64.00 KiB |
| Per-core INT32 psum slice | 12.75 KiB |
| Per-core Q buffer | 25.50 KiB |
| Per-core Gate or GeGLU buffer | 51.00 KiB |
| Per-core score tile | 27.09 KiB |
| Per-core probability tile | 13.55 KiB |
| Per-core BRAM-like total | 278.89 KiB |
| All-core BRAM-like total | 2.1788 MiB |
| Prefix KV, 18 layers | 7.1719 MiB |
| Local current-layer KV, 8 copies | 3.3867 MiB |
| Prefix plus local KV | 10.5586 MiB |

Estimated URAM banking:

```text
Prefix K/V at 256-bit: 232 URAM
8 local K/V caches at 512-bit: 128 URAM
Total: 360 / 544 base_5 URAM
Margin: 184 URAM
```
