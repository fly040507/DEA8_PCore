#!/usr/bin/env python3
"""V3.3 analytic model for the pi0 Action Expert FPGA architecture.

The model freezes the fused K/V schedule, buffer banking, interconnect widths,
quantization metadata, and resource/timing budgets. Results remain analytic
estimates until HLS/RTL synthesis, Vitis linking, timing closure, and board test.
"""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

KIB = 1024
MIB = 1024 * KIB


@dataclass(frozen=True)
class Model:
    suffix_tokens: int = 51
    prefix_tokens: int = 816
    total_kv_tokens: int = 867
    hidden: int = 1024
    query_heads: int = 8
    head_dim: int = 256
    ffn: int = 4096
    layers: int = 18
    denoise_steps: int = 10


@dataclass(frozen=True)
class Hardware:
    frequency_mhz: int = 250
    cores: int = 8
    array_m: int = 8
    array_n: int = 64
    k_tile: int = 256
    stream_bits: int = 256
    base5_dsp_available: int = 4920
    base5_bram36_available: int = 1116
    base5_uram_available: int = 544
    chip_bram36_nominal: int = 1344

    @property
    def bytes_per_cycle(self) -> int:
        return self.stream_bits // 8

    @property
    def cycles_per_ms(self) -> int:
        return self.frequency_mhz * 1000


def ceil_div(value: int, divisor: int) -> int:
    return (value + divisor - 1) // divisor


def os_cycles(m: int, k: int, n: int, hw: Hardware) -> int:
    """Output-stationary 8x64 array estimate with K tiled in time."""
    k_work = 0
    for start in range(0, k, hw.k_tile):
        extent = min(hw.k_tile, k - start)
        k_work += extent + hw.array_m + hw.array_n - 2
    return ceil_div(m, hw.array_m) * ceil_div(n, hw.array_n) * k_work


def uram_blocks(total_bytes: int, port_bits: int) -> int:
    words = ceil_div(total_bytes * 8, port_bits)
    return ceil_div(port_bits, 72) * ceil_div(words, 4096)


def mib(value: float) -> float:
    return value / MIB


def ms(cycles: int, hw: Hardware) -> float:
    return cycles / hw.cycles_per_ms


def build_timeline(stage_cycles: list[tuple[str, str, str, int, str]]) -> list[dict[str, Any]]:
    timeline: list[dict[str, Any]] = []
    cursor = 0
    for stage_id, label, resource, cycles, overlap in stage_cycles:
        timeline.append(
            {
                "id": stage_id,
                "label": label,
                "resource": resource,
                "start": cursor,
                "end": cursor + cycles,
                "cycles": cycles,
                "parallel": overlap,
            }
        )
        cursor += cycles
    return timeline


def evaluate(model: Model, hw: Hardware) -> dict[str, Any]:
    q_width_per_core = model.head_dim
    kv_slice_per_core = model.head_dim // hw.cores
    fused_kv_width_per_core = 2 * kv_slice_per_core
    ffn_width_per_core = model.ffn // hw.cores

    q_cycles = os_cycles(model.suffix_tokens, model.hidden, q_width_per_core, hw)
    fused_kv_cycles = os_cycles(
        model.suffix_tokens, model.hidden, fused_kv_width_per_core, hw
    )
    o_cycles = os_cycles(model.suffix_tokens, model.head_dim, model.hidden, hw)
    gate_cycles = os_cycles(model.suffix_tokens, model.hidden, ffn_width_per_core, hw)
    up_cycles = gate_cycles
    down_cycles = os_cycles(model.suffix_tokens, ffn_width_per_core, model.hidden, hw)

    attention_blocks = [256, 256, 256, 99]
    q_tiles = ceil_div(model.suffix_tokens, hw.array_m)
    qk_per_qtile = sum(
        os_cycles(hw.array_m, model.head_dim, block, hw)
        for block in attention_blocks
    )
    pv_per_qtile = sum(
        os_cycles(hw.array_m, block, model.head_dim, hw)
        for block in attention_blocks
    )
    qk_cycles = q_tiles * qk_per_qtile
    pv_cycles = q_tiles * pv_per_qtile
    attention_matrix_cycles = qk_cycles + pv_cycles
    attention_final_tail = ceil_div(hw.array_m * model.head_dim, 4)
    attention_cycles = attention_matrix_cycles + attention_final_tail

    kv_stream_bytes = model.total_kv_tokens * model.head_dim * 2
    kv_multicast_cycles = ceil_div(kv_stream_bytes, hw.bytes_per_cycle)
    suffix_pack_cycles = model.suffix_tokens * hw.cores * 2

    rmsnorm_pass = model.suffix_tokens * ceil_div(model.hidden, 16)
    rmsnorm_quant_tail = ceil_div(model.hidden, 16)
    rmsnorm_one = 2 * rmsnorm_pass + rmsnorm_quant_tail

    sum_lanes = hw.stream_bits // 32
    sum_payload = ceil_div(model.suffix_tokens * model.hidden, sum_lanes)
    sum_depth = int(math.log2(hw.cores))

    stage_cycles = [
        (
            "rmsnorm1",
            "RMSNorm1 + Quant",
            "Shared RMSNorm/Quant",
            rmsnorm_one,
            "BF16 Bank A保留residual；结果写Shared INT8及51个token scale",
        ),
        (
            "q",
            "Q Projection + RoPE/Requant",
            "8 Core MAC + Local Vector",
            q_cycles,
            "PC8预取整层K/V；私有权重ping-pong；Q写Q/O复用Buffer",
        ),
        (
            "fused_kv",
            "Fused K/V Projection",
            "8 Core MAC + Local Vector + MAX Tree",
            fused_kv_cycles,
            "每核前32列K、后32列V；K RoPE/公共scale与后处理重叠；Suffix pack隐藏",
        ),
        (
            "kv_multicast",
            "Prefix/Suffix K/V Multicast",
            "Central KV Fabric + 8 Local Cache Writers",
            kv_multicast_cycles,
            "Score A/B与Context A/B分别合并为16 KiB转置Scratch A/B并ping-pong；V按token-major直接写Local V",
        ),
        (
            "attention",
            "QK + Online Softmax + PV",
            "8 Core Mixed-Width MAC + Online Vector",
            attention_cycles,
            "Softmax处理block b时MAC处理相邻QK/PV block；仅保留最后512-cycle尾巴",
        ),
        (
            "o",
            "O Projection + SUM + Residual",
            "8 Core MAC + SUM Tree + Post-SUM",
            o_cycles + sum_depth,
            "8路INT32 partial边产生边归约；payload已隐藏，仅计3-cycle树尾",
        ),
        (
            "rmsnorm2",
            "RMSNorm2 + Quant",
            "Shared RMSNorm/Quant",
            rmsnorm_one,
            "BF16 Bank B保留FFN residual；结果写Shared INT8",
        ),
        (
            "gate",
            "Gate Projection",
            "8 Core MAC + Gate Buffer",
            gate_cycles,
            "私有权重ping-pong；每核写51x512 BF16 Gate",
        ),
        (
            "up",
            "Up Projection + GeGLU",
            "8 Core MAC + Local Vector",
            up_cycles,
            "Up输出与Gate读取、GELU和乘法流水重叠；写GeGLU BF16 Buffer",
        ),
        (
            "down",
            "Down Projection + SUM + Residual",
            "8 Core MAC + SUM Tree + Post-SUM",
            down_cycles + sum_depth,
            "GeGLU公共scale后边读边量化；SUM/dequant/residual流式重叠",
        ),
    ]
    timeline = build_timeline(stage_cycles)
    layer_cycles = timeline[-1]["end"]

    private_weight_payload_per_layer = (
        model.hidden * q_width_per_core
        + model.head_dim * model.hidden
        + model.hidden * ffn_width_per_core
        + model.hidden * ffn_width_per_core
        + ffn_width_per_core * model.hidden
    )
    private_scale_outputs_per_layer = (
        q_width_per_core
        + model.hidden
        + ffn_width_per_core
        + ffn_width_per_core
        + model.hidden
    )
    private_scale_bytes_per_layer = private_scale_outputs_per_layer * 2
    private_per_layer = private_weight_payload_per_layer + private_scale_bytes_per_layer

    kv_payload_per_layer = 2 * model.hidden * model.head_dim
    kv_scale_bytes_per_layer = 2 * model.head_dim * 2
    kv_per_layer = kv_payload_per_layer + kv_scale_bytes_per_layer
    kv_prefetch_cycles = ceil_div(kv_per_layer, hw.bytes_per_cycle)

    prefix_one_bytes = model.prefix_tokens * model.head_dim * model.layers
    prefix_kv_bytes = prefix_one_bytes * 2
    local_kv_one_kind = model.total_kv_tokens * model.head_dim

    core_buffers = [
        {
            "name": "Private Weight Ping/Pong",
            "logical_bytes": 32 * KIB,
            "bram36": 16,
            "organization": "2 banks x 16 KiB; each bank 512-bit read",
        },
        {
            "name": "Fused K/V Layer Weight Buffer",
            "logical_bytes": 64 * KIB,
            "bram36": 16,
            "organization": "K 32 KiB/256-bit + V 32 KiB/256-bit, simultaneous",
        },
        {
            "name": "Activation Tile A/B",
            "logical_bytes": 2 * KIB,
            "bram36": 1,
            "organization": "8x256 INT8; 64-bit MAC A-side",
        },
        {
            "name": "INT32 Psum Slice",
            "logical_bytes": 51 * 64 * 4,
            "bram36": 4,
            "organization": "51x64 S32; 256-bit result stream",
        },
        {
            "name": "Q/O_attn Reuse Buffer",
            "logical_bytes": model.suffix_tokens * model.head_dim,
            "bram36": 8,
            "organization": "8 token-lane banks; bank=t mod 8; addr=floor(t/8)*256+d",
        },
        {
            "name": "Gate BF16 Buffer",
            "logical_bytes": model.suffix_tokens * ffn_width_per_core * 2,
            "bram36": 16,
            "organization": "51x512 BF16; 128-bit local vector read",
        },
        {
            "name": "GeGLU BF16 Buffer",
            "logical_bytes": model.suffix_tokens * ffn_width_per_core * 2,
            "bram36": 16,
            "organization": "51x512 BF16; Down reads and requantizes on the fly",
        },
        {
            "name": "Score A/B",
            "logical_bytes": 2 * 8 * 256 * 4,
            "bram36": 8,
            "organization": "two 8x256 FP32 banks; 256-bit vector port",
        },
        {
            "name": "Probability A/B",
            "logical_bytes": 2 * 8 * 256 * 2,
            "bram36": 4,
            "organization": "two 8x256 U16 banks; 128-bit PV A-side",
        },
        {
            "name": "Context A/B",
            "logical_bytes": 2 * 8 * 256 * 4,
            "bram36": 4,
            "organization": "two 8x256 FP32 banks; 4-lane update",
        },
        {
            "name": "PV FIFO",
            "logical_bytes": 8 * KIB,
            "bram36": 2,
            "organization": "QK/PV/online-state decoupling",
        },
        {
            "name": "Metadata/Scale/Fused-KV Skid",
            "logical_bytes": 2 * KIB,
            "bram36": 1,
            "organization": "tile-local K/V BF16 staging, scales, boundary/skid FIFO",
        },
    ]
    core_bram = sum(item["bram36"] for item in core_buffers)

    shared_buffers = [
        {
            "name": "Shared BF16 Activation A/B",
            "logical_bytes": 2 * model.suffix_tokens * model.hidden * 2,
            "bram36": 56,
            "organization": "two 102 KiB banks; each is 4 BRAM wide x 7 deep for a 256-bit port",
        },
        {
            "name": "Shared INT8 Normalized Activation",
            "logical_bytes": model.suffix_tokens * model.hidden,
            "bram36": 16,
            "organization": "51x1024 INT8 plus token scales in Scale SRAM",
        },
        {
            "name": "Suffix K/V Buffer",
            "logical_bytes": model.suffix_tokens * model.head_dim * 2,
            "bram36": 8,
            "organization": "K and V each use a 256-bit streamable bank",
        },
        {
            "name": "RoPE ROM + Scale SRAM",
            "logical_bytes": model.suffix_tokens * (model.head_dim // 2) * 2 * 2,
            "bram36": 8,
            "organization": "BF16 sin/cos and Q/K/O/GeGLU scale metadata",
        },
        {
            "name": "DMA/CDC/Reduction FIFO Reserve",
            "logical_bytes": 0,
            "bram36": 16,
            "organization": "AXI CDC, multicast skid, collector, SUM/MAX alignment, debug",
        },
    ]
    shared_bram = sum(item["bram36"] for item in shared_buffers)

    dsp = {
        "per_core": {
            "mixed_width_mac_array": 512,
            "online_softmax_nominal": 14,
            "local_vector_unit": 8,
            "nominal_total": 534,
            "mac_modes": ["S8xS8->S32", "U16xS8->S32"],
        },
        "all_core_local": 8 * 534,
        "shared": {
            "shared_reciprocal": 8,
            "rmsnorm_sfu_planned": 48,
            "post_sum_dequant": 16,
            "quant_conversion": 16,
            "online_ip_engineering_margin": 24,
            "total": 112,
        },
        "planned_total": 4384,
        "available": hw.base5_dsp_available,
        "margin": hw.base5_dsp_available - 4384,
    }

    hbm = [
        {
            "pc": f"PC{pc}",
            "mc": f"MC{mc}",
            "owner": f"Core{core}",
            "content": "Q/O/Gate/Up/Down INT8 private weights + BF16 scales",
            "size_mib": mib(private_per_layer * model.layers),
        }
        for pc, mc, core in [
            (0, 0, 0),
            (2, 1, 1),
            (4, 2, 2),
            (6, 3, 3),
            (16, 8, 4),
            (18, 9, 5),
            (20, 10, 6),
            (22, 11, 7),
        ]
    ]
    hbm.extend(
        [
            {
                "pc": "PC8",
                "mc": "MC4",
                "owner": "Fused K/V DMA",
                "content": "18-layer K/V INT8 weights + BF16 weight scales + static V cache scales",
                "size_mib": mib(kv_per_layer * model.layers),
            },
            {
                "pc": "PC12",
                "mc": "MC6",
                "owner": "Input DMA",
                "content": "state/action inputs and runtime activations",
                "size_mib": None,
            },
            {
                "pc": "PC14",
                "mc": "MC7",
                "owner": "Shared Weight DMA",
                "content": "RMSNorm gamma and state/action/time/out projection weights",
                "size_mib": None,
            },
            {
                "pc": "PC24",
                "mc": "MC12",
                "owner": "Prefix DMA",
                "content": "18-layer Prefix K/V backing and initialization",
                "size_mib": mib(prefix_kv_bytes),
            },
            {
                "pc": "PC28",
                "mc": "MC14",
                "owner": "Output DMA",
                "content": "final action, counters, and debug trace",
                "size_mib": None,
            },
        ]
    )
    hbm.sort(key=lambda item: int(item["pc"][2:]))

    links = [
        {
            "name": "Private weight AXI",
            "count": 8,
            "width_bits": 256,
            "format": "INT8 payload + BF16 scale",
            "source": "PC0/2/4/6/16/18/20/22",
            "sink": "8 Private DMA/CDC",
        },
        {
            "name": "Fused K/V weight AXI",
            "count": 1,
            "width_bits": 256,
            "format": "interleaved K/V INT8 tiles + scales",
            "source": "PC8",
            "sink": "K/V DMA -> 8-way demux",
        },
        {
            "name": "Activation backbone",
            "count": 1,
            "width_bits": 256,
            "format": "BF16 or INT8 by phase",
            "source": "Shared A/B or Shared INT8",
            "sink": "registered 1->2->8 multicast",
        },
        {
            "name": "Activation multicast leaves",
            "count": 8,
            "width_bits": 256,
            "format": "same activation stream replicated",
            "source": "multicast tree",
            "sink": "8 Activation Tile buffers",
        },
        {
            "name": "MAC A-side linear/QK",
            "count": 8,
            "width_bits": 64,
            "format": "8xS8/cycle",
            "source": "Activation Tile or Q/O_attn buffer",
            "sink": "8x64 MAC rows",
        },
        {
            "name": "MAC A-side PV",
            "count": 8,
            "width_bits": 128,
            "format": "8xU16/cycle",
            "source": "Probability A/B",
            "sink": "8x64 MAC rows",
        },
        {
            "name": "MAC B-side private",
            "count": 8,
            "width_bits": 512,
            "format": "64xS8/cycle",
            "source": "Private Weight Ping/Pong",
            "sink": "MAC columns",
        },
        {
            "name": "MAC B-side fused K/V",
            "count": 8,
            "width_bits": 512,
            "format": "K 32xS8 + V 32xS8 each cycle",
            "source": "K 256-bit bank + V 256-bit bank",
            "sink": "MAC columns 0:31 and 32:63",
        },
        {
            "name": "MAC result stream",
            "count": 8,
            "width_bits": 256,
            "format": "8xS32/cycle",
            "source": "MAC/psum",
            "sink": "Local Vector, Q/O, Gate/GeGLU, collector, or SUM Tree",
        },
        {
            "name": "Fused K/V slice ingress",
            "count": 8,
            "width_bits": 256,
            "format": "32xINT8 K or 32xINT8 V, time-multiplexed",
            "source": "8 core egress skid FIFOs",
            "sink": "registered 8:1 K/V collector",
        },
        {
            "name": "Suffix K/V packed stream",
            "count": 1,
            "width_bits": 256,
            "format": "token-major INT8",
            "source": "K/V collector",
            "sink": "Suffix K/V Buffer",
        },
        {
            "name": "Prefix/Suffix K/V stream",
            "count": 1,
            "width_bits": 256,
            "format": "K then V INT8 plus metadata sideband",
            "source": "Prefix URAM + Suffix Buffer",
            "sink": "registered 1->2->8 K/V multicast",
        },
        {
            "name": "K/V multicast leaves",
            "count": 8,
            "width_bits": 256,
            "format": "replicated token-major K/V",
            "source": "K/V multicast tree",
            "sink": "8 Local Cache Layout Writers",
        },
        {
            "name": "Local K cache read",
            "count": 8,
            "width_bits": 512,
            "format": "64 key values for one head dimension",
            "source": "Local K URAM",
            "sink": "QK MAC B-side",
        },
        {
            "name": "Local V cache read",
            "count": 8,
            "width_bits": 512,
            "format": "64 V dimensions for one token",
            "source": "Local V URAM",
            "sink": "PV MAC B-side",
        },
        {
            "name": "SUM inputs",
            "count": 8,
            "width_bits": 256,
            "format": "8xS32/cycle per core",
            "source": "O/Down partial streams",
            "sink": "3-stage SUM Tree",
        },
        {
            "name": "SUM output",
            "count": 1,
            "width_bits": 256,
            "format": "8xS32/cycle",
            "source": "SUM Tree",
            "sink": "Post-SUM dequant/residual",
        },
        {
            "name": "MAX inputs",
            "count": 8,
            "width_bits": 16,
            "format": "one BF16 abs-max scalar/core/cycle",
            "source": "Local Vector units",
            "sink": "3-stage MAX Tree",
        },
        {
            "name": "Scale broadcast",
            "count": 8,
            "width_bits": 16,
            "format": "BF16 common scale",
            "source": "MAX Tree/Scale SRAM",
            "sink": "8 Local Vector units",
        },
        {
            "name": "Control/event",
            "count": 1,
            "width_bits": 32,
            "format": "descriptor, barrier, tile id, valid/ready",
            "source": "Scheduler",
            "sink": "DMA, cores, buffers, collector, reductions",
        },
    ]

    quantization = [
        {
            "tensor": "RMSNorm output Xn",
            "storage": "Shared INT8",
            "scale": "BF16 per token over complete 1024-d vector",
            "reason": "Q/K/V or Gate/Up reuse the same quantized activation",
        },
        {
            "tensor": "Linear weights",
            "storage": "HBM INT8",
            "scale": "BF16 per output channel; zero point 0",
            "reason": "keeps S8xS8 MAC and limits channel outliers",
        },
        {
            "tensor": "Q",
            "storage": "Q/O_attn Reuse Buffer INT8",
            "scale": "BF16 per query token per core/head",
            "reason": "each core computes one independent Q head",
        },
        {
            "tensor": "K cache",
            "storage": "Prefix/Local K INT8",
            "scale": "BF16 per key token over complete 256-d K",
            "reason": "all eight 32-d slices share one scale after MAX Tree",
        },
        {
            "tensor": "V cache",
            "storage": "Prefix/Local V INT8",
            "scale": "static BF16 per layer and V output channel",
            "reason": "scale is constant along the token reduction dimension, so PV remains INT32",
        },
        {
            "tensor": "Softmax P",
            "storage": "Probability A/B U16",
            "scale": "fixed 2^-15",
            "reason": "non-negative fixed-point probability supports U16xS8 MAC",
        },
        {
            "tensor": "O_attn",
            "storage": "Q/O_attn Reuse Buffer INT8",
            "scale": "BF16 per token, common across all eight cores",
            "reason": "O partials can be summed directly in INT32",
        },
        {
            "tensor": "GeGLU",
            "storage": "GeGLU Buffer BF16, requantized on Down read",
            "scale": "BF16 per token, common across all eight cores",
            "reason": "Down partials can be summed directly in INT32",
        },
        {
            "tensor": "Layer/residual activation",
            "storage": "Shared BF16 A/B",
            "scale": "none",
            "reason": "preserves residual precision across layers",
        },
    ]

    bram_total = core_bram * hw.cores + shared_bram
    local_kv_uram = 2 * uram_blocks(local_kv_one_kind, 512)
    uram_total = 2 * uram_blocks(prefix_one_bytes, hw.stream_bits) + hw.cores * local_kv_uram

    result = {
        "scope": {
            "included": "18-layer pi0 Action Expert Transformer body with cached Prefix K/V",
            "excluded": [
                "PaliGemma/VLM prefix generation",
                "state_proj 32->1024",
                "action_in_proj 32->1024",
                "action_time_mlp 2048->1024->1024",
                "action_out_proj 1024->32",
                "host/PCIe/robot I/O",
            ],
        },
        "decisions": {
            "cores": 8,
            "fused_kv": True,
            "q_o_buffer_reuse": True,
            "online_softmax_overlap": True,
            "gate_geglu_uram_migration": "not baseline; post-link fallback only",
            "address_offsets": "not frozen",
            "shared_bf16_bram_correction": "56 physical BRAM36 for two 256-bit banks, not the 48-block capacity approximation",
        },
        "cores": {
            "count": hw.cores,
            "mapping": {
                "q": "one complete 256-d query head/core",
                "fused_kv": "one 64-d output/core: K[32] + V[32]",
                "attention": "one complete query head/core using replicated K/V",
                "o": "one 256-d K slice/core -> complete 1024-d S32 partial",
                "gate_up": "one 512-d output slice/core",
                "down": "one 512-d K slice/core -> complete 1024-d S32 partial",
            },
            "dsp": dsp["per_core"],
            "bram36": core_bram,
            "uram": local_kv_uram,
            "buffers": core_buffers,
            "local_cache_layout": {
                "k": "[key_block_64][dimension][64 keys], 512-bit read",
                "v": "[token][dimension_block_64][64 dimensions], 512-bit read",
                "writer": "K reuses Score A/B and Context A/B as two 16 KiB transpose ping-pong tiles; V writes directly",
            },
        },
        "shared": {
            "dsp": dsp["shared"],
            "bram36": shared_bram,
            "buffers": shared_buffers,
            "prefix_uram": {
                "k": uram_blocks(prefix_one_bytes, hw.stream_bits),
                "v": uram_blocks(prefix_one_bytes, hw.stream_bits),
                "total": 2 * uram_blocks(prefix_one_bytes, hw.stream_bits),
            },
            "sum_tree": {
                "inputs": 8,
                "lanes": sum_lanes,
                "int32_adders": sum_lanes * (hw.cores - 1),
                "pipeline_depth": sum_depth,
                "payload_cycles": sum_payload,
                "tail_cycles": sum_depth,
                "dsp": 0,
            },
            "max_tree": {
                "inputs": 8,
                "pipeline_depth": sum_depth,
                "dsp": 0,
                "uses": ["K scale", "O_attn scale", "GeGLU scale"],
            },
        },
        "resources": {
            "dsp": {
                **dsp,
            },
            "bram36": {
                "per_core": core_bram,
                "all_cores": core_bram * hw.cores,
                "shared": shared_bram,
                "planned_total": bram_total,
                "base5_available": hw.base5_bram36_available,
                "base5_margin": hw.base5_bram36_available - bram_total,
                "chip_nominal": hw.chip_bram36_nominal,
                "optimistic_capacity_only_total_rejected": 864,
            },
            "uram": {
                "per_core": local_kv_uram,
                "all_cores": hw.cores * local_kv_uram,
                "shared_prefix": 2 * uram_blocks(prefix_one_bytes, hw.stream_bits),
                "planned_total": uram_total,
                "available": hw.base5_uram_available,
                "margin": hw.base5_uram_available - uram_total,
            },
        },
        "hbm": {
            "mapping": hbm,
            "stream_width_bits": hw.stream_bits,
            "bytes_per_cycle": hw.bytes_per_cycle,
            "design_bandwidth_gbps_per_port": hw.bytes_per_cycle * hw.frequency_mhz / 1000,
            "private_weight_per_layer_per_core_bytes": private_per_layer,
            "private_weight_all_layers_per_core_bytes": private_per_layer * model.layers,
            "kv_weight_per_layer_bytes": kv_per_layer,
            "kv_prefetch_cycles": kv_prefetch_cycles,
            "kv_prefetch_hidden_in_q": kv_prefetch_cycles <= q_cycles,
            "kv_prefetch_margin_cycles": q_cycles - kv_prefetch_cycles,
        },
        "links": links,
        "quantization": quantization,
        "cycles": {
            "rmsnorm_one": rmsnorm_one,
            "q": q_cycles,
            "fused_kv": fused_kv_cycles,
            "suffix_pack": suffix_pack_cycles,
            "suffix_pack_hidden_in_fused_kv": suffix_pack_cycles <= fused_kv_cycles,
            "kv_multicast": kv_multicast_cycles,
            "qk": qk_cycles,
            "pv": pv_cycles,
            "attention_matrix": attention_matrix_cycles,
            "attention_final_tail": attention_final_tail,
            "online_attention": attention_cycles,
            "o": o_cycles,
            "gate": gate_cycles,
            "up": up_cycles,
            "down": down_cycles,
            "sum_payload": sum_payload,
            "sum_tail_each": sum_depth,
            "layer": layer_cycles,
            "layer_ms": ms(layer_cycles, hw),
            "eighteen_layers": layer_cycles * model.layers,
            "eighteen_layers_ms": ms(layer_cycles * model.layers, hw),
            "ten_denoise_steps": layer_cycles * model.layers * model.denoise_steps,
            "ten_denoise_steps_ms": ms(
                layer_cycles * model.layers * model.denoise_steps, hw
            ),
            "v32_saved_cycles_per_layer": 401990 - layer_cycles,
        },
        "timeline": timeline,
        "provenance": {
            "status": "analytic estimate",
            "clock": "250 MHz target",
            "must_verify": [
                "one DSP48E2 per mixed-width PE and II=1",
                "14 DSP/core online softmax implementation",
                "shared BF16 bank BRAM mapping and timing",
                "K transpose writer and URAM byte-write behavior",
                "HBM/CDC stalls and multicast backpressure",
                "base_5 Link Summary and SLR distribution",
            ],
        },
    }

    assert fused_kv_cycles == 9128
    assert suffix_pack_cycles == 816
    assert layer_cycles == 392862
    assert dsp["planned_total"] == 4384
    assert core_bram == 96
    assert shared_bram == 104
    assert bram_total == 872
    assert uram_total == 360
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "v3.3-results",
    )
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    model = Model()
    hardware = Hardware()
    result = evaluate(model, hardware)
    output = {
        "model": asdict(model),
        "hardware": asdict(hardware),
        "result": result,
    }
    output_path = args.output_dir / "physical_architecture_budget.json"
    output_path.write_text(
        json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(
        json.dumps(
            {
                "output": str(output_path),
                "layer_cycles": result["cycles"]["layer"],
                "layer_ms": result["cycles"]["layer_ms"],
                "dsp": result["resources"]["dsp"]["planned_total"],
                "bram36": result["resources"]["bram36"]["planned_total"],
                "uram": result["resources"]["uram"]["planned_total"],
            },
            ensure_ascii=False,
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
