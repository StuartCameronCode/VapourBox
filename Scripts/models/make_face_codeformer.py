#!/usr/bin/env python3
"""Convert CodeFormer (sczhou/CodeFormer, release v0.1.0's codeformer.pth) to
face-codeformer-v0.1.0.onnx for the face-codeformer add-on.

Inputs: `input`, (1, 3, 512, 512) RGB in [-1, 1]; `w`, shape (1,), the
fidelity weight (0 = the codebook's best guess, 1 = closest to the input).
Output: `output`, (1, 3, 512, 512) RGB in [-1, 1]. float32, static shapes.
Upstream's inference runs with adain=True, as this does.

Why `w` is an input rather than a few fixed exports: CodeFormer uses w in one
place, each fusion block's `out = dec + w * (dec * scale + shift)`, behind an
`if w > 0`. The export traces the w > 0 branch, and at w = 0 that branch adds
exactly zero, so one graph is the network at every w — where fixed exports
would mean a ~377 MB file per offered value. The parity record checks w = 0,
0.5, 0.7 and 1 against PyTorch (which skips the fusion at w = 0).

Licence: S-Lab License 1.0 — redistribution for non-commercial purposes only,
with the copyright notice. The add-on carries that as its usageNote.

Usage (conversion venv, see docs/ADDONS.md):

    VAPOURBOX_ADDON_STAGING=/path/to/addon-staging python Scripts/models/make_face_codeformer.py
"""

import logging
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import face_models_common as fm  # noqa: E402

CODEFORMER = ("sczhou/CodeFormer", "b33cc7d639d6545bfcccc7e0bc6ae51f24e79c2b")
CKPT = (
    "https://github.com/sczhou/CodeFormer/releases/download/v0.1.0/codeformer.pth",
    "1009e537e0c2a07d4cabce6355f53cb66767cd4b4297ec7a4a64ca4b8a5684b7",
)
W_CHECKS = [0.0, 0.5, 0.7, 1.0]


def codeformer():
    import torch

    src = fm.upstream_source(*CODEFORMER)
    fm.stub_module("basicsr.utils", get_root_logger=lambda *a, **k: logging.getLogger("codeformer"))
    fm.stub_module("basicsr.utils.registry", ARCH_REGISTRY=fm.Registry())
    fm.stub_module("basicsr.archs").__path__ = [os.path.join(src, "basicsr", "archs")]
    from basicsr.archs.codeformer_arch import CodeFormer

    net = CodeFormer(dim_embd=512, codebook_size=1024, n_head=8, n_layers=9, connect_list=["32", "64", "128", "256"])
    ckpt = fm.load_checkpoint(fm.fetch(*CKPT))
    net.load_state_dict(ckpt["params_ema"], strict=True)
    net.eval()

    import torch.nn.functional as F
    from basicsr.archs.codeformer_arch import adaptive_instance_normalization

    class Restore(torch.nn.Module):
        """CodeFormer.forward(x, w, adain=True)[0], line for line, except that
        feature sizes are taken as Python ints (`str(x.shape[-1])` is a
        tensor's repr under the tracer, which breaks the dict lookups) and the
        fusion runs for every w (see the module docstring)."""

        def __init__(self, inner):
            super().__init__()
            self.inner = inner

        def forward(self, x, w):
            m = self.inner
            enc_feat_dict = {}
            out_list = [m.fuse_encoder_block[f] for f in m.connect_list]
            for i, block in enumerate(m.encoder.blocks):
                x = block(x)
                if i in out_list:
                    enc_feat_dict[str(int(x.shape[-1]))] = x.clone()
            lq_feat = x
            pos_emb = m.position_emb.unsqueeze(1).repeat(1, x.shape[0], 1)
            query_emb = m.feat_emb(lq_feat.flatten(2).permute(2, 0, 1))
            for layer in m.ft_layers:
                query_emb = layer(query_emb, query_pos=pos_emb)
            logits = m.idx_pred_layer(query_emb).permute(1, 0, 2)
            soft_one_hot = F.softmax(logits, dim=2)
            _, top_idx = torch.topk(soft_one_hot, 1, dim=2)
            quant_feat = m.quantize.get_codebook_feat(top_idx, shape=[x.shape[0], 16, 16, 256])
            quant_feat = adaptive_instance_normalization(quant_feat, lq_feat)
            x = quant_feat
            fuse_list = [m.fuse_generator_block[f] for f in m.connect_list]
            for i, block in enumerate(m.generator.blocks):
                x = block(x)
                if i in fuse_list:
                    f_size = str(int(x.shape[-1]))
                    x = m.fuse_convs_dict[f_size](enc_feat_dict[f_size], x, w)
            return x

    class Reference(torch.nn.Module):
        """Upstream's own call, with w a Python float (so w = 0 skips the
        fusion blocks, as it does in inference_codeformer.py)."""

        def __init__(self, inner):
            super().__init__()
            self.inner = inner

        def forward(self, x, w):
            return self.inner(x, w=float(w.reshape(-1)[0]), adain=True)[0]

    return Restore(net).eval(), Reference(net).eval()


def main():
    import torch

    torch.manual_seed(0)
    net, reference = codeformer()
    out = os.path.join(fm.STAGING, "face-codeformer-v0.1.0.onnx")
    x = fm.face_test_input()
    w = np.array([0.5], np.float32)
    info = fm.export(net, [torch.from_numpy(x), torch.from_numpy(w)], ["input", "w"], ["output"], out)
    info["checkpoint"] = CKPT[0]
    info["parity"] = {}
    for wv in W_CHECKS:
        info["parity"][f"w={wv}"] = fm.parity(reference, out, {"input": x, "w": np.array([wv], np.float32)})
    fm.write_record("face-codeformer", {"opset": fm.OPSET, "irVersion": fm.IR_VERSION,
                                        "torch": torch.__version__, "models": [info]})


if __name__ == "__main__":
    main()
