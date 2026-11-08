#!/usr/bin/env python3
"""Convert xinntao's Real-ESRGAN PyTorch checkpoints to ONNX for VSNCNN.

Upstream (https://github.com/xinntao/Real-ESRGAN, BSD-3-Clause) publishes
these models only as `.pth` checkpoints. The Crop & Resize AI upscaler runs
networks through vs-mlrt's VSNCNN (`ncnn.Model`), which reads ONNX, so we
convert them and host the result on the `addon-models-v1` release (see
docs/ADDONS.md, "Hosting files we convert ourselves").

Two architectures, each defined here so no basicsr/realesrgan install is
needed (both transcribed from basicsr 1.4.2 / realesrgan 0.3.0, the code the
checkpoints were trained with):

- SRVGGNetCompact (`realesr-general-x4v3`, `realesr-general-wdn-x4v3`): the
  same architecture as vs-mlrt's `RealESRGANv2-animevideo-*` ONNX the deps
  bundle ships, with 32 body convs instead of 16.
- RRDBNet (`RealESRGAN_x4plus`, `RealESRGAN_x2plus`): 23 RRDB blocks.

The ONNX match the conventions of the models VSNCNN already runs: one input
`input` and one output `output`, float32 NCHW RGB in 0..1, batch, height and
width dynamic, opset 13, IR version 7 (vs-mlrt's own conversions). Two
deliberate choices keep them inside what ncnn's ONNX importer handles:

- x2plus starts with `pixel_unshuffle(2)`, which the TorchScript exporter
  writes as a 6-D Reshape/Transpose pair ncnn cannot import. It is replaced by
  the equivalent stride-2 convolution with one-hot weights (exact: every output
  is one input sample times 1.0).
- The legacy (TorchScript) exporter is used, not dynamo: it writes plain
  Conv/LeakyRelu/PRelu/Resize/Add graphs at opset 13.

Every checkpoint is pinned by URL and SHA-256; a different download fails.
With torch 2.15.0 and onnx 1.23.2 (the conversion venv of 2026-11) the output
is byte-for-byte reproducible: two runs give the hashes pinned in
`app/assets/addons/upscale-general.json` / `upscale-esrgan-plus.json`.
After export the script checks PyTorch against ONNX Runtime on a seeded random
image and a smooth synthetic one, and prints the maximum and mean absolute
difference (in 0..1 units) — the parity numbers in
docs/reports/issue-ai-upscale-addons/.

Usage (in the conversion venv, see docs/ADDONS.md):

    python -I Scripts/models/convert_realesrgan.py <checkpoint-dir> <out-dir> [model ...]

`<checkpoint-dir>` holds the downloaded `.pth` files (or they are fetched
into it); each model is written as `<out-dir>/upscale-<name>.onnx`.
"""
import hashlib
import os
import sys
import urllib.request

import numpy as np
import onnx
import onnxruntime as ort
import torch
from torch import nn
from torch.nn import functional as F

OPSET = 13
IR_VERSION = 7

REL = "https://github.com/xinntao/Real-ESRGAN/releases/download"

# name -> (checkpoint url, sha256, architecture, kwargs)
MODELS = {
    "realesr-general-x4v3": (
        f"{REL}/v0.2.5.0/realesr-general-x4v3.pth",
        "8dc7edb9ac80ccdc30c3a5dca6616509367f05fbc184ad95b731f05bece96292",
        "srvgg", dict(num_feat=64, num_conv=32, upscale=4),
    ),
    "realesr-general-wdn-x4v3": (
        f"{REL}/v0.2.5.0/realesr-general-wdn-x4v3.pth",
        "1641f8c4464b9f097c9fdda5589273713f67cf59f3d909e0bd688f0cee269dca",
        "srvgg", dict(num_feat=64, num_conv=32, upscale=4),
    ),
    "RealESRGAN_x4plus": (
        f"{REL}/v0.1.0/RealESRGAN_x4plus.pth",
        "4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1",
        "rrdb", dict(scale=4),
    ),
    "RealESRGAN_x2plus": (
        f"{REL}/v0.2.1/RealESRGAN_x2plus.pth",
        "49fafd45f8fd7aa8d31ab2a22d14d91b536c34494a5cfe31eb5d89c2fa266abb",
        "rrdb", dict(scale=2),
    ),
}


# --- SRVGGNetCompact (realesrgan/archs/srvgg_arch.py) -----------------------

class SRVGGNetCompact(nn.Module):
    def __init__(self, num_in_ch=3, num_out_ch=3, num_feat=64, num_conv=16, upscale=4):
        super().__init__()
        self.upscale = upscale
        self.body = nn.ModuleList()
        self.body.append(nn.Conv2d(num_in_ch, num_feat, 3, 1, 1))
        self.body.append(nn.PReLU(num_parameters=num_feat))
        for _ in range(num_conv):
            self.body.append(nn.Conv2d(num_feat, num_feat, 3, 1, 1))
            self.body.append(nn.PReLU(num_parameters=num_feat))
        self.body.append(nn.Conv2d(num_feat, num_out_ch * upscale * upscale, 3, 1, 1))
        self.upsampler = nn.PixelShuffle(upscale)

    def forward(self, x):
        out = x
        for layer in self.body:
            out = layer(out)
        out = self.upsampler(out)
        return out + F.interpolate(x, scale_factor=self.upscale, mode="nearest")


# --- RRDBNet (basicsr/archs/rrdbnet_arch.py) --------------------------------

class ResidualDenseBlock(nn.Module):
    def __init__(self, num_feat=64, num_grow_ch=32):
        super().__init__()
        self.conv1 = nn.Conv2d(num_feat, num_grow_ch, 3, 1, 1)
        self.conv2 = nn.Conv2d(num_feat + num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv3 = nn.Conv2d(num_feat + 2 * num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv4 = nn.Conv2d(num_feat + 3 * num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv5 = nn.Conv2d(num_feat + 4 * num_grow_ch, num_feat, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(negative_slope=0.2, inplace=True)

    def forward(self, x):
        x1 = self.lrelu(self.conv1(x))
        x2 = self.lrelu(self.conv2(torch.cat((x, x1), 1)))
        x3 = self.lrelu(self.conv3(torch.cat((x, x1, x2), 1)))
        x4 = self.lrelu(self.conv4(torch.cat((x, x1, x2, x3), 1)))
        x5 = self.conv5(torch.cat((x, x1, x2, x3, x4), 1))
        return x5 * 0.2 + x


class RRDB(nn.Module):
    def __init__(self, num_feat, num_grow_ch=32):
        super().__init__()
        self.rdb1 = ResidualDenseBlock(num_feat, num_grow_ch)
        self.rdb2 = ResidualDenseBlock(num_feat, num_grow_ch)
        self.rdb3 = ResidualDenseBlock(num_feat, num_grow_ch)

    def forward(self, x):
        out = self.rdb3(self.rdb2(self.rdb1(x)))
        return out * 0.2 + x


class PixelUnshuffleConv(nn.Module):
    """`F.pixel_unshuffle(x, s)` as a stride-s convolution with one-hot
    weights: output channel c*s*s + i*s + j takes input channel c at offset
    (i, j) of each s x s cell — pixel_unshuffle's channel order."""

    def __init__(self, channels, s):
        super().__init__()
        w = torch.zeros(channels * s * s, channels, s, s)
        for c in range(channels):
            for i in range(s):
                for j in range(s):
                    w[c * s * s + i * s + j, c, i, j] = 1.0
        self.register_buffer("weight", w)
        self.s = s

    def forward(self, x):
        return F.conv2d(x, self.weight, stride=self.s)


class RRDBNet(nn.Module):
    def __init__(self, num_in_ch=3, num_out_ch=3, scale=4, num_feat=64, num_block=23, num_grow_ch=32):
        super().__init__()
        self.scale = scale
        if scale == 2:
            num_in_ch = num_in_ch * 4
            self.unshuffle = PixelUnshuffleConv(3, 2)
        elif scale == 1:
            num_in_ch = num_in_ch * 16
            self.unshuffle = PixelUnshuffleConv(3, 4)
        else:
            self.unshuffle = None
        self.conv_first = nn.Conv2d(num_in_ch, num_feat, 3, 1, 1)
        self.body = nn.Sequential(*[RRDB(num_feat, num_grow_ch) for _ in range(num_block)])
        self.conv_body = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_up1 = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_up2 = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_hr = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_last = nn.Conv2d(num_feat, num_out_ch, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(negative_slope=0.2, inplace=True)

    def forward(self, x):
        feat = self.unshuffle(x) if self.unshuffle is not None else x
        feat = self.conv_first(feat)
        feat = feat + self.conv_body(self.body(feat))
        feat = self.lrelu(self.conv_up1(F.interpolate(feat, scale_factor=2, mode="nearest")))
        feat = self.lrelu(self.conv_up2(F.interpolate(feat, scale_factor=2, mode="nearest")))
        return self.conv_last(self.lrelu(self.conv_hr(feat)))


# --- conversion -------------------------------------------------------------

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch(url, digest, ckpt_dir):
    path = os.path.join(ckpt_dir, url.rsplit("/", 1)[1])
    if not os.path.exists(path):
        print(f"downloading {url}")
        urllib.request.urlretrieve(url, path)
    got = sha256(path)
    if got != digest:
        sys.exit(f"{path}: sha256 {got}, expected {digest}")
    return path


def build(arch, kwargs, ckpt):
    net = SRVGGNetCompact(**kwargs) if arch == "srvgg" else RRDBNet(**kwargs)
    state = torch.load(ckpt, map_location="cpu", weights_only=True)
    state = state.get("params_ema", state.get("params", state))
    missing, unexpected = net.load_state_dict(state, strict=False)
    # The only parameter not in the checkpoint is our unshuffle conv's buffer.
    if unexpected or any(not k.startswith("unshuffle.") for k in missing):
        sys.exit(f"{ckpt}: missing {missing}, unexpected {unexpected}")
    if getattr(net, "unshuffle", None) is not None:
        # The replacement must be exactly upstream's pixel_unshuffle.
        x = torch.rand(1, 3, 12, 16)
        if not torch.equal(net.unshuffle(x), F.pixel_unshuffle(x, net.unshuffle.s)):
            sys.exit("PixelUnshuffleConv differs from F.pixel_unshuffle")
    return net.eval()


def test_images(h=96, w=128):
    rng = np.random.default_rng(1)
    noise = rng.random((1, 3, h, w), dtype=np.float32)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    smooth = np.stack([
        0.5 + 0.4 * np.sin(xx / 9.0),
        0.5 + 0.4 * np.cos(yy / 7.0),
        (xx + yy) / (h + w),
    ])[None].astype(np.float32)
    return {"random": noise, "smooth": smooth}


def convert(name, ckpt_dir, out_dir):
    url, digest, arch, kwargs = MODELS[name]
    net = build(arch, kwargs, fetch(url, digest, ckpt_dir))
    out = os.path.join(out_dir, f"upscale-{name}.onnx")
    dummy = torch.rand(1, 3, 64, 64)
    torch.onnx.export(
        net, (dummy,), out, dynamo=False, opset_version=OPSET,
        input_names=["input"], output_names=["output"],
        dynamic_axes={"input": {0: "batch", 2: "height", 3: "width"},
                      "output": {0: "batch", 2: "height", 3: "width"}},
        do_constant_folding=True,
    )
    model = onnx.load(out)
    model.ir_version = IR_VERSION
    model.producer_name = "vapourbox"
    onnx.checker.check_model(model)
    onnx.save(model, out)

    sess = ort.InferenceSession(out, providers=["CPUExecutionProvider"])
    ops = sorted({n.op_type for n in model.graph.node})
    print(f"{name}: {os.path.getsize(out)} bytes, sha256 {sha256(out)}, ops {ops}")
    for label, img in test_images().items():
        with torch.no_grad():
            ref = net(torch.from_numpy(img)).numpy()
        got = sess.run(None, {"input": img})[0]
        diff = np.abs(ref - got)
        print(f"  parity {label}: shape {got.shape}, max {diff.max():.3e}, mean {diff.mean():.3e}"
              f" (8-bit levels: max {diff.max() * 255:.4f})")
    return out


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    ckpt_dir, out_dir = sys.argv[1], sys.argv[2]
    names = sys.argv[3:] or list(MODELS)
    for n in names:
        if n not in MODELS:
            sys.exit(f"unknown model {n}; known: {', '.join(MODELS)}")
    torch.manual_seed(0)
    for n in names:
        convert(n, ckpt_dir, out_dir)


if __name__ == "__main__":
    main()
