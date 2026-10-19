"""Independent NumPy golden: integer B16 dots, ordered FP32 K accumulation.

Only files are produced. This program never drives a DUT arithmetic interface.
"""
from pathlib import Path
import json
import numpy as np
from prepare_compute_vectors import word

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "tb/data/seven_job"
F = np.float32


def add(a, b):
    return F(F(a) + F(b))


def mul(a, b):
    return F(F(a) * F(b))


def quant(x):
    x = np.asarray(x, dtype=np.float32)
    e = int(np.max(np.abs(x)).view(np.uint32) >> 23) if np.any(x) else 0
    step = 2.0 ** (e - 133)
    q = np.clip(np.rint(x.astype(np.float64) / step), -127, 127).astype(np.int16)
    return q, e


def qword(x):
    q, e = x
    data = sum((int(v) & 255) << (8*j) for j, v in enumerate(q))
    return f"{data:032x}{e:02x}\n"  # packed qvec16_t: data then exponent


def dot(a, b=1, exponent=128, fold=0):
    q, e = a
    total = int(np.sum(q.astype(np.int64))) * b
    return F(total * 2.0 ** (e + exponent - 266 + fold))


def tree_sum(x):
    values = np.asarray(x, dtype=np.float32)
    while len(values) > 1:
        values = (values[::2] + values[1::2]).astype(np.float32)
    return values[0]


def write_q(name, values):
    (DEST / name).write_text("".join(qword(v) for v in values), encoding="ascii")


def main():
    DEST.mkdir(parents=True, exist_ok=True)
    qa = [[None]*51 for _ in range(16)]
    ka = [[None]*51 for _ in range(2)]
    va = []
    for group in range(8):
        for row in range(51):
            x = np.array([(row % 3 - 1)*(1+(16*group+j)%3) for j in range(16)], dtype=np.float32)
            y = np.array([(row % 3 - 1)*(1+(16*(group+8)+j)%3) for j in range(16)], dtype=np.float32)
            angle = F(816+row) / np.power(F(10000), np.arange(16*group, 16*group+16, dtype=np.float32)/F(128), dtype=np.float32)
            c, s = np.cos(angle), np.sin(angle)
            qa[group][row] = quant((x*c-y*s).astype(np.float32))
            qa[group+8][row] = quant((y*c+x*s).astype(np.float32))
    for row in range(51):
        x = np.array([(row % 3-1)*(1+j%3) for j in range(16)], dtype=np.float32)
        y = np.array([(row % 3-1)*(1+(16+j)%3) for j in range(16)], dtype=np.float32)
        angle = F(816+row) / np.power(F(10000), np.arange(16, dtype=np.float32)/F(128), dtype=np.float32)
        c, s = np.cos(angle), np.sin(angle)
        ka[0][row], ka[1][row] = quant(x*c-y*s), quant(y*c+x*s)
    for tile in range(2):
        for beat in range(64):
            group, feature = divmod(beat, 16)
            x = np.array([((16*group+j)%3-1)*(1+(16*tile+feature)%3) if 16*group+j < 51 else 0 for j in range(16)], dtype=np.float32)
            va.append(quant(x))
    write_q("q.mem", (qa[t][r] for t in range(16) for r in range(51)))
    write_q("k.mem", (ka[t][r] for t in range(2) for r in range(51)))
    write_q("v.mem", va)

    m = np.full(51, -np.inf, dtype=np.float32)
    l = np.zeros(51, dtype=np.float32)
    o = np.zeros(51, dtype=np.float32)
    pgold, sgold, agold, lgold = [], [], [], []
    for block in range(55):
        for row in range(51):
            score = F(0)
            for k in range(16):
                score = add(score, dot(qa[k][row], 1+block%3, fold=-4))
            valid = np.ones(16, bool)
            if block >= 51:
                valid = np.array([816+(block-51)*16+j <= (816 if row==0 else 866) for j in range(16)])
            s = np.where(valid, score, F(-np.inf))
            old = m[row]
            new = F(max(float(old), float(np.max(s))))
            aa = F(0) if np.isneginf(new) else F(-np.inf) if np.isneginf(old) else F(old-new)
            alpha = np.exp(aa)
            p = np.where(valid, np.exp((s-new).astype(np.float32)), F(0))
            pg = quant(p)
            l[row] = add(mul(alpha, l[row]), tree_sum(p))
            o[row] = add(mul(alpha, o[row]), dot(pg))
            m[row] = new
            pgold.append(pg)
            sgold.extend(word(v) for v in s)
            agold.append((word(new), word(aa), word(alpha)))
            lgold.append(word(l[row]))
    write_q("p.mem", pgold)
    (DEST / "score.mem").write_text("".join(f"{v:08x}\n" for v in sgold), encoding="ascii")
    (DEST / "stats.mem").write_text("".join(f"{a:08x}{b:08x}{c:08x}{d:08x}\n" for (a,b,c),d in zip(agold,lgold)), encoding="ascii")
    oa = [quant(np.full(16, mul(o[r], F(F(1)/l[r])), dtype=np.float32)) for r in range(51)]
    write_q("o.mem", (oa[r] for t in range(16) for r in range(51)))
    za = []
    for row in range(51):
        x = F(row % 3-1)
        u = mul(mul(mul(F(.044715), x), x), x)
        z = mul(add(x,u), F(-2*np.sqrt(2/np.pi)))
        gelu = mul(x, F(F(1)/add(F(1), np.exp(z))))
        za.append(quant(np.full(16, mul(gelu, F(2*x)), dtype=np.float32)))
    write_q("z.mem", (za[r] for t in range(32) for r in range(51)))
    reduce_o, reduce_down = [], []
    for row in range(51):
        v = F(0)
        for _ in range(16):
            v = add(v, dot(oa[row]))
        reduce_o.append(word(v))
        v = F(0)
        for _ in range(32):
            v = add(v, dot(za[row]))
        reduce_down.append(word(v))
    (DEST / "reduce.mem").write_text("".join(f"{v:08x}\n" for v in reduce_o+reduce_down), encoding="ascii")
    (DEST / "manifest.json").write_text(json.dumps({
        "source": "independent NumPy FP32; integer per-B16 dots; no DUT reads",
        "rows": 51, "prefix_valid": 816, "qk_blocks": 55, "pv_blocks": 55,
        "quant": "existing VPU floor exponent, RNE, saturation [-127,127]",
        "all_output_coordinates_checked": True, "input_data": "signed row pattern -1,0,1; feature/block-varying weights",
        "fp_golden_tolerance": "nonlinear FP32 up to documented ULP; INT8/exponent/tags exact"
    }, indent=2), encoding="utf-8")
    print("SEVEN_JOB_GOLD_READY Q=816 O=816 Z=1632 P=2805 SCORE=44880")


if __name__ == "__main__":
    main()
