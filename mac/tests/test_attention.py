import unittest
from types import SimpleNamespace

import torch
from torch import nn

from beacon.attention import NativeAttention


class NativeAttentionTests(unittest.TestCase):
    def test_matches_explicit_attention_and_reuses_weights(self):
        torch.manual_seed(7)
        original = SimpleNamespace(num_heads=4, scale=8 ** -0.5,
                                   qkv=nn.Linear(32, 96), proj=nn.Linear(32, 32),
                                   attn_drop=nn.Dropout(0.2), proj_drop=nn.Dropout(0),
                                   training=False)
        native = NativeAttention(original)
        self.assertIs(native.qkv.weight, original.qkv.weight)
        for tokens in (1, 31, 200):
            x = torch.randn(2, tokens, 32)
            q, k, v = original.qkv(x).reshape(2, tokens, 3, 4, 8).permute(2, 0, 3, 1, 4)
            attention = ((q * original.scale) @ k.transpose(-2, -1)).softmax(-1)
            expected = original.proj((attention @ v).transpose(1, 2).reshape(2, tokens, 32))
            torch.testing.assert_close(native(x), expected, rtol=1e-5, atol=1e-6)


if __name__ == '__main__':
    unittest.main()
