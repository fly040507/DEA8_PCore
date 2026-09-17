"""Generate ignored full-shape Projection test vectors from an independent oracle."""
from pathlib import Path
from pcore.model.projection_reference import projection_vectors, quantize_fp32, K, TILE


def main():
    root = Path(__file__).resolve().parents[1] / "rtl" / "test_vectors"
    root.mkdir(exist_ok=True)
    count = final_count = 0
    with (root / "projection_acc.txt").open("w") as acc, \
         (root / "projection_psum.txt").open("w") as psum, \
         (root / "projection_final.txt").open("w") as final, \
         (root / "projection_qoz.txt").open("w") as qoz:
        for nt, kt, row, lanes, dots in projection_vectors():
            psum.write("".join(f"{value & 0xffffffff:08x}" for value in reversed(dots)) + "\n")
            word = "".join(f"{value:08x}" for value in reversed(lanes))
            acc.write(word + "\n")
            count += 1
            if kt == K // TILE - 1:
                final.write(word + "\n")
                data, scale = quantize_fp32(lanes)
                qoz.write("".join(f"{x & 255:02x}" for x in reversed(data)) + f"{scale:02x}\n")
                final_count += 1
    print(f"Projection oracle: {count} FP32 partial vectors, {final_count} final/QOZ vectors")


if __name__ == "__main__":
    main()
