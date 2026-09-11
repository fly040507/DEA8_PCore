"""Scalar DEQACC reference for one lane.

The exponent path is exact for the architectural E8M0 power-of-two scale.
The FP32 conversion/addition is delegated to Python float for the first
functional model; RTL will use the project's certified FP32 IP.
"""

from __future__ import annotations

import math


DOT_EXP_OFFSET = 266


def lzc32(value: int) -> int:
    value &= 0xFFFFFFFF
    if value == 0:
        return 32
    return 32 - value.bit_length()


def dequantize_psum(psum: int, e_stream: int, e_stat: int, exp_fold: int = 0) -> float:
    signed = psum & 0xFFFFFFFF
    if signed & 0x80000000:
        signed -= 1 << 32
    exponent = int(e_stream) + int(e_stat) - DOT_EXP_OFFSET + int(exp_fold)
    return float(signed) * math.ldexp(1.0, exponent)


def accumulate_lane(
    psum: int,
    e_stream: int,
    e_stat: int,
    old_acc: float | None,
    exp_fold: int = 0,
) -> float:
    partial = dequantize_psum(psum, e_stream, e_stat, exp_fold)
    return partial if old_acc is None else old_acc + partial

