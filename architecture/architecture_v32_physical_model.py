#!/usr/bin/env python3
"""V3.2 analytic hardware, floorplan, and layer-timeline model.

This model is intentionally conservative. It keeps the V3.1 sequential K then V
baseline and labels every result as an analytic estimate pending HLS/RTL
synthesis, timing closure, Vitis link, and board measurement.
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
    k_work = 0
    for start in range(0, k, hw.k_tile):
        extent = min(hw.k_tile, k - start)
        k_work += extent + hw.array_m + hw.array_n - 2
    return ceil_div(m, hw.array_m) * ceil_div(n, hw.array_n) * k_work


def uram_blocks(total_bytes: int, port_bits: int) -> int:
    words = ceil_div(total_bytes * 8, port_bits)
    return ceil_div(port_bits, 72) * ceil_div(words, 4096)


def kib(value: float) -> float:
    return value / KIB


def mib(value: float) -> float:
    return value / MIB


def ms(cycles: int, hw: Hardware) -> float:
    return cycles / hw.cycles_per_ms


def evaluate(model: Model, hw: Hardware) -> dict[str, Any]:
    q_width_per_core = model.head_dim
    kv_width_per_core = model.head_dim // hw.cores
    ffn_width_per_core = model.ffn // hw.cores

    q_cycles = os_cycles(model.suffix_tokens, model.hidden, q_width_per_core, hw)
    k_cycles = os_cycles(model.suffix_tokens, model.hidden, kv_width_per_core, hw)
    v_cycles = k_cycles
    o_cycles = os_cycles(model.suffix_tokens, model.head_dim, model.hidden, hw)
    gate_cycles = os_cycles(model.suffix_tokens, model.hidden, ffn_width_per_core, hw)
    up_cycles = gate_cycles
    down_cycles = os_cycles(model.suffix_tokens, ffn_width_per_core, model.hidden, hw)

    attention_blocks = [256, 256, 256, 99]
    q_tiles = ceil_div(model.suffix_tokens, hw.array_m)
    qk_per_qtile = sum(os_cycles(hw.array_m, model.head_dim, b, hw) for b in attention_blocks)
    pv_per_qtile = sum(os_cycles(hw.array_m, b, model.head_dim, hw) for b in attention_blocks)
    qk_cycles = q_tiles * qk_per_qtile
    pv_cycles = q_tiles * pv_per_qtile
    attention_matrix_cycles = qk_cycles + pv_cycles
    attention_final_tail = ceil_div(hw.array_m * model.head_dim, 4)
    attention_cycles = attention_matrix_cycles + attention_final_tail

    kv_stream_bytes = model.total_kv_tokens * model.head_dim * 2
    kv_multicast_cycles = ceil_div(kv_stream_bytes, hw.bytes_per_cycle)

    rmsnorm_pass = model.suffix_tokens * ceil_div(model.hidden, 16)
    rmsnorm_quant_tail = ceil_div(model.hidden, 16)
    rmsnorm_one = 2 * rmsnorm_pass + rmsnorm_quant_tail

    sum_lanes = hw.stream_bits // 32
    sum_payload = ceil_div(model.suffix_tokens * model.hidden, sum_lanes)
    sum_depth = int(math.log2(hw.cores))

    timeline = [
        {
            "id": "rmsnorm1",
            "label": "RMSNorm 1 + Quant",
            "resource": "Shared RMSNorm/Quant",
            "start": 0,
            "end": rmsnorm_one,
            "parallel": "输入/残差保留在 Shared BF16 Bank A；末段写 Shared INT8 Buffer",
        },
        {
            "id": "q",
            "label": "Q Projection",
            "resource": "8 Core MAC Arrays",
            "start": rmsnorm_one,
            "end": rmsnorm_one + q_cycles,
            "parallel": "PC8 预取本层 K/V；Private DMA 做权重 ping-pong；Local Vector 做 RoPE",
        },
        {
            "id": "k",
            "label": "K Projection",
            "resource": "8 Core MAC Arrays",
            "start": rmsnorm_one + q_cycles,
            "end": rmsnorm_one + q_cycles + k_cycles,
            "parallel": "8 核各算 32-d；Local Vector 做 RoPE/local max；MAX Tree 产生公共 K scale",
        },
        {
            "id": "v",
            "label": "V Projection",
            "resource": "8 Core MAC Arrays",
            "start": rmsnorm_one + q_cycles + k_cycles,
            "end": rmsnorm_one + q_cycles + k_cycles + v_cycles,
            "parallel": "8 核各算 32-d；K/V Assemble 按通道拼接，不求和",
        },
    ]
    cursor = timeline[-1]["end"]
    timeline.append(
        {
            "id": "kv_multicast",
            "label": "Prefix/Suffix K/V Multicast",
            "resource": "Central KV Fabric",
            "start": cursor,
            "end": cursor + kv_multicast_cycles,
            "parallel": "Prefix URAM 与 Suffix Buffer 顺序出流；2x4 广播写 8 个 Local K/V URAM",
        }
    )
    cursor = timeline[-1]["end"]
    timeline.append(
        {
            "id": "attention",
            "label": "QK + Online Softmax + PV",
            "resource": "Core MAC + Online Vector",
            "start": cursor,
            "end": cursor + attention_cycles,
            "parallel": "QK/PV 在同一 MAC 上串行；Softmax/FMA block-wise 重叠；最后 512-cycle 归一化尾巴",
        }
    )
    cursor = timeline[-1]["end"]
    timeline.append(
        {
            "id": "o",
            "label": "O Projection + SUM",
            "resource": "8 Core MAC + SUM Tree",
            "start": cursor,
            "end": cursor + o_cycles + sum_depth,
            "parallel": "SUM/Dequant/Residual 跟随输出流；只保留 3-cycle tree tail",
        }
    )
    cursor = timeline[-1]["end"]
    timeline.append(
        {
            "id": "rmsnorm2",
            "label": "RMSNorm 2 + Quant",
            "resource": "Shared RMSNorm/Quant",
            "start": cursor,
            "end": cursor + rmsnorm_one,
            "parallel": "Bank B 保留 FFN residual；归一化结果写 Shared INT8 Buffer",
        }
    )
    cursor = timeline[-1]["end"]
    timeline.extend(
        [
            {
                "id": "gate",
                "label": "Gate Projection",
                "resource": "8 Core MAC Arrays",
                "start": cursor,
                "end": cursor + gate_cycles,
                "parallel": "Private DMA ping-pong；输出写每核 Gate Buffer",
            },
            {
                "id": "up",
                "label": "Up Projection + GeGLU",
                "resource": "8 Core MAC + Local Vector",
                "start": cursor + gate_cycles,
                "end": cursor + gate_cycles + up_cycles,
                "parallel": "Up 流出时读取 Gate Buffer，GeGLU 流式写 GeGLU Buffer",
            },
            {
                "id": "down",
                "label": "Down Projection + SUM",
                "resource": "8 Core MAC + SUM Tree",
                "start": cursor + gate_cycles + up_cycles,
                "end": cursor + gate_cycles + up_cycles + down_cycles + sum_depth,
                "parallel": "公共 scale 后做 INT32 partial；SUM/Dequant/Residual 流式重叠，3-cycle tail",
            },
        ]
    )
    layer_cycles = timeline[-1]["end"]

    private_weight_payload_per_layer = (
        model.hidden * q_width_per_core
        + model.head_dim * model.hidden
        + model.hidden * ffn_width_per_core
        + model.hidden * ffn_width_per_core
        + ffn_width_per_core * model.hidden
    )
    private_scale_outputs_per_layer = (
        q_width_per_core + model.hidden + ffn_width_per_core + ffn_width_per_core + model.hidden
    )
    private_scale_bytes_per_layer = private_scale_outputs_per_layer * 2
    private_per_layer = private_weight_payload_per_layer + private_scale_bytes_per_layer

    kv_payload_per_layer = 2 * model.hidden * model.head_dim
    kv_scale_bytes_per_layer = 2 * model.head_dim * 2
    kv_per_layer = kv_payload_per_layer + kv_scale_bytes_per_layer
    kv_prefetch_cycles = ceil_div(kv_per_layer, hw.bytes_per_cycle)

    prefix_kv_bytes = model.prefix_tokens * model.head_dim * 2 * model.layers
    prefix_one_bytes = model.prefix_tokens * model.head_dim * model.layers
    local_kv_one_kind = model.total_kv_tokens * model.head_dim

    core_buffers = [
        {"name": "Private Weight Ping/Pong", "bytes": 32 * KIB, "bram36": 16, "medium": "BRAM"},
        {"name": "K/V Layer Weight Buffer", "bytes": 64 * KIB, "bram36": 16, "medium": "BRAM"},
        {"name": "Activation Tile", "bytes": 2 * KIB, "bram36": 1, "medium": "BRAM"},
        {"name": "INT32 Psum Slice", "bytes": int(12.75 * KIB), "bram36": 4, "medium": "BRAM"},
        {"name": "Q Buffer", "bytes": int(25.5 * KIB), "bram36": 8, "medium": "BRAM"},
        {"name": "Gate Buffer", "bytes": 51 * KIB, "bram36": 16, "medium": "BRAM"},
        {"name": "GeGLU Buffer", "bytes": 51 * KIB, "bram36": 16, "medium": "BRAM"},
        {"name": "Score A/B", "bytes": 16 * KIB, "bram36": 6, "medium": "BRAM"},
        {"name": "P A/B", "bytes": 8 * KIB, "bram36": 3, "medium": "BRAM"},
        {"name": "Dual Query Context", "bytes": 16 * KIB, "bram36": 6, "medium": "BRAM"},
        {"name": "PV Output FIFO", "bytes": 8 * KIB, "bram36": 3, "medium": "BRAM"},
        {"name": "Local control/skid reserve", "bytes": 0, "bram36": 1, "medium": "BRAM/LUTRAM"},
    ]
    core_bram = sum(item["bram36"] for item in core_buffers)
    core_buffer_bytes = sum(item["bytes"] for item in core_buffers)

    shared_buffers = [
        {
            "name": "Shared BF16 Activation A/B",
            "bytes": 2 * model.suffix_tokens * model.hidden * 2,
            "bram36": 48,
            "medium": "BRAM",
            "reason": "两个完整 bank；一边保留 residual，一边接收 O/Down 结果",
        },
        {
            "name": "Shared INT8 Normalized Activation",
            "bytes": model.suffix_tokens * model.hidden,
            "bram36": 16,
            "medium": "BRAM",
            "reason": "RMSNorm 后量化一次，Q/K/V 或 Gate/Up 分阶段重复读取",
        },
        {
            "name": "Suffix K/V Buffer",
            "bytes": model.suffix_tokens * model.head_dim * 2,
            "bram36": 8,
            "medium": "BRAM",
            "reason": "暂存 51-token K/V，再与 Prefix 按 token 顺序拼接",
        },
        {
            "name": "RoPE ROM + Scale SRAM",
            "bytes": model.suffix_tokens * (model.head_dim // 2) * 2 * 2,
            "bram36": 8,
            "medium": "BRAM/ROM",
            "reason": "51 个位置的 BF16 sin/cos，加少量动态 scale 元数据",
        },
        {
            "name": "DMA/CDC/Reduction FIFO Reserve",
            "bytes": 0,
            "bram36": 16,
            "medium": "BRAM/LUTRAM",
            "reason": "AXI 异步 FIFO、multicast skid、SUM/MAX 对齐和 debug FIFO",
        },
    ]
    shared_bram = sum(item["bram36"] for item in shared_buffers)

    dsp = {
        "per_core": {
            "int8_mac_array": 512,
            "online_softmax_nominal": 14,
            "local_vector_unit": 8,
            "nominal_total": 534,
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
        {"pc": "PC0", "mc": "MC0", "owner": "Core0", "content": "Q/O/Gate/Up/Down 私有 INT8 权重+scale", "size_mib": mib(private_per_layer * model.layers)},
        {"pc": "PC2", "mc": "MC1", "owner": "Core1", "content": "Q/O/Gate/Up/Down 私有 INT8 权重+scale", "size_mib": mib(private_per_layer * model.layers)},
        {"pc": "PC4", "mc": "MC2", "owner": "Core2", "content": "Q/O/Gate/Up/Down 私有 INT8 权重+scale", "size_mib": mib(private_per_layer * model.layers)},
        {"pc": "PC6", "mc": "MC3", "owner": "Core3", "content": "Q/O/Gate/Up/Down 私有 INT8 权重+scale", "size_mib": mib(private_per_layer * model.layers)},
        {"pc": "PC8", "mc": "MC4", "owner": "K/V DMA", "content": "18 层 K/V INT8 权重+scale", "size_mib": mib(kv_per_layer * model.layers)},
        {"pc": "PC12", "mc": "MC6", "owner": "Input DMA", "content": "初始 state/action 激活与运行时输入", "size_mib": None},
        {"pc": "PC14", "mc": "MC7", "owner": "Shared Weight DMA", "content": "RMSNorm gamma、state/action/time/out 小型投影权重", "size_mib": None},
        {"pc": "PC16", "mc": "MC8", "owner": "Core4", "content": "Q/O/Gate/Up/Down 私有 INT8 权重+scale", "size_mib": mib(private_per_layer * model.layers)},
        {"pc": "PC18", "mc": "MC9", "owner": "Core5", "content": "Q/O/Gate/Up/Down 私有 INT8 权重+scale", "size_mib": mib(private_per_layer * model.layers)},
        {"pc": "PC20", "mc": "MC10", "owner": "Core6", "content": "Q/O/Gate/Up/Down 私有 INT8 权重+scale", "size_mib": mib(private_per_layer * model.layers)},
        {"pc": "PC22", "mc": "MC11", "owner": "Core7", "content": "Q/O/Gate/Up/Down 私有 INT8 权重+scale", "size_mib": mib(private_per_layer * model.layers)},
        {"pc": "PC24", "mc": "MC12", "owner": "Prefix DMA", "content": "18 层 Prefix K/V HBM backing", "size_mib": mib(prefix_kv_bytes)},
        {"pc": "PC28", "mc": "MC14", "owner": "Output DMA", "content": "最终动作、性能计数器和 debug trace", "size_mib": None},
    ]

    links = [
        {"name": "Private weight AXI", "count": 8, "width_bits": 256, "format": "INT8 + BF16 scale", "source": "PC0/2/4/6/16/18/20/22", "sink": "8 Private Weight DMA/CDC"},
        {"name": "K/V weight AXI", "count": 1, "width_bits": 256, "format": "INT8 + BF16 scale", "source": "PC8", "sink": "K/V DMA -> 8-way Demux"},
        {"name": "Shared activation backbone", "count": 1, "width_bits": 256, "format": "BF16 or INT8 by phase", "source": "Shared buffers/RMSNorm", "sink": "2x4 Activation Multicast"},
        {"name": "MAC A-side", "count": 8, "width_bits": 64, "format": "8xINT8/cycle; PV uses 8xU16=128-bit", "source": "Activation/P Buffer", "sink": "8x64 MAC"},
        {"name": "MAC B-side private", "count": 8, "width_bits": 512, "format": "64xINT8/cycle", "source": "Private Weight PP", "sink": "MAC B"},
        {"name": "MAC B-side K/V", "count": 8, "width_bits": 256, "format": "32xINT8/cycle", "source": "K/V Layer Weight Buffer", "sink": "MAC B lower 32 columns"},
        {"name": "Local K/V cache read", "count": 16, "width_bits": 512, "format": "64xINT8/cycle", "source": "K or V URAM bank", "sink": "QK/PV MAC B"},
        {"name": "K/V slice collect", "count": 8, "width_bits": 256, "format": "32xINT8", "source": "Core K/V routers", "sink": "K/V Assemble"},
        {"name": "K/V multicast", "count": 1, "width_bits": 256, "format": "INT8 + scale", "source": "Prefix/Suffix Streamer", "sink": "2x4 tree -> 8 Local K/V caches"},
        {"name": "SUM inputs", "count": 8, "width_bits": 256, "format": "8xINT32", "source": "Core O/Down partials", "sink": "3-stage SUM Tree"},
        {"name": "SUM output", "count": 1, "width_bits": 256, "format": "8xINT32", "source": "SUM Tree", "sink": "Post-SUM Dequant/Residual"},
        {"name": "MAX inputs", "count": 8, "width_bits": 16, "format": "BF16 scalar", "source": "Core local max", "sink": "3-stage MAX Tree"},
        {"name": "Control/event network", "count": 1, "width_bits": 32, "format": "descriptor/event/barrier", "source": "Scheduler", "sink": "DMA, cores, buffers, reductions"},
    ]

    result = {
        "scope": {
            "included": "18-layer pi0 Action Expert Transformer body with cached Prefix K/V",
            "excluded_from_401990_cycles": [
                "PaliGemma VLM prefix generation",
                "state_proj 32->1024",
                "action_in_proj 32->1024",
                "action_time_mlp 2048->1024->1024",
                "action_out_proj 1024->32",
                "host/PCIe and robot I/O",
            ],
            "note": "PC14 reserves storage for the small pre/post projections, but their cycles require a separate schedule.",
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
            "kv_prefetch_hidden_in_q": kv_prefetch_cycles < q_cycles,
            "kv_prefetch_margin_cycles": q_cycles - kv_prefetch_cycles,
        },
        "cores": {
            "count": hw.cores,
            "per_core_mapping": {
                "q": "one complete 256-d query head",
                "k": "one 32-d output slice; all 8 cores run together",
                "v": "one 32-d output slice; all 8 cores run together after K",
                "o": "one 256-d K slice -> complete 1024-d INT32 partial",
                "gate_up": "one 512-d N slice",
                "down": "one 512-d K slice -> complete 1024-d INT32 partial",
            },
            "dsp": dsp["per_core"],
            "bram36_engineering_budget": core_bram,
            "logical_buffer_bytes": core_buffer_bytes,
            "buffers": core_buffers,
            "local_kv_uram_per_core": 2 * uram_blocks(local_kv_one_kind, 512),
        },
        "shared": {
            "dsp": dsp["shared"],
            "bram36_engineering_budget": shared_bram,
            "buffers": shared_buffers,
            "sum_tree": {
                "inputs": 8,
                "lanes": sum_lanes,
                "int32_adders": sum_lanes * (hw.cores - 1),
                "pipeline_depth": sum_depth,
                "dsp": 0,
                "payload_cycles": sum_payload,
                "tail_cycles": sum_depth,
            },
            "max_tree": {
                "inputs": 8,
                "comparators_per_scalar_lane": hw.cores - 1,
                "pipeline_depth": sum_depth,
                "dsp": 0,
                "uses": ["K scale", "O input common scale", "Down input common scale"],
            },
        },
        "dsp": dsp,
        "bram36": {
            "per_core": core_bram,
            "all_cores": core_bram * hw.cores,
            "shared": shared_bram,
            "planned_total": core_bram * hw.cores + shared_bram,
            "chip_nominal": hw.chip_bram36_nominal,
            "chip_nominal_margin": hw.chip_bram36_nominal - core_bram * hw.cores - shared_bram,
            "warning": "base_5 dynamic-region BRAM availability must be confirmed in Vitis Link Summary",
        },
        "uram": {
            "prefix_k": uram_blocks(prefix_one_bytes, hw.stream_bits),
            "prefix_v": uram_blocks(prefix_one_bytes, hw.stream_bits),
            "prefix_total": 2 * uram_blocks(prefix_one_bytes, hw.stream_bits),
            "local_kv_per_core": 2 * uram_blocks(local_kv_one_kind, 512),
            "local_kv_all_cores": hw.cores * 2 * uram_blocks(local_kv_one_kind, 512),
            "planned_total": 2 * uram_blocks(prefix_one_bytes, hw.stream_bits)
            + hw.cores * 2 * uram_blocks(local_kv_one_kind, 512),
            "available": hw.base5_uram_available,
            "margin": hw.base5_uram_available
            - 2 * uram_blocks(prefix_one_bytes, hw.stream_bits)
            - hw.cores * 2 * uram_blocks(local_kv_one_kind, 512),
        },
        "links": links,
        "cycles": {
            "rmsnorm_one": rmsnorm_one,
            "q": q_cycles,
            "k": k_cycles,
            "v": v_cycles,
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
            "ten_denoise_steps_ms": ms(layer_cycles * model.layers * model.denoise_steps, hw),
        },
        "timeline": timeline,
        "provenance": {
            "status": "analytic estimate",
            "clock": "250 MHz target",
            "not_measured": ["HLS/RTL synthesis", "timing closure", "Vitis link", "board test"],
        },
    }

    assert model.prefix_tokens + model.suffix_tokens == model.total_kv_tokens
    assert q_cycles == 36512
    assert k_cycles == 9128 and v_cycles == 9128
    assert kv_prefetch_cycles == 16416
    assert kv_multicast_cycles == 13872
    assert attention_cycles == 64576
    assert layer_cycles == 401990
    assert core_bram == 96
    assert shared_bram == 96
    assert result["bram36"]["planned_total"] == 864
    assert result["uram"]["planned_total"] == 360
    assert dsp["planned_total"] == 4384
    return result


def esc(text: Any) -> str:
    return (
        str(text)
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def svg_text(x: float, y: float, text: str, cls: str = "body", anchor: str = "start") -> str:
    return f'<text x="{x}" y="{y}" class="{cls}" text-anchor="{anchor}">{esc(text)}</text>'


def svg_box(
    x: float,
    y: float,
    w: float,
    h: float,
    title: str,
    lines: list[str],
    cls: str,
) -> list[str]:
    out = [f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" class="{cls}"/>']
    out.append(svg_text(x + w / 2, y + 25, title, "box-title", "middle"))
    for idx, line in enumerate(lines):
        out.append(svg_text(x + w / 2, y + 50 + idx * 20, line, "small", "middle"))
    return out


def svg_path(points: list[tuple[float, float]], cls: str, label: str | None = None) -> list[str]:
    d = "M" + " L".join(f"{x},{y}" for x, y in points)
    out = [f'<path d="{d}" class="{cls}"/>']
    if label:
        x = sum(p[0] for p in points) / len(points)
        y = sum(p[1] for p in points) / len(points) - 7
        out.append(svg_text(x, y, label, "edge-label", "middle"))
    return out


SVG_DEFS = """
<defs>
  <marker id="arrow-data" markerWidth="9" markerHeight="9" refX="8" refY="3" orient="auto"><path d="M0,0 L0,6 L8,3 z" fill="#1769aa"/></marker>
  <marker id="arrow-reduce" markerWidth="9" markerHeight="9" refX="8" refY="3" orient="auto"><path d="M0,0 L0,6 L8,3 z" fill="#bd5d12"/></marker>
  <marker id="arrow-control" markerWidth="9" markerHeight="9" refX="8" refY="3" orient="auto"><path d="M0,0 L0,6 L8,3 z" fill="#7050a0"/></marker>
  <style>
    .title{font:700 32px "Microsoft YaHei","Noto Sans CJK SC",Arial;fill:#172033}
    .subtitle{font:16px "Microsoft YaHei","Noto Sans CJK SC",Arial;fill:#4b5563}
    .section{font:700 18px "Microsoft YaHei","Noto Sans CJK SC",Arial;fill:#172033}
    .box-title{font:700 15px "Microsoft YaHei","Noto Sans CJK SC",Arial;fill:#172033}
    .body{font:14px "Microsoft YaHei","Noto Sans CJK SC",Arial;fill:#27364a}
    .small{font:12px "Microsoft YaHei","Noto Sans CJK SC",Arial;fill:#394960}
    .tiny{font:11px "Microsoft YaHei","Noto Sans CJK SC",Arial;fill:#4b596d}
    .edge-label{font:700 11px "Microsoft YaHei","Noto Sans CJK SC",Arial;fill:#0e4d82}
    .hbm{fill:#e8ebef;stroke:#5f6b7a;stroke-width:2}
    .core{fill:#f7fbff;stroke:#1769aa;stroke-width:2.5}
    .matrix{fill:#dcecff;stroke:#1769aa;stroke-width:2}
    .buffer{fill:#e5f2df;stroke:#39763d;stroke-width:2}
    .vector{fill:#fff0d8;stroke:#bd5d12;stroke-width:2}
    .shared{fill:#eee7f8;stroke:#7050a0;stroke-width:2}
    .neutral{fill:#f8fafc;stroke:#94a0b2;stroke-width:1.5}
    .data{fill:none;stroke:#1769aa;stroke-width:2.5;marker-end:url(#arrow-data)}
    .reduce{fill:none;stroke:#bd5d12;stroke-width:2.5;marker-end:url(#arrow-reduce)}
    .control{fill:none;stroke:#7050a0;stroke-width:2;stroke-dasharray:7 6;marker-end:url(#arrow-control)}
  </style>
</defs>
"""


def build_floorplan_svg(result: dict[str, Any]) -> str:
    width, height = 2800, 1900
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">']
    out.append(SVG_DEFS)
    out.append(f'<rect width="{width}" height="{height}" fill="#ffffff"/>')
    out.append(svg_text(40, 48, "pi0 Action Expert FPGA V3.2 物理规划与互连拓扑", "title"))
    out.append(svg_text(40, 78, "逻辑物理规划，不是 post-route die 截图；所有资源均为 250 MHz 解析估算", "subtitle"))

    out.append(svg_text(55, 125, "HBM Stack 0 / 左侧数据源", "section"))
    out.append(svg_text(2180, 125, "HBM Stack 1 / 右侧数据源", "section"))
    left_hbm = [
        ("PC0/MC0", "Core0 private weights"),
        ("PC2/MC1", "Core1 private weights"),
        ("PC4/MC2", "Core2 private weights"),
        ("PC6/MC3", "Core3 private weights"),
        ("PC8/MC4", "all K/V weights"),
        ("PC12/MC6", "input activations"),
        ("PC14/MC7", "shared/pre-post weights"),
    ]
    right_hbm = [
        ("PC16/MC8", "Core4 private weights"),
        ("PC18/MC9", "Core5 private weights"),
        ("PC20/MC10", "Core6 private weights"),
        ("PC22/MC11", "Core7 private weights"),
        ("PC24/MC12", "Prefix K/V backing"),
        ("PC28/MC14", "output/debug"),
    ]
    for idx, (pc, desc) in enumerate(left_hbm):
        y = 150 + idx * 92
        out.extend(svg_box(45, y, 300, 72, pc, [desc, "256-bit AXI + DMA/CDC"], "hbm"))
    for idx, (pc, desc) in enumerate(right_hbm):
        y = 150 + idx * 92
        out.extend(svg_box(2455, y, 300, 72, pc, [desc, "256-bit AXI + DMA/CDC"], "hbm"))

    core_y = [185, 500, 815, 1130]
    left_core_ids = [0, 1, 2, 3]
    right_core_ids = [4, 5, 6, 7]

    def draw_core(x: int, y: int, core_id: int) -> None:
        out.append(f'<rect x="{x}" y="{y}" width="650" height="270" rx="7" class="core"/>')
        out.append(svg_text(x + 20, y + 28, f"Private Core {core_id}", "section"))
        out.extend(svg_box(x + 20, y + 48, 185, 82, "Weight/Tile BRAM", ["PP 32 KiB", "K/V W 64 KiB"], "buffer"))
        out.extend(svg_box(x + 225, y + 48, 200, 82, "8x64 INT8 MAC", ["512 DSP", "Q/K/V/QK/PV/O/FFN"], "matrix"))
        out.extend(svg_box(x + 445, y + 48, 185, 82, "Local Vector", ["RoPE/GeGLU/MAX", "8 DSP"], "vector"))
        out.extend(svg_box(x + 20, y + 150, 185, 90, "Local Buffers", ["Q/Gate/GeGLU/Psum", "non-attention total: 78 BRAM36"], "buffer"))
        out.extend(svg_box(x + 225, y + 150, 200, 90, "Online Attention", ["2 EXP + 4 Scale/FMA", "14 DSP; 18 BRAM36"], "vector"))
        out.extend(svg_box(x + 445, y + 150, 185, 90, "Local K/V URAM", ["K 8 + V 8 URAM", "512-bit read/side"], "buffer"))
        out.extend(svg_path([(x + 205, y + 89), (x + 217, y + 89)], "data"))
        out.extend(svg_path([(x + 425, y + 89), (x + 437, y + 89)], "data"))
        out.extend(svg_path([(x + 425, y + 195), (x + 437, y + 195)], "data"))

    for y, core_id in zip(core_y, left_core_ids):
        draw_core(390, y, core_id)
    for y, core_id in zip(core_y, right_core_ids):
        draw_core(1760, y, core_id)

    out.append(f'<rect x="1090" y="120" width="620" height="1515" rx="8" class="shared"/>')
    out.append(svg_text(1400, 153, "Central Shared Spine", "section", "middle"))
    shared_boxes = [
        (175, "Scheduler / AXI-Lite / Barrier", ["Layer/step/tile FSM", "DMA descriptor + performance counter"], "shared"),
        (305, "Shared Activation Buffers", ["BF16 A/B: 204 KiB, 48 BRAM36", "INT8 normalized: 51 KiB, 16 BRAM36"], "buffer"),
        (435, "RMSNorm + Quant", ["48 + 16 DSP", "writes 51 KiB Shared INT8 buffer"], "vector"),
        (565, "2x4 Activation Multicast", ["256-bit registered tree", "Q/K/V and Gate/Up reuse"], "matrix"),
        (695, "K/V Weight DMA + 8-way Demux", ["PC8 513 KiB/layer", "writes 64 KiB/core during Q"], "matrix"),
        (825, "K/V Assemble + Suffix Buffer", ["8 x 32-d concatenate", "Suffix K/V 25.5 KiB"], "buffer"),
        (955, "Prefix K/V Central URAM", ["K 116 + V 116 = 232 URAM", "18 layers resident"], "buffer"),
        (1085, "Prefix/Suffix Streamer + 2x4 KV Multicast", ["867 x 256 x K/V", "13,872 cycles -> 8 caches"], "matrix"),
        (1215, "MAX Tree + Scale Broadcast", ["8-input, 3 stages, 0 DSP", "K/O/Down common scale"], "vector"),
        (1345, "SUM Tree + Post-SUM", ["8 x 256-bit -> 256-bit", "56 INT32 adders, 3-stage tail"], "vector"),
        (1475, "Dequant / Residual / Output DMA", ["16 DSP post-SUM", "feedback to BF16 bank or PC28"], "vector"),
    ]
    for y, title, lines, cls in shared_boxes:
        out.extend(svg_box(1120, y, 560, 100, title, lines, cls))

    # HBM to adjacent private cores.
    for idx, y in enumerate(core_y):
        out.extend(svg_path([(345, 186 + idx * 92), (365, 186 + idx * 92), (365, y + 90), (382, y + 90)], "data"))
        out.extend(svg_path([(2455, 186 + idx * 92), (2435, 186 + idx * 92), (2435, y + 90), (2418, y + 90)], "data"))

    # Special HBM paths.
    out.extend(svg_path([(345, 554), (1045, 554), (1045, 745), (1112, 745)], "data", "PC8 K/V"))
    out.extend(svg_path([(345, 646), (1060, 646), (1060, 355), (1112, 355)], "data", "input"))
    out.extend(svg_path([(345, 738), (1075, 738), (1075, 485), (1112, 485)], "data", "shared weights"))
    out.extend(svg_path([(2455, 554), (1730, 554), (1730, 1005), (1688, 1005)], "data", "Prefix init"))
    out.extend(svg_path([(1688, 1525), (1730, 1525), (1730, 646), (2455, 646)], "data", "output/debug"))

    # Central spine vertical data flow.
    for y1, y2 in [(405, 427), (535, 557), (615, 687), (795, 817), (925, 947), (1055, 1077), (1135, 1207), (1265, 1337), (1395, 1467)]:
        out.extend(svg_path([(1400, y1), (1400, y2)], "data"))

    # Shared activation multicast to all cores.
    for y in core_y:
        out.extend(svg_path([(1120, 615), (1065, 615), (1065, y + 89), (1048, y + 89)], "data"))
        out.extend(svg_path([(1680, 615), (1735, 615), (1735, y + 89), (1752, y + 89)], "data"))

    # K/V weights to all core layer buffers.
    for y in core_y:
        out.extend(svg_path([(1120, 745), (1075, 745), (1075, y + 65), (1048, y + 65)], "data"))
        out.extend(svg_path([(1680, 745), (1725, 745), (1725, y + 65), (1752, y + 65)], "data"))

    # K/V slices from cores to assemble and multicast back to local cache.
    for y in core_y:
        out.extend(svg_path([(1048, y + 220), (1070, y + 220), (1070, 875), (1112, 875)], "data"))
        out.extend(svg_path([(1752, y + 220), (1730, y + 220), (1730, 875), (1688, 875)], "data"))
        out.extend(svg_path([(1120, 1135), (1085, 1135), (1085, y + 200), (1048, y + 200)], "data"))
        out.extend(svg_path([(1680, 1135), (1715, 1135), (1715, y + 200), (1752, y + 200)], "data"))

    # Reduction paths.
    for y in core_y:
        out.extend(svg_path([(1048, y + 245), (1090, y + 245), (1090, 1265), (1112, 1265)], "reduce"))
        out.extend(svg_path([(1752, y + 245), (1710, y + 245), (1710, 1265), (1688, 1265)], "reduce"))
        out.extend(svg_path([(1048, y + 135), (1100, y + 135), (1100, 1395), (1112, 1395)], "reduce"))
        out.extend(svg_path([(1752, y + 135), (1700, y + 135), (1700, 1395), (1688, 1395)], "reduce"))

    # Feedback.
    out.extend(svg_path([(1400, 1575), (1400, 1665), (1025, 1665), (1025, 355), (1112, 355)], "data", "layer feedback"))

    # Control fanout.
    out.extend(svg_path([(1120, 225), (1060, 225), (1060, 1650), (365, 1650), (365, 320), (382, 320)], "control"))
    out.extend(svg_path([(1680, 225), (1740, 225), (1740, 1650), (2435, 1650), (2435, 320), (2418, 320)], "control"))

    out.append(f'<rect x="45" y="1710" width="2710" height="135" rx="6" class="neutral"/>')
    out.append(svg_text(70, 1740, "资源总账（解析预算）", "section"))
    summary = [
        "DSP: 8 x (512 MAC + 14 Online + 8 Local Vector) + 112 shared = 4384 / 4920，余 536",
        "BRAM36: 96/core x 8 + 96 shared = 864；仅与芯片标称 1344 对比，base_5 动态区必须看 Link Summary",
        "URAM: Prefix 232 + Local K/V 16/core x 8 = 360 / 544，余 184",
        "蓝线=data，橙线=SUM/MAX reduction，紫色虚线=control/event；Multicast 均采用注册化 2x4 树",
    ]
    for idx, line in enumerate(summary):
        out.append(svg_text(70, 1770 + idx * 22, line, "body"))
    out.append("</svg>")
    return "\n".join(out)


def build_timeline_svg(result: dict[str, Any]) -> str:
    width, height = 2800, 1350
    left = 310
    right = 2740
    top = 165
    total = result["cycles"]["layer"]
    plot_width = right - left
    scale = plot_width / total
    lanes = [
        "Shared RMSNorm/Quant",
        "8 Core MAC Arrays",
        "PC8 K/V DMA",
        "Private Weight DMA",
        "Central K/V Fabric",
        "Online Softmax Vector",
        "Local Vector Units",
        "SUM/MAX + Post-SUM",
        "Shared BF16/INT8 Buffers",
    ]
    lane_y = {lane: top + idx * 105 for idx, lane in enumerate(lanes)}
    colors = {
        "rms": "#7050a0",
        "mac": "#1769aa",
        "dma": "#5f6b7a",
        "kv": "#39763d",
        "online": "#bd5d12",
        "local": "#b07a13",
        "reduce": "#b94b24",
        "buffer": "#4d7f52",
        "tail": "#9b2c2c",
    }
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">']
    out.append(
        """
<defs>
  <style>
    .title{font:700 32px "Microsoft YaHei","Noto Sans CJK SC",Arial;fill:#172033}
    .subtitle{font:16px "Microsoft YaHei","Noto Sans CJK SC",Arial;fill:#4b5563}
    .lane{font:700 14px "Microsoft YaHei","Noto Sans CJK SC",Arial;fill:#27364a}
    .tick{font:11px "Microsoft YaHei","Noto Sans CJK SC",Arial;fill:#4b5563}
    .bar{stroke:#ffffff;stroke-width:1}
    .bar-text{font:700 11px "Microsoft YaHei","Noto Sans CJK SC",Arial;fill:#ffffff}
    .note{font:12px "Microsoft YaHei","Noto Sans CJK SC",Arial;fill:#27364a}
    .grid{stroke:#d7dce3;stroke-width:1}
    .axis{stroke:#778396;stroke-width:1.5}
  </style>
</defs>
"""
    )
    out.append(f'<rect width="{width}" height="{height}" fill="#ffffff"/>')
    out.append(svg_text(40, 48, "V3.2 单层执行时间轴：物理位置、耗时与并行覆盖", "title"))
    out.append(svg_text(40, 78, "401,990 cycles = 1.607960 ms @250 MHz + stall；K/V 权重预取被 Q 窗口隐藏", "subtitle"))

    for lane in lanes:
        y = lane_y[lane]
        out.append(svg_text(285, y + 29, lane, "lane", "end"))
        out.append(f'<line x1="{left}" y1="{y + 38}" x2="{right}" y2="{y + 38}" class="grid"/>')

    for cycles in range(0, 400001, 50000):
        x = left + cycles * scale
        out.append(f'<line x1="{x}" y1="{top - 20}" x2="{x}" y2="{top + len(lanes) * 105 - 30}" class="grid"/>')
        out.append(svg_text(x, top - 30, f"{cycles / 1000:.0f}k", "tick", "middle"))
    out.append(svg_text(left, top - 57, "cycle", "tick"))

    def bar(lane: str, start: int, end: int, label: str, color: str, text_color: str = "#ffffff") -> None:
        x = left + start * scale
        w = max(2.0, (end - start) * scale)
        y = lane_y[lane] + 8
        out.append(f'<rect x="{x}" y="{y}" width="{w}" height="54" rx="4" fill="{color}" class="bar"/>')
        if w > 75:
            cls = "bar-text"
            out.append(f'<text x="{x + w / 2}" y="{y + 23}" class="{cls}" text-anchor="middle" fill="{text_color}">{esc(label)}</text>')
            out.append(f'<text x="{x + w / 2}" y="{y + 42}" class="{cls}" text-anchor="middle" fill="{text_color}">{end-start:,} cyc</text>')
        else:
            short_cycles = f"{(end - start) / 1000:.1f}k" if end - start >= 1000 else f"{end - start}"
            out.append(f'<line x1="{x + w / 2}" y1="{y + 54}" x2="{x + w / 2}" y2="{y + 66}" stroke="{color}" stroke-width="1"/>')
            out.append(svg_text(x + w / 2, y + 79, f"{label} {short_cycles}", "tick", "middle"))

    t = {item["id"]: item for item in result["timeline"]}
    bar("Shared RMSNorm/Quant", t["rmsnorm1"]["start"], t["rmsnorm1"]["end"], "RMS1", colors["rms"])
    bar("Shared RMSNorm/Quant", t["rmsnorm2"]["start"], t["rmsnorm2"]["end"], "RMS2", colors["rms"])

    for key, label in [("q", "Q"), ("k", "K"), ("v", "V"), ("o", "O"), ("gate", "Gate"), ("up", "Up"), ("down", "Down")]:
        bar("8 Core MAC Arrays", t[key]["start"], t[key]["end"], label, colors["mac"])
    att_start = t["attention"]["start"]
    att_matrix_end = t["attention"]["end"] - result["cycles"]["attention_final_tail"]
    bar("8 Core MAC Arrays", att_start, att_matrix_end, "QK/PV alternating", colors["mac"])

    q_start = t["q"]["start"]
    kv_prefetch_end = q_start + result["hbm"]["kv_prefetch_cycles"]
    bar("PC8 K/V DMA", q_start, kv_prefetch_end, "513 KiB K/V prefetch", colors["dma"])
    for key in ["q", "o", "gate", "up", "down"]:
        bar("Private Weight DMA", t[key]["start"], t[key]["end"], f"{key} weight PP", colors["dma"])

    bar("Central K/V Fabric", t["kv_multicast"]["start"], t["kv_multicast"]["end"], "KV multicast", colors["kv"])
    bar("Online Softmax Vector", att_start, att_matrix_end, "block online max/exp/FMA", colors["online"])
    bar("Online Softmax Vector", att_matrix_end, t["attention"]["end"], "norm tail", colors["tail"])

    bar("Local Vector Units", t["q"]["start"], t["q"]["end"], "Q RoPE/requant", colors["local"])
    bar("Local Vector Units", t["k"]["start"], t["k"]["end"], "K RoPE/max", colors["local"])
    bar("Local Vector Units", t["up"]["start"], t["up"]["end"], "GeGLU", colors["local"])

    bar("SUM/MAX + Post-SUM", t["k"]["start"], t["k"]["end"], "K MAX/scale", colors["reduce"])
    bar("SUM/MAX + Post-SUM", t["o"]["start"], t["o"]["end"], "O SUM/dequant/residual", colors["reduce"])
    bar("SUM/MAX + Post-SUM", t["down"]["start"], t["down"]["end"], "Down SUM/dequant/residual", colors["reduce"])

    bar("Shared BF16/INT8 Buffers", 0, t["rmsnorm1"]["end"], "A residual + normalized INT8", colors["buffer"])
    bar("Shared BF16/INT8 Buffers", t["o"]["start"], t["rmsnorm2"]["end"], "B O-residual + FFN input", colors["buffer"])
    bar("Shared BF16/INT8 Buffers", t["down"]["start"], t["down"]["end"], "A next-layer output", colors["buffer"])

    note_y = top + len(lanes) * 105 + 20
    notes = [
        "1. Q、K、V、QK、PV、O、Gate、Up、Down 共用每核同一 MAC，因此这些矩阵阶段在核内不能相互并行。",
        "2. “8 核并行”指 8 个核同步工作：Q 各算一个完整 Head；K/V 各算 32-d slice；O/Down 各算同一输出的 K-slice partial。",
        "3. Online Softmax 的 max/exp/rowsum/O_tilde 更新与 QK/PV block 重叠；解析关键路径只增加最后 512 cycles。",
        "4. SUM Tree 连续吞吐 8x256-bit partial，6528-cycle payload 已包含在 O/Down 输出阶段，只额外增加 3-cycle tail。",
        "5. 当前 401,990-cycle 基线不含 VLM、state/action/time 投影和 action_out_proj；这些模块可复用 8 核阵列，但需另排时间。",
    ]
    out.append(f'<rect x="40" y="{note_y}" width="2715" height="180" rx="6" fill="#f8fafc" stroke="#94a0b2"/>')
    out.append(svg_text(65, note_y + 28, "并行关系与边界", "lane"))
    for idx, note in enumerate(notes):
        out.append(svg_text(65, note_y + 55 + idx * 24, note, "note"))
    out.append("</svg>")
    return "\n".join(out)


def render_markdown(model: Model, hw: Hardware, result: dict[str, Any]) -> str:
    c = result["cycles"]
    b = result["bram36"]
    u = result["uram"]
    d = result["dsp"]
    return "\n".join(
        [
            "# V3.2 physical architecture analytic summary",
            "",
            "> Analytic estimate at 250 MHz; not a synthesis, timing, link, or board result.",
            "",
            "## Resource totals",
            "",
            f"- DSP: {d['planned_total']} / {d['available']}, margin {d['margin']}.",
            f"- BRAM36: {b['planned_total']} planned; nominal chip comparison {b['chip_nominal']}, margin {b['chip_nominal_margin']}.",
            f"- URAM: {u['planned_total']} / {u['available']}, margin {u['margin']}.",
            f"- Per core: {result['cores']['dsp']['nominal_total']} nominal DSP, {result['cores']['bram36_engineering_budget']} BRAM36, {result['cores']['local_kv_uram_per_core']} URAM.",
            "",
            "## Timing",
            "",
            f"- One layer: {c['layer']} cycles = {c['layer_ms']:.6f} ms plus stalls.",
            f"- 18 layers: {c['eighteen_layers']} cycles = {c['eighteen_layers_ms']:.6f} ms plus stalls.",
            f"- 10 denoise steps: {c['ten_denoise_steps']} cycles = {c['ten_denoise_steps_ms']:.6f} ms plus stalls.",
            f"- K/V prefetch: {result['hbm']['kv_prefetch_cycles']} cycles inside Q's {c['q']} cycles; margin {result['hbm']['kv_prefetch_margin_cycles']}.",
            "",
            "## Important correction",
            "",
            "- Shared BF16 activation storage is two complete 102 KiB banks (204 KiB total).",
            "- A separate 51 KiB shared INT8 normalized-activation buffer lets Q/K/V and Gate/Up reuse one quantization result.",
            "- The 401990-cycle timing scope is the Transformer body only; pre/post projections remain outside this baseline.",
            "",
        ]
    )


def write_png(svg_path: Path, png_path: Path) -> str:
    try:
        import cairosvg

        cairosvg.svg2png(url=str(svg_path), write_to=str(png_path), output_width=2800)
        return "cairosvg"
    except Exception as exc:  # pragma: no cover - fallback status is recorded.
        return f"not generated: {exc}"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "v3.2-results",
    )
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    model = Model()
    hw = Hardware()
    result = evaluate(model, hw)
    payload = {
        "model": asdict(model),
        "hardware": asdict(hw),
        "result": result,
    }
    json_path = args.output_dir / "physical_architecture_budget.json"
    summary_path = args.output_dir / "physical_architecture_summary.md"
    floorplan_svg = Path(__file__).resolve().parent / "v32_physical_floorplan.svg"
    floorplan_png = Path(__file__).resolve().parent / "v32_physical_floorplan.png"
    timeline_svg = Path(__file__).resolve().parent / "v32_layer_timeline.svg"
    timeline_png = Path(__file__).resolve().parent / "v32_layer_timeline.png"

    json_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    summary_path.write_text(render_markdown(model, hw, result), encoding="utf-8")
    floorplan_svg.write_text(build_floorplan_svg(result), encoding="utf-8")
    timeline_svg.write_text(build_timeline_svg(result), encoding="utf-8")
    png_status = {
        "floorplan": write_png(floorplan_svg, floorplan_png),
        "timeline": write_png(timeline_svg, timeline_png),
    }
    print(
        json.dumps(
            {
                "layer_cycles": result["cycles"]["layer"],
                "layer_ms": result["cycles"]["layer_ms"],
                "dsp": result["dsp"]["planned_total"],
                "bram36": result["bram36"]["planned_total"],
                "uram": result["uram"]["planned_total"],
                "png": png_status,
            },
            ensure_ascii=False,
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
