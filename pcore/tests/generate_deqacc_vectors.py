"""Generate deterministic XSim inputs using the independent integer oracle."""
from pathlib import Path
import random

from pcore.model.deqacc_bitexact import add_bits, dequantize_bits, accumulate_bits


def packed(values, width):
    return sum((v & ((1 << width) - 1)) << (i * width) for i, v in enumerate(values))


def main():
    out = Path(__file__).resolve().parents[1] / 'rtl' / 'test_vectors'
    out.mkdir(exist_ok=True)
    rng = random.Random(20260912)
    edges = [0, 0x80000000, 1, 0x007fffff, 0x00800000, 0x3f800000,
             0xbf800000, 0x7f7fffff, 0xff7fffff, 0x7f800000, 0xff800000,
             0x7fc00000, 0x7f800001, 0x3f800001, 0x33800000]
    with (out / 'fp_add.txt').open('w', encoding='ascii') as f:
        cases = [(a, b) for a in edges for b in edges]
        cases.extend((rng.getrandbits(32), rng.getrandbits(32)) for _ in range(100000))
        for a, b in cases:
            f.write(f'{a:08x} {b:08x} {add_bits(a, b):08x}\n')
    with (out / 'dequant.txt').open('w', encoding='ascii') as f:
        cases = [(p, a, b, fold) for p in [0, 1, -1, -(1 << 31), 262144, -260096,
                                          (1 << 24) + 1, (1 << 24) + 3]
                 for a in [0, 1, 100, 127, 133, 254, 255]
                 for b in [0, 1, 17, 127, 133, 254, 255] for fold in [-32, -4, 0, 31]]
        cases.extend((rng.randrange(-(1 << 31), 1 << 31), rng.randrange(256),
                      rng.randrange(256), rng.randrange(-32, 32)) for _ in range(50000))
        for p, a, b, fold in cases:
            f.write(f'{p & 0xffffffff:08x} {a:02x} {b:02x} {fold & 63:02x} '
                    f'{dequantize_bits(p, a, b, fold):08x}\n')
    memory = [[[0] * 16 for _ in range(816)] for _ in range(3)]
    with (out / 'pipeline.txt').open('w', encoding='ascii') as f:
        commands = [(0, row, kt == 0, -4, 0xffff) for kt in range(16) for row in range(51)]
        commands += [(1, row, kt == 0, 0, 0xffff) for kt in range(2) for row in range(51)]
        commands += [(2, addr, block == 0, 0, 0xa55a if block == 1 else 0xffff)
                     for block in range(3) for addr in range(816)]
        # Minimum supported RAW separation: addresses repeat every four issues.
        commands += [(0, addr, False, 0, 0xffff) for _ in range(4) for addr in range(4)]
        commands += [(1, row, True, -32 if row % 2 else 31, 0xffff) for row in range(51)]
        for index, (sel, addr, clear, fold, mask) in enumerate(commands):
            psums = [rng.randrange(-260096, 262145) for _ in range(16)]
            scales = [rng.randrange(125, 138) for _ in range(16)]
            stream = rng.randrange(125, 138)
            if fold in (-32, 31):
                psums = [rng.randrange(-(1 << 31), 1 << 31) for _ in range(16)]
                scales = [rng.randrange(256) for _ in range(16)]
                stream = rng.randrange(256)
            if index % 97 == 0:
                psums[0:3] = [-(1 << 31), 0, 262144]
                scales[0:3] = [0, 255, 254]
            expected = [accumulate_bits(p, stream, e, old, fold, clear)
                        for p, e, old in zip(psums, scales, memory[sel][addr])]
            for lane in range(16):
                if mask & (1 << lane):
                    memory[sel][addr][lane] = expected[lane]
            f.write(f'{sel:x} {addr:x} {int(clear):x} {mask:04x} {stream:02x} '
                    f'{fold & 63:02x} {packed(psums,32):0128x} {packed(scales,8):032x} '
                    f'{packed(expected,32):0128x}\n')
    print(f'DEQACC vectors: {out}')
    # Independent end-to-end oracle for tb_dea8_mxu's deterministic INT8 data.
    acc = [[0] * 16 for _ in range(51)]
    with (out / 'mxu_chain.txt').open('w', encoding='ascii') as f:
        for tile in range(32):
            for row in range(51):
                for lane in range(16):
                    psum = 0
                    for k in range(16):
                        a = -128 if tile == 0 else ((tile*13+row*3+k*17) % 256) - 128
                        w = (-128 if tile == 0 else 127 if tile == 1
                             else ((tile*37+k*11+lane*7) % 256) - 128)
                        psum += a*w
                    acc[row][lane] = accumulate_bits(psum, 110+(tile+row) % 80,
                                                    100+(tile+lane) % 90, acc[row][lane],
                                                    clear=tile % 16 == 0)
                f.write(f'{packed(acc[row],32):0128x}\n')


if __name__ == '__main__':
    main()
