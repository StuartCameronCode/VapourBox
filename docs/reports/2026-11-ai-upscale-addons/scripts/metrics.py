"""Two measurements on vspipe's raw RGBS output (planes G, B, R).

  metrics.py ort <frame.gbrpf> W H <a.onnx[,b.onnx]> <vsncnn.raw>
      VSNCNN against ONNX Runtime (CPU, fp32) on the same input: max / mean /
      99.9th-percentile absolute difference in 8-bit levels, after clipping
      both to 0..1 as the pipeline's conversion back does.

  metrics.py psnr <truth.gbrpf> W H <upscaled.raw>
      PSNR and mean absolute difference against a ground-truth frame, 8 px
      border excluded. PSNR rewards softness: a model that removes the
      source's compression noise or redraws texture scores lower however good
      it looks, so this ranks fidelity, not appearance.

Run with the conversion venv's Python (numpy, onnxruntime).
"""
import sys

import numpy as np


def read_gbr(path, w, h):
    return np.fromfile(path, dtype=np.float32)[: 3 * w * h].reshape(3, h, w)


def main():
    mode = sys.argv[1]
    if mode == 'ort':
        import onnxruntime as ort
        frame, w, h, models, vsout = sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5], sys.argv[6]
        x = read_gbr(frame, w, h)[[2, 0, 1]][None]
        for m in models.split(','):
            s = ort.InferenceSession(m, providers=['CPUExecutionProvider'])
            x = s.run(None, {s.get_inputs()[0].name: x})[0]
        ref = x[0]
        got = read_gbr(vsout, ref.shape[2], ref.shape[1])[[2, 0, 1]]
        d = np.abs(np.clip(ref, 0, 1) - np.clip(got, 0, 1)) * 255
        print(f'max {d.max():.3f} mean {d.mean():.4f} p99.9 {np.percentile(d, 99.9):.3f}')
    elif mode == 'psnr':
        truth, w, h, out = sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
        d = (np.clip(read_gbr(out, w, h), 0, 1) - np.clip(read_gbr(truth, w, h), 0, 1))[:, 8:-8, 8:-8] * 255
        print(f'PSNR {10 * np.log10(255 ** 2 / (d ** 2).mean()):.2f} dB  mean abs {np.abs(d).mean():.2f}')
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main()
