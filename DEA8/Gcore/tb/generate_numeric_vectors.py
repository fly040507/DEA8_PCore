"""Independent NumPy binary32/BF16 reference; not a port of the RTL functions."""
from pathlib import Path
import json
import numpy as np

OUT = Path(__file__).resolve().parent / "data"
OUT.mkdir(exist_ok=True)
F32 = np.float32
RNG = np.random.default_rng(510016)
np.seterr(all="ignore")


def bits(x):
    return int(np.asarray(x, dtype=np.float32).view(np.uint32))


def value(x):
    return np.asarray(x, dtype=np.uint32).view(np.float32)[()]


def bf16(x):
    u = bits(x)
    if (u & 0x7F800000) == 0x7F800000 and (u & 0x7FFFFF):
        return (u >> 16) | 0x40
    return ((u + 0x7FFF + ((u >> 16) & 1)) >> 16) & 0xFFFF


def from_bf(u):
    return value(int(u) << 16)


def packed(values, width):
    return sum(int(v) << (width * i) for i, v in enumerate(values))


def write(name, words, width):
    (OUT / name).write_text("".join(f"{int(w):0{(width+3)//4}x}\n" for w in words), encoding="ascii")


def quantize(values):
    if not np.isfinite(values).all():
        return 1 << 136
    maximum = float(np.max(np.abs(values)))
    scale = next((e for e in range(255) if maximum <= 127 * 2.0 ** (e - 133)), 254)
    q = [max(-128, min(127, int(round(float(v) * 2.0 ** (133-scale))))) & 255 for v in values]
    return (scale << 128) | packed(q, 8)


def square_sums(residual):
    sq = np.zeros(51, dtype=np.float32)
    for nt in range(64):
        for row in range(51):
            a = np.asarray([from_bf(v) for v in residual[nt, row]], dtype=np.float32)
            a = np.multiply(a, a, dtype=np.float32)
            while len(a) > 1:
                a = np.add(a[::2], a[1::2], dtype=np.float32)
            sq[row] = F32(sq[row] + a[0])
    return sq


def norm_reference(name, residual):
    sq = square_sums(residual)
    u = np.add(np.multiply(sq, F32(2.0 ** -10), dtype=np.float32), F32(1e-6), dtype=np.float32)
    inverse = np.asarray([F32(1.0 / np.sqrt(float(v))) for v in u], dtype=np.float32)
    q = []
    for nt in range(64):
        for row in range(51):
            a = np.asarray([from_bf(v) for v in residual[nt, row]], dtype=np.float32)
            q.append(quantize(np.multiply(a, inverse[row], dtype=np.float32)))
    write(f"{name}_sq.mem", [bits(x) for x in sq], 32)
    write(f"{name}_u.mem", [bits(x) for x in u], 32)
    write(f"{name}_inv.mem", [bits(x) for x in inverse], 32)
    write(f"{name}_xhat.mem", q, 136)


edge = [0, 0x80000000, 1, 0x80000001, 0x007FFFFF, 0x00800000,
        0x3F800000, 0x3F7FFFFF, 0x3F800001, 0x40000000, 0x7F7FFFFF,
        0x7F800000, 0xFF800000, 0x7FC00000, 0x3F000000, 0xBF800000]
mul = []
add = []
for i in range(4096):
    a = edge[i // len(edge)] if i < len(edge)**2 else int(RNG.integers(0, 2**32, dtype=np.uint32))
    b = edge[i % len(edge)] if i < len(edge)**2 else int(RNG.integers(0, 2**32, dtype=np.uint32))
    product = F32(value(a) * value(b))
    golden = 0x7FC00000 if np.isnan(product) else bits(product)
    mul.append((a << 64) | (b << 32) | golden)
    total = F32(value(a) + value(b))
    add.append((a << 64) | (b << 32) | (0x7FC00000 if np.isnan(total) else bits(total)))
write("multiply.mem", mul, 96)
write("add.mem", add, 96)

rsqrt = []
for i in range(8192):
    if i < 277:
        x = bits(F32(2.0 ** (i - 149)))
    elif i < 309:
        x = [1, 2, 3, 0x007FFFFF, 0x00800000, 0x7F7FFFFF, 0x3F7FFFFF, 0x3F800001][i % 8]
    else:
        x = int(RNG.integers(1, 0x7F800000))
    y = bits(F32(1.0 / np.sqrt(float(value(x)))))
    rsqrt.append((x << 32) | y)
write("rsqrt.mem", rsqrt, 64)

rounding = []
for i in range(2048):
    if i < 1024:
        a = ((0x3E00 + i // 4) << 16) | [0x7FFF, 0x8000, 0x8001, 0][i % 4]
        if i & 4:
            a |= 0x80000000
    else:
        a = int(RNG.integers(0, 2**32, dtype=np.uint32))
    rounding.append((a << 16) | bf16(value(a)))
write("bf16.mem", rounding, 48)

quant = []
for i in range(256):
    a = RNG.normal(size=16).astype(np.float32) * F32(2.0 ** ((i % 100) - 50))
    if i == 0:
        a[:] = 0
    elif i < 16:
        threshold = value(0x3FFE0000)
        a[:] = 0
        a[0] = value(bits(threshold) + i - 8)
    elif i < 32:
        a = np.asarray([value(0x007F0000 + (i-24)*4+j) for j in range(16)], dtype=np.float32)
    elif i == 32:
        a[7] = F32(np.inf)
    elif i == 33:
        a[2] = F32(np.nan)
    elif i == 34:
        a[:] = value(0x7F7FFFFF)
        a[1] = -a[1]
    quant.append((packed([bits(v) for v in a], 32) << 137) | quantize(a))
write("quantize.mem", quant, 649)

initial = np.empty((64, 51, 16), dtype=np.uint16)
delta_o = np.empty((64, 51, 16), dtype=np.float32)
delta_d = np.empty_like(delta_o)
for nt in range(64):
    for row in range(51):
        for lane in range(16):
            x = F32(((row*13+nt*7+lane*11) % 255 - 127) / 64.0)
            if row == 0:
                x = F32(0)
            initial[nt, row, lane] = bf16(x)
            delta_o[nt, row, lane] = F32(((row*17+nt*5+lane*3) % 63-31) / 128.0)
            delta_d[nt, row, lane] = F32(((row*3+nt*11+lane*7) % 47-23) / 256.0)
mid = np.empty_like(initial)
following = np.empty_like(initial)
for nt in range(64):
    for row in range(51):
        for lane in range(16):
            mid[nt, row, lane] = bf16(F32(from_bf(initial[nt,row,lane]) + delta_o[nt,row,lane]))
            following[nt, row, lane] = bf16(F32(from_bf(mid[nt,row,lane]) + delta_d[nt,row,lane]))
for name, residual in [("initial", initial), ("mid", mid), ("next", following)]:
    write(f"{name}_residual.mem", [packed(row,16) for row in residual.reshape(-1,16)], 256)
    norm_reference(name, residual)
write("reduce_o.mem", [packed([bits(v) for v in row],32) for row in delta_o.reshape(-1,16)], 512)
write("reduce_down.mem", [packed([bits(v) for v in row],32) for row in delta_d.reshape(-1,16)], 512)
(OUT / "reference.json").write_text(json.dumps({"seed":510016,"numpy":np.__version__,
    "rows":51,"hidden":1024,"mul_vectors":4096,"bf16_vectors":2048,"quant_vectors":256,
    "add_vectors":4096,"rsqrt_input_values":8192,
    "rsqrt":"FP32(1/sqrt(FP32 u)) golden; native IP tolerance <= 1 ULP",
    "reduction":"FP32 adjacent SUM16 tree, then nt=0..63 FP32 accumulation"},indent=2)+"\n",encoding="ascii")
print("Generated independent GCore numeric vectors")
