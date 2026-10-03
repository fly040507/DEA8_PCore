from __future__ import annotations

import statistics

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


def build_inputs(model: PI0Pytorch, device: torch.device):
    config = model.config
    state = torch.randn(1, config.action_dim, device=device, dtype=torch.float32)
    noisy_actions = torch.randn(
        1,
        config.action_horizon,
        config.action_dim,
        device=device,
        dtype=torch.float32,
    )
    timestep = torch.full((1,), 0.5, device=device, dtype=torch.float32)

    with torch.inference_mode():
        suffix_embs, _, _, adarms_cond = model.embed_suffix(
            state,
            noisy_actions,
            timestep,
        )
        suffix_embs = suffix_embs.to(torch.bfloat16)

    length = suffix_embs.shape[1]
    attention_mask = torch.zeros(
        1,
        1,
        length,
        length,
        device=device,
        dtype=suffix_embs.dtype,
    )
    position_ids = torch.arange(
        length,
        device=device,
        dtype=torch.long,
    )[None, :]

    return suffix_embs, adarms_cond, attention_mask, position_ids


def forward_once(
    model: PI0Pytorch,
    suffix_embs,
    adarms_cond,
    attention_mask,
    position_ids,
):
    outputs, _ = model.paligemma_with_expert.forward(
        attention_mask=attention_mask,
        position_ids=position_ids,
        past_key_values=None,
        inputs_embeds=[None, suffix_embs],
        use_cache=False,
        adarms_cond=[None, adarms_cond],
    )
    suffix_out = outputs[1]
    action_features = suffix_out[:, -model.config.action_horizon :].float()
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

    print("正在构建模型……")
    model = PI0Pytorch(config)
    model.eval()
    move_action_path_to_device(model, device)

    expert = model.paligemma_with_expert.gemma_expert
    core_params = sum(p.numel() for p in expert.model.layers.parameters())
    core_params += sum(p.numel() for p in expert.model.norm.parameters())

    projection_modules = [
        model.state_proj,
        model.action_in_proj,
        model.action_time_mlp_in,
        model.action_time_mlp_out,
        model.action_out_proj,
    ]
    projection_params = sum(
        p.numel()
        for module in projection_modules
        for p in module.parameters()
    )

    suffix_embs, adarms_cond, attention_mask, position_ids = build_inputs(
        model, device
    )

    warmup = 5
    repeats = 20

    with torch.inference_mode():
        for _ in range(warmup):
            forward_once(
                model,
                suffix_embs,
                adarms_cond,
                attention_mask,
                position_ids,
            )
        torch.cuda.synchronize()

        torch.cuda.reset_peak_memory_stats(0)
        times_ms = []

        for _ in range(repeats):
            start = torch.cuda.Event(enable_timing=True)
            end = torch.cuda.Event(enable_timing=True)

            start.record()
            output = forward_once(
                model,
                suffix_embs,
                adarms_cond,
                attention_mask,
                position_ids,
            )
            end.record()

            torch.cuda.synchronize()
            times_ms.append(start.elapsed_time(end))

    print("=" * 72)
    print("正式 Action Expert 稳定性能测试")
    print("GPU:", torch.cuda.get_device_name(0))
    print("Transformer 层数:", len(expert.model.layers))
    print(f"18层 Transformer 核心参数量: {core_params:,}")
    print(f"动作输入输出投影参数量: {projection_params:,}")
    print(f"实际动作计算路径参数量: {core_params + projection_params:,}")
    print("输出 Shape:", list(output.shape))
    print("预热次数:", warmup)
    print("测量次数:", repeats)
    print(f"平均耗时: {statistics.mean(times_ms):.2f} ms")
    print(f"中位数耗时: {statistics.median(times_ms):.2f} ms")
    print(f"最小耗时: {min(times_ms):.2f} ms")
    print(f"最大耗时: {max(times_ms):.2f} ms")
    print(
        "峰值显存:",
        f"{torch.cuda.max_memory_allocated(0) / 1024 / 1024:.2f} MiB",
    )
    print("=" * 72)


if __name__ == "__main__":
    main()
