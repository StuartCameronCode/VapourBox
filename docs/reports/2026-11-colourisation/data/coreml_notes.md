# Core ML observations not in the JSON files

Exploratory runs of `scripts/coreml_variants.py` on colorize-ddcolor-tiny.onnx
(the shipped, one-partition export), 512x512, conversion venv, ONNX Runtime
1.31.1, M1 Pro, idle machine:

| Options | Session | ms/run |
|---|---|---|
| MLProgram, ALL | 80.2 s | 101.0 |
| MLProgram, CPUAndGPU | 50.8 s | 102.1 |
| MLProgram, CPUAndNeuralEngine | 56.3 s | 389.3 |
| NeuralNetwork, ALL | 9.9 s | 3017.6 |
| MLProgram, ALL, ModelCacheDirectory (first session) | 80.0 s | 101.2 |
| MLProgram, ALL, ModelCacheDirectory (second session) | 14.5 s | 101.8 |

The cache directory held 898 MB after the first session (one subdirectory,
named from a hash; its key is the model's path, so another render size of the
same file would look the same to it).

`provider_bench_unrewritten_ddcolor.jsonl`: the same options as the first
row, on the export without the Core ML rewrites
(`scripts/export_unrewritten_ddcolor.py`): 75.6 s session, 261.0 ms per run.

Earlier, with free height and width (no overrides), Core ML failed to build
the six-partition DDColor at all ("Failed to build the model execution plan
using a model architecture file").
