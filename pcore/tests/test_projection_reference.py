import struct
import unittest
from pcore.model.projection_reference import quantize_fp32


def fp(x):
    return struct.unpack("<I", struct.pack("<f", x))[0]


class ProjectionQuantizationTest(unittest.TestCase):
    def test_zero_block(self):
        self.assertEqual(quantize_fp32([0, 0x80000000] * 8), ([0] * 16, 0))

    def test_ties_even_and_scale(self):
        values = [127, 0.5, 1.5, 2.5, -0.5, -1.5, -2.5, -127] * 2
        q, scale = quantize_fp32(list(map(fp, values)))
        self.assertEqual(scale, 133)
        self.assertEqual(q, [127, 0, 2, 2, 0, -2, -2, -127] * 2)

    def test_scale_boundary(self):
        q, scale = quantize_fp32([fp(128)] * 16)
        self.assertEqual((q, scale), ([64] * 16, 134))

    def test_subnormal(self):
        self.assertEqual(quantize_fp32([1] * 16), ([0] * 16, 0))

    def test_reject_nonfinite(self):
        for bits in [0x7F800000, 0xFF800000, 0x7FC00000]:
            with self.assertRaises(ValueError):
                quantize_fp32([bits] * 16)
