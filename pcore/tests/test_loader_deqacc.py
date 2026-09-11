import unittest

from pcore.model.deqacc_reference import accumulate_lane, dequantize_psum, lzc32
from pcore.model.weight_loader_reference import WLoader, unpack_axi_tile


class LoaderDeqaccTest(unittest.TestCase):
    def test_nine_axi_beats_split_256_plus_16(self) -> None:
        beats = [bytes([i] * 32) for i in range(9)]
        tile = unpack_axi_tile(beats)
        self.assertEqual(len(tile.payload), 256)
        self.assertEqual(len(tile.scales), 16)
        self.assertEqual(tile.payload[-1], 7)
        self.assertEqual(tile.scales, bytes([8] * 16))
        self.assertEqual(len(tile.payload_words), 16)
        self.assertEqual(tile.payload_words[0], beats[0][:16])
        self.assertEqual(tile.payload_words[1], beats[0][16:])
        self.assertEqual(tile.scale_word, beats[8][:16])

    def test_first_row_pops_scale_and_total_load_is_sixteen(self):
        loader = WLoader()
        loader.push(unpack_axi_tile([bytes(range(32)) for _ in range(9)]))
        words = [loader.step() for _ in range(16)]
        self.assertEqual([word[0] for word in words], list(range(16)))
        self.assertEqual(words[0][2], bytes(range(16)))
        self.assertTrue(all(word[2] is None for word in words[1:]))
        self.assertIsNone(loader.step())

    def test_no_start_without_full_data_and_scale(self):
        loader = WLoader()
        loader.data_fifo = [bytes(16)] * 15
        loader.scale_fifo = [bytes(16)]
        self.assertIsNone(loader.step())
        loader.data_fifo.append(bytes(16))
        loader.scale_fifo.clear()
        self.assertIsNone(loader.step())
        loader.scale_fifo.append(bytes(16))
        self.assertIsNotNone(loader.step())

    def test_enable_only_gates_start_not_inflight_load(self):
        loader = WLoader()
        tile = unpack_axi_tile([bytes(32)] * 9)
        loader.push(tile)
        loader.push(tile)
        self.assertIsNone(loader.step(False))
        self.assertEqual(loader.step()[0], 0)
        for i in range(1, 16):
            self.assertEqual(loader.step(False)[0], i)
        self.assertIsNone(loader.step(False))
        self.assertEqual(loader.step()[0], 0)

    def test_deqacc_exponent_and_first_accum_bypass(self) -> None:
        self.assertEqual(lzc32(0), 32)
        self.assertEqual(lzc32(1), 31)
        value = dequantize_psum(16, 127, 127, -4)
        # 按规格：127 + 127 - 266 - 4 = -16，16 * 2^-16 = 2^-12。
        self.assertEqual(value, 2.0 ** -12)
        self.assertEqual(accumulate_lane(16, 127, 127, None, -4), 2.0 ** -12)
        self.assertEqual(accumulate_lane(16, 127, 127, 2.0, -4), 2.0 + 2.0 ** -12)


if __name__ == "__main__":
    unittest.main()
