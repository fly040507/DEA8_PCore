from __future__ import annotations

import torch
from torch import nn


def describe_shape(value):
    """递归提取张量、列表和元组中的 Shape。"""
    if torch.is_tensor(value):
        return list(value.shape)

    if value is None:
        return None

    if isinstance(value, (list, tuple)):
        return [describe_shape(item) for item in value]

    if isinstance(value, dict):
        return {key: describe_shape(item) for key, item in value.items()}

    return type(value).__name__


def make_hook(name: str):
    def hook(module: nn.Module, inputs, output):
        input_shapes = describe_shape(inputs)
        output_shapes = describe_shape(output)

        print(
            f"{name:<48} "
            f"input={input_shapes} "
            f"output={output_shapes}"
        )

    return hook


def register_action_expert_hooks(
    model: nn.Module,
    layer_ids=(0, 17),
):
    """
    给 π0 Action Expert 注册 Shape Hook。

    默认只打印第0层和第17层，避免18层全部打印导致日志过长。
    将 layer_ids 改成 range(18)，可以输出全部18层。
    """
    model = getattr(model, "module", model)
    handles = []

    top_modules = {
        "state_proj": getattr(model, "state_proj", None),
        "action_in_proj": getattr(model, "action_in_proj", None),
        "action_time_mlp_in": getattr(
            model, "action_time_mlp_in", None
        ),
        "action_time_mlp_out": getattr(
            model, "action_time_mlp_out", None
        ),
        "time_mlp_in": getattr(model, "time_mlp_in", None),
        "time_mlp_out": getattr(model, "time_mlp_out", None),
        "action_out_proj": getattr(model, "action_out_proj", None),
    }

    for name, module in top_modules.items():
        if module is not None:
            handles.append(
                module.register_forward_hook(make_hook(name))
            )

    expert_model = (
        model.paligemma_with_expert
        .gemma_expert
        .model
    )

    for layer_id in layer_ids:
        layer = expert_model.layers[layer_id]

        layer_modules = {
            f"layer{layer_id}.input_layernorm":
                layer.input_layernorm,

            f"layer{layer_id}.q_proj":
                layer.self_attn.q_proj,

            f"layer{layer_id}.k_proj":
                layer.self_attn.k_proj,

            f"layer{layer_id}.v_proj":
                layer.self_attn.v_proj,

            f"layer{layer_id}.o_proj":
                layer.self_attn.o_proj,

            f"layer{layer_id}.post_attention_layernorm":
                layer.post_attention_layernorm,

            f"layer{layer_id}.mlp.gate_proj":
                layer.mlp.gate_proj,

            f"layer{layer_id}.mlp.up_proj":
                layer.mlp.up_proj,

            f"layer{layer_id}.mlp.down_proj":
                layer.mlp.down_proj,
        }

        for name, module in layer_modules.items():
            handles.append(
                module.register_forward_hook(make_hook(name))
            )

    handles.append(
        expert_model.norm.register_forward_hook(
            make_hook("expert.final_norm")
        )
    )

    return handles


def remove_hooks(handles):
    """运行完成后移除所有 Hook。"""
    for handle in handles:
        handle.remove()