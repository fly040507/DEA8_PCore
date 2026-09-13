"""Independent integer oracle for the shared QK/PV engine test."""
from pathlib import Path
import struct
from pcore.model.deqacc_bitexact import add_bits, dequantize_bits


def a(j, row, tile, k):
    return (j * 19 + row * 3 + (tile if j % 2 == 0 else 0) * 11 + k * 7) % 255 - 127


def w(j, tile, k, n):
    return (j * 17 + tile * 31 + k * 13 + n * 5) % 255 - 127


def scaled_half(bits):
    value = struct.unpack("!f", struct.pack("!I", bits))[0]
    return struct.unpack("!I", struct.pack("!f", value * 0.5))[0]


def word(lanes):
    return "".join(f"{value:08x}" for value in reversed(lanes))


def main():
    root = Path(__file__).resolve().parents[1] / "rtl" / "test_vectors"
    root.mkdir(exist_ok=True)
    facc = [[0] * 16 for _ in range(51)]
    oacc = [[0] * 16 for _ in range(816)]
    results = []
    for j in range(4):
        if j == 3:
            oacc = [[scaled_half(x) for x in row] for row in oacc]
            (root / "matrix_scaled.txt").write_text("\n".join(map(word, oacc)) + "\n")
        for tile in range(16):
            for row in range(51):
                es = 128 + (row + (tile if j % 2 == 0 else 0) + j) % 5
                addr = row if j % 2 == 0 else row * 16 + tile
                bank = facc if j % 2 == 0 else oacc
                out = []
                for n in range(16):
                    psum = sum(a(j, row, tile, k) * w(j, tile, k, n) for k in range(16))
                    partial = dequantize_bits(psum, es, 128 + (j + tile + n) % 7, -4 if j % 2 == 0 else 0)
                    clear = tile == 0 if j % 2 == 0 else j == 1
                    out.append(partial if clear else add_bits(bank[addr][n], partial))
                bank[addr] = out
                results.append(word(out))
    (root / "matrix_jobs.txt").write_text("\n".join(results) + "\n")


if __name__ == "__main__":
    main()
