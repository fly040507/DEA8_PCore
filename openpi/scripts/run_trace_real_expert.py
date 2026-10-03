from __future__ import annotations

import time

import torch

from openpi.models.pi0_config import Pi0Config
from openpi.models_pytorch.pi0_pytorch import PI0Pytorch
from scripts.trace_action_expert_shapes import (
    register_action_expert_hooks,
    remove_hooks,
)


def move_action_path_to_device(model: PI0Pytorch, device: torch.device) -> None:
    """仅把 Action Expert 及动作输入/输出层移动到 GPU。"""
    model.state_proj.to(device)
    model.action_in_proj.to(device)
    model.action_time_mlp_in.to(device)
    model.action_time_mlp_out.to(device)
    model.action_out_proj.to(device)
    model.paligemma_with_expert.gemma_expert.to(device)


def main() -> None:
    if not torch.cuda.is_available():
        raise RuntimeError("CUDA 不可用，请检查 CUDA_VISIBLE_DEVICES。")

    torch.cuda.set_device(0)
    device = torch.device("cuda:0")

    print("=" * 88)
    print("真实配置 Action Expert Shape 验证（不加载训练权重）")
    print("PyTorch:", torch.__version__)
    print("可见 GPU:", torch.cuda.get_device_name(0))
    print("=" * 88)

    config = Pi0Config(
        dtype="bfloat16",
        paligemma_variant="gemma_2b",
        action_expert_variant="gemma_300m",
        action_dim=32,
        action_horizon=50,
        pytorch_compile_mode=None,
    )

    print("正在构建完整结构；VLM 保留在 CPU，只把 Action Expert 移到 GPU……")
    model = PI0Pytorch(config)
    model.eval()
    move_action_path_to_device(model, device)

    expert = model.paligemma_with_expert.gemma_expert
    expert_params = sum(p.numel() for p in expert.parameters())
    expert_dtype = next(expert.parameters()).dtype

    print(f"Action Expert 参数量: {expert_params:,}")
    print("Action Expert 参数 dtype:", expert_dtype)
    print("Action Expert 层数:", len(expert.model.layers))

    handles = register_action_expert_hooks(model, layer_ids=(0, 17))

    batch_size = 1
    state = torch.randn(
        batch_size,
        config.action_dim,
        device=device,
        dtype=torch.float32,
    )
    noisy_actions = torch.randn(
        batch_size,
        config.action_horizon,
        config.action_dim,
        device=device,
        dtype=torch.float32,
    )
    timestep = torch.full(
        (batch_size,),
        0.5,
        device=device,
        dtype=torch.float32,
    )

    try:
        torch.cuda.reset_peak_memory_stats(0)

        with torch.inference_mode():
            suffix_embs, _, _, adarms_cond = model.embed_suffix(
                state,
                noisy_actions,
                timestep,
            )

            suffix_length = suffix_embs.shape[1]
            attention_mask = torch.zeros(
                batch_size,
                1,
                suffix_length,
                suffix_length,
                device=device,
                dtype=torch.float32,
            )
            position_ids = torch.arange(
                suffix_length,
                device=device,
                dtype=torch.long,
            )[None, :].expand(batch_size, -1)

            torch.cuda.synchronize()
            start = time.perf_counter()

            outputs, _ = model.paligemma_with_expert.forward(
                attention_mask=attention_mask,
                position_ids=position_ids,
                past_key_values=None,
                inputs_embeds=[None, suffix_embs],
                use_cache=False,
                adarms_cond=[None, adarms_cond],
            )

            suffix_out = outputs[1]
            action_features = suffix_out[:, -config.action_horizon :].to(
                torch.float32
            )
            predicted_velocity = model.action_out_proj(action_features)

            torch.cuda.synchronize()
            elapsed_ms = (time.perf_counter() - start) * 1000

        print("=" * 88)
        print("最终结果")
        print("suffix_embs:", list(suffix_embs.shape), suffix_embs.dtype)
        print("suffix_out:", list(suffix_out.shape), suffix_out.dtype)
        print(
            "predicted_velocity:",
            list(predicted_velocity.shape),
            predicted_velocity.dtype,
        )
        print(f"单次 Action Expert 前向耗时: {elapsed_ms:.2f} ms")
        print(
            "峰值显存 MiB:",
            round(torch.cuda.max_memory_allocated(0) / 1024 / 1024, 2),
        )
        print("=" * 88)

    finally:
        remove_hooks(handles)


if __name__ == "__main__":
    main()
