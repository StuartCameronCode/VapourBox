#!/usr/bin/env python3
"""Time the colourisation ONNX models at each render size on every execution
provider this machine's onnxruntime offers, and compare each provider's
output with the CPU's. Used for the provider table in
docs/reports/2026-11-colourisation.

    python Scripts/models/colorize_provider_bench.py <addon-staging dir> [runs]

Sessions are made the way worker/templates/ai_runtime.py makes them (Core ML
as an MLProgram on all compute units, the render size fixed with
free-dimension overrides); "dynamic" rows leave the size free, for
comparison. Session creation is timed separately: it includes Core ML's
compilation of the graph.
"""

import json
import os
import sys
import time

import numpy as np
import onnxruntime as ort

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from colorize_models_common import test_input  # noqa: E402

SIZES = {
    "colorize-ddcolor-tiny.onnx": (256, 384, 512),
    "colorize-deoldify-video.onnx": (256, 336, 448),
}
OPTIONS = {"CoreMLExecutionProvider": {"ModelFormat": "MLProgram", "MLComputeUnits": "ALL"}}


def session(path, provider, size=None):
    opts = ort.SessionOptions()
    opts.log_severity_level = 3
    if size:
        opts.add_free_dimension_override_by_name("height", size)
        opts.add_free_dimension_override_by_name("width", size)
    providers = [(provider, OPTIONS[provider]) if provider in OPTIONS else provider]
    if provider != "CPUExecutionProvider":
        providers.append("CPUExecutionProvider")
    return ort.InferenceSession(path, sess_options=opts, providers=providers)


def main():
    staging = sys.argv[1]
    runs = int(sys.argv[2]) if len(sys.argv) > 2 else 5
    only = sys.argv[3:]  # optional: model files, providers or "dynamic"
    providers = [p for p in ort.get_available_providers() if p in ("CoreMLExecutionProvider", "CPUExecutionProvider")]
    for name, sizes in SIZES.items():
        path = os.path.join(staging, name)
        if not os.path.exists(path) or (only and name not in only and not any(o.endswith("Provider") or o == "dynamic" for o in only)):
            continue
        for size in sizes:
            x = test_input(size, seed=size)
            cpu_out = None
            variants = [(p, True) for p in sorted(providers, key=lambda p: p != "CPUExecutionProvider")]
            if "dynamic" in only:
                variants.append(("CoreMLExecutionProvider", False))
            for p, fixed in variants:
                t0 = time.perf_counter()
                try:
                    s = session(path, p, size if fixed else None)
                except Exception as e:  # Core ML refuses some dynamic shapes outright
                    print(json.dumps({"model": name, "size": size, "provider": p, "fixedShape": fixed,
                                      "error": str(e)[:200]}), flush=True)
                    continue
                created = time.perf_counter() - t0
                feeds = {s.get_inputs()[0].name: x}
                out = s.run(None, feeds)
                t0 = time.perf_counter()
                for _ in range(runs):
                    out = s.run(None, feeds)
                per = (time.perf_counter() - t0) / runs
                row = {"model": name, "size": size, "provider": p, "fixedShape": fixed,
                       "sessionSeconds": round(created, 2), "msPerRun": round(per * 1000, 1),
                       "onnxruntime": ort.__version__}
                if p == "CPUExecutionProvider":
                    cpu_out = out
                elif cpu_out is not None:
                    row["maxDiffVsCpu"] = float(max(np.abs(a - b).max() for a, b in zip(out, cpu_out)))
                    row["meanDiffVsCpu"] = float(max(np.abs(a - b).mean() for a, b in zip(out, cpu_out)))
                print(json.dumps(row), flush=True)


if __name__ == "__main__":
    main()
