"""Independent Q projection oracle: integer dot, FP32 fold, MXINT8-B16 RNE.

No RTL calls and no simulator-produced expected values. RoPE is out of scope.
"""
from .deqacc_bitexact import add_bits, dequantize_bits

M, K, N, TILE = 51, 1024, 256, 16


def activation(row, kt, k):
    return 0 if row == 0 else (row * 29 + kt * 11 + k * 7) % 256 - 128


def weight(nt, kt, k, n):
    return (nt * 31 + kt * 17 + k * 13 + n * 19) % 256 - 128


def activation_scale(row, kt):
    return 125 + (row + kt * 3) % 9


def weight_scale(nt, kt, n):
    return 125 + (nt * 3 + kt + n * 5) % 9


def _dyadic(bits):
    exp = (bits >> 23) & 255
    if exp == 255:
        raise ValueError("Projection quantizer requires finite FP32 inputs")
    mantissa = bits & 0x7FFFFF
    if exp:
        mantissa |= 1 << 23
    return (-mantissa if bits >> 31 else mantissa), exp - 150 if exp else -149


def _rne_scaled(integer, exponent):
    if exponent >= 0:
        return integer << exponent
    sign = -1 if integer < 0 else 1
    kept, lost = divmod(abs(integer), 1 << -exponent)
    half = 1 << (-exponent - 1)
    return sign * (kept + int(lost > half or (lost == half and kept & 1)))


def quantize_fp32(lanes):
    """E8M0 convention x=q*2**(E-133), min non-clipping E, all-zero E=0."""
    if len(lanes) != TILE:
        raise ValueError("Exactly 16 lanes are required")
    values = [_dyadic(x) for x in lanes]
    def fits(scale):
        for integer, exponent in values:
            shift = exponent - (scale - 133)
            if shift >= 0:
                if (abs(integer) << shift) > 127:
                    return False
            elif abs(integer) > (127 << -shift):
                return False
        return True
    scale = next((e for e in range(255) if fits(e)), 254)
    data = [max(-128, min(127, _rne_scaled(v, e - scale + 133))) for v, e in values]
    return data, scale


def projection_vectors():
    """Yield every nt/kt/row FP32 accumulation, not just the final matrix."""
    for nt in range(N // TILE):
        accum = [[0] * TILE for _ in range(M)]
        for kt in range(K // TILE):
            weights = [[weight(nt, kt, k, n) for k in range(TILE)] for n in range(TILE)]
            for row in range(M):
                av = [activation(row, kt, k) for k in range(TILE)]
                dots = []
                for n in range(TILE):
                    dot = sum(x * y for x, y in zip(av, weights[n]))
                    dots.append(dot)
                    partial = dequantize_bits(dot, activation_scale(row, kt), weight_scale(nt, kt, n))
                    accum[row][n] = partial if kt == 0 else add_bits(accum[row][n], partial)
                yield nt, kt, row, list(accum[row]), dots
