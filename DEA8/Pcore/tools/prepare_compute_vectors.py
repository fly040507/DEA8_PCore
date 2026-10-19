"""External configuration images and independent CPU arithmetic vectors."""
from pathlib import Path
import argparse
import ast
import json
import struct
import numpy as np

ROOT = Path(__file__).resolve().parents[1]


def word(x):
    return int(np.asarray(x, dtype=np.float32).view(np.uint32))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--position", type=int, default=816)
    args = ap.parse_args()
    if not 0 <= args.position <= 816:
        raise ValueError("prefix validity count outside this hardware profile")
    dest = ROOT / "units/rom"
    dest.mkdir(parents=True, exist_ok=True)
    prefix = np.arange(816) < args.position
    masks = [sum(int(v) << i for i, v in enumerate(row)) for row in prefix.reshape(51, 16)]
    masks += [1, 0, 0, 0, 65535, 65535, 65535, 7] + [0] * 5
    (dest / "mask.mem").write_text("".join(f"{v:04x}\n" for v in masks), encoding="ascii")
    frequencies = np.arange(128, dtype=np.float32) / np.float32(128)
    timescale = np.power(np.float32(10000), frequencies, dtype=np.float32)
    lines = []
    for row in range(51):
        angle = np.float32(args.position + row) / timescale
        cosine, sine = np.cos(angle), np.sin(angle)
        for group in range(32):
            value = sum((word(cosine[4 * group + j]) | word(sine[4 * group + j]) << 32) << (64 * j)
                        for j in range(4))
            lines.append(f"{value:064x}\n")
    (dest / "rope.mem").write_text("".join(lines), encoding="ascii")
    rng = np.random.default_rng(20261018)
    vectors = ROOT / "tb/data/compute"
    vectors.mkdir(parents=True, exist_ok=True)
    for name, prefix_word in [("empty", 0), ("full", 65535), ("holes", 0x55aa)]:
        image = [prefix_word]*51 + [1,0,0,0,65535,65535,65535,7] + [0]*5
        (vectors / f"mask_{name}.mem").write_text("".join(f"{v:04x}\n" for v in image), encoding="ascii")
    a = rng.uniform(-64, 64, 256).astype(np.float32)
    b = rng.uniform(-16, 16, 256).astype(np.float32)
    (vectors / "binary.mem").write_text("".join(
        f"{word(x):08x}{word(y):08x}{word(np.float32(x+y)):08x}{word(np.float32(x*y)):08x}\n"
        for x, y in zip(a, b)), encoding="ascii")
    aa = np.linspace(-3, 0, 51, dtype=np.float32)
    ls = np.linspace(1, 16, 51, dtype=np.float32)
    (vectors / "sfu_scalar.mem").write_text("".join(
        f"{word(x):08x}{word(np.exp(x)):08x}{word(l):08x}{word(np.float32(1)/l):08x}\n"
        for x, l in zip(aa, ls)), encoding="ascii")
    scores, gelus = [], []
    for row in range(51):
        m = np.float32(row / 8)
        for lane in range(16):
            s = np.float32(-np.inf) if row == 0 or lane == 15 else np.float32(m - lane / 4)
            p = np.float32(0) if np.isneginf(s) else np.exp(np.float32(s-m))
            scores.append(f"{word(s):08x}{word(m):08x}{word(p):08x}\n")
            x = np.float32(((row * 16 + lane) % 65 - 32) / 8)
            u = np.float32(np.float32(np.float32(np.float32(.044715)*x)*x)*x)
            z = np.float32(np.float32(x+u)*np.float32(-2*np.sqrt(2/np.pi)))
            y = np.float32(x*np.float32(np.float32(1)/np.float32(1+np.exp(z))))
            gelus.append(f"{word(x):08x}{word(y):08x}\n")
    (vectors / "sfu_score.mem").write_text("".join(scores), encoding="ascii")
    (vectors / "sfu_gelu.mem").write_text("".join(gelus), encoding="ascii")
    source = ROOT.parents[1] / "openpi/src/openpi/models/pi0.py"
    checks = 0
    if source.exists():
        tree = ast.parse(source.read_text(encoding="utf-8"))
        fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "make_attn_mask")
        scope = {"jnp": np}
        exec(compile(ast.Module(body=[fn], type_ignores=[]), str(source), "exec"), scope)
        suffix = scope["make_attn_mask"](np.ones((1, 51), bool), np.array([1, 1] + [0] * 49))[0]
        for case in range(102):
            p = np.full(816, case == 1, bool) if case < 2 else rng.integers(0, 2, 816).astype(bool)
            reference = np.concatenate([np.repeat(p[None], 51, axis=0), suffix, np.zeros((51, 13), bool)], axis=1)
            actual = np.zeros((51, 880), bool)
            actual[:, :816] = p
            actual[0, 816] = True
            actual[1:, 816:867] = True
            assert np.array_equal(reference, actual)
            checks += 1
    (dest / "configuration.json").write_text(json.dumps({
        "pi05": False, "rows": 51, "prefix_slots": 816, "position_base": args.position,
        "rope_version": 1, "mask_version": 1, "official_mask_cases": checks,
        "rope_formula": "FP32 timescale, division, sin/cos; parameter image, not an internal TB service"
    }, indent=2), encoding="utf-8")
    print(f"CONFIG_READY position={args.position} official_mask_cases={checks}")


if __name__ == "__main__":
    main()
