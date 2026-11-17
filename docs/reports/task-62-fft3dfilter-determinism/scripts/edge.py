"""The push gate's flat-picture oracle, measured: worst |left 16 columns -
column 32| (luma; chroma 16) and the same over interior columns, 4 runs.
  run.sh <deps> edge.py"""
import vapoursynth as vs
core = vs.core
core.num_threads = 8
for run in range(4):
  flat = core.std.BlankClip(format=vs.YUV420P8, width=352, height=288, length=6, color=[100, 128, 128])
  left = ctrl = 0
  for f in core.fft3dfilter.FFT3DFilter(flat, sigma=2.0, bt=3).frames():
    for p in range(3):
        for row in f[p].tolist():
            r = row[32 if p == 0 else 16]
            left = max(left, max(abs(v - r) for v in row[:16]))
            ctrl = max(ctrl, max(abs(v - r) for v in row[40:120 if p == 0 else 80]))
  print('left', left, 'interior', ctrl)
