#!/usr/bin/env python3
"""Analytic 4-core/8-core trade-off model for the pi0 Action Expert.

This is an event-level lower-bound model, not a cycle-accurate simulator or
synthesis result. Hardware throughput and bandwidth are explicit parameters so
that unverified DSP packing assumptions do not become architectural facts.
"""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import asdict, dataclass
from pathlib import Path


MIB = 1024 * 1024
GIGA = 1_000_000_000


@dataclass(frozen=True)
class ModelConfig:
    tokens: int = 51
    hidden: int = 1024
    ffn: int = 4096
    query_heads: int = 8
    kv_heads: int = 1
    head_dim: int = 256
    kv_tokens: int = 867
    layers: int = 18
    flow_steps: int = 10

    @property
    def query_width(self) -> int:
        return self.query_heads * self.head_dim


@dataclass(frozen=True)
class HardwareConfig:
    weight_bytes: int = 2
    partial_sum_bytes: int = 4
    frequency_mhz: float = 200.0
    macs_per_cycle_per_core: float = 512.0
    compute_efficiency: float = 0.70
    hbm_total_gbps: float = 316.0
    hbm_efficiency: float = 0.70
    private_hbm_channels: int = 8
    reduction_link_gbps: float = 32.0

    @property
    def core_macs_per_second(self) -> float:
        return (
            self.frequency_mhz
            * 1_000_000
            * self.macs_per_cycle_per_core
            * self.compute_efficiency
        )

    @property
    def private_channel_bytes_per_second(self) -> float:
        return (
            self.hbm_total_gbps
            * GIGA
            * self.hbm_efficiency
            / self.private_hbm_channels
        )

    @property
    def reduction_link_bytes_per_second(self) -> float:
        return self.reduction_link_gbps * GIGA


@dataclass(frozen=True)
class OperatorMapping:
    name: str
    m: int
    k: int
    n: int
    split_axis: str
    result_merge: str
    shared: bool = False

    @property
    def macs(self) -> int:
        return self.m * self.k * self.n

    @property
    def weight_parameters(self) -> int:
        return self.k * self.n


def build_operator_map(model: ModelConfig) -> list[OperatorMapping]:
    return [
        OperatorMapping(
            "Q",
            model.tokens,
            model.hidden,
            model.query_width,
            "N",
            "disjoint write / logical concatenate",
        ),
        OperatorMapping(
            "K",
            model.tokens,
            model.hidden,
            model.kv_heads * model.head_dim,
            "shared",
            "broadcast once",
            shared=True,
        ),
        OperatorMapping(
            "V",
            model.tokens,
            model.hidden,
            model.kv_heads * model.head_dim,
            "shared",
            "broadcast once",
            shared=True,
        ),
        OperatorMapping(
            "O",
            model.tokens,
            model.query_width,
            model.hidden,
            "K",
            "sum reduction",
        ),
        OperatorMapping(
            "Gate",
            model.tokens,
            model.hidden,
            model.ffn,
            "N",
            "disjoint write / logical concatenate",
        ),
        OperatorMapping(
            "Up",
            model.tokens,
            model.hidden,
            model.ffn,
            "N",
            "disjoint write / logical concatenate",
        ),
        OperatorMapping(
            "Down",
            model.tokens,
            model.ffn,
            model.hidden,
            "K",
            "sum reduction",
        ),
    ]


def validate_strategy(model: ModelConfig, cores: int) -> None:
    if cores <= 0 or cores & (cores - 1):
        raise ValueError("Core count must be a positive power of two.")
    if model.query_heads % cores != 0:
        raise ValueError(
            f"{cores} cores do not divide {model.query_heads} query heads. "
            "That strategy would split a head and needs a different attention model."
        )
    if model.ffn % cores != 0:
        raise ValueError(f"{cores} cores do not divide FFN width {model.ffn}.")


def evaluate_strategy(
    model: ModelConfig, hardware: HardwareConfig, cores: int
) -> dict[str, object]:
    validate_strategy(model, cores)
    operators = build_operator_map(model)
    private_ops = [op for op in operators if not op.shared]
    shared_ops = [op for op in operators if op.shared]

    private_weight_parameters = sum(op.weight_parameters for op in private_ops)
    shared_weight_parameters = sum(op.weight_parameters for op in shared_ops)
    private_weight_bytes_per_core_layer = (
        private_weight_parameters * hardware.weight_bytes / cores
    )
    shared_weight_bytes_per_layer = shared_weight_parameters * hardware.weight_bytes

    private_projection_macs_per_core = sum(op.macs for op in private_ops) / cores
    shared_kv_macs = sum(op.macs for op in shared_ops)
    total_attention_macs = (
        2
        * model.query_heads
        * model.tokens
        * model.kv_tokens
        * model.head_dim
    )
    attention_macs_per_core = total_attention_macs / cores

    partial_elements = model.tokens * model.hidden
    partial_bytes = partial_elements * hardware.partial_sum_bytes
    reduction_depth = int(math.log2(cores))
    reduction_traffic_per_operator = (cores - 1) * partial_bytes
    reduction_traffic_per_layer = 2 * reduction_traffic_per_operator
    reduction_critical_seconds = (
        2
        * reduction_depth
        * partial_bytes
        / hardware.reduction_link_bytes_per_second
    )

    core_compute_seconds = (
        private_projection_macs_per_core + attention_macs_per_core
    ) / hardware.core_macs_per_second
    shared_kv_compute_seconds = shared_kv_macs / hardware.core_macs_per_second
    compute_lower_bound_seconds = max(core_compute_seconds, shared_kv_compute_seconds)

    private_load_seconds = (
        private_weight_bytes_per_core_layer
        / hardware.private_channel_bytes_per_second
    )
    shared_kv_load_seconds = (
        shared_weight_bytes_per_layer
        / hardware.private_channel_bytes_per_second
    )
    weight_load_lower_bound_seconds = max(
        private_load_seconds, shared_kv_load_seconds
    )

    layer_lower_bound_seconds = (
        max(compute_lower_bound_seconds, weight_load_lower_bound_seconds)
        + reduction_critical_seconds
    )

    return {
        "cores": cores,
        "heads_per_core": model.query_heads // cores,
        "q_n_per_core": model.query_width // cores,
        "o_k_per_core": model.query_width // cores,
        "ffn_n_per_core": model.ffn // cores,
        "down_k_per_core": model.ffn // cores,
        "private_weight_mib_per_core_per_layer": private_weight_bytes_per_core_layer
        / MIB,
        "private_weight_mib_per_core_all_layers": (
            private_weight_bytes_per_core_layer * model.layers / MIB
        ),
        "shared_kv_weight_mib_all_layers": (
            shared_weight_bytes_per_layer * model.layers / MIB
        ),
        "private_projection_mmac_per_core_layer": private_projection_macs_per_core
        / 1_000_000,
        "attention_mmac_per_core_layer": attention_macs_per_core / 1_000_000,
        "shared_kv_mmac_per_layer": shared_kv_macs / 1_000_000,
        "reduction_tree_depth": reduction_depth,
        "partial_output_mib": partial_bytes / MIB,
        "reduction_traffic_mib_per_layer": reduction_traffic_per_layer / MIB,
        "reduction_traffic_mib_full_inference": (
            reduction_traffic_per_layer * model.layers * model.flow_steps / MIB
        ),
        "private_weight_load_ms_per_layer": private_load_seconds * 1000,
        "core_compute_ms_per_layer": core_compute_seconds * 1000,
        "shared_kv_compute_ms_per_layer": shared_kv_compute_seconds * 1000,
        "reduction_critical_ms_per_layer": reduction_critical_seconds * 1000,
        "analytic_layer_lower_bound_ms": layer_lower_bound_seconds * 1000,
        "analytic_action_expert_lower_bound_ms": (
            layer_lower_bound_seconds * model.layers * model.flow_steps * 1000
        ),
    }


def format_table(headers: list[str], rows: list[list[str]]) -> str:
    header = "| " + " | ".join(headers) + " |"
    separator = "| " + " | ".join("---" for _ in headers) + " |"
    body = ["| " + " | ".join(row) + " |" for row in rows]
    return "\n".join([header, separator, *body])


def render_markdown(
    model: ModelConfig,
    hardware: HardwareConfig,
    strategies: list[dict[str, object]],
) -> str:
    operators = build_operator_map(model)
    operator_rows = []
    for op in operators:
        operator_rows.append(
            [
                op.name,
                f"[{op.m},{op.k}] x [{op.k},{op.n}]",
                op.split_axis,
                op.result_merge,
                f"{op.macs / 1_000_000:.3f}",
            ]
        )

    strategy_rows = []
    for item in strategies:
        strategy_rows.append(
            [
                str(item["cores"]),
                str(item["heads_per_core"]),
                f'{item["private_weight_mib_per_core_per_layer"]:.3f}',
                f'{item["private_projection_mmac_per_core_layer"]:.3f}',
                f'{item["attention_mmac_per_core_layer"]:.3f}',
                str(item["reduction_tree_depth"]),
                f'{item["reduction_traffic_mib_per_layer"]:.3f}',
                f'{item["analytic_layer_lower_bound_ms"]:.3f}',
            ]
        )

    lines = [
        "# pi0 Action Expert 架构参数化评估",
        "",
        "> 本报告由 `architecture_tradeoff.py` 生成。结果是解析下界，不是周期精确仿真或综合结果。",
        "",
        "## 模型参数",
        "",
        f"- Suffix Token: {model.tokens}",
        f"- Hidden / FFN: {model.hidden} / {model.ffn}",
        f"- Query Heads / KV Heads / Head Dim: {model.query_heads} / {model.kv_heads} / {model.head_dim}",
        f"- 最大 K/V Token: {model.kv_tokens}",
        f"- 层数 / Flow Steps: {model.layers} / {model.flow_steps}",
        "",
        "## 矩阵映射",
        "",
        format_table(
            ["算子", "矩阵", "切分", "合并方式", "MMAC/层"],
            operator_rows,
        ),
        "",
        "## 4 核与 8 核比较",
        "",
        format_table(
            [
                "核数",
                "Head/核",
                "私有权重 MiB/核/层",
                "私有投影 MMAC/核/层",
                "Attention MMAC/核/层",
                "归约深度",
                "归约流量 MiB/层",
                "解析下界 ms/层",
            ],
            strategy_rows,
        ),
        "",
        "## 硬件假设",
        "",
        f"- 权重 / 部分和字节数: {hardware.weight_bytes} / {hardware.partial_sum_bytes}",
        f"- 频率: {hardware.frequency_mhz:.1f} MHz",
        f"- 每核 MAC/cycle: {hardware.macs_per_cycle_per_core:.1f}",
        f"- 计算效率: {hardware.compute_efficiency:.2f}",
        f"- HBM 总带宽 / 有效效率: {hardware.hbm_total_gbps:.1f} GB/s / {hardware.hbm_efficiency:.2f}",
        f"- 逻辑私有通道数: {hardware.private_hbm_channels}",
        f"- 单链路归约带宽: {hardware.reduction_link_gbps:.1f} GB/s",
        "",
        "## 解释",
        "",
        "- 4 核和 8 核都保持完整 Head，不引入 Head 内部归约。",
        "- 8 核将每个 Query Head 映射到一个核，私有权重和计算负载约为 4 核的一半。",
        "- 8 核的代价是归约树由 2 级增至 3 级，且总归约流量增加。",
        "- 只有 O 和 Down 沿 K 维切分，因此只有这两个算子做算术求和归约。",
        "- Q、Gate、Up 沿 N 维切分，结果写入互不重叠的地址区间，不进行算术归约。",
        "- 共享 K/V 的计算和广播必须通过实测确认不会限制 8 核利用率。",
        "",
    ]
    return "\n".join(lines)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cores", type=int, nargs="+", default=[4, 8])
    parser.add_argument("--tokens", type=int, default=51)
    parser.add_argument("--kv-tokens", type=int, default=867)
    parser.add_argument("--weight-bytes", type=int, default=2)
    parser.add_argument("--partial-sum-bytes", type=int, default=4)
    parser.add_argument("--frequency-mhz", type=float, default=200.0)
    parser.add_argument("--macs-per-cycle-per-core", type=float, default=512.0)
    parser.add_argument("--compute-efficiency", type=float, default=0.70)
    parser.add_argument("--hbm-total-gbps", type=float, default=316.0)
    parser.add_argument("--hbm-efficiency", type=float, default=0.70)
    parser.add_argument("--private-hbm-channels", type=int, default=8)
    parser.add_argument("--reduction-link-gbps", type=float, default=32.0)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--json-output", type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    model = ModelConfig(tokens=args.tokens, kv_tokens=args.kv_tokens)
    hardware = HardwareConfig(
        weight_bytes=args.weight_bytes,
        partial_sum_bytes=args.partial_sum_bytes,
        frequency_mhz=args.frequency_mhz,
        macs_per_cycle_per_core=args.macs_per_cycle_per_core,
        compute_efficiency=args.compute_efficiency,
        hbm_total_gbps=args.hbm_total_gbps,
        hbm_efficiency=args.hbm_efficiency,
        private_hbm_channels=args.private_hbm_channels,
        reduction_link_gbps=args.reduction_link_gbps,
    )
    strategies = [evaluate_strategy(model, hardware, cores) for cores in args.cores]
    report = render_markdown(model, hardware, strategies)

    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(report, encoding="utf-8")
    else:
        print(report)

    if args.json_output:
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        args.json_output.write_text(
            json.dumps(
                {
                    "model": asdict(model),
                    "hardware": asdict(hardware),
                    "strategies": strategies,
                },
                ensure_ascii=False,
                indent=2,
            ),
            encoding="utf-8",
        )


if __name__ == "__main__":
    main()
