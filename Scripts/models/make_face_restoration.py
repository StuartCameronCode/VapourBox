#!/usr/bin/env python3
"""Convert the face-restoration add-on's three models to ONNX:

  face-restoration-retinaface-r50.onnx   RetinaFace ResNet-50 face detector
                                         (facexlib's detection_Resnet50_Final.pth,
                                         network from biubug6/Pytorch_Retinaface, MIT)
  face-restoration-bisenet.onnx          BiSeNet face parser (facexlib's
                                         parsing_bisenet.pth, network from
                                         zllrunning/face-parsing.PyTorch, MIT)
  face-restoration-restoreformerpp.onnx  RestoreFormer++ (wzhouxiff/RestoreFormerPlusPlus
                                         v1.0.0, Apache-2.0)

`--detector mobilenet` also writes face-restoration-retinaface-mnet.onnx
(detection_mobilenet0.25_Final.pth), used only for the detector comparison in
docs/reports/issue-face-restoration (the add-on ships ResNet-50).

Shapes are static, which Core ML needs to take a whole graph: the detector
takes (1, 3, 640, 640) BGR minus the (104, 117, 123) mean, as upstream does,
padded by the caller; BiSeNet takes (1, 3, 512, 512) RGB normalised with
ImageNet's mean and std; RestoreFormer++ takes and returns (1, 3, 512, 512)
RGB in [-1, 1]. All three are float32.

Usage (conversion venv, see docs/ADDONS.md):

    VAPOURBOX_ADDON_STAGING=/path/to/addon-staging \\
        python Scripts/models/make_face_restoration.py [--detector mobilenet]

prints, and writes beside the models, a record of each file's size, SHA-256
and its parity with PyTorch (max / mean absolute difference, CPU provider).
"""

import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import face_models_common as fm  # noqa: E402

FACEXLIB = ("xinntao/facexlib", "260620ae93990a300f4b16448df9bb459f1caba9")
RESTOREFORMER = ("wzhouxiff/RestoreFormerPlusPlus", "59d250f45d6b11a3e620d62e6e067ca1288f93a9")

CKPT = {
    "r50": (
        "https://github.com/xinntao/facexlib/releases/download/v0.1.0/detection_Resnet50_Final.pth",
        "6d1de9c2944f2ccddca5f5e010ea5ae64a39845a86311af6fdf30841b0a5a16d",
    ),
    "mnet": (
        "https://github.com/xinntao/facexlib/releases/download/v0.1.0/detection_mobilenet0.25_Final.pth",
        "2979b33ffafda5d74b6948cd7a5b9a7a62f62b949cef24e95fd15d2883a65220",
    ),
    "bisenet": (
        "https://github.com/xinntao/facexlib/releases/download/v0.2.0/parsing_bisenet.pth",
        "468e13ca13a9b43cc0881a9f99083a430e9c0a38abd935431d1c28ee94b26567",
    ),
    "restoreformerpp": (
        "https://github.com/wzhouxiff/RestoreFormerPlusPlus/releases/download/v1.0.0/RestoreFormer++.ckpt",
        "613fe52805f86bf8c2bffff08ae9f7a0b99f408be1bf221767af6183038be3a2",
    ),
}

DET_SIZE = 640


def facexlib_packages():
    """Make facexlib's detection and parsing modules importable without
    running its package __init__ files (which pull in every other model)."""
    src = fm.upstream_source(*FACEXLIB)
    for pkg in ("facexlib", "facexlib.detection", "facexlib.parsing"):
        mod = fm.stub_module(pkg)
        mod.__path__ = [os.path.join(src, *pkg.split("."))]
    return src


def detector(kind):
    import torch

    facexlib_packages()
    from facexlib.detection.retinaface import RetinaFace

    net = RetinaFace(network_name="resnet50" if kind == "r50" else "mobile0.25", device=torch.device("cpu"))
    state = fm.load_checkpoint(fm.fetch(*CKPT[kind]))
    state = {k[7:] if k.startswith("module.") else k: v for k, v in state.items()}
    net.load_state_dict(state, strict=True)
    return net.eval()


def bisenet():
    import torch

    facexlib_packages()
    from facexlib.parsing.bisenet import BiSeNet

    net = BiSeNet(num_class=19)
    net.load_state_dict(fm.load_checkpoint(fm.fetch(*CKPT["bisenet"])), strict=True)

    class First(torch.nn.Module):
        """BiSeNet returns (out, out16, out32); inference uses out only."""

        def __init__(self, inner):
            super().__init__()
            self.inner = inner

        def forward(self, x):
            return self.inner(x)[0]

    return First(net.eval()).eval()


def restoreformerpp():
    import torch

    src = fm.upstream_source(*RESTOREFORMER)
    sys.path.insert(0, src)
    from RestoreFormer.modules.vqvae.vqvae_arch import VQVAEGANMultiHeadTransformer

    net = VQVAEGANMultiHeadTransformer(head_size=4, ex_multi_scale_num=1)
    ckpt = fm.load_checkpoint(fm.fetch(*CKPT["restoreformerpp"]))
    state = {k[len("vqvae."):] if k.startswith("vqvae.") else k: v for k, v in ckpt["state_dict"].items()}
    # Upstream loads with strict=False: the checkpoint also holds the
    # training-only discriminator and perceptual-loss weights. Insist that
    # every weight the network itself has is present.
    missing, unexpected = net.load_state_dict(state, strict=False)
    if missing:
        raise SystemExit(f"RestoreFormer++ checkpoint lacks {missing[:5]}…")

    class Restore(torch.nn.Module):
        """Upstream calls self.RF(x)[0]: the restored image."""

        def __init__(self, inner):
            super().__init__()
            self.inner = inner

        def forward(self, x):
            return self.inner(x)[0]

    print(f"RestoreFormer++: {len(unexpected)} checkpoint tensors unused (training-only)")
    return Restore(net.eval()).eval()


def det_input(seed=1):
    rng = np.random.default_rng(seed)
    img = rng.uniform(0, 255, (1, 3, DET_SIZE, DET_SIZE)).astype(np.float32)
    return img - np.array([104.0, 117.0, 123.0], np.float32)[None, :, None, None]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--detector", choices=["r50", "mobilenet", "both"], default="r50")
    ap.add_argument("--only", choices=["detector", "bisenet", "restoreformerpp"], action="append")
    args = ap.parse_args()
    import torch

    torch.manual_seed(0)
    os.makedirs(fm.STAGING, exist_ok=True)
    record = {"opset": fm.OPSET, "irVersion": fm.IR_VERSION, "torch": torch.__version__, "models": []}
    only = set(args.only or ["detector", "bisenet", "restoreformerpp"])

    if "detector" in only:
        kinds = {"r50": ["r50"], "mobilenet": ["mnet"], "both": ["r50", "mnet"]}[args.detector]
        for kind in kinds:
            net = detector(kind)
            out = os.path.join(fm.STAGING, f"face-restoration-retinaface-{kind}.onnx")
            x = det_input()
            info = fm.export(net, [torch.from_numpy(x)], ["input"], ["loc", "conf", "landmarks"], out)
            info["checkpoint"] = CKPT[kind][0]
            info["parity"] = fm.parity(net, out, {"input": x})
            record["models"].append(info)

    if "bisenet" in only:
        net = bisenet()
        out = os.path.join(fm.STAGING, "face-restoration-bisenet.onnx")
        x = fm.face_test_input()
        info = fm.export(net, [torch.from_numpy(x)], ["input"], ["parsing"], out)
        info["checkpoint"] = CKPT["bisenet"][0]
        p = fm.parity(net, out, {"input": x})
        # What the pass uses is the argmax class per pixel.
        import onnxruntime as ort

        with torch.no_grad():
            ref = net(torch.from_numpy(x)).numpy().argmax(1)
        got = ort.InferenceSession(out, providers=["CPUExecutionProvider"]).run(None, {"input": x})[0].argmax(1)
        p["argmaxAgreement"] = float((ref == got).mean())
        info["parity"] = p
        record["models"].append(info)

    if "restoreformerpp" in only:
        net = restoreformerpp()
        out = os.path.join(fm.STAGING, "face-restoration-restoreformerpp.onnx")
        x = fm.face_test_input()
        info = fm.export(net, [torch.from_numpy(x)], ["input"], ["output"], out)
        info["checkpoint"] = CKPT["restoreformerpp"][0]
        info["parity"] = fm.parity(net, out, {"input": x})
        record["models"].append(info)

    fm.write_record("face-restoration", record)


if __name__ == "__main__":
    main()
