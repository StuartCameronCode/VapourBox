#!/usr/bin/env python3
"""Convert GFPGAN v1.4 (TencentARC/GFPGAN, release v1.3.0's GFPGANv1.4.pth) to
face-gfpgan-v1.4.onnx for the face-gfpgan add-on.

The network is GFPGANv1Clean (the "clean" architecture GFPGANer uses for
v1.4, with no custom CUDA ops). Input and output are (1, 3, 512, 512) RGB in
[-1, 1], float32, static.

One deliberate difference from upstream inference: GFPGANer runs the
StyleGAN2 decoder with randomize_noise=True, drawing fresh noise for every
call. On video that is new random texture on every frame — flicker by
construction — so the export uses randomize_noise=False, the generator's
fixed noise buffers (part of the checkpoint), which makes the model a pure
function of its input. The parity record compares against PyTorch with the
same setting, and also states how far upstream's random-noise output sits
from it, for scale.

Licence: GFPGAN is Apache-2.0 except its StyleGAN2-derived code, which is
under NVIDIA's licence (non-commercial: research or evaluation only). The
add-on carries that as its usageNote.

Usage (conversion venv, see docs/ADDONS.md):

    VAPOURBOX_ADDON_STAGING=/path/to/addon-staging python Scripts/models/make_face_gfpgan.py
"""

import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import face_models_common as fm  # noqa: E402

GFPGAN = ("TencentARC/GFPGAN", "7552a7791caad982045a7bbe5634bbf1cd5c8679")
CKPT = (
    "https://github.com/TencentARC/GFPGAN/releases/download/v1.3.0/GFPGANv1.4.pth",
    "e2cd4703ab14f4d01fd1383a8a8b266f9a5833dacee8e6a79d3bf21a1b6be5ad",
)


def gfpgan():
    import torch

    src = fm.upstream_source(*GFPGAN)
    fm.stub_module("basicsr.utils.registry", ARCH_REGISTRY=fm.Registry())
    fm.stub_module("basicsr.archs.arch_util", default_init_weights=lambda *a, **k: None)
    for pkg in ("gfpgan", "gfpgan.archs"):
        fm.stub_module(pkg).__path__ = [os.path.join(src, *pkg.split("."))]
    from gfpgan.archs.gfpganv1_clean_arch import GFPGANv1Clean

    net = GFPGANv1Clean(
        out_size=512,
        num_style_feat=512,
        channel_multiplier=2,
        decoder_load_path=None,
        fix_decoder=False,
        num_mlp=8,
        input_is_latent=True,
        different_w=True,
        narrow=1,
        sft_half=True,
    )
    ckpt = fm.load_checkpoint(fm.fetch(*CKPT))
    net.load_state_dict(ckpt["params_ema"] if "params_ema" in ckpt else ckpt["params"], strict=True)
    net.eval()

    class Restore(torch.nn.Module):
        def __init__(self, inner, randomize_noise=False):
            super().__init__()
            self.inner = inner
            self.randomize_noise = randomize_noise

        def forward(self, x):
            return self.inner(x, return_rgb=False, randomize_noise=self.randomize_noise)[0]

    return Restore(net).eval(), Restore(net, randomize_noise=True).eval()


def main():
    import torch

    torch.manual_seed(0)
    net, upstream = gfpgan()
    out = os.path.join(fm.STAGING, "face-gfpgan-v1.4.onnx")
    x = fm.face_test_input()
    info = fm.export(net, [torch.from_numpy(x)], ["input"], ["output"], out)
    info["checkpoint"] = CKPT[0]
    info["parity"] = fm.parity(net, out, {"input": x})
    with torch.no_grad():
        fixed = net(torch.from_numpy(x)).numpy()
        rand = upstream(torch.from_numpy(x)).numpy()
    d = np.abs(fixed - rand)
    info["fixedVsRandomNoise"] = {"max": float(d.max()), "mean": float(d.mean()), "unit": "[-1, 1] output"}
    fm.write_record("face-gfpgan", {"opset": fm.OPSET, "irVersion": fm.IR_VERSION,
                                    "torch": torch.__version__, "models": [info]})


if __name__ == "__main__":
    main()
