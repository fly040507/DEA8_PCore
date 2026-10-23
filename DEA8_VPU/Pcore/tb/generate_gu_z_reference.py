"""Independent GU/Z fixture: staged FP32, tanh GELU, E8M0, RNE INT8.

This is a simulation contract, not a finalized SFU approximation profile.
Outputs stay alongside this script under tb/data (no RTL is generated).
"""
import math
import struct
from pathlib import Path


def f32(x):
    return struct.unpack('<f', struct.pack('<f', x))[0]


def bits(x):
    return struct.unpack('<I', struct.pack('<f', x))[0]


def a_value(row, k, i):
    return (row + 2*k + 3*i) % 9 - 4


def b_value(n, k, i, col, up):
    return ((2*n + 3*k + 2*col + i) % 13 - 6 if up else
            (n + k + col + 2*i) % 11 - 5)


def quantize(values):
    maximum = max(abs(x) for x in values)
    e = 0 if maximum == 0 else max(0, min(254, math.ceil(math.log2(maximum/127)) + 133))
    step = math.ldexp(1.0, e - 133)
    data = 0
    for c, value in enumerate(values):
        q = max(-128, min(127, round(value/step)))
        data |= (q & 255) << (8*c)
    return (data << 8) | e


def main():
    dest = Path(__file__).resolve().parent / 'data'
    dest.mkdir(exist_ok=True)
    gu, zwords = [], []
    for n in range(32):
        for row in range(51):
            g, u = [], []
            for col in range(16):
                results = []
                for up in (False, True):
                    acc = 0.0
                    for k in range(64):
                        dot = sum(a_value(row, k, i)*b_value(n, k, i, col, up) for i in range(16))
                        partial = f32(math.ldexp(dot, (128 + row % 3) + (128 + col % 2) - 266))
                        acc = f32(acc + partial)
                    results.append(acc)
                g.append(results[0]); u.append(results[1])
            gu.append(sum(bits(x) << (32*c) for c, x in enumerate(g)) |
                      (sum(bits(x) << (32*c) for c, x in enumerate(u)) << 512))
            gelu = [f32(0.5*x*(1 + math.tanh(math.sqrt(2/math.pi)*(x + 0.044715*x*x*x)))) for x in g]
            zwords.append(quantize([f32(x*y) for x, y in zip(gelu, u)]))
    fp_text = ''.join(f'{x:0256x}\n' for x in gu)
    z_text = ''.join(f'{x:034x}\n' for x in zwords)
    (dest / 'gu_fp32.mem').write_text(fp_text, encoding='ascii')
    (dest / 'gu_z_mxint8.mem').write_text(z_text, encoding='ascii')
    # The single-tile RTL TB only consumes n=0.  Keep a bounded fixture for
    # simulators that warn when a large reference file is mapped to 51 words.
    (dest / 'gu_n0_fp32.mem').write_text(''.join(f'{x:0256x}\n' for x in gu[:51]), encoding='ascii')
    (dest / 'gu_n0_z_mxint8.mem').write_text(''.join(f'{x:034x}\n' for x in zwords[:51]), encoding='ascii')
    print(f'GU reference: rows={len(gu)}, FP32 values={len(gu)*32}, Z values={len(gu)*16}')


if __name__ == '__main__':
    main()
