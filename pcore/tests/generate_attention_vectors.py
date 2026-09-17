"""Independent FP32 oracle for the simulation-only Softmax clients.

Dense attention with a padding mask (867 valid keys). No causal-mask claim.
Q/K/V are deterministic non-uniform INT8 tensors; P is quantized per row.
"""
import math
import struct
from pathlib import Path

ROWS, TILE, DIM, BLOCKS, VALID_KEYS = 51, 16, 256, 55, 867


def f32(value):
    return struct.unpack('<f', struct.pack('<f', value))[0]


def bits(value):
    return struct.unpack('<I', struct.pack('<f', value))[0]


def vector_line(values):
    return ''.join(f'{bits(v):08x}' for v in reversed(values)) + '\n'


def main():
    output = Path(__file__).resolve().parents[1] / 'test_vectors'
    output.mkdir(exist_ok=True)
    m = [-math.inf] * ROWS
    l = [0.0] * ROWS
    oacc = [[0.0] * DIM for _ in range(ROWS)]
    with (output / 'attention_pv.hex').open('w') as pv, \
         (output / 'attention_scalar.hex').open('w') as scalar:
        for block in range(BLOCKS):
            for row in range(ROWS):
                q = 1 + row % 3
                scores = [float(q * (block + 1 + n % 3))
                          if block * TILE + n < VALID_KEYS else -math.inf
                          for n in range(TILE)]
                new_m = max(m[row], max(scores))
                aa = f32(m[row] - new_m)
                alpha = f32(math.exp(aa))
                probabilities = [f32(math.exp(f32(s - new_m))) for s in scores]
                row_sum = 0.0
                for p in probabilities:
                    row_sum = f32(row_sum + p)
                l[row] = f32(f32(alpha * l[row]) + row_sum)
                m[row] = new_m
                exponent = math.ceil(math.log2(max(probabilities) / 127.0))
                codes = [min(127, round(p / (2.0 ** exponent))) for p in probabilities]
                scalar.write(vector_line([new_m, aa, alpha, l[row]]))
                for feature in range(DIM):
                    psum = sum(codes[k] * ((block * 3 + k * 2 + feature * 5) % 15 - 7)
                               for k in range(TILE))
                    partial = f32(psum * (2.0 ** exponent))
                    old = f32(alpha * oacc[row][feature]) if block else 0.0
                    oacc[row][feature] = f32(old + partial)
            # Real matrix write order is output tile, then row, then lane.
            for tile in range(DIM // TILE):
                for row in range(ROWS):
                    pv.write(vector_line(oacc[row][tile * TILE:(tile + 1) * TILE]))
    with (output / 'attention_final.hex').open('w') as final:
        for row in range(ROWS):
            reciprocal = f32(1.0 / l[row])
            for tile in range(DIM // TILE):
                final.write(vector_line([f32(x * reciprocal)
                                         for x in oacc[row][tile * TILE:(tile + 1) * TILE]]))
    # A deliberately omitted tail scaling must be detectable by the test data.
    assert all(0.0 < math.exp(-(1 + r % 3)) < 1.0 for r in range(ROWS))
    print(f'Attention oracle: {BLOCKS * ROWS * DIM // TILE} PV vectors, '
          f'{ROWS * DIM // TILE} A_FIN vectors, nonidentity alpha54, padding mask')


if __name__ == '__main__':
    main()
