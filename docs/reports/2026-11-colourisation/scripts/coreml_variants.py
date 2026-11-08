#!/usr/bin/env python3
"""Session time and per-run time of one model on Core ML with given provider
options, at a fixed square size (free-dimension overrides, as ai_runtime does).
Used for the unrewritten-DDColor comparison and the model-cache trial.

Run in the conversion venv:

    python coreml_variants.py <model.onnx> <size> '<options JSON>' ['<options JSON>' ...]

e.g. '{"ModelFormat": "MLProgram", "MLComputeUnits": "ALL"}', or with
"ModelCacheDirectory": "<dir>" twice in a row to time a cached second session.
Prints one JSON line per option set.
"""
import json
import sys
import time

import numpy as np
import onnxruntime as ort


def main():
    path, size = sys.argv[1], int(sys.argv[2])
    x = np.random.default_rng(0).uniform(0, 1, (1, 1, size, size)).astype(np.float32)
    for opt in (json.loads(v) for v in sys.argv[3:]):
        opts = ort.SessionOptions()
        opts.log_severity_level = 3
        opts.add_free_dimension_override_by_name("height", size)
        opts.add_free_dimension_override_by_name("width", size)
        t0 = time.perf_counter()
        try:
            s = ort.InferenceSession(path, sess_options=opts,
                                     providers=[("CoreMLExecutionProvider", opt), "CPUExecutionProvider"])
        except Exception as e:
            print(json.dumps({"opt": opt, "error": str(e)[:200]}), flush=True)
            continue
        created = time.perf_counter() - t0
        feeds = {s.get_inputs()[0].name: x}
        s.run(None, feeds)
        t0 = time.perf_counter()
        for _ in range(3):
            s.run(None, feeds)
        print(json.dumps({"opt": opt, "session": round(created, 2),
                          "ms": round((time.perf_counter() - t0) / 3 * 1000, 1)}), flush=True)


if __name__ == "__main__":
    main()
