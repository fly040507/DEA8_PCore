import random
import unittest

from pcore.model.mxu_reference import MXU_LAT, TILE, MxuCycleModel, MxuRequest, dot16, mxu_tile


class MxuReferenceTest(unittest.TestCase):
    def test_all_ones(self) -> None:
        weights = [[1] * TILE for _ in range(TILE)]
        self.assertEqual(mxu_tile([1] * TILE, weights), (16,) * TILE)

    def test_signed_int8(self) -> None:
        activation = [-127, 127] * 8
        weights = [[-1 if n % 2 == 0 else 1 for n in range(TILE)] for _ in range(TILE)]
        expected_lane0 = dot16(activation, [-1] * TILE)
        expected_lane1 = dot16(activation, [1] * TILE)
        result = mxu_tile(activation, weights)
        self.assertEqual(result[0], expected_lane0)
        self.assertEqual(result[1], expected_lane1)

    def test_random_matches_direct_sum(self) -> None:
        rng = random.Random(0xDEA8)
        for _ in range(100):
            activation = [rng.randint(-127, 127) for _ in range(TILE)]
            weights = [[rng.randint(-127, 127) for _ in range(TILE)] for _ in range(TILE)]
            result = mxu_tile(activation, weights)
            direct = tuple(sum(activation[k] * weights[k][n] for k in range(TILE)) for n in range(TILE))
            self.assertEqual(result, direct)

    def test_six_enabled_cycle_alignment(self) -> None:
        weights = [[1] * TILE for _ in range(TILE)]
        model = MxuCycleModel(weights)
        req = MxuRequest(
            activation=(1,) * TILE,
            e_stream=0x81,
            e_stat=tuple(range(TILE)),
            tag={"row": 7, "kt": 3},
        )

        self.assertIsNone(model.step(req))
        for _ in range(MXU_LAT - 2):
            self.assertIsNone(model.step(None))
        rsp = model.step(None)
        self.assertIsNotNone(rsp)
        assert rsp is not None
        self.assertEqual(rsp.psum, (16,) * TILE)
        self.assertEqual(rsp.e_stream, req.e_stream)
        self.assertEqual(rsp.e_stat, req.e_stat)
        self.assertEqual(rsp.tag, req.tag)

    def test_continuous_rows_preserve_unique_tags(self):
        model = MxuCycleModel([[2] * TILE for _ in range(TILE)])
        outputs = []
        for row in range(51):
            rsp = model.step(MxuRequest((row,) * TILE, 100+row, (120,) * TILE, row))
            if rsp is not None:
                outputs.append(rsp)
        for _ in range(MXU_LAT-1):
            rsp = model.step(None)
            if rsp is not None:
                outputs.append(rsp)
        self.assertEqual([x.tag for x in outputs], list(range(51)))
        self.assertEqual([x.psum[0] for x in outputs], [32*r for r in range(51)])


if __name__ == "__main__":
    unittest.main()
