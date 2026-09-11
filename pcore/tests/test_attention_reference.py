import math
import unittest

from pcore.model.attention_reference import dequantize_mxint8, online_attention, quantize_mxint8


class AttentionReferenceTest(unittest.TestCase):
    def test_online_matches_single_block(self):
        q = [[1.0, 0.5], [0.25, -1.0]]
        k = [[1.0, 0.0], [0.0, 1.0], [0.5, 0.5], [-1.0, 0.25]]
        v = [[1.0, 2.0], [2.0, 1.0], [3.0, 0.0], [0.0, 3.0]]
        a = online_attention(q, k, v, blocks=2)
        b = online_attention(q, k, v, blocks=16)
        for x, y in zip(a, b):
            for u, w in zip(x, y):
                self.assertAlmostEqual(u, w, places=12)

    def test_masked_tail_does_not_change_result(self):
        q = [[1.0, 0.0]]
        k = [[1.0, 0.0], [0.0, 1.0], [99.0, 99.0]]
        v = [[2.0], [4.0], [1000.0]]
        a = online_attention(q, k, v, blocks=2, valid_key=2)
        b = online_attention(q, k[:2], v[:2], blocks=16)
        self.assertAlmostEqual(a[0][0], b[0][0], places=12)

    def test_mxint8_round_trip(self):
        src = [-1.0, -0.25, 0.0, 0.25, 1.0]
        q = quantize_mxint8(src, 133)
        dst = dequantize_mxint8(q, 133)
        for x, y in zip(src, dst):
            self.assertLessEqual(abs(x - y), 0.5)


if __name__ == "__main__":
    unittest.main()
