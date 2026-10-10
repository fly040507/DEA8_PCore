"""Independent exact-integer binary32 oracle. No RTL arithmetic is imported."""
from pathlib import Path
import random


def add32(a, b):
    ea, eb = (a >> 23) & 255, (b >> 23) & 255
    fa, fb = a & 0x7fffff, b & 0x7fffff
    sa, sb = a >> 31, b >> 31
    if (ea == 255 and fa) or (eb == 255 and fb):
        return 0x7fc00000
    if ea == 255 or eb == 255:
        if ea == eb == 255 and sa != sb:
            return 0x7fc00000
        return a if ea == 255 else b
    # Every finite binary32 is an integer multiple of 2**-149.
    ia = ((1 << 23) | fa) << (ea - 1) if ea else fa
    ib = ((1 << 23) | fb) << (eb - 1) if eb else fb
    total = (-ia if sa else ia) + (-ib if sb else ib)
    if not total:
        return (sa & sb) << 31
    sign, value = int(total < 0), abs(total)
    if value < (1 << 23):
        return (sign << 31) | value
    shift = max(0, value.bit_length() - 24)
    kept = value >> shift
    if shift:
        rem = value - (kept << shift)
        half = 1 << (shift - 1)
        kept += rem > half or (rem == half and (kept & 1))
    if kept == (1 << 24):
        kept >>= 1
        shift += 1
    exponent = shift + 1
    if exponent >= 255:
        return (sign << 31) | 0x7f800000
    return (sign << 31) | (exponent << 23) | (kept & 0x7fffff)


def tree(values):
    while len(values) > 1:
        values = [add32(values[i], values[i + 1]) for i in range(0, len(values), 2)]
    return values[0]


def main():
    rng = random.Random(0xDEA8)
    specials = [0, 0x80000000, 1, 0x80000001, 0x007fffff, 0x00800000,
                0x3f800000, 0xbf800000, 0x33800000, 0x7f7fffff,
                0xff7fffff, 0x7f800000, 0xff800000, 0x7fc00001]
    cases = [[0x80000000] * 8, [1] * 8, [0x007fffff] * 8,
             [0x3f800000, 0xbf800000] * 4,
             [0x3f800000, 0x33800000, 0, 0, 0, 0, 0, 0]]
    for i in range(1024 - len(cases)):
        if i % 4 == 0:
            cases.append([rng.choice(specials) for _ in range(8)])
        elif i % 4 == 1:
            # Nearby exponents exercise cancellation and rounding.
            exp = rng.randrange(1, 253)
            cases.append(([(rng.randrange(2) << 31) | (exp << 23) |
                           rng.randrange(1 << 23) for _ in range(8)]))
        else:
            cases.append([rng.getrandbits(32) for _ in range(8)])
    root = Path(__file__).resolve().parent
    (root / "operands.hex").write_text("".join(
        f"{sum(v << (32*c) for c,v in enumerate(case)):064x}\n" for case in cases), encoding="ascii")
    (root / "expected.hex").write_text("".join(f"{tree(case):08x}\n" for case in cases), encoding="ascii")
    assert add32(0x3f800000, 0x33800000) == 0x3f800000
    assert add32(0x007fffff, 1) == 0x00800000
    assert add32(0x80000000, 0x80000000) == 0x80000000
    print(f"Generated {len(cases)} exact tree vectors")


if __name__ == "__main__":
    main()
