#!/usr/bin/env python3
"""Time each face-restoration ONNX model on every execution provider this
machine's onnxruntime offers, and compare each provider's output with the
CPU's. Used for the provider table in docs/reports/issue-face-restoration.

    python Scripts/models/face_provider_bench.py <addon-staging dir> [runs]

Session options mirror worker/templates/ai_runtime.py (Core ML as an
MLProgram on all compute units).
"""

import json
import os
import sys
import time

import numpy as np
import onnxruntime as ort

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from face_models_common import face_test_input  # noqa: E402

MODELS = {
    "face-restoration-retinaface-r50.onnx": lambda: {"input": det_input()},
    "face-restoration-retinaface-mnet.onnx": lambda: {"input": det_input()},
    "face-restoration-bisenet.onnx": lambda: {"input": face_test_input()},
    "face-restoration-restoreformerpp.onnx": lambda: {"input": face_test_input()},
    "face-gfpgan-v1.4.onnx": lambda: {"input": face_test_input()},
    "face-codeformer-v0.1.0.onnx": lambda: {"input": face_test_input(), "w": np.array([0.7], np.float32)},
}
OPTIONS = {"CoreMLExecutionProvider": {"ModelFormat": "MLProgram", "MLComputeUnits": "ALL"}}


def det_input():
    rng = np.random.default_rng(1)
    return (rng.uniform(0, 255, (1, 3, 640, 640)) - 117.0).astype(np.float32)


def session(path, provider):
    opts = ort.SessionOptions()
    opts.log_severity_level = 3
    providers = [(provider, OPTIONS[provider]) if provider in OPTIONS else provider]
    if provider != "CPUExecutionProvider":
        providers.append("CPUExecutionProvider")
    return ort.InferenceSession(path, sess_options=opts, providers=providers)


def main():
    staging = sys.argv[1]
    runs = int(sys.argv[2]) if len(sys.argv) > 2 else 5
    providers = [p for p in ort.get_available_providers() if p in ("CoreMLExecutionProvider", "CPUExecutionProvider")]
    results = []
    for name, feeds in MODELS.items():
        path = os.path.join(staging, name)
        if not os.path.exists(path):
            continue
        f = feeds()
        cpu_out = None
        for p in sorted(providers, key=lambda p: p != "CPUExecutionProvider"):
            t0 = time.perf_counter()
            s = session(path, p)
            created = time.perf_counter() - t0
            out = s.run(None, f)  # warm-up
            t0 = time.perf_counter()
            for _ in range(runs):
                out = s.run(None, f)
            per = (time.perf_counter() - t0) / runs
            row = {"model": name, "provider": p, "sessionSeconds": round(created, 2), "msPerRun": round(per * 1000, 1)}
            if p == "CPUExecutionProvider":
                cpu_out = out
            else:
                row["maxDiffVsCpu"] = float(max(np.abs(a - b).max() for a, b in zip(out, cpu_out)))
            print(json.dumps(row), flush=True)
            results.append(row)
    return results


if __name__ == "__main__":
    main()
