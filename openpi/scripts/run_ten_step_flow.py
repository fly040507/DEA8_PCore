from __future__ import annotations

import time
import torch

from openpi.models.pi0_config import Pi0Config
from openpi.models_pytorch.pi0_pytorch import PI0Pytorch


def move_action_path_to_device(model: PI0Pytorch, device: torch.device) -> None:
    model.state_proj.to(device)
    model.action_in_proj.to(device)
    model.action_time_mlp_in.to(device)
    model.action_time_mlp_out.to(device)
    model.action_out_proj.to(device)
    model.paligemma_with_expert.gemma_expert.to(device)


def predict_velocity(model, state, x_t, timestep):
    with torch.inference_mode():
        suffix_embs, _, _, adarms_cond = model.embed_suffix(state, x_t, timestep)
        suffix_embs = suffix_embs.to(torch.bfloat16)

        length = suffix_embs.shape[1]
        attention_mask = torch.zeros(
            1, 1, length, length,
            device=x_t.device,
            dtype=suffix_embs.dtype,
        )
        position_ids = torch.arange(
            length, device=x_t.device, dtype=torch.long
        )[None, :]

        outputs, _ = model.paligemma_with_expert.forward(
            attention_mask=attention_mask,
            position_ids=position_ids,
            past_key_values=None,
            inputs_embeds=[None, suffix_embs],
            use_cache=False,
            adarms_cond=[None, adarms_cond],
        )

        suffix_out = outputs[1]
        action_features = suffix_out[:, -model.config.action_horizon:].float()
        return model.action_out_proj(action_features)


def main() -> None:
    if not torch.cuda.is_available():
        raise RuntimeError("CUDA 不可用")

    torch.cuda.set_device(0)
    device = torch.device("cuda:0")

    config = Pi0Config(
        dtype="bfloat16",
        paligemma_variant="gemma_2b",
        action_expert_variant="gemma_300m",
        action_dim=32,
        action_horizon=50,
        pytorch_compile_mode=None,
    )

    print("正在构建真实结构（随机初始化，不加载训练权重）……")
    model = PI0Pytorch(config)
    model.eval()
    move_action_path_to_device(model, device)

    torch.manual_seed(0)
    state = torch.randn(1, config.action_dim, device=device)
    x_t = torch.randn(
        1, config.action_horizon, config.action_dim, device=device
    )

    num_steps = 10
    dt = -1.0 / num_steps
    step_times = []

    print("=" * 82)
    print("10 步 Flow Matching 迭代")
    print("初始动作 Shape:", list(x_t.shape))
    print("dt:", dt)
    print("=" * 82)

    torch.cuda.reset_peak_memory_stats(0)
    total_start = time.perf_counter()

    for step in range(num_steps):
        t_value = 1.0 + step * dt
        timestep = torch.full(
            (1,), t_value, device=device, dtype=torch.float32
        )

        torch.cuda.synchronize()
        start = time.perf_counter()

        velocity = predict_velocity(model, state, x_t, timestep)
        x_t = x_t + dt * velocity

        torch.cuda.synchronize()
        elapsed_ms = (time.perf_counter() - start) * 1000
        step_times.append(elapsed_ms)

        print(
            f"step={step + 1:02d} "
            f"t={t_value:.1f} "
            f"x_t={list(x_t.shape)} "
            f"v_t={list(velocity.shape)} "
            f"x_mean={x_t.mean().item():+.5f} "
            f"x_std={x_t.std().item():.5f} "
            f"time={elapsed_ms:.2f} ms"
        )

    total_ms = (time.perf_counter() - total_start) * 1000

    print("=" * 82)
    print("最终动作 Shape:", list(x_t.shape))
    print("是否存在 NaN:", bool(torch.isnan(x_t).any().item()))
    print(f"10 步总耗时: {total_ms:.2f} ms")
    print(f"平均每步耗时: {sum(step_times) / len(step_times):.2f} ms")
    print(
        "峰值显存:",
        f"{torch.cuda.max_memory_allocated(0) / 1024 / 1024:.2f} MiB",
    )
    print("=" * 82)
    print("说明：当前使用随机初始化权重，数值不代表真实机器人动作。")


if __name__ == "__main__":
    main()
