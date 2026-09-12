"""Integer-only binary32 RNE oracle, not synthesizable RTL or a cycle model."""

QNAN = 0x7FC00000
INF = 0x7F800000
SIGN = 0x80000000


def _round_shift(value: int, shift: int) -> int:
    if shift <= 0:
        return value << -shift
    kept, lost = divmod(value, 1 << shift)
    half = 1 << (shift - 1)
    return kept + int(lost > half or (lost == half and kept & 1))


def pack_dyadic(value: int, exponent: int, negative_zero: bool = False) -> int:
    """Round the exact signed integer * 2**exponent once to binary32."""
    if value == 0:
        return SIGN if negative_zero else 0
    sign = SIGN if value < 0 else 0
    magnitude = abs(value)
    p = magnitude.bit_length() - 1
    unbiased = p + exponent
    if unbiased < -126:
        fraction = _round_shift(magnitude, -(exponent + 149))
        # Rounding can promote the largest subnormal to the minimum normal.
        return sign | fraction
    significand = _round_shift(magnitude, p - 23)
    if significand == 1 << 24:
        significand >>= 1
        unbiased += 1
    if unbiased > 127:
        return sign | INF
    return sign | ((unbiased + 127) << 23) | (significand & 0x7FFFFF)


def dequantize_bits(psum: int, e_stream: int, e_stat: int, fold: int = 0) -> int:
    if not -(1 << 31) <= psum < (1 << 31):
        raise ValueError("psum must fit signed INT32")
    if not 0 <= e_stream <= 255 or not 0 <= e_stat <= 255:
        raise ValueError("scale must fit E8M0")
    if not -32 <= fold <= 31:
        raise ValueError("fold must fit signed 6 bits")
    if e_stream == 255 or e_stat == 255:
        return QNAN
    return pack_dyadic(psum, e_stream + e_stat - 266 + fold)


def _decode_finite(bits: int) -> tuple[int, int]:
    exp = (bits >> 23) & 255
    mantissa = bits & 0x7FFFFF
    if exp:
        mantissa |= 1 << 23
    if bits & SIGN:
        mantissa = -mantissa
    return mantissa, exp - 150 if exp else -149


def add_bits(left: int, right: int) -> int:
    """One FP32 addition, gradual underflow and canonical quiet NaN."""
    if not 0 <= left <= 0xFFFFFFFF or not 0 <= right <= 0xFFFFFFFF:
        raise ValueError("operands must be binary32 bit patterns")
    for bits in (left, right):
        if bits & INF == INF and bits & 0x7FFFFF:
            return QNAN
    left_inf = left & 0x7FFFFFFF == INF
    right_inf = right & 0x7FFFFFFF == INF
    if left_inf and right_inf and (left ^ right) & SIGN:
        return QNAN
    if left_inf:
        return left
    if right_inf:
        return right
    a, ea = _decode_finite(left)
    b, eb = _decode_finite(right)
    common = min(ea, eb)
    total = (a << (ea - common)) + (b << (eb - common))
    return pack_dyadic(total, common, negative_zero=left == SIGN and right == SIGN)


def accumulate_bits(psum: int, e_stream: int, e_stat: int, old: int,
                    fold: int = 0, clear: bool = False) -> int:
    partial = dequantize_bits(psum, e_stream, e_stat, fold)
    return partial if clear else add_bits(old, partial)
