#!/usr/bin/env python3
"""Convert DDColor-T (piddnad/DDColor, the ddcolor_paper_tiny checkpoint) to
colorize-ddcolor-tiny.onnx for the colorize-ddcolor add-on.

DDColor predicts the a and b channels of CIELAB from a grey picture; the
Colourisation pass (worker/templates/colorize.py) puts them back together
with the source's own lightness, as upstream's ColorizationPipeline does.

The exported graph wraps the network so its interface is the pass's:

    input   "luma"  (1, 1, H, W) float32, the grey picture in [0, 1]
    output  "ab"    (1, 2, H, W) float32, CIELAB a and b (about -128..127)

H and W are dynamic (named "height" and "width"), multiples of 32: DDColor's
decoder concatenates skip connections without resampling, so a size the
encoder's four stride-2 stages don't divide fails. The pass fixes them per
session (ai_runtime's free-dimension overrides), which gives Core ML the
static shapes it needs. Upstream feeds the grey picture as RGB with three
equal channels (the L of CIELAB with a = b = 0, converted back to RGB), so
the wrapper repeats the one channel; the network normalises with ImageNet's
mean and deviation itself.

Licence: Apache-2.0 for the code (LICENSE) and the weights (the Hugging
Face model card's licence field).

Usage (conversion venv, see docs/ADDONS.md):

    VAPOURBOX_ADDON_STAGING=/path/to/addon-staging python Scripts/models/make_colorize_ddcolor.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import colorize_models_common as cm  # noqa: E402
import face_models_common as fm  # noqa: E402

DDCOLOR = ("piddnad/DDColor", "2adb63f2656ac41cbdf7b894cddd94121a3faf13")
# ddcolor_paper_tiny at Hugging Face revision cf9fd99c (the LFS hash the
# repository lists for pytorch_model.bin).
CKPT = (
    "https://huggingface.co/piddnad/ddcolor_paper_tiny/resolve/"
    "cf9fd99c1d7472689ec7413441c1b799a51866a3/pytorch_model.bin",
    "8a1277bc90a1bfbb6d2d83933a9a6bc821931879ca93e26e4fcec12165d41fce",
)
OUT = "colorize-ddcolor-tiny.onnx"
EXPORT_SIZE = 512  # upstream's input_size
PARITY_SIZES = (512, 256, 384, 640)


def ddcolor():
    import torch

    src = fm.upstream_source(*DDCOLOR)
    # Import the network modules without running basicsr/__init__.py (which
    # pulls in training code and its dependencies).
    for pkg in ("basicsr", "basicsr.archs", "basicsr.archs.ddcolor_arch_utils", "ddcolor"):
        fm.stub_module(pkg).__path__ = [os.path.join(src, *pkg.split("."))]
    from ddcolor.model import DDColor

    net = DDColor(
        encoder_name="convnext-t",
        decoder_name="MultiScaleColorDecoder",
        input_size=[EXPORT_SIZE, EXPORT_SIZE],
        num_output_channels=2,
        last_norm="Spectral",
        do_normalize=False,
        num_queries=100,
        num_scales=3,
        dec_layers=9,
    )
    state = fm.load_checkpoint(fm.fetch(*CKPT))
    state = state.get("params", state)
    # Upstream loads with strict=False; check that nothing is actually missing.
    missing, unexpected = net.load_state_dict(state, strict=False)
    if missing or unexpected:
        raise SystemExit(f"checkpoint mismatch: missing {missing}, unexpected {unexpected}")
    net.eval()

    class Colorize(torch.nn.Module):
        def __init__(self, inner):
            super().__init__()
            self.inner = inner

        def forward(self, luma):
            return self.inner(cm.grey_to_rgb(luma))

    return Colorize(net).eval()


def core_ml_friendly(net):
    """Rewrite the two kinds of operation Core ML's ML Program cannot take,
    each into an exact equivalent: the decoder's ReplicationPad2d (four of
    them) and the colour decoder's einsum("bqc,bchw->bqhw"), which becomes a
    matrix product over the flattened image. Without these, Core ML splits
    the graph into six partitions and compiles for about 80 s at every
    session (docs/reports/2026-11-colourisation)."""
    import types

    import torch

    import ddcolor.model as upstream

    pads = cm.replace_replication_pads(net)

    def einsum(equation, *operands):
        if equation == "bqc,bchw->bqhw":
            embed, feats = operands
            return torch.matmul(embed, feats.flatten(2)).unflatten(2, feats.shape[2:])
        return torch.einsum(equation, *operands)

    proxy = types.ModuleType("torch_with_matmul_einsum")
    proxy.__getattr__ = lambda name: getattr(torch, name)
    proxy.einsum = einsum
    upstream.torch = proxy
    return {"replicationPadsRewritten": pads, "einsumRewritten": True}


def main():
    import onnxruntime as ort
    import torch

    torch.manual_seed(0)
    net = ddcolor()
    # References from the network exactly as upstream loads it, before the
    # spectral norms are baked in and the Core ML rewrites made for export.
    refs = {}
    for size in PARITY_SIZES:
        xs = cm.test_input(size, seed=size)
        with torch.no_grad():
            refs[size] = (xs, net(torch.from_numpy(xs)).numpy())
    cm.bake_norms(net)
    rewrites = core_ml_friendly(net)
    out = os.path.join(fm.STAGING, OUT)
    x = cm.test_input(EXPORT_SIZE)
    info = fm.export(net, [torch.from_numpy(x)], ["luma"], ["ab"], out,
                     dynamic_axes={"luma": {2: "height", 3: "width"}, "ab": {2: "height", 3: "width"}})
    info["checkpoint"] = CKPT[0]
    info["checkpointSha256"] = CKPT[1]
    info["source"] = f"https://github.com/{DDCOLOR[0]}/tree/{DDCOLOR[1]}"
    info["rewrites"] = rewrites
    sess = ort.InferenceSession(out, providers=["CPUExecutionProvider"])
    info["parity"] = cm.parity_at_sizes(sess, refs, "luma", "CIELAB a/b")
    fm.write_record("colorize-ddcolor", {"opset": fm.OPSET, "irVersion": fm.IR_VERSION,
                                         "torch": torch.__version__, "models": [info]})


if __name__ == "__main__":
    main()
