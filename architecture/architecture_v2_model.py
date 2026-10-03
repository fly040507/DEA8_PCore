#!/usr/bin/env python3
"""Analytic architecture model for the pi0 Action Expert on Alveo U50.

The model is intentionally conservative:

* One physical MAC lane consumes one DSP48E2.
* Linear projections use W8A8 with INT32 accumulation.
* The shared K/V engine overlaps the private Q projection.
* Weight DMA is checked against one HBM pseudo-channel per private core.
* Results are analytic estimates, not synthesis or measured performance.

The script emits JSON, CSV, and Markdown files used by the V2 architecture
report.  All cycle equations are kept here so that future synthesis and HBM
measurements can replace assumptions without redrawing the architecture.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
from dataclasses import asdict, dataclass
from pathlib import Path


MIB = 1024 * 1024


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
    dsp_total: int = 5952
    private_dsp_budget: int = 4096
    shared_kv_m: int = 8
    shared_kv_n: int = 64
    k_tile: int = 256
    hbm_pc_gbps: float = 13.0
    stream_width_bits: int = 256
    weight_bytes: int = 1
    activation_bytes: int = 1
    partial_sum_bytes: int = 4

    @property
    def stream_bytes_per_cycle(self) -> int:
        return self.stream_width_bits // 8

    @property
    def cycles_per_ms(self) -> float:
        return self.frequency_mhz * 1000.0


@dataclass(frozen=True)
class Strategy:
    cores: int
    array_m: int
    array_n: int
    note: str

    @property
    def pes_per_core(self) -> int:
        return self.array_m * self.array_n

    @property
    def private_dsps(self) -> int:
        return self.cores * self.pes_per_core


@dataclass(frozen=True)
class Operator:
    name: str
    m: int
    k: int
    n: int
    split: str
    merge: str

    @property
    def macs(self) -> int:
        return self.m * self.k * self.n

    @property
    def parameters(self) -> int:
        return self.k * self.n


def ceil_div(value: int, divisor: int) -> int:
    return (value + divisor - 1) // divisor


def os_array_cycles(
    m: int,
    k: int,
    n: int,
    array_m: int,
    array_n: int,
    k_tile: int,
) -> int:
    """Cycles for an output-stationary systolic array.

    Each output tile takes ``k_extent + array_m + array_n - 2`` cycles for a
    K slice.  The final K slice uses its real extent; the physical M/N pipeline
    dimensions remain unchanged for edge tiles.
    """

    m_tiles = ceil_div(m, array_m)
    n_tiles = ceil_div(n, array_n)
    k_cycles = 0
    for k_start in range(0, k, k_tile):
        k_extent = min(k_tile, k - k_start)
        k_cycles += k_extent + array_m + array_n - 2
    return m_tiles * n_tiles * k_cycles


def cycles_to_ms(cycles: int, hardware: Hardware) -> float:
    return cycles / hardware.cycles_per_ms


def operators(model: Model) -> list[Operator]:
    return [
        Operator(
            "Q",
            model.tokens,
            model.hidden,
            model.query_width,
            "N / query-head",
            "disjoint write",
        ),
        Operator(
            "K",
            model.tokens,
            model.hidden,
            model.head_dim,
            "shared",
            "broadcast",
        ),
        Operator(
            "V",
            model.tokens,
            model.hidden,
            model.head_dim,
            "shared",
            "broadcast",
        ),
        Operator(
            "O",
            model.tokens,
            model.query_width,
            model.hidden,
            "K / query-head",
            "sum reduction",
        ),
        Operator(
            "Gate",
            model.tokens,
            model.hidden,
            model.ffn,
            "N",
            "disjoint write",
        ),
        Operator(
            "Up",
            model.tokens,
            model.hidden,
            model.ffn,
            "N",
            "disjoint write",
        ),
        Operator(
            "Down",
            model.tokens,
            model.ffn,
            model.hidden,
            "K",
            "sum reduction",
        ),
    ]


def private_weight_parameters(model: Model) -> int:
    return (
        model.hidden * model.query_width
        + model.query_width * model.hidden
        + 3 * model.hidden * model.ffn
    )


def shared_kv_weight_parameters(model: Model) -> int:
    return 2 * model.hidden * model.head_dim


def evaluate_strategy(
    model: Model,
    hardware: Hardware,
    strategy: Strategy,
) -> dict[str, object]:
    cores = strategy.cores
    if model.ffn % cores:
        raise ValueError(f"{cores} cores do not divide FFN width {model.ffn}")
    if model.query_width % cores:
        raise ValueError(
            f"{cores} cores do not divide query width {model.query_width}"
        )

    q_n = model.query_width // cores
    o_k = model.query_width // cores
    ffn_n = model.ffn // cores
    down_k = model.ffn // cores

    q_cycles = os_array_cycles(
        model.tokens,
        model.hidden,
        q_n,
        strategy.array_m,
        strategy.array_n,
        hardware.k_tile,
    )
    o_cycles = os_array_cycles(
        model.tokens,
        o_k,
        model.hidden,
        strategy.array_m,
        strategy.array_n,
        hardware.k_tile,
    )
    gate_cycles = os_array_cycles(
        model.tokens,
        model.hidden,
        ffn_n,
        strategy.array_m,
        strategy.array_n,
        hardware.k_tile,
    )
    up_cycles = gate_cycles
    down_cycles = os_array_cycles(
        model.tokens,
        down_k,
        model.hidden,
        strategy.array_m,
        strategy.array_n,
        hardware.k_tile,
    )

    kv_one_cycles = os_array_cycles(
        model.tokens,
        model.hidden,
        model.head_dim,
        hardware.shared_kv_m,
        hardware.shared_kv_n,
        hardware.k_tile,
    )
    kv_cycles = 2 * kv_one_cycles

    if cores <= model.query_heads:
        heads_per_core = model.query_heads // cores
        head_parts = 1
        attention_rows = model.tokens * heads_per_core
        attention_k = model.head_dim
        attention_out_n = model.head_dim
    else:
        if cores % model.query_heads:
            raise ValueError(
                f"{cores} cores cannot evenly split {model.query_heads} heads"
            )
        heads_per_core = 0.5
        head_parts = cores // model.query_heads
        attention_rows = model.tokens
        attention_k = model.head_dim // head_parts
        attention_out_n = model.head_dim // head_parts

    qk_cycles = os_array_cycles(
        attention_rows,
        attention_k,
        model.full_kv_tokens,
        strategy.array_m,
        strategy.array_n,
        hardware.k_tile,
    )
    sv_cycles = os_array_cycles(
        attention_rows,
        model.full_kv_tokens,
        attention_out_n,
        strategy.array_m,
        strategy.array_n,
        hardware.k_tile,
    )

    score_pair_cycles = 0
    if head_parts > 1:
        score_bytes = (
            model.tokens * model.full_kv_tokens * hardware.partial_sum_bytes
        )
        one_score_stream = ceil_div(
            score_bytes, hardware.stream_bytes_per_cycle
        )
        # One pass sums the partial scores; one pass broadcasts the softmax
        # result back to both halves.  All head pairs operate in parallel.
        score_pair_cycles = 2 * one_score_stream

    kv_broadcast_bytes = (
        2
        * model.full_kv_tokens
        * model.head_dim
        * hardware.activation_bytes
    )
    kv_broadcast_cycles = ceil_div(
        kv_broadcast_bytes, hardware.stream_bytes_per_cycle
    )

    reduction_depth = int(math.log2(cores))
    reduction_result_bytes = (
        model.tokens * model.hidden * hardware.partial_sum_bytes
    )
    reduction_stream_cycles = ceil_div(
        reduction_result_bytes, hardware.stream_bytes_per_cycle
    )
    # O and Down each traverse the critical path of the tree.
    reduction_cycles = 2 * reduction_depth * reduction_stream_cycles

    attention_cycles = qk_cycles + sv_cycles + score_pair_cycles
    ffn_cycles = gate_cycles + up_cycles + down_cycles
    layer_cycles = (
        max(q_cycles, kv_cycles)
        + kv_broadcast_cycles
        + attention_cycles
        + o_cycles
        + ffn_cycles
        + reduction_cycles
    )

    private_weights = (
        private_weight_parameters(model)
        * hardware.weight_bytes
        / cores
    )
    shared_weights = (
        shared_kv_weight_parameters(model) * hardware.weight_bytes
    )
    private_load_ms = private_weights / (hardware.hbm_pc_gbps * 1e9) * 1000
    shared_load_ms = shared_weights / (hardware.hbm_pc_gbps * 1e9) * 1000

    shared_kv_dsps = hardware.shared_kv_m * hardware.shared_kv_n
    main_dsps = strategy.private_dsps + shared_kv_dsps
    dsp_margin = hardware.dsp_total - main_dsps

    return {
        "cores": cores,
        "array_per_core": f"{strategy.array_m}x{strategy.array_n}",
        "k_tile": hardware.k_tile,
        "pes_per_core": strategy.pes_per_core,
        "private_dsps": strategy.private_dsps,
        "shared_kv_dsps": shared_kv_dsps,
        "main_mac_dsps": main_dsps,
        "dsp_margin": dsp_margin,
        "dsp_margin_percent": 100.0 * dsp_margin / hardware.dsp_total,
        "fits_dsp": dsp_margin >= 0,
        "heads_per_core": heads_per_core,
        "head_parts": head_parts,
        "q_n_per_core": q_n,
        "o_k_per_core": o_k,
        "ffn_n_per_core": ffn_n,
        "down_k_per_core": down_k,
        "reduction_depth": reduction_depth,
        "private_weight_mib_per_core_layer": private_weights / MIB,
        "private_weight_mib_per_core_18_layers": (
            private_weights * model.layers / MIB
        ),
        "shared_kv_weight_mib_18_layers": (
            shared_weights * model.layers / MIB
        ),
        "private_weight_load_ms_per_layer": private_load_ms,
        "shared_kv_weight_load_ms_per_layer": shared_load_ms,
        "q_ms": cycles_to_ms(q_cycles, hardware),
        "shared_kv_ms": cycles_to_ms(kv_cycles, hardware),
        "kv_broadcast_ms": cycles_to_ms(kv_broadcast_cycles, hardware),
        "qk_ms": cycles_to_ms(qk_cycles, hardware),
        "sv_ms": cycles_to_ms(sv_cycles, hardware),
        "head_split_overhead_ms": cycles_to_ms(
            score_pair_cycles, hardware
        ),
        "attention_ms": cycles_to_ms(attention_cycles, hardware),
        "o_ms": cycles_to_ms(o_cycles, hardware),
        "gate_ms": cycles_to_ms(gate_cycles, hardware),
        "up_ms": cycles_to_ms(up_cycles, hardware),
        "down_ms": cycles_to_ms(down_cycles, hardware),
        "reduction_ms": cycles_to_ms(reduction_cycles, hardware),
        "analytic_layer_ms": cycles_to_ms(layer_cycles, hardware),
        "analytic_18_layer_step_ms": cycles_to_ms(
            layer_cycles * model.layers, hardware
        ),
        "analytic_10_step_ms": cycles_to_ms(
            layer_cycles * model.layers * model.denoise_steps, hardware
        ),
        "note": strategy.note,
    }


def evaluate_same_tile(
    model: Model,
    hardware: Hardware,
    cores: int,
    array_m: int = 8,
    array_n: int = 64,
) -> dict[str, object]:
    result = evaluate_strategy(
        model,
        hardware,
        Strategy(
            cores=cores,
            array_m=array_m,
            array_n=array_n,
            note="Identical 8x64 private core comparison",
        ),
    )
    return {
        "cores": cores,
        "array_per_core": result["array_per_core"],
        "private_dsps": result["private_dsps"],
        "main_mac_dsps": result["main_mac_dsps"],
        "fits_dsp": result["fits_dsp"],
        "analytic_layer_ms": result["analytic_layer_ms"],
    }


def write_csv(path: Path, rows: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8-sig") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def markdown_table(headers: list[str], rows: list[list[str]]) -> str:
    result = [
        "| " + " | ".join(headers) + " |",
        "| " + " | ".join("---" for _ in headers) + " |",
    ]
    result.extend("| " + " | ".join(row) + " |" for row in rows)
    return "\n".join(result)


def render_markdown(
    model: Model,
    hardware: Hardware,
    results: list[dict[str, object]],
    same_tile: list[dict[str, object]],
) -> str:
    op_rows = [
        [
            op.name,
            f"[{op.m},{op.k}] x [{op.k},{op.n}]",
            op.split,
            op.merge,
            f"{op.macs / 1e6:.3f}",
        ]
        for op in operators(model)
    ]
    result_rows = [
        [
            str(item["cores"]),
            str(item["array_per_core"]),
            str(item["private_dsps"]),
            str(item["main_mac_dsps"]),
            f'{item["dsp_margin_percent"]:.1f}%',
            str(item["heads_per_core"]),
            str(item["reduction_depth"]),
            f'{item["head_split_overhead_ms"]:.3f}',
            f'{item["analytic_layer_ms"]:.3f}',
        ]
        for item in results
    ]
    detail_rows = [
        [
            str(item["cores"]),
            f'{item["q_ms"]:.3f}',
            f'{item["shared_kv_ms"]:.3f}',
            f'{item["kv_broadcast_ms"]:.3f}',
            f'{item["attention_ms"]:.3f}',
            f'{item["o_ms"]:.3f}',
            f'{item["gate_ms"]:.3f}',
            f'{item["up_ms"]:.3f}',
            f'{item["down_ms"]:.3f}',
            f'{item["reduction_ms"]:.3f}',
        ]
        for item in results
    ]
    same_tile_rows = [
        [
            str(item["cores"]),
            str(item["array_per_core"]),
            str(item["private_dsps"]),
            str(item["main_mac_dsps"]),
            "yes" if item["fits_dsp"] else "no",
            f'{item["analytic_layer_ms"]:.3f}',
        ]
        for item in same_tile
    ]

    return "\n".join(
        [
            "# pi0 Action Expert FPGA V2 analytic comparison",
            "",
            "> Analytic array/interconnect estimate. It excludes RMSNorm, RoPE,",
            "> GeGLU, residual, host overhead, and timing closure effects.",
            "",
            "## Fixed model",
            "",
            f"- Tokens: {model.tokens}",
            f"- Hidden / FFN: {model.hidden} / {model.ffn}",
            f"- Q heads / KV heads / head dimension: "
            f"{model.query_heads} / {model.kv_heads} / {model.head_dim}",
            f"- Prefix / full KV tokens: "
            f"{model.prefix_tokens} / {model.full_kv_tokens}",
            f"- Layers / denoise steps: {model.layers} / {model.denoise_steps}",
            "",
            "## Operator mapping",
            "",
            markdown_table(
                ["Operator", "GEMM", "Split", "Cross-core merge", "MMAC"],
                op_rows,
            ),
            "",
            "## Fixed aggregate private-DSP comparison",
            "",
            markdown_table(
                [
                    "Cores",
                    "Array/core",
                    "Private DSP",
                    "Main MAC DSP",
                    "DSP margin",
                    "Heads/core",
                    "Reduction depth",
                    "Head-split ms",
                    "Layer ms",
                ],
                result_rows,
            ),
            "",
            "## Stage latency",
            "",
            markdown_table(
                [
                    "Cores",
                    "Q",
                    "Shared K/V",
                    "KV bcast",
                    "Attention",
                    "O",
                    "Gate",
                    "Up",
                    "Down",
                    "O+Down reduce",
                ],
                detail_rows,
            ),
            "",
            "Q and shared K/V overlap, so the layer total uses their maximum.",
            "",
            "## Identical 8x64 core comparison",
            "",
            markdown_table(
                [
                    "Cores",
                    "Array/core",
                    "Private DSP",
                    "Main MAC DSP",
                    "Fits U50",
                    "Layer ms",
                ],
                same_tile_rows,
            ),
            "",
            "## Frozen V1 tile",
            "",
            "- 8 cores, one complete query head per core.",
            "- Private array/core: 8x64 PEs, K tile 256.",
            "- Shared K/V array: 8x64 PEs.",
            "- Main MAC DSPs: 8x512 + 512 = 4608.",
            f"- DSP margin: {hardware.dsp_total - 4608} / "
            f"{hardware.dsp_total}.",
            "- One INT8 MAC per DSP is assumed until packing is synthesized.",
            "",
        ]
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "v2-results",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    output_dir: Path = args.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)

    model = Model()
    hardware = Hardware()
    strategies = [
        Strategy(
            cores=4,
            array_m=32,
            array_n=32,
            note="Two complete query heads per core",
        ),
        Strategy(
            cores=8,
            array_m=8,
            array_n=64,
            note="One complete query head per core",
        ),
        Strategy(
            cores=16,
            array_m=8,
            array_n=32,
            note="Each query head is split across a core pair",
        ),
    ]
    results = [
        evaluate_strategy(model, hardware, strategy)
        for strategy in strategies
    ]
    same_tile = [
        evaluate_same_tile(model, hardware, cores)
        for cores in (4, 8, 16)
    ]

    payload = {
        "model": asdict(model),
        "hardware": asdict(hardware),
        "strategies": results,
        "same_8x64_tile": same_tile,
        "provenance": {
            "model_dimensions": "OpenPI code and mentor report",
            "u50_resources": "Mentor report and AMD DS965",
            "cycle_model": "Analytic assumption",
            "frequency": "Architecture target; pending timing closure",
            "hbm_pc_gbps": "Analytic assumption; pending board measurement",
            "dsp_packing": "One MAC/DSP conservative baseline",
        },
    }
    (output_dir / "architecture_v2_results.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    write_csv(output_dir / "core_comparison.csv", results)
    write_csv(output_dir / "same_8x64_tile.csv", same_tile)
    (output_dir / "architecture_v2_comparison.md").write_text(
        render_markdown(model, hardware, results, same_tile),
        encoding="utf-8",
    )

    print(
        json.dumps(
            [
                {
                    "cores": item["cores"],
                    "array": item["array_per_core"],
                    "main_mac_dsps": item["main_mac_dsps"],
                    "layer_ms": round(float(item["analytic_layer_ms"]), 6),
                }
                for item in results
            ],
            ensure_ascii=False,
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
