"""Native PyTorch attention for the depth model, reusing its trained weights."""
from torch import nn
from torch.nn import functional as F


class NativeAttention(nn.Module):
    def __init__(self, original):
        super().__init__()
        self.num_heads = original.num_heads
        self.scale = original.scale
        self.qkv = original.qkv
        self.proj = original.proj
        self.attn_drop = original.attn_drop
        self.proj_drop = original.proj_drop
        self.train(original.training)

    def forward(self, x, attn_bias=None):
        if attn_bias is not None:
            raise ValueError("Beacon depth inference expects a single image tensor")
        batch, tokens, channels = x.shape
        q, k, v = self.qkv(x).reshape(
            batch, tokens, 3, self.num_heads, channels // self.num_heads
        ).permute(2, 0, 3, 1, 4).unbind(0)
        x = F.scaled_dot_product_attention(
            q, k, v, dropout_p=self.attn_drop.p if self.training else 0.0,
            scale=self.scale,
        )
        x = x.transpose(1, 2).reshape(batch, tokens, channels)
        return self.proj_drop(self.proj(x))


def use_native_attention(model, attention_type):
    for name, child in list(model.named_children()):
        if isinstance(child, attention_type):
            setattr(model, name, NativeAttention(child))
        else:
            use_native_attention(child, attention_type)
