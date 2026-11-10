"""Shared pieces of the colourisation model conversions
(make_colorize_ddcolor.py, make_colorize_deoldify.py). The download, export
and record plumbing is face_models_common's; downloads are cached in
addon-staging/colorize-work (FACE_MODELS_WORK overrides it)."""

import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import face_models_common as fm  # noqa: E402

os.environ.setdefault("FACE_MODELS_WORK", os.path.join(fm.STAGING, "colorize-work"))


def bake_norms(net):
    """Replace every spectral- or weight-normalised weight with its value.

    In eval mode torch's spectral_norm divides weight_orig by the sigma its
    stored u and v give, on every call (and weight_norm recombines g and v),
    so a traced graph keeps a second, reshaped copy of each weight to compute
    the normalisation from (50 MB of DDColor-T's export). The remove_*
    functions compute the same weight once, without a power iteration, so
    the network's output is unchanged."""
    import torch
    from torch.nn.utils.spectral_norm import SpectralNorm
    from torch.nn.utils.weight_norm import WeightNorm

    for module in net.modules():
        for hook in list(module._forward_pre_hooks.values()):
            if isinstance(hook, SpectralNorm):
                torch.nn.utils.remove_spectral_norm(module, hook.name)
            elif isinstance(hook, WeightNorm):
                torch.nn.utils.remove_weight_norm(module, hook.name)


def edge_pad_top_left():
    """A module equal to nn.ReplicationPad2d((1, 0, 1, 0)) — repeat the first
    row and column — written as slices and concatenations. Core ML's ML
    Program has no edge-mode Pad, so the original splits the graph into a
    partition per pad (DDColor's export: six partitions, 80 s to compile);
    this exports as Slice + Concat, which it takes, and gives the same
    numbers exactly."""
    import torch
    from torch import nn

    class EdgePadTopLeft(nn.Module):
        def forward(self, x):
            x = torch.cat([x[:, :, :1], x], dim=2)
            return torch.cat([x[:, :, :, :1], x], dim=3)

    return EdgePadTopLeft()


def replace_replication_pads(net):
    """Swap every ReplicationPad2d((1, 0, 1, 0)) in `net` for edge_pad_top_left()."""
    from torch import nn

    count = 0
    for module in list(net.modules()):
        for name, child in list(module.named_children()):
            if isinstance(child, nn.ReplicationPad2d) and tuple(child.padding) == (1, 0, 1, 0):
                setattr(module, name, edge_pad_top_left())
                count += 1
    return count


def grey_to_rgb(luma):
    """(1, 1, H, W) -> (1, 3, H, W) by concatenation, which Core ML takes
    (Tensor.repeat exports as Expand/Tile, which it does not)."""
    import torch

    return torch.cat([luma, luma, luma], dim=1)


def test_input(size, seed=0):
    """A deterministic grey (1, 1, size, size) picture in [0, 1]: a soft
    blob, two hard edges and noise, so the networks see structure."""
    rng = np.random.default_rng(seed)
    y, x = np.mgrid[0:size, 0:size].astype(np.float32) / size
    img = 0.35 + 0.3 * np.exp(-((x - 0.4) ** 2 + (y - 0.35) ** 2) / 0.05)
    img += 0.25 * (x > 0.7) - 0.15 * (y > 0.8)
    img += rng.normal(0, 0.03, img.shape).astype(np.float32)
    return np.clip(img, 0, 1)[None, None].astype(np.float32)


def parity_at_sizes(sess, refs, input_name, unit):
    """ONNX Runtime's output against PyTorch references {size: (x, ref)}."""
    out = {}
    for size, (x, ref) in refs.items():
        got = sess.run(None, {input_name: x})[0]
        d = np.abs(ref.astype(np.float64) - got)
        out[str(size)] = {"max": float(d.max()), "mean": float(d.mean()), "unit": unit,
                          "refRange": [float(ref.min()), float(ref.max())]}
    return out
