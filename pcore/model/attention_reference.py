"""Reference model for the blockwise FlashAttention contract used by DEA-8."""
from __future__ import annotations

import math
from typing import Sequence


def online_attention(q: Sequence[Sequence[float]], k: Sequence[Sequence[float]],
                     v: Sequence[Sequence[float]], blocks: int = 16,
                     valid_key: int | None = None,
                     causal: bool = False) -> list[list[float]]:
    rows = len(q)
    dim = len(q[0])
    out = [[0.0] * len(v[0]) for _ in range(rows)]
    m = [-math.inf] * rows
    l = [0.0] * rows
    end = len(k) if valid_key is None else min(valid_key, len(k))
    for base in range(0, end, blocks):
        kb = k[base:min(base + blocks, end)]
        vb = v[base:min(base + blocks, end)]
        scores = []
        for r, qr in enumerate(q):
            line = []
            for j, kr in enumerate(kb):
                allowed = not causal or base + j <= r
                line.append(sum(a * b for a, b in zip(qr, kr)) * (2.0 ** -4)
                            if allowed else -math.inf)
            scores.append(line)
        rho = [max(line) for line in scores]
        new_m = [max(m[r], rho[r]) for r in range(rows)]
        for r in range(rows):
            alpha = 0.0 if m[r] == -math.inf else math.exp(m[r] - new_m[r])
            p = [0.0 if x == -math.inf else math.exp(x - new_m[r]) for x in scores[r]]
            new_l = alpha * l[r] + sum(p)
            for d in range(len(vb[0])):
                out[r][d] = alpha * out[r][d] + sum(p[j] * vb[j][d] for j in range(len(vb)))
            m[r], l[r] = new_m[r], new_l
    return [[out[r][d] / l[r] if l[r] else 0.0 for d in range(len(out[r]))]
            for r in range(rows)]


def quantize_mxint8(values: Sequence[float], exponent: int) -> list[int]:
    scale = 2.0 ** (133 - exponent)
    return [max(-128, min(127, int(math.floor(x * scale + 0.5)))) for x in values]


def dequantize_mxint8(values: Sequence[int], exponent: int) -> list[float]:
    scale = 2.0 ** (exponent - 133)
    return [x * scale for x in values]
