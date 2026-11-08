#!/usr/bin/env python3
"""Build the AI runtime's self-test model: y = x * 2 + 1 on a float32 NCHW
tensor with three channels and any height and width.

`vapourbox-worker --probe-ai-runtime` runs it through ONNX Runtime from the
ai-runtime add-on to prove that the add-on imports, that a session can be
created on the chosen execution provider, and that it computes the right
answer. It is deliberately tiny (two nodes, no weights) so it can live inside
`worker/templates/ai_runtime.py` as base64 and ship wherever the templates do.

Written with an explicit IR version and opset rather than the onnx package's
defaults, so the oldest ONNX Runtime the add-on pins (1.23.2, the last with an
Intel macOS wheel) can load it.

Usage (in the conversion venv, see docs/ADDONS.md):

    python Scripts/models/make_ai_runtime_selftest.py Tests/TestResources/ai_runtime_selftest.onnx

then paste the printed base64 into `_SELFTEST_MODEL_B64` in
`worker/templates/ai_runtime.py`. `ai_runtime_selftest_test.dart` asserts the
two agree.
"""
import base64
import sys

import onnx
from onnx import TensorProto, helper

IR_VERSION = 8
OPSET = 13


def build() -> onnx.ModelProto:
    x = helper.make_tensor_value_info("x", TensorProto.FLOAT, [1, 3, "h", "w"])
    y = helper.make_tensor_value_info("y", TensorProto.FLOAT, [1, 3, "h", "w"])
    two = helper.make_tensor("two", TensorProto.FLOAT, [], [2.0])
    one = helper.make_tensor("one", TensorProto.FLOAT, [], [1.0])
    graph = helper.make_graph(
        [
            helper.make_node("Mul", ["x", "two"], ["x2"]),
            helper.make_node("Add", ["x2", "one"], ["y"]),
        ],
        "vapourbox_selftest",
        [x],
        [y],
        initializer=[two, one],
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
    print(base64.b64encode(data).decode())


if __name__ == "__main__":
    main()
