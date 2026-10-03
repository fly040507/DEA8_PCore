#!/usr/bin/env python3
"""Analytic V3 model for the pi0 Action Expert on AMD Alveo U50.

V3 removes the dedicated 8x64 K/V array.  The eight private 8x64 arrays first
compute one complete Q head each, then jointly compute the single K/V head by
splitting its 256 output channels into eight 32-channel slices.

K/V weights are prefetched as a complete layer while Q is running.  This
avoids depending on a per-tile HBM schedule whose margin collapses when only
32 of the 64 physical output columns are active.

The model separates:

* array/interconnect lower bound;
* vector-stage first-order cost;
* HBM tile-overlap checks;
* DSP, BRAM, and URAM allocation checks.

All results are estimates until synthesis and board measurements replace the
frequency, platform resource, and memory-bandwidth assumptions.
"""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import asdict, dataclass
from pathlib import Path


KIB = 1024
MIB = 1024 * KIB


@dataclass(frozen=True)
class Model:
    tokens: int = 51
    hidden: int = 1024
    ffn: int = 4096
    query_heads: int = 8
    kv_heads: int = 1
    head_dim: int = 256
    prefix_tokens: int = 816
    full_kv_tokens: int = 867
    layers: int = 18
    denoise_steps: int = 10

    @property
    def query_width(self) -> int:
        return self.query_heads * self.head_dim


@dataclass(frozen=True)
class Hardware:
    frequency_mhz: float = 250.0
    cores: int = 8
    array_m: int = 8
    array_n: int = 64
    k_tile: int = 256
    stream_width_bits: int = 256
    reduction_lane_bits: int = 32
    chip_dsp_total: int = 5952
    base5_dsp_available: int = 4920
    chip_uram_blocks: int = 640
    base5_uram_available: int = 544
    uram_block_bits: int = 288 * 1024
    uram_native_width_bits: int = 72
    uram_native_depth: int = 4096
    softmax_query_lanes_per_core: int = 8
    vector_bf16_lanes: int = 16

    @property
    def cycles_per_ms(self) -> float:
        return self.frequency_mhz * 1000.0

    @property
    def stream_bytes_per_cycle(self) -> int:
        return self.stream_width_bits // 8

    @property
    def design_side_gbps(self) -> float:
        return self.stream_bytes_per_cycle * self.frequency_mhz / 1000.0


def ceil_div(value: int, divisor: int) -> int:
    return (value + divisor - 1) // divisor


def cycles_to_ms(cycles: int, hardware: Hardware) -> float:
    return cycles / hardware.cycles_per_ms


def os_array_cycles(
    m: int,
    k: int,
    n: int,
    hardware: Hardware,
    *,
    active_array_n: int | None = None,
) -> int:
    """Output-stationary array cycles including fill/drain for each K tile."""

    m_tiles = ceil_div(m, hardware.array_m)
    n_tiles = ceil_div(n, hardware.array_n)
    drain_n = (
        hardware.array_n
        if active_array_n is None
        else active_array_n
    )
    k_cycles = 0
    for k_start in range(0, k, hardware.k_tile):
        k_extent = min(hardware.k_tile, k - k_start)
        k_cycles += (
            k_extent + hardware.array_m + drain_n - 2
        )
    return m_tiles * n_tiles * k_cycles


def pipelined_tree_cycles(
    elements: int,
    inputs: int,
    hardware: Hardware,
) -> int:
    """Cycles for a fully pipelined reduction tree.

    The 8-input tree accepts one 256-bit vector from every core each cycle.
    Its three adder levels operate concurrently, so latency is stream length
    plus pipeline depth, not stream length multiplied by depth.
    """

    lanes = hardware.stream_width_bits // hardware.reduction_lane_bits
    stream_cycles = ceil_div(elements, lanes)
    depth = ceil_div(int(math.ceil(math.log2(inputs))), 1)
    return stream_cycles + depth


def uram_blocks_for_stream(
    total_bytes: int,
    port_width_bits: int,
    hardware: Hardware,
) -> int:
    words = ceil_div(total_bytes * 8, port_width_bits)
    width_banks = ceil_div(
        port_width_bits, hardware.uram_native_width_bits
    )
    depth_banks = ceil_div(words, hardware.uram_native_depth)
    return width_banks * depth_banks


def hbm_allocation() -> list[dict[str, object]]:
    return [
        {"pc": "PC0", "content": "Core 0 private weights", "mc": "MC0"},
        {"pc": "PC2", "content": "Core 1 private weights", "mc": "MC1"},
        {"pc": "PC4", "content": "Core 2 private weights", "mc": "MC2"},
        {"pc": "PC6", "content": "Core 3 private weights", "mc": "MC3"},
        {"pc": "PC8", "content": "Shared K/V weights", "mc": "MC4"},
        {"pc": "PC12", "content": "Input / initial activations", "mc": "MC6"},
        {"pc": "PC16", "content": "Core 4 private weights", "mc": "MC8"},
        {"pc": "PC18", "content": "Core 5 private weights", "mc": "MC9"},
        {"pc": "PC20", "content": "Core 6 private weights", "mc": "MC10"},
        {"pc": "PC22", "content": "Core 7 private weights", "mc": "MC11"},
        {"pc": "PC24", "content": "Prefix KV HBM backing", "mc": "MC12"},
        {"pc": "PC28", "content": "Final output / debug", "mc": "MC14"},
    ]


def evaluate(model: Model, hardware: Hardware) -> dict[str, object]:
    q_n = model.query_width // hardware.cores
    kv_n = model.head_dim // hardware.cores
    ffn_n = model.ffn // hardware.cores

    q_cycles = os_array_cycles(
        model.tokens, model.hidden, q_n, hardware
    )
    kv_slice_one_cycles = os_array_cycles(
        model.tokens, model.hidden, kv_n, hardware
    )
    kv_slice_one_active_n_cycles = os_array_cycles(
        model.tokens,
        model.hidden,
        kv_n,
        hardware,
        active_array_n=kv_n,
    )
    distributed_kv_cycles = 2 * kv_slice_one_cycles
    distributed_kv_active_n_cycles = (
        2 * kv_slice_one_active_n_cycles
    )
    q_then_kv_cycles = q_cycles + distributed_kv_cycles
    q_then_kv_active_n_cycles = (
        q_cycles + distributed_kv_active_n_cycles
    )

    v2_shared_kv_one_cycles = os_array_cycles(
        model.tokens, model.hidden, model.head_dim, hardware
    )
    v2_parallel_q_kv_cycles = max(
        q_cycles, 2 * v2_shared_kv_one_cycles
    )

    kv_broadcast_bytes = (
        2 * model.full_kv_tokens * model.head_dim
    )
    kv_broadcast_cycles = ceil_div(
        kv_broadcast_bytes, hardware.stream_bytes_per_cycle
    )

    qk_cycles = os_array_cycles(
        model.tokens,
        model.head_dim,
        model.full_kv_tokens,
        hardware,
    )
    sv_cycles = os_array_cycles(
        model.tokens,
        model.full_kv_tokens,
        model.head_dim,
        hardware,
    )
    softmax_cycles = (
        ceil_div(model.tokens, hardware.array_m)
        * 3
        * model.full_kv_tokens
    )

    o_cycles = os_array_cycles(
        model.tokens,
        model.head_dim,
        model.hidden,
        hardware,
    )
    gate_cycles = os_array_cycles(
        model.tokens,
        model.hidden,
        ffn_n,
        hardware,
    )
    up_cycles = gate_cycles
    down_cycles = os_array_cycles(
        model.tokens,
        ffn_n,
        model.hidden,
        hardware,
    )

    one_sum_reduction_cycles = pipelined_tree_cycles(
        model.tokens * model.hidden,
        hardware.cores,
        hardware,
    )
    two_sum_reductions_cycles = 2 * one_sum_reduction_cycles

    reduction_depth = int(math.log2(hardware.cores))
    one_max_and_scale_broadcast = (
        model.tokens + reduction_depth + model.tokens
    )
    max_scale_control_cycles = 3 * one_max_and_scale_broadcast

    one_rmsnorm_cycles = (
        2
        * model.tokens
        * ceil_div(model.hidden, hardware.vector_bf16_lanes)
    )
    two_rmsnorm_cycles = 2 * one_rmsnorm_cycles
    q_rope_cycles = model.tokens * ceil_div(
        q_n, hardware.vector_bf16_lanes
    )
    k_rope_cycles = model.tokens * ceil_div(
        kv_n, hardware.vector_bf16_lanes
    )
    rope_cycles = q_rope_cycles + k_rope_cycles
    geglu_cycles = model.tokens * ceil_div(
        ffn_n, hardware.vector_bf16_lanes
    )
    two_residual_cycles = (
        2
        * model.tokens
        * ceil_div(model.hidden, hardware.vector_bf16_lanes)
    )

    array_interconnect_cycles = (
        q_then_kv_cycles
        + kv_broadcast_cycles
        + qk_cycles
        + sv_cycles
        + o_cycles
        + gate_cycles
        + up_cycles
        + down_cycles
        + two_sum_reductions_cycles
    )
    explicit_vector_cycles = (
        softmax_cycles
        + two_rmsnorm_cycles
        + rope_cycles
        + geglu_cycles
        + two_residual_cycles
        + max_scale_control_cycles
    )
    first_order_layer_cycles = (
        array_interconnect_cycles + explicit_vector_cycles
    )

    private_weight_tile_bytes = (
        hardware.k_tile * hardware.array_n
    )
    kv_global_weight_tile_bytes = hardware.k_tile * model.head_dim
    kv_slice_weight_tile_bytes = kv_global_weight_tile_bytes // hardware.cores
    tile_compute_reuse_cycles = (
        ceil_div(model.tokens, hardware.array_m)
        * (
            hardware.k_tile
            + hardware.array_m
            + hardware.array_n
            - 2
        )
    )
    kv_active_n_tile_compute_cycles = (
        ceil_div(model.tokens, hardware.array_m)
        * (
            hardware.k_tile
            + hardware.array_m
            + kv_n
            - 2
        )
    )
    private_tile_load_cycles = ceil_div(
        private_weight_tile_bytes, hardware.stream_bytes_per_cycle
    )
    kv_global_tile_load_cycles = ceil_div(
        kv_global_weight_tile_bytes, hardware.stream_bytes_per_cycle
    )

    private_weight_bytes_per_core_layer = (
        model.hidden * q_n
        + model.head_dim * model.hidden
        + model.hidden * ffn_n
        + model.hidden * ffn_n
        + ffn_n * model.hidden
    )
    kv_weight_bytes_per_layer = (
        2 * model.hidden * model.head_dim
    )
    kv_weight_scale_bytes_per_layer = (
        2 * model.head_dim * 2
    )
    kv_layer_prefetch_bytes = (
        kv_weight_bytes_per_layer
        + kv_weight_scale_bytes_per_layer
    )
    kv_layer_prefetch_cycles = ceil_div(
        kv_layer_prefetch_bytes,
        hardware.stream_bytes_per_cycle,
    )
    kv_layer_prefetch_margin_cycles = (
        q_cycles - kv_layer_prefetch_cycles
    )
    kv_layer_prefetch_occupancy_percent = (
        100 * kv_layer_prefetch_cycles / q_cycles
    )
    kv_tile_required_efficiency_percent = (
        100
        * kv_global_tile_load_cycles
        / kv_active_n_tile_compute_cycles
    )
    kv_layer_weight_buffer_bytes_per_core = (
        kv_weight_bytes_per_layer // hardware.cores
    )

    shared_activation_bytes = model.tokens * model.hidden * 2
    q_buffer_bytes = model.tokens * q_n * 2
    gate_or_geglu_buffer_bytes = model.tokens * ffn_n * 2
    score_tile_bytes = (
        hardware.array_m * model.full_kv_tokens * 4
    )
    probability_tile_bytes = (
        hardware.array_m * model.full_kv_tokens * 2
    )
    psum_slice_bytes = (
        model.tokens * hardware.array_n * 4
    )
    local_kv_bytes_per_core = (
        2 * model.full_kv_tokens * model.head_dim
    )
    prefix_kv_bytes = (
        2
        * model.prefix_tokens
        * model.head_dim
        * model.layers
    )

    per_core_bram_like_bytes = (
        2 * private_weight_tile_bytes
        + kv_layer_weight_buffer_bytes_per_core
        + hardware.array_m * hardware.k_tile
        + psum_slice_bytes
        + q_buffer_bytes
        + 2 * gate_or_geglu_buffer_bytes
        + score_tile_bytes
        + probability_tile_bytes
    )

    prefix_k_bytes = (
        model.prefix_tokens * model.head_dim * model.layers
    )
    local_k_bytes = model.full_kv_tokens * model.head_dim
    prefix_k_blocks = uram_blocks_for_stream(
        prefix_k_bytes, hardware.stream_width_bits, hardware
    )
    prefix_kv_blocks = 2 * prefix_k_blocks
    local_k_blocks_per_core = uram_blocks_for_stream(
        local_k_bytes, 512, hardware
    )
    local_kv_blocks_all_cores = (
        2 * local_k_blocks_per_core * hardware.cores
    )
    planned_uram_blocks = (
        prefix_kv_blocks + local_kv_blocks_all_cores
    )

    main_array_dsps = (
        hardware.cores * hardware.array_m * hardware.array_n
    )

    return {
        "architecture": {
            "cores": hardware.cores,
            "array_per_core": f"{hardware.array_m}x{hardware.array_n}",
            "k_tile": hardware.k_tile,
            "q_output_channels_per_core": q_n,
            "kv_output_channels_per_core": kv_n,
            "ffn_channels_per_core": ffn_n,
            "dedicated_kv_array": False,
        },
        "dsp": {
            "main_array_dsps": main_array_dsps,
            "chip_total": hardware.chip_dsp_total,
            "chip_margin": hardware.chip_dsp_total - main_array_dsps,
            "chip_margin_percent": (
                100
                * (hardware.chip_dsp_total - main_array_dsps)
                / hardware.chip_dsp_total
            ),
            "base5_available": hardware.base5_dsp_available,
            "base5_margin": hardware.base5_dsp_available - main_array_dsps,
            "base5_margin_percent": (
                100
                * (hardware.base5_dsp_available - main_array_dsps)
                / hardware.base5_dsp_available
            ),
            "v2_main_array_dsps": main_array_dsps
            + hardware.array_m * hardware.array_n,
            "v3_saved_dsps": hardware.array_m * hardware.array_n,
        },
        "cycles": {
            "q": q_cycles,
            "distributed_k_one": kv_slice_one_cycles,
            "distributed_v_one": kv_slice_one_cycles,
            "distributed_k_one_active_n": (
                kv_slice_one_active_n_cycles
            ),
            "distributed_v_one_active_n": (
                kv_slice_one_active_n_cycles
            ),
            "q_then_kv": q_then_kv_cycles,
            "q_then_kv_active_n": q_then_kv_active_n_cycles,
            "v2_parallel_q_shared_kv_phase": v2_parallel_q_kv_cycles,
            "phase_saved_vs_v2": (
                v2_parallel_q_kv_cycles - q_then_kv_cycles
            ),
            "kv_broadcast": kv_broadcast_cycles,
            "qk": qk_cycles,
            "softmax_three_pass": softmax_cycles,
            "sv": sv_cycles,
            "o": o_cycles,
            "gate": gate_cycles,
            "up": up_cycles,
            "down": down_cycles,
            "one_pipelined_sum_reduction": one_sum_reduction_cycles,
            "two_pipelined_sum_reductions": two_sum_reductions_cycles,
            "max_scale_control": max_scale_control_cycles,
            "two_rmsnorm": two_rmsnorm_cycles,
            "rope": rope_cycles,
            "geglu": geglu_cycles,
            "two_residual": two_residual_cycles,
            "array_interconnect_lower_bound": array_interconnect_cycles,
            "explicit_vector_first_order": explicit_vector_cycles,
            "first_order_layer": first_order_layer_cycles,
        },
        "latency_ms": {
            key: cycles_to_ms(value, hardware)
            for key, value in {
                "q": q_cycles,
                "distributed_kv": distributed_kv_cycles,
                "distributed_kv_active_n": (
                    distributed_kv_active_n_cycles
                ),
                "q_then_kv": q_then_kv_cycles,
                "q_then_kv_active_n": q_then_kv_active_n_cycles,
                "phase_saved_vs_v2": (
                    v2_parallel_q_kv_cycles - q_then_kv_cycles
                ),
                "kv_broadcast": kv_broadcast_cycles,
                "qk": qk_cycles,
                "softmax_three_pass": softmax_cycles,
                "sv": sv_cycles,
                "o": o_cycles,
                "gate": gate_cycles,
                "up": up_cycles,
                "down": down_cycles,
                "two_pipelined_sum_reductions": (
                    two_sum_reductions_cycles
                ),
                "array_interconnect_lower_bound": (
                    array_interconnect_cycles
                ),
                "explicit_vector_first_order": explicit_vector_cycles,
                "first_order_layer": first_order_layer_cycles,
                "first_order_18_layer_step": (
                    first_order_layer_cycles * model.layers
                ),
                "first_order_10_step": (
                    first_order_layer_cycles
                    * model.layers
                    * model.denoise_steps
                ),
            }.items()
        },
        "hbm": {
            "stream_width_bits": hardware.stream_width_bits,
            "bytes_per_cycle": hardware.stream_bytes_per_cycle,
            "design_side_gbps_at_250mhz": hardware.design_side_gbps,
            "allocation": hbm_allocation(),
            "private_weight_bytes_per_core_layer": (
                private_weight_bytes_per_core_layer
            ),
            "private_weight_load_ms_per_core_layer": (
                private_weight_bytes_per_core_layer
                / (hardware.design_side_gbps * 1e9)
                * 1000
            ),
            "kv_weight_bytes_per_layer": kv_weight_bytes_per_layer,
            "kv_weight_scale_bytes_per_layer": (
                kv_weight_scale_bytes_per_layer
            ),
            "kv_weight_load_ms_per_layer": (
                kv_weight_bytes_per_layer
                / (hardware.design_side_gbps * 1e9)
                * 1000
            ),
            "kv_layer_prefetch_bytes": kv_layer_prefetch_bytes,
            "kv_layer_prefetch_cycles": kv_layer_prefetch_cycles,
            "kv_layer_prefetch_margin_cycles": (
                kv_layer_prefetch_margin_cycles
            ),
            "kv_layer_prefetch_occupancy_percent": (
                kv_layer_prefetch_occupancy_percent
            ),
            "kv_layer_prefetch_hidden_in_q": (
                kv_layer_prefetch_margin_cycles >= 0
            ),
            "private_weight_tile_bytes": private_weight_tile_bytes,
            "kv_global_weight_tile_bytes": kv_global_weight_tile_bytes,
            "kv_slice_weight_tile_bytes_per_core": (
                kv_slice_weight_tile_bytes
            ),
            "private_tile_load_cycles": private_tile_load_cycles,
            "kv_global_tile_load_cycles": kv_global_tile_load_cycles,
            "tile_compute_reuse_cycles": tile_compute_reuse_cycles,
            "kv_active_n_tile_compute_cycles": (
                kv_active_n_tile_compute_cycles
            ),
            "kv_tile_required_efficiency_percent": (
                kv_tile_required_efficiency_percent
            ),
            "kv_tile_margin_cycles_active_n": (
                kv_active_n_tile_compute_cycles
                - kv_global_tile_load_cycles
            ),
            "private_tile_hidden": (
                private_tile_load_cycles < tile_compute_reuse_cycles
            ),
            "kv_tile_robust": False,
            "kv_tile_risk_note": (
                "A 64 KiB tile has only 10 ideal cycles of margin "
                "when the 32 active columns drain in 294 cycles. "
                "The frozen design therefore prefetches the full "
                "K/V layer during Q."
            ),
        },
        "buffers": {
            "shared_activation_bytes": shared_activation_bytes,
            "private_weight_ping_pong_bytes_per_core": (
                2 * private_weight_tile_bytes
            ),
            "kv_layer_weight_buffer_bytes_per_core": (
                kv_layer_weight_buffer_bytes_per_core
            ),
            "activation_tile_bytes_per_core": (
                hardware.array_m * hardware.k_tile
            ),
            "int32_psum_slice_bytes_per_core": psum_slice_bytes,
            "q_buffer_bytes_per_core": q_buffer_bytes,
            "gate_buffer_bytes_per_core": gate_or_geglu_buffer_bytes,
            "geglu_buffer_bytes_per_core": gate_or_geglu_buffer_bytes,
            "score_tile_bytes_per_core": score_tile_bytes,
            "probability_tile_bytes_per_core": probability_tile_bytes,
            "bram_like_bytes_per_core": per_core_bram_like_bytes,
            "bram_like_bytes_all_cores": (
                per_core_bram_like_bytes * hardware.cores
            ),
            "prefix_kv_bytes_all_layers": prefix_kv_bytes,
            "local_kv_bytes_per_core": local_kv_bytes_per_core,
            "local_kv_bytes_all_cores": (
                local_kv_bytes_per_core * hardware.cores
            ),
            "prefix_plus_local_kv_bytes": (
                prefix_kv_bytes
                + local_kv_bytes_per_core * hardware.cores
            ),
        },
        "uram": {
            "prefix_kv_blocks_256bit": prefix_kv_blocks,
            "local_kv_blocks_512bit_all_cores": (
                local_kv_blocks_all_cores
            ),
            "planned_blocks": planned_uram_blocks,
            "base5_available_blocks": hardware.base5_uram_available,
            "base5_margin_blocks": (
                hardware.base5_uram_available - planned_uram_blocks
            ),
            "note": (
                "Banking estimate uses URAM288 72-bit x 4096 primitives; "
                "synthesis may add padding and FIFO blocks."
            ),
        },
    }


def render_summary(
    model: Model,
    hardware: Hardware,
    result: dict[str, object],
) -> str:
    dsp = result["dsp"]
    cycles = result["cycles"]
    latency = result["latency_ms"]
    hbm = result["hbm"]
    buffers = result["buffers"]
    uram = result["uram"]

    hbm_rows = "\n".join(
        f'| {row["pc"]} | {row["mc"]} | {row["content"]} |'
        for row in hbm["allocation"]
    )

    return f"""# pi0 Action Expert FPGA V3 analytic summary

> V3 uses eight time-shared 8x64 arrays.  It is an analytic architecture
> estimate, not a synthesis or board result.

## Frozen topology

- 8 cores, one complete 256-d query head per core.
- Each core: 8x64 INT8 MAC array, K tile 256, 512 DSP.
- K/V: eight cores jointly compute one 256-d KV head as eight 32-d slices.
- Dedicated K/V array: removed.
- Main array DSP: {dsp["main_array_dsps"]}.
- Physical-chip DSP margin: {dsp["chip_margin"]} ({dsp["chip_margin_percent"]:.2f}%).
- base_5 dynamic-region DSP margin: {dsp["base5_margin"]} ({dsp["base5_margin_percent"]:.2f}%).

## Key cycle equations

```text
Q = 7 * 4 * 4 * (256 + 8 + 64 - 2)
  = {cycles["q"]} cycles

K or V per core = 7 * 1 * 4 * (256 + 8 + 64 - 2)
                = {cycles["distributed_k_one"]} cycles

Q then K then V = {cycles["q_then_kv"]} cycles
                = {latency["q_then_kv"]:.6f} ms
```

The frozen schedule keeps the physical 64-column fill/drain term.  If RTL
can bypass the inactive upper 32 columns, K or V becomes
{cycles["distributed_k_one_active_n"]} cycles and Q+K+V becomes
{cycles["q_then_kv_active_n"]} cycles
({latency["q_then_kv_active_n"]:.6f} ms).  This is an optimization target,
not the baseline timing claim.

The V2 Q/shared-KV phase was {cycles["v2_parallel_q_shared_kv_phase"]} cycles.
V3 saves {cycles["phase_saved_vs_v2"]} cycles
({latency["phase_saved_vs_v2"]:.6f} ms) in that phase and saves 512 DSP.

For O/Down, the fully pipelined 8-input tree is:

```text
payload = 51 * 1024 / 8 INT32 lanes = 6528 cycles
depth   = log2(8) = 3 cycles
one reduction = 6528 + 3 = {cycles["one_pipelined_sum_reduction"]} cycles
```

It is not `6528 * 3`; all three tree levels work concurrently after fill.

## Latency

| Stage | ms |
|---|---:|
| Q then distributed K/V | {latency["q_then_kv"]:.6f} |
| KV multicast | {latency["kv_broadcast"]:.6f} |
| QK | {latency["qk"]:.6f} |
| Three-pass Softmax | {latency["softmax_three_pass"]:.6f} |
| SxV | {latency["sv"]:.6f} |
| O | {latency["o"]:.6f} |
| Gate | {latency["gate"]:.6f} |
| Up | {latency["up"]:.6f} |
| Down | {latency["down"]:.6f} |
| Two pipelined SUM reductions | {latency["two_pipelined_sum_reductions"]:.6f} |
| Array/interconnect lower bound | {latency["array_interconnect_lower_bound"]:.6f} |
| Explicit vector-stage first order | {latency["explicit_vector_first_order"]:.6f} |
| First-order layer total | {latency["first_order_layer"]:.6f} |
| 18-layer denoise step | {latency["first_order_18_layer_step"]:.6f} |
| 10 denoise steps | {latency["first_order_10_step"]:.6f} |

The vector estimate explicitly includes three-pass Softmax, two RMSNorms,
RoPE, GeGLU, two residual passes, and three MAX/scale-control operations.
Overlap and final timing closure are still pending.

## HBM allocation

| PC | MC | Data |
|---|---|---|
{hbm_rows}

At 256 bits and 250 MHz, the design-side ceiling is:

```text
32 Byte/cycle * 250 MHz = {hbm["design_side_gbps_at_250mhz"]:.1f} GB/s
```

Private-tile overlap check:

| Item | Load cycles | Compute reuse cycles | Hidden |
|---|---:|---:|---|
| 16 KiB private tile | {hbm["private_tile_load_cycles"]} | {hbm["tile_compute_reuse_cycles"]} | {hbm["private_tile_hidden"]} |

K/V uses a full-layer prefetch during Q:

```text
K/V INT8 payload             = {hbm["kv_weight_bytes_per_layer"] / KIB:.0f} KiB
K/V BF16 scale metadata      = {hbm["kv_weight_scale_bytes_per_layer"] / KIB:.0f} KiB
PC8 transfer                 = {hbm["kv_layer_prefetch_bytes"] / KIB:.0f} KiB
transfer cycles              = {hbm["kv_layer_prefetch_cycles"]}
Q compute window             = {cycles["q"]}
margin                       = {hbm["kv_layer_prefetch_margin_cycles"]} cycles
PC8 occupancy in Q window    = {hbm["kv_layer_prefetch_occupancy_percent"]:.2f}%
```

The rejected per-tile alternative loads a 64 KiB tile in
{hbm["kv_global_tile_load_cycles"]} cycles.  With 32 active columns its
compute window is only {hbm["kv_active_n_tile_compute_cycles"]} cycles, so it
would require {hbm["kv_tile_required_efficiency_percent"]:.2f}% sustained AXI
efficiency and has only {hbm["kv_tile_margin_cycles_active_n"]} ideal cycles
of margin.

## Buffer and URAM

| Item | Capacity |
|---|---:|
| Shared BF16 activation | {buffers["shared_activation_bytes"] / KIB:.2f} KiB |
| Per-core private weight ping/pong | {buffers["private_weight_ping_pong_bytes_per_core"] / KIB:.2f} KiB |
| Per-core K/V layer weight buffer | {buffers["kv_layer_weight_buffer_bytes_per_core"] / KIB:.2f} KiB |
| Per-core INT32 psum slice | {buffers["int32_psum_slice_bytes_per_core"] / KIB:.2f} KiB |
| Per-core Q buffer | {buffers["q_buffer_bytes_per_core"] / KIB:.2f} KiB |
| Per-core Gate or GeGLU buffer | {buffers["gate_buffer_bytes_per_core"] / KIB:.2f} KiB |
| Per-core score tile | {buffers["score_tile_bytes_per_core"] / KIB:.2f} KiB |
| Per-core probability tile | {buffers["probability_tile_bytes_per_core"] / KIB:.2f} KiB |
| Per-core BRAM-like total | {buffers["bram_like_bytes_per_core"] / KIB:.2f} KiB |
| All-core BRAM-like total | {buffers["bram_like_bytes_all_cores"] / MIB:.4f} MiB |
| Prefix KV, 18 layers | {buffers["prefix_kv_bytes_all_layers"] / MIB:.4f} MiB |
| Local current-layer KV, 8 copies | {buffers["local_kv_bytes_all_cores"] / MIB:.4f} MiB |
| Prefix plus local KV | {buffers["prefix_plus_local_kv_bytes"] / MIB:.4f} MiB |

Estimated URAM banking:

```text
Prefix K/V at 256-bit: {uram["prefix_kv_blocks_256bit"]} URAM
8 local K/V caches at 512-bit: {uram["local_kv_blocks_512bit_all_cores"]} URAM
Total: {uram["planned_blocks"]} / {uram["base5_available_blocks"]} base_5 URAM
Margin: {uram["base5_margin_blocks"]} URAM
```
"""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "v3-results",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    output_dir: Path = args.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)

    model = Model()
    hardware = Hardware()
    result = evaluate(model, hardware)
    payload = {
        "model": asdict(model),
        "hardware": asdict(hardware),
        "result": result,
        "provenance": {
            "model_dimensions": "Mentor report and OpenPI code",
            "chip_resources": "Mentor report / AMD U50 documentation",
            "base5_resources": "AMD Vitis U50 base_5 platform documentation",
            "cycle_model": "Analytic output-stationary and streaming model",
            "frequency": "250 MHz target; pending timing closure",
            "dsp_packing": "One signed INT8 MAC per DSP conservative baseline",
        },
    }

    (output_dir / "architecture_v3_results.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    (output_dir / "architecture_v3_summary.md").write_text(
        render_summary(model, hardware, result),
        encoding="utf-8",
    )

    print(
        json.dumps(
            {
                "main_array_dsps": result["dsp"]["main_array_dsps"],
                "base5_dsp_margin": result["dsp"]["base5_margin"],
                "q_then_kv_ms": round(
                    result["latency_ms"]["q_then_kv"], 6
                ),
                "array_interconnect_lower_bound_ms": round(
                    result["latency_ms"][
                        "array_interconnect_lower_bound"
                    ],
                    6,
                ),
                "first_order_layer_ms": round(
                    result["latency_ms"]["first_order_layer"], 6
                ),
                "planned_uram_blocks": result["uram"]["planned_blocks"],
            },
            ensure_ascii=False,
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
