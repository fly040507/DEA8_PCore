"""Pack four consecutive 256-bit RoPE words into one 1024-bit ROM word."""
from pathlib import Path
import argparse


def pack_rope_rom(source: Path, destination: Path) -> int:
    words = [int(line, 16) for line in source.read_text(encoding="ascii").split()]
    if not words or len(words) % 4 or any(word < 0 or word.bit_length() > 256 for word in words):
        raise ValueError("RoPE image must contain a nonempty multiple of four 256-bit hex words")
    wide = [sum(words[i + part] << (256 * part) for part in range(4))
            for i in range(0, len(words), 4)]
    destination.write_text("".join(f"{word:0256x}\n" for word in wide), encoding="ascii")
    return len(wide)


if __name__ == "__main__":
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=root / "units/rom/rope.mem")
    parser.add_argument("--output", type=Path, default=root / "units/rom/rope_wide.mem")
    args = parser.parse_args()
    count = pack_rope_rom(args.source, args.output)
    print(f"ROPE_IMAGE_PACKED words={count} bits_per_word=1024 output={args.output}")
