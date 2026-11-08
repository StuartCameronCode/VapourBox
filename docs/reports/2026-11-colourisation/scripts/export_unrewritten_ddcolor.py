#!/usr/bin/env python3
"""DDColor exported as make_colorize_ddcolor.py does, but WITHOUT the Core ML
rewrites (Tensor.repeat, ReplicationPad2d and the einsum left as they are):
the six-partition graph the report times against the shipped one with
coreml_variants.py. Not shipped.

Run in the conversion venv from the repository root:

    VAPOURBOX_ADDON_STAGING=<addon-staging> python docs/reports/2026-11-colourisation/scripts/export_unrewritten_ddcolor.py <out.onnx>
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "..", "Scripts", "models"))

import torch  # noqa: E402

import colorize_models_common as cm  # noqa: E402
import face_models_common as fm  # noqa: E402
import make_colorize_ddcolor as m  # noqa: E402


class Repeat(torch.nn.Module):
    def __init__(self, wrapped):
        super().__init__()
        self.inner = wrapped.inner

    def forward(self, luma):
        return self.inner(luma.repeat(1, 3, 1, 1))


def main():
    net = m.ddcolor()
    cm.bake_norms(net)
    x = cm.test_input(m.EXPORT_SIZE)
    print(fm.export(Repeat(net), [torch.from_numpy(x)], ["luma"], ["ab"], sys.argv[1],
                    dynamic_axes={"luma": {2: "height", 3: "width"}, "ab": {2: "height", 3: "width"}}))


if __name__ == "__main__":
    main()
