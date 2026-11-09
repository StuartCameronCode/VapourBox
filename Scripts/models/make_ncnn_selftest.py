#!/usr/bin/env python3
"""Build the AI-upscaling probe's self-test model for VSNCNN (vs-mlrt's
`ncnn.Model`): one 1x1 convolution on a float32 NCHW tensor with three
channels and any height and width, which swaps the first and third channels
and adds 0.125 to every one:

    y[0] = x[2] + 0.125,  y[1] = x[1] + 0.125,  y[2] = x[0] + 0.125

`vapourbox-worker --probe-upscale` runs it through the bundled VSNCNN plugin
on the GPU and checks that answer. The upscaling models themselves are an
add-on (docs/ADDONS.md), so the probe must not need one: with this model it
tells "no Vulkan device / broken plugin" apart from "models not installed"
before the user has downloaded anything. It is compiled into the worker
(`include_bytes!` in `worker/src/gpu_plugin.rs`) and handed to VSNCNN as bytes
(`path_is_serialization=True`), so nothing is written to disk.

A convolution, rather than the elementwise arithmetic of the AI runtime's
self-test, because that is what the real upscalers are made of and what
vs-mlrt's onnx2ncnn and ncnn's Vulkan shaders must handle. Written with an
explicit IR version and opset that vs-mlrt's pinned onnx accepts.

Usage (in the conversion venv, see docs/ADDONS.md):

    python Scripts/models/make_ncnn_selftest.py Tests/TestResources/ncnn_selftest.onnx

`gpu_plugin::tests::ncnn_selftest_is_the_committed_model` and the Dart
`gpu_plugin_selftest_test.dart` check the committed file is what the worker
embeds.
"""
import sys

import onnx
from onnx import TensorProto, helper

IR_VERSION = 7
OPSET = 11
BIAS = 0.125


def build() -> onnx.ModelProto:
    x = helper.make_tensor_value_info("input", TensorProto.FLOAT, ["n", 3, "h", "w"])
    y = helper.make_tensor_value_info("output", TensorProto.FLOAT, ["n", 3, "h", "w"])
    # out channel o reads in channel 2 - o.
    weight = [1.0 if i == 2 - o else 0.0 for o in range(3) for i in range(3)]
    w = helper.make_tensor("weight", TensorProto.FLOAT, [3, 3, 1, 1], weight)
    b = helper.make_tensor("bias", TensorProto.FLOAT, [3], [BIAS] * 3)
    graph = helper.make_graph(
        [helper.make_node("Conv", ["input", "weight", "bias"], ["output"], kernel_shape=[1, 1])],
        "vapourbox_ncnn_selftest",
        [x],
        [y],
        initializer=[w, b],
    )
    model = helper.make_model(
        graph,
        producer_name="vapourbox",
        opset_imports=[helper.make_opsetid("", OPSET)],
    )
    model.ir_version = IR_VERSION
    onnx.checker.check_model(model)
    return model


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    data = build().SerializeToString()
    with open(sys.argv[1], "wb") as f:
        f.write(data)
    print(f"{len(data)} bytes")


if __name__ == "__main__":
    main()
