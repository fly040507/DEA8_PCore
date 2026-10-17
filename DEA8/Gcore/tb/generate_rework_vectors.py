"""Independent NumPy reference for grouped SUM64, online gamma and core partials."""
import json
import numpy as np
import generate_numeric_vectors as base

F32 = np.float32
OUT = base.OUT
factors = np.asarray([1, 2, 4, 8, -1, -2, -4, 0], dtype=np.float32) / F32(8)


def reduce_delta(delta):
    values = np.multiply(delta[..., None], factors, dtype=np.float32)
    while values.shape[-1] > 1:
        values = np.add(values[..., ::2], values[..., 1::2], dtype=np.float32)
    return values[..., 0]


def residual(old, delta):
    result = np.empty_like(old)
    for n in range(64):
        for r in range(51):
            for i in range(16):
                result[n, r, i] = base.bf16(F32(base.from_bf(old[n, r, i]) + delta[n, r, i]))
    return result


gamma = []
for k in range(2):
    values = np.asarray([F32(0.5 + ((c * 5 + k * 7) % 25) / 16) for c in range(1024)])
    values[::37] *= F32(-1)
    values[::127] = F32(0)
    gamma.append(values.reshape(64, 16))
    base.write(f"group_gamma{k}.mem", [base.bits(v) for v in values], 32)


def reference(name, stored, which_gamma):
    sq = np.zeros(51, dtype=np.float32)
    for g in range(16):
        for r in range(51):
            terms = np.asarray([base.from_bf(v) for v in stored[4*g:4*g+4, r].reshape(-1)], dtype=np.float32)
            terms = np.multiply(terms, terms, dtype=np.float32)
            while len(terms) > 1:
                terms = np.add(terms[::2], terms[1::2], dtype=np.float32)
            sq[r] = F32(sq[r] + terms[0])
    u = np.add(np.multiply(sq, F32(2**-10), dtype=np.float32), F32(1e-6), dtype=np.float32)
    inv = np.asarray([F32(1.0 / np.sqrt(float(x))) for x in u], dtype=np.float32)
    quantized = []
    for n in range(64):
        for r in range(51):
            x = np.asarray([base.from_bf(v) for v in stored[n, r]], dtype=np.float32)
            h = np.multiply(x, inv[r], dtype=np.float32)
            y = np.multiply(h, gamma[which_gamma][n], dtype=np.float32)
            quantized.append(base.quantize(y))
    base.write(f"group_{name}_residual.mem", [base.packed(row, 16) for row in stored.reshape(-1, 16)], 256)
    for suffix, values in [("sq", sq), ("u", u), ("inv", inv)]:
        base.write(f"group_{name}_{suffix}.mem", [base.bits(v) for v in values], 32)
    base.write(f"group_{name}_xhat.mem", quantized, 136)


mid = residual(base.initial, reduce_delta(base.delta_o))
last = residual(mid, reduce_delta(base.delta_d))
reference("initial", base.initial, 0)
reference("mid", mid, 1)
reference("next", last, 0)
final_values = []
for n in range(64):
    for r in range(51):
        # Reuse the separately generated FP32 inverse, not any RTL output.
        u_bits = (OUT / "group_next_inv.mem").read_text().splitlines()[r]
        inverse = base.value(int(u_bits, 16))
        x = np.asarray([base.from_bf(v) for v in last[n, r]], dtype=np.float32)
        y = np.multiply(np.multiply(x, inverse, dtype=np.float32), gamma[0][n], dtype=np.float32)
        final_values.append(base.packed([base.bits(v) for v in y], 32))
base.write("group_final_fp32.mem", final_values, 512)
(OUT / "group_reference.json").write_text(json.dumps({
    "rows": 51, "hidden": 1024, "gamma_slots": 2,
    "reduction": "adjacent SUM8 then adjacent SUM64, then g=0..15 FP32 RNE accumulation",
    "core_factors": factors.tolist(), "norm": "FP32(FP32(BF16(X)*inv)*gamma), direct B16 quantization",
    "rsqrt_tolerance_ulp": 1,
}, indent=2) + "\n", encoding="ascii")
print("Generated grouped reference with two nontrivial gamma parameter sets")
