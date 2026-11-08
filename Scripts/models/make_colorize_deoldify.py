#!/usr/bin/env python3
"""Convert DeOldify's Video generator (jantic/DeOldify, ColorizeVideo_gen.pth)
to colorize-deoldify-video.onnx for the colorize-deoldify add-on.

DeOldify is built on fastai v1 (pinned to 1.0.60, Python 3.6-3.8 era), which
does not install alongside a current PyTorch. The generator is therefore
rebuilt here in plain PyTorch, module for module, from DeOldify's
deoldify/unet.py and layers.py at the pinned commit and the fastai 1.0.60
layers they use (conv_layer, res_block, PixelShuffle_ICNR, SelfAttention,
MergeLayer, SigmoidRange), on torchvision's ResNet-101. The checkpoint loads
into it with strict=True (every one of its 754 tensors, no missing and no
extra key), and the result is checked against an independent export:
FaceFusion's deoldify.onnx (models-3.0.0), a conversion of the same weights
made with fastai itself (VERIFY_REFERENCE below; downloaded only to verify,
never shipped).

What is DeOldify's video colouriser (get_video_colorizer, render_factor 21):
DynamicUnetWide(resnet101, nf_factor=2, blur, self-attention, spectral norm,
y_range=(-3, 3)) over a grey picture stretched to a render_factor x 16 pixel
square, ImageNet-normalised, denormalised after. The exported graph wraps it
so its interface is the pass's:

    input   "luma"  (1, 1, H, W) float32, the grey picture in [0, 1]
    output  "rgb"   (1, 3, H, W) float32, the colourised picture in [0, 1]

H and W are dynamic (named "height" and "width"), multiples of 16. The
colouriser keeps only the output's chroma (upstream: cv2's YUV, Y from the
source); the pass does the same in the source's own YUV
(worker/templates/colorize.py). Two departures, both at sizes upstream never
sees or in values it would mangle:

- fastai's U-Net resamples a skip connection (nearest) only when its size
  differs from the upsampled path's; the rebuilt block always resamples to the
  skip's size (the identity when they agree), so one traced graph serves every
  size rather than only the size it was traced at.
- Upstream converts the denormalised output to uint8 with no clamp, so a value
  outside [0, 1] wraps around; the export clamps.

The export also writes the blur's ReplicationPad2d as slices and
concatenations (colorize_models_common.edge_pad_top_left, exact), since Core
ML has no edge-mode Pad and would otherwise split the graph around each one.

Licence: MIT for the code and, per DeOldify's README ("are trained by
ourselves and are released under the MIT license"), the weights. Copyright
(c) 2018 Jason Antic (LICENSE).

Usage (conversion venv, see docs/ADDONS.md):

    VAPOURBOX_ADDON_STAGING=/path/to/addon-staging python Scripts/models/make_colorize_deoldify.py
"""

import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import colorize_models_common as cm  # noqa: E402
import face_models_common as fm  # noqa: E402

DEOLDIFY_COMMIT = "jantic/DeOldify@5f86c28923799036ad4b1bf7af8c629ac65efd75"
# The README's "Video" generator link. The same file (same SHA-256) is
# mirrored at huggingface.co/spensercai/DeOldify (revision 448956a5), should
# DeepAI's host go away.
CKPT = (
    "https://data.deepai.org/deoldify/ColorizeVideo_gen.pth",
    "e3d98bb6a222354c79f95485c2f078a89dc724e9183662506d9e0f5aafac83ad",
)
# Independent conversion of the same weights, for verification only.
VERIFY_REFERENCE = (
    "https://github.com/facefusion/facefusion-assets/releases/download/models-3.0.0/deoldify.onnx",
    "a00de09afacbed28b30ea63d174e1ade855b497c0fc61372217953c429696a9a",
)
OUT = "colorize-deoldify-video.onnx"
EXPORT_SIZE = 336  # render_factor 21, upstream's default for video
PARITY_SIZES = (336, 256, 512)
IMAGENET_MEAN = (0.485, 0.456, 0.406)
IMAGENET_STD = (0.229, 0.224, 0.225)


def build():
    import torch
    import torch.nn.functional as F
    import torchvision
    from torch import nn
    from torch.nn.utils import spectral_norm, weight_norm

    def conv(ni, nf, ks=3, norm="spectral", use_activ=True, bn=False, self_attention=False):
        """DeOldify's custom_conv_layer / fastai's conv_layer: conv (spectral
        or weight normalised), ReLU, BatchNorm, self-attention, in that order.
        Bias only without BatchNorm."""
        c = nn.Conv2d(ni, nf, kernel_size=ks, padding=(ks - 1) // 2, bias=not bn)
        c = spectral_norm(c) if norm == "spectral" else weight_norm(c)
        layers = [c]
        if use_activ:
            layers.append(nn.ReLU(True))
        if bn:
            layers.append(nn.BatchNorm2d(nf))
        if self_attention:
            layers.append(SelfAttention(nf))
        return nn.Sequential(*layers)

    class SelfAttention(nn.Module):
        """fastai 1.0.60's SelfAttention (SAGAN), spectral-normalised 1x1 conv1d."""

        def __init__(self, n):
            super().__init__()
            self.query = spectral_norm(nn.Conv1d(n, n // 8, 1, bias=False))
            self.key = spectral_norm(nn.Conv1d(n, n // 8, 1, bias=False))
            self.value = spectral_norm(nn.Conv1d(n, n, 1, bias=False))
            self.gamma = nn.Parameter(torch.tensor([0.0]))

        def forward(self, x):
            size = x.size()
            x = x.view(*size[:2], -1)
            f, g, h = self.query(x), self.key(x), self.value(x)
            beta = F.softmax(torch.bmm(f.transpose(1, 2), g), dim=1)
            o = self.gamma * torch.bmm(h, beta) + x
            return o.view(*size).contiguous()

    class CustomPixelShuffle(nn.Module):
        """DeOldify's CustomPixelShuffle_ICNR with blur (spectral norm + BN)."""

        def __init__(self, ni, nf):
            super().__init__()
            self.conv = conv(ni, nf * 4, ks=1, use_activ=False, bn=True)
            self.shuf = nn.PixelShuffle(2)
            self.pad = nn.ReplicationPad2d((1, 0, 1, 0))
            self.blur = nn.AvgPool2d(2, stride=1)
            self.relu = nn.ReLU(True)

        def forward(self, x):
            return self.blur(self.pad(self.shuf(self.relu(self.conv(x)))))

    class UnetBlockWide(nn.Module):
        def __init__(self, up_in_c, x_in_c, n_out, self_attention):
            super().__init__()
            up_out = x_out = n_out // 2
            self.shuf = CustomPixelShuffle(up_in_c, up_out)
            self.bn = nn.BatchNorm2d(x_in_c)
            self.conv = conv(up_out + x_in_c, x_out, bn=True, self_attention=self_attention)
            self.relu = nn.ReLU()

        def forward(self, up_in, s):
            up_out = self.shuf(up_in)
            # Always resampled to the skip's size (see the module docstring).
            up_out = F.interpolate(up_out, s.shape[-2:], mode="nearest")
            return self.conv(self.relu(torch.cat([up_out, self.bn(s)], dim=1)))

    class PixelShuffleICNR(nn.Module):
        """fastai's PixelShuffle_ICNR with its defaults (weight norm). Its
        blur=False does not turn the blur off: fastai 1.0.60 always creates
        the AvgPool2d and tests the module (always true), not the flag, so
        the blur runs. Leaving it out was the difference the verification
        against FaceFusion's export caught (mean 0.016, max 0.12)."""

        def __init__(self, ni):
            super().__init__()
            self.conv = conv(ni, ni * 4, ks=1, norm="weight", use_activ=False)
            self.shuf = nn.PixelShuffle(2)
            self.pad = nn.ReplicationPad2d((1, 0, 1, 0))
            self.blur = nn.AvgPool2d(2, stride=1)
            self.relu = nn.ReLU(True)

        def forward(self, x):
            return self.blur(self.pad(self.shuf(self.relu(self.conv(x)))))

    class ResBlock(nn.Module):
        """fastai's res_block(ni, norm_type=Spectral): two convs, then x + input."""

        def __init__(self, ni):
            super().__init__()
            self.layers = nn.ModuleList([conv(ni, ni), conv(ni, ni)])

        def forward(self, x):
            return x + self.layers[1](self.layers[0](x))

    class DynamicUnetWide(nn.Module):
        """DeOldify's DynamicUnetWide for resnet101, nf_factor 2, as a module
        list numbered as fastai's SequentialEx numbers it (so the
        checkpoint's keys load unchanged)."""

        def __init__(self):
            super().__init__()
            r = torchvision.models.resnet101(weights=None)
            body = nn.Sequential(r.conv1, r.bn1, r.relu, r.maxpool, r.layer1, r.layer2, r.layer3, r.layer4)
            nf = 1024
            self.layers = nn.ModuleList([
                body,                                   # 0
                nn.BatchNorm2d(2048),                   # 1
                nn.ReLU(),                              # 2
                nn.Sequential(conv(2048, 4096, bn=True), conv(4096, 2048, bn=True)),  # 3 middle
                UnetBlockWide(2048, 1024, nf, False),   # 4  skip: layer3
                UnetBlockWide(512, 512, nf, True),      # 5  skip: layer2, self-attention
                UnetBlockWide(512, 256, nf, False),     # 6  skip: layer1
                UnetBlockWide(512, 64, nf // 2, False),  # 7  skip: the stem's ReLU
                PixelShuffleICNR(256),                  # 8
                nn.Identity(),                          # 9  MergeLayer(dense): concat the input
                ResBlock(259),                          # 10
                conv(259, 3, ks=1, use_activ=False),    # 11
            ])

        def forward(self, x):
            skips = {}
            h = x
            for i, layer in enumerate(self.layers[0]):
                h = layer(h)
                if i in (2, 4, 5, 6):
                    skips[i] = h
            h = self.layers[3](self.layers[2](self.layers[1](h)))
            h = self.layers[4](h, skips[6])
            h = self.layers[5](h, skips[5])
            h = self.layers[6](h, skips[4])
            h = self.layers[7](h, skips[2])
            h = self.layers[8](h)
            h = torch.cat([h, x], dim=1)
            h = self.layers[10](h)
            h = self.layers[11](h)
            return torch.sigmoid(h) * 6.0 - 3.0  # SigmoidRange(-3, 3)

    return DynamicUnetWide()


def deoldify():
    import torch

    net = build()
    torch.serialization.add_safe_globals([slice])  # fastai's checkpoint pickles a slice
    ckpt = torch.load(fm.fetch(*CKPT), map_location="cpu", weights_only=True)
    state = ckpt["model"]
    net.load_state_dict(state, strict=True)
    net.eval()

    class Colorize(torch.nn.Module):
        """Grey [0, 1] in, RGB [0, 1] out, as ColorizerFilter._model_process."""

        def __init__(self, inner):
            super().__init__()
            self.inner = inner
            self.register_buffer("mean", torch.tensor(IMAGENET_MEAN).view(1, 3, 1, 1))
            self.register_buffer("std", torch.tensor(IMAGENET_STD).view(1, 3, 1, 1))

        def forward(self, luma):
            x = (cm.grey_to_rgb(luma) - self.mean) / self.std
            return torch.clamp(self.inner(x) * self.std + self.mean, 0.0, 1.0)

    return Colorize(net).eval(), len(state)


def verify_against_reference(net):
    """Compare the rebuilt network with FaceFusion's independent export of
    the same checkpoint, on that export's own interface (the normalised
    three-channel grey picture in, the normalised picture out)."""
    import onnxruntime as ort
    import torch

    path = fm.fetch(*VERIFY_REFERENCE)
    sess = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
    inp = sess.get_inputs()[0]
    shape = [d if isinstance(d, int) else 256 for d in inp.shape]
    size = shape[2]
    g = cm.test_input(size, seed=7)
    # FaceFusion's graph takes the grey picture as 0-255 RGB and returns
    # 0-255 RGB, normalising and denormalising inside; ours takes [0, 1] luma.
    ref = sess.run(None, {inp.name: np.repeat(g, 3, axis=1) * 255.0})[0] / 255.0
    with torch.no_grad():
        got = net(torch.from_numpy(g)).numpy()
    d = np.abs(ref.astype(np.float64) - got)
    return {"reference": VERIFY_REFERENCE[0], "referenceSha256": VERIFY_REFERENCE[1],
            "inputShape": shape, "max": float(d.max()), "mean": float(d.mean()), "unit": "[0, 1] RGB"}


def main():
    import onnxruntime as ort
    import torch

    torch.manual_seed(0)
    net, tensors = deoldify()
    record = {"checkpointTensors": tensors, "strictLoad": True}
    record["verification"] = verify_against_reference(net)
    refs = {}
    for size in PARITY_SIZES:
        xs = cm.test_input(size, seed=size)
        with torch.no_grad():
            refs[size] = (xs, net(torch.from_numpy(xs)).numpy())
    cm.bake_norms(net)
    # Core ML has no edge-mode Pad: the five blur pads, rewritten exactly.
    record["replicationPadsRewritten"] = cm.replace_replication_pads(net)
    out = os.path.join(fm.STAGING, OUT)
    x = cm.test_input(EXPORT_SIZE)
    info = fm.export(net, [torch.from_numpy(x)], ["luma"], ["rgb"], out,
                     dynamic_axes={"luma": {2: "height", 3: "width"}, "rgb": {2: "height", 3: "width"}})
    info["checkpoint"] = CKPT[0]
    info["checkpointSha256"] = CKPT[1]
    info["source"] = "https://github.com/" + DEOLDIFY_COMMIT.replace("@", "/tree/")
    sess = ort.InferenceSession(out, providers=["CPUExecutionProvider"])
    info["parity"] = cm.parity_at_sizes(sess, refs, "luma", "[0, 1] RGB")
    record.update({"opset": fm.OPSET, "irVersion": fm.IR_VERSION, "torch": torch.__version__, "models": [info]})
    fm.write_record("colorize-deoldify", record)


if __name__ == "__main__":
    main()
