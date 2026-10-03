#!/usr/bin/env python3
"""Analytic V3.1 resource and cycle model for the pi0 Action Expert."""

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
    base5_dsp_available: int = 4920
    chip_dsp_total: int = 5952
    base5_uram_available: int = 544
    uram_native_width_bits: int = 72
    uram_native_depth: int = 4096
    online_exp_lanes_per_core: int = 2
    online_state_lanes_per_core: int = 4
    vector_lanes: int = 16

    @property
    def cycles_per_ms(self) -> float:
        return self.frequency_mhz * 1000.0

    @property
    def stream_bytes_per_cycle(self) -> int:
        return self.stream_width_bits // 8


def ceil_div(value: int, divisor: int) -> int:
    return (value + divisor - 1) // divisor


def ms(cycles: int, hardware: Hardware) -> float:
    return cycles / hardware.cycles_per_ms


def os_cycles(m: int, k: int, n: int, hardware: Hardware) -> int:
    total_per_mn_tile = 0
    for start in range(0, k, hardware.k_tile):
        extent = min(hardware.k_tile, k - start)
        total_per_mn_tile += extent + hardware.array_m + hardware.array_n - 2
    return (
        ceil_div(m, hardware.array_m)
        * ceil_div(n, hardware.array_n)
        * total_per_mn_tile
    )


def uram_blocks(total_bytes: int, port_bits: int, hardware: Hardware) -> int:
    words = ceil_div(total_bytes * 8, port_bits)
    return (
        ceil_div(port_bits, hardware.uram_native_width_bits)
        * ceil_div(words, hardware.uram_native_depth)
    )


def evaluate(model: Model, hardware: Hardware) -> dict[str, object]:
    q_n = model.query_width // hardware.cores
    kv_n = model.head_dim // hardware.cores
    ffn_n = model.ffn // hardware.cores

    q_cycles = os_cycles(model.tokens, model.hidden, q_n, hardware)
    kv_one_cycles = os_cycles(model.tokens, model.hidden, kv_n, hardware)
    q_k_v_cycles = q_cycles + 2 * kv_one_cycles

    kv_broadcast_bytes = 2 * model.full_kv_tokens * model.head_dim
    kv_broadcast_cycles = ceil_div(
        kv_broadcast_bytes, hardware.stream_bytes_per_cycle
    )

    attention_blocks = []
    q_tiles = ceil_div(model.tokens, hardware.array_m)
    matrix_per_query_tile = 0
    for start in range(0, model.full_kv_tokens, hardware.k_tile):
        keys = min(hardware.k_tile, model.full_kv_tokens - start)
        qk = os_cycles(hardware.array_m, model.head_dim, keys, hardware)
        pv = os_cycles(hardware.array_m, keys, model.head_dim, hardware)
        exp_work = ceil_div(
            hardware.array_m * keys,
            hardware.online_exp_lanes_per_core,
        )
        state_work = ceil_div(
            hardware.array_m * model.head_dim,
            hardware.online_state_lanes_per_core,
        )
        attention_blocks.append(
            {
                "keys": keys,
                "qk_cycles": qk,
                "pv_cycles": pv,
                "exp_work_cycles": exp_work,
                "state_work_cycles": state_work,
                "exp_hidden_by_qk": exp_work <= qk,
                "state_hidden_by_pv": state_work <= pv,
            }
        )
        matrix_per_query_tile += qk + pv

    qk_cycles = q_tiles * sum(x["qk_cycles"] for x in attention_blocks)
    pv_cycles = q_tiles * sum(x["pv_cycles"] for x in attention_blocks)
    attention_matrix_cycles = q_tiles * matrix_per_query_tile
    final_normalize_cycles = ceil_div(
        hardware.array_m * model.head_dim,
        hardware.online_state_lanes_per_core,
    )
    online_attention_cycles = attention_matrix_cycles + final_normalize_cycles

    o_cycles = os_cycles(model.tokens, model.head_dim, model.hidden, hardware)
    gate_cycles = os_cycles(model.tokens, model.hidden, ffn_n, hardware)
    up_cycles = gate_cycles
    down_cycles = os_cycles(model.tokens, ffn_n, model.hidden, hardware)

    sum_payload_cycles = ceil_div(
        model.tokens * model.hidden,
        hardware.stream_width_bits // 32,
    )
    sum_tree_depth = int(math.log2(hardware.cores))
    one_sum_stream_cycles = sum_payload_cycles + sum_tree_depth
    two_sum_tail_cycles = 2 * sum_tree_depth

    rmsnorm_pass_cycles = (
        model.tokens * ceil_div(model.hidden, hardware.vector_lanes)
    )
    rmsnorm_quant_tail = ceil_div(model.hidden, hardware.vector_lanes)
    one_rmsnorm_cycles = 2 * rmsnorm_pass_cycles + rmsnorm_quant_tail
    two_rmsnorm_cycles = 2 * one_rmsnorm_cycles

    matrix_and_interconnect_cycles = (
        q_k_v_cycles
        + kv_broadcast_cycles
        + online_attention_cycles
        + o_cycles
        + gate_cycles
        + up_cycles
        + down_cycles
        + two_sum_tail_cycles
    )
    first_order_layer_cycles = matrix_and_interconnect_cycles + two_rmsnorm_cycles

    main_array_dsps = hardware.cores * hardware.array_m * hardware.array_n
    online_attention_nominal_dsps = (
        hardware.cores
        * (
            hardware.online_exp_lanes_per_core
            + hardware.online_state_lanes_per_core
            + 2 * hardware.online_state_lanes_per_core
        )
        + 8
    )
    dsp = {
        "main_array": main_array_dsps,
        "online_attention_nominal": online_attention_nominal_dsps,
        "online_attention_planned": 144,
        "shared_rmsnorm_nominal": 41,
        "shared_rmsnorm_planned": 48,
        "local_vector_units": hardware.cores * 8,
        "post_sum_dequant": 16,
        "shared_quant_conversion": 16,
    }
    dsp["non_matrix_nominal"] = (
        dsp["online_attention_nominal"]
        + dsp["shared_rmsnorm_nominal"]
        + dsp["local_vector_units"]
        + dsp["post_sum_dequant"]
        + dsp["shared_quant_conversion"]
    )
    dsp["non_matrix_planned"] = (
        dsp["online_attention_planned"]
        + dsp["shared_rmsnorm_planned"]
        + dsp["local_vector_units"]
        + dsp["post_sum_dequant"]
        + dsp["shared_quant_conversion"]
    )
    dsp["non_matrix_hard_cap"] = 320
    dsp["planned_total"] = main_array_dsps + dsp["non_matrix_planned"]
    dsp["hard_cap_total"] = main_array_dsps + dsp["non_matrix_hard_cap"]
    dsp["base5_planned_margin"] = hardware.base5_dsp_available - dsp["planned_total"]
    dsp["base5_hard_cap_margin"] = hardware.base5_dsp_available - dsp["hard_cap_total"]

    score_pp = 2 * hardware.array_m * hardware.k_tile * 4
    prob_pp = 2 * hardware.array_m * hardware.k_tile * 2
    dual_context = 2 * hardware.array_m * model.head_dim * 4
    pv_fifo = hardware.array_m * model.head_dim * 4
    attention_buffer = score_pp + prob_pp + dual_context + pv_fifo

    private_weight_pp = 2 * hardware.k_tile * hardware.array_n
    kv_layer_weights = 2 * model.hidden * kv_n
    activation_tile = hardware.array_m * hardware.k_tile
    psum_slice = model.tokens * hardware.array_n * 4
    q_buffer = model.tokens * q_n * 2
    gate = model.tokens * ffn_n * 2
    per_core_bram_like = (
        private_weight_pp
        + kv_layer_weights
        + activation_tile
        + psum_slice
        + q_buffer
        + gate
        + gate
        + attention_buffer
    )

    prefix_kv_bytes = (
        2 * model.prefix_tokens * model.head_dim * model.layers
    )
    local_kv_bytes_per_core = 2 * model.full_kv_tokens * model.head_dim
    prefix_one = model.prefix_tokens * model.head_dim * model.layers
    prefix_kv_uram = 2 * uram_blocks(
        prefix_one, hardware.stream_width_bits, hardware
    )
    local_one = model.full_kv_tokens * model.head_dim
    local_kv_uram = (
        2 * uram_blocks(local_one, 512, hardware) * hardware.cores
    )

    kv_prefetch_bytes = 2 * model.hidden * model.head_dim + 2 * model.head_dim * 2
    kv_prefetch_cycles = ceil_div(
        kv_prefetch_bytes, hardware.stream_bytes_per_cycle
    )

    cycles = {
        "q": q_cycles,
        "distributed_k": kv_one_cycles,
        "distributed_v": kv_one_cycles,
        "q_k_v": q_k_v_cycles,
        "kv_multicast": kv_broadcast_cycles,
        "qk_total": qk_cycles,
        "pv_total": pv_cycles,
        "attention_matrix": attention_matrix_cycles,
        "online_final_normalize": final_normalize_cycles,
        "online_attention": online_attention_cycles,
        "o": o_cycles,
        "gate": gate_cycles,
        "up": up_cycles,
        "down": down_cycles,
        "sum_payload_per_reduction": sum_payload_cycles,
        "sum_stream_per_reduction": one_sum_stream_cycles,
        "sum_tail_per_reduction": sum_tree_depth,
        "two_sum_tails": two_sum_tail_cycles,
        "rmsnorm_pass": rmsnorm_pass_cycles,
        "rmsnorm_quant_tail": rmsnorm_quant_tail,
        "one_rmsnorm": one_rmsnorm_cycles,
        "two_rmsnorm": two_rmsnorm_cycles,
        "matrix_and_interconnect": matrix_and_interconnect_cycles,
        "first_order_layer": first_order_layer_cycles,
    }

    return {
        "architecture": {
            "cores": hardware.cores,
            "array_per_core": "8x64 INT8 MAC",
            "tile": {"m": 8, "n": 64, "k": 256},
            "online_exp_lanes_per_core": hardware.online_exp_lanes_per_core,
            "online_state_lanes_per_core": hardware.online_state_lanes_per_core,
            "attention_blocks": attention_blocks,
        },
        "dsp": dsp,
        "cycles": cycles,
        "latency_ms": {key: ms(value, hardware) for key, value in cycles.items() if isinstance(value, int)},
        "buffers": {
            "score_ping_pong_per_core": score_pp,
            "probability_ping_pong_per_core": prob_pp,
            "dual_query_context_per_core": dual_context,
            "pv_output_fifo_per_core": pv_fifo,
            "attention_total_per_core": attention_buffer,
            "attention_total_all_cores": attention_buffer * hardware.cores,
            "attention_bram36_capacity_lower_bound": 86,
            "attention_bram36_engineering_budget": 144,
            "bram_like_per_core": per_core_bram_like,
            "bram_like_all_cores": per_core_bram_like * hardware.cores,
            "prefix_kv_all_layers": prefix_kv_bytes,
            "local_kv_per_core": local_kv_bytes_per_core,
        },
        "uram": {
            "prefix_kv": prefix_kv_uram,
            "local_kv_all_cores": local_kv_uram,
            "planned": prefix_kv_uram + local_kv_uram,
            "base5_available": hardware.base5_uram_available,
            "margin": hardware.base5_uram_available - prefix_kv_uram - local_kv_uram,
        },
        "hbm": {
            "stream_width_bits": hardware.stream_width_bits,
            "bytes_per_cycle": hardware.stream_bytes_per_cycle,
            "gbps_per_port": hardware.stream_bytes_per_cycle * hardware.frequency_mhz / 1000.0,
            "kv_layer_prefetch_bytes": kv_prefetch_bytes,
            "kv_layer_prefetch_cycles": kv_prefetch_cycles,
            "q_window_cycles": q_cycles,
            "kv_prefetch_margin_cycles": q_cycles - kv_prefetch_cycles,
        },
    }


def render_summary(model: Model, hardware: Hardware, result: dict[str, object]) -> str:
    c = result["cycles"]
    d = result["dsp"]
    b = result["buffers"]
    lines = [
        "# pi0 Action Expert FPGA V3.1 analytic summary",
        "",
        "> Frozen analytic baseline; synthesis and board tests are still required.",
        "",
        "## Frozen decisions",
        "",
        "- 8 homogeneous cores; each core has one 8x64 INT8 MAC array (512 DSP).",
        "- QK and PV reuse the same array and therefore execute sequentially.",
        "- Online attention uses 2 EXP lanes and 4 Scale/FMA state lanes per core.",
        "- O/Down SUM trees stream with MAC output; only 3 tail cycles are added per reduction.",
        "",
        "## DSP budget",
        "",
        f"- Main arrays: {d['main_array']} DSP.",
        f"- Non-matrix nominal: {d['non_matrix_nominal']} DSP.",
        f"- Non-matrix planned: {d['non_matrix_planned']} DSP.",
        f"- Planned total: {d['planned_total']} / {hardware.base5_dsp_available} DSP; margin {d['base5_planned_margin']}.",
        f"- Hard-cap total: {d['hard_cap_total']} DSP; margin {d['base5_hard_cap_margin']}.",
        "",
        "## Attention timing",
        "",
        f"- QK matrix total: {c['qk_total']} cycles.",
        f"- PV matrix total: {c['pv_total']} cycles.",
        f"- Matrix lower bound: {c['attention_matrix']} cycles.",
        f"- Final O normalization tail: {c['online_final_normalize']} cycles.",
        f"- Online attention: {c['online_attention']} cycles = {result['latency_ms']['online_attention']:.6f} ms.",
        "",
        "## RMSNorm and layer timing",
        "",
        f"- One RMSNorm: {c['one_rmsnorm']} cycles.",
        f"- Two RMSNorms: {c['two_rmsnorm']} cycles.",
        f"- One layer: {c['first_order_layer']} cycles = {result['latency_ms']['first_order_layer']:.6f} ms plus stalls.",
        f"- 18-layer step: {18 * result['latency_ms']['first_order_layer']:.6f} ms plus stalls.",
        f"- 10 denoise steps: {180 * result['latency_ms']['first_order_layer']:.6f} ms plus stalls.",
        "",
        "## Attention buffer",
        "",
        f"- Per core: {b['attention_total_per_core'] / KIB:.0f} KiB.",
        f"- Eight cores: {b['attention_total_all_cores'] / KIB:.0f} KiB.",
        f"- BRAM36 engineering budget: {b['attention_bram36_engineering_budget']} blocks.",
    ]
    return "\n".join(lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "v3.1-results",
    )
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    model = Model()
    hardware = Hardware()
    result = evaluate(model, hardware)
    payload = {
        "model": asdict(model),
        "hardware": asdict(hardware),
        "result": result,
        "provenance": {
            "status": "analytic estimate",
            "frequency": "250 MHz target, pending timing closure",
            "dsp_baseline": "one signed INT8 MAC per DSP",
        },
    }
    (args.output_dir / "architecture_v31_results.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    (args.output_dir / "architecture_v31_summary.md").write_text(
        render_summary(model, hardware, result), encoding="utf-8"
    )
    print(json.dumps({
        "attention_cycles": result["cycles"]["online_attention"],
        "layer_cycles": result["cycles"]["first_order_layer"],
        "planned_dsp": result["dsp"]["planned_total"],
        "base5_margin": result["dsp"]["base5_planned_margin"],
    }, indent=2))


if __name__ == "__main__":
    main()
