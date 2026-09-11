"""Cycle model for the DEA-8 16x16 weight-stationary MXU.

This model is intentionally limited to the PCore MXU boundary. It models the
six register stages from input acceptance to Psum_out. This arithmetic-only
model does not own bank state; the W_Loader/MXU RTL test checks bank transitions.
"""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass
from typing import Any, Iterable, Sequence


TILE = 16
MXU_LAT = 6


def _s8(value: int) -> int:
    value &= 0xFF
    return value - 0x100 if value & 0x80 else value


def dot16(activation: Sequence[int], weights: Sequence[int]) -> int:
    if len(activation) != TILE or len(weights) != TILE:
        raise ValueError("dot16 requires exactly 16 activation and weight values")
    return sum(_s8(a) * _s8(w) for a, w in zip(activation, weights))


def mxu_tile(activation: Sequence[int], weight_tile: Sequence[Sequence[int]]) -> tuple[int, ...]:
    """Compute one [1,16] x [16,16] signed-INT8 tile product."""
    if len(activation) != TILE or len(weight_tile) != TILE:
        raise ValueError("MXU tile dimensions must be 16x16")
    if any(len(row) != TILE for row in weight_tile):
        raise ValueError("every weight row must contain 16 output channels")
    return tuple(dot16(activation, [weight_tile[k][n] for k in range(TILE)]) for n in range(TILE))


@dataclass(frozen=True)
class MxuRequest:
    activation: tuple[int, ...]
    e_stream: int
    e_stat: tuple[int, ...]
    tag: Any


@dataclass(frozen=True)
class MxuResponse:
    psum: tuple[int, ...]
    e_stream: int
    e_stat: tuple[int, ...]
    tag: Any


class MxuCycleModel:
    def __init__(self, weight_tile: Sequence[Sequence[int]]) -> None:
        if len(weight_tile) != TILE or any(len(row) != TILE for row in weight_tile):
            raise ValueError("weight tile must be 16x16")
        self.weight_tile = tuple(tuple(_s8(v) for v in row) for row in weight_tile)
        self._pipe: deque[MxuResponse | None] = deque([None] * MXU_LAT, maxlen=MXU_LAT)

    def step(self, request: MxuRequest | None) -> MxuResponse | None:
        """Advance one clock.

        Return the post-edge output. A request accepted on edge E0 appears
        immediately after E5 (six register stages, five edge intervals).
        """
        self._pipe.pop()
        issued = None
        if request is not None:
            if len(request.activation) != TILE or len(request.e_stat) != TILE:
                raise ValueError("request activation and E_stat must each have 16 entries")
            issued = MxuResponse(
                psum=mxu_tile(request.activation, self.weight_tile),
                e_stream=request.e_stream & 0xFF,
                e_stat=tuple(v & 0xFF for v in request.e_stat),
                tag=request.tag,
            )
        self._pipe.appendleft(issued)
        return self._pipe[-1]


def make_weight_tile(rows: Iterable[Iterable[int]]) -> tuple[tuple[int, ...], ...]:
    return tuple(tuple(row) for row in rows)
