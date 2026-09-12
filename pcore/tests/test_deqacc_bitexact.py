import random
import struct
import unittest

from pcore.model.deqacc_bitexact import (
    INF, QNAN, SIGN, accumulate_bits, add_bits, dequantize_bits, pack_dyadic,
)


def float_bits(value):
    try:
        return int.from_bytes(struct.pack('>f', value), 'big')
    except OverflowError:
        return INF | (SIGN if value < 0 else 0)


class DeqaccBitexactTest(unittest.TestCase):
    def test_qk_fold_and_extremes(self):
        self.assertEqual(dequantize_bits(16, 127, 127, -4), 0x39800000)
        self.assertEqual(dequantize_bits(-(1 << 31), 133, 133), 0xCF000000)
        self.assertEqual(dequantize_bits(262144, 133, 133), 0x48800000)
        self.assertEqual(dequantize_bits(-260096, 133, 133), float_bits(-260096))

    def test_special_scales_and_zero(self):
        self.assertEqual(dequantize_bits(0, 254, 254), 0)
        self.assertEqual(dequantize_bits(0, 255, 133), QNAN)
        self.assertEqual(dequantize_bits(1, 0, 0), 0)
        self.assertEqual(dequantize_bits(-1, 0, 0), SIGN)
        self.assertEqual(dequantize_bits(1, 254, 254), INF)

    def test_rounding_ties(self):
        self.assertEqual(pack_dyadic((1 << 24) + 1, 0), 0x4B800000)
        self.assertEqual(pack_dyadic((1 << 24) + 3, 0), 0x4B800002)
        self.assertEqual(pack_dyadic(1, -150), 0)
        self.assertEqual(pack_dyadic(3, -150), 2)
        self.assertEqual(pack_dyadic((1 << 24) - 1, -150), 0x00800000)
        self.assertEqual(pack_dyadic((1 << 25) - 1, 103), INF)

    def test_add_exceptions(self):
        self.assertEqual(add_bits(INF, INF | SIGN), QNAN)
        self.assertEqual(add_bits(QNAN, 0), QNAN)
        self.assertEqual(add_bits(INF, 0x3F800000), INF)
        self.assertEqual(add_bits(SIGN, SIGN), SIGN)
        self.assertEqual(add_bits(SIGN, 0), 0)
        self.assertEqual(add_bits(0x3F800000, 0xBF800000), 0)
        self.assertEqual(add_bits(1, 1), 2)
        self.assertEqual(add_bits(0x007FFFFF, 1), 0x00800000)

    def test_clear_is_not_kt_zero(self):
        self.assertEqual(accumulate_bits(1, 133, 133, 0x40000000), 0x40400000)
        self.assertEqual(accumulate_bits(1, 133, 133, QNAN, clear=True), 0x3F800000)

    def test_random_dequantization_against_struct(self):
        rng = random.Random(12)
        # Every INT32 * power of two here is exact in binary64 before packing.
        for _ in range(10000):
            psum = rng.randrange(-(1 << 31), 1 << 31)
            a, b, fold = rng.randrange(255), rng.randrange(255), rng.randrange(-32, 32)
            expected = float_bits(psum * 2.0 ** (a + b - 266 + fold))
            self.assertEqual(dequantize_bits(psum, a, b, fold), expected)

    def test_random_addition_exact_binary64_window(self):
        rng = random.Random(13)
        # Close exponents make the exact sum fit binary64; no double rounding.
        for _ in range(10000):
            operands = [(rng.randrange(2) << 31) | (rng.randrange(100, 120) << 23)
                        | rng.randrange(1 << 23) for _ in range(2)]
            values = [struct.unpack('>f', bits.to_bytes(4, 'big'))[0] for bits in operands]
            self.assertEqual(add_bits(*operands), float_bits(sum(values)))


if __name__ == '__main__':
    unittest.main()
