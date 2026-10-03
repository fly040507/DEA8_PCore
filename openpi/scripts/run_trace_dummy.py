from __future__ import annotations

import torch

from openpi.models.pi0_config import Pi0Config
from openpi.models_pytorch.pi0_pytorch import PI0Pytorch
from scripts.trace_action_expert_shapes import (
    register_action_expert_hooks,
    remove_hooks,
)


def main() -> None:
    if not torch.cuda.is_available():
        raise RuntimeError("CUDA 不可用，请检查环境和 CUDA_VISIBLE_DEVICES。")

    device = torch.device("cuda:0")
    torch.cuda.reset_peak_memory_stats(device)

    print("=" * 80)
    print("Dummy Action Expert Shape 验证")
    print("PyTorch:", torch.__version__)
    print("可见 GPU:", torch.cuda.get_device_name(0))
    print("=" * 80)

    config = Pi0Config(
        dtype="float32",
        paligemma_variant="dummy",
        action_expert_variant="dummy",
        action_dim=32,
        action_horizon=50,
        pytorch_compile_mode=None,
    )

    model = PI0Pytorch(config).to(device)
    model.eval()

    handles = register_action_expert_hooks(model, layer_ids=(0, 3))

    batch_size = 1
    state = torch.randn(
        batch_size, config.action_dim, device=device, dtype=torch.float32
    )
    noisy_actions = torch.randn(
        batch_size,
        config.action_horizon,
        config.action_dim,
        device=device,
        dtype=torch.float32,
    )
    timestep = torch.full(
        (batch_size,), 0.5, device=device, dtype=torch.float32
    )

    try:
        with torch.no_grad():
            suffix_embs, _, _, adarms_cond = model.embed_suffix(
                state, noisy_actions, timestep
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
                suffix_length, device=device, dtype=torch.long
            )[None, :].expand(batch_size, -1)

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

        print("=" * 80)
        print("最终结果")
        print("suffix_embs:", list(suffix_embs.shape))
        print("suffix_out:", list(suffix_out.shape))
        print("predicted_velocity:", list(predicted_velocity.shape))
        print(
            "峰值显存 MiB:",
            round(torch.cuda.max_memory_allocated(device) / 1024 / 1024, 2),
        )
        print("=" * 80)
    finally:
        remove_hooks(handles)


if __name__ == "__main__":
    main()
