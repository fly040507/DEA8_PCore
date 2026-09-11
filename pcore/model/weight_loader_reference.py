"""Reference model for the 9-beat HBM -> tile FIFO loader.

The physical HBM format is 8 payload beats followed by one scale beat. The
payload becomes sixteen 128-bit FIFO entries; the scale beat becomes one
128-bit word containing E_stat[0:15].
"""

from __future__ import annotations

from dataclasses import dataclass


AXI_BEAT_BYTES = 32
TILE = 16
WEIGHT_WORD_BYTES = TILE
TILE_BYTES = TILE * TILE
SCALE_BYTES = TILE
HBM_BEATS_PER_TILE = 9


@dataclass(frozen=True)
class WeightTile:
    payload: bytes
    scales: bytes

    @property
    def payload_words(self) -> tuple[bytes, ...]:
        return tuple(
            self.payload[i : i + WEIGHT_WORD_BYTES]
            for i in range(0, TILE_BYTES, WEIGHT_WORD_BYTES)
        )

    @property
    def scale_word(self) -> bytes:
        return self.scales


def unpack_axi_tile(beats: list[bytes]) -> WeightTile:
    """Split exactly eight payload beats and one scale beat."""
    if len(beats) != HBM_BEATS_PER_TILE:
        raise ValueError("a weight tile requires exactly 9 AXI beats")
    if any(len(beat) != AXI_BEAT_BYTES for beat in beats):
        raise ValueError("each AXI beat must contain 32 bytes")
    raw = b"".join(beats)
    return WeightTile(
        payload=raw[:TILE_BYTES],
        scales=raw[TILE_BYTES : TILE_BYTES + SCALE_BYTES],
    )


class WLoader:
    """FIFO-to-bank model; one step is one load edge, no partial tile start."""

    def __init__(self) -> None:
        self.data_fifo: list[bytes] = []
        self.scale_fifo: list[bytes] = []
        self.index = 0
        self.loading = False

    def push(self, tile: WeightTile) -> None:
        if len(tile.payload) != TILE_BYTES or len(tile.scales) != SCALE_BYTES:
            raise ValueError("invalid tile size")
        self.data_fifo.extend(tile.payload_words)
        self.scale_fifo.append(tile.scale_word)

    def step(self, enable: bool = True) -> tuple[int, bytes, bytes | None] | None:
        if not self.loading:
            if not enable or len(self.data_fifo) < TILE or not self.scale_fifo:
                return None
            self.loading = True
            self.index = 0
        if not self.data_fifo:
            raise RuntimeError("reserved tile underflow")
        row = self.index
        scale = self.scale_fifo.pop(0) if row == 0 else None
        data = self.data_fifo.pop(0)
        self.index += 1
        if self.index == TILE:
            self.loading = False
        return row, data, scale
