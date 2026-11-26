# Deterministic repro (task #120): output frame 0 reads source frame 0 at
# once and again only once heavy[0] (about a second of C filtering) is ready,
# by when vspipe has run every other output and the reader has read the whole
# clip. The pipe node's cache holds one frame, so the second request reaches
# the reader. VB_PIPE_SOURCE_DIR: worker/templates, or a directory holding the
# old pipe_source.py. Input: raw64.yuv (make_inputs.sh) on stdin:
#   VB_PIPE_SOURCE_DIR=... vspipe late_output.vpy -c y4m - < raw64.yuv > out.y4m
# Old reader: "frame 0 was asked for after it left the cache" 10 of 10 runs;
# new: 10 of 10 complete, every frame byte-exact. app/test/pipe_source_order_test.dart
# runs the same script.
import os, sys
import vapoursynth as vs
core = vs.core
sys.path.insert(0, os.environ['VB_PIPE_SOURCE_DIR'])
import pipe_source
W, H, N = 64, 48, 120
src = pipe_source.create_pipe_clip(W, H, N, 25, 1, 'yuv420p', cache_frames=40)
core.std.SetVideoCache(src, mode=1, fixedsize=1, maxsize=1)
# heavy[0] takes a second or so of C filtering; every other frame is instant.
slow = core.std.BlankClip(width=2048, height=2048, format=vs.GRAYS, length=1)
for _ in range(int(os.environ.get('VB_PASSES', '40'))):
    slow = core.std.BoxBlur(slow, hradius=40, vradius=40)
fast = core.std.BlankClip(width=2048, height=2048, format=vs.GRAYS, length=N - 1)
heavy = slow + fast
# Output n asks for src[n] at once, and again once heavy[n] is ready.
late = core.std.FrameEval(src, lambda n, f: src, prop_src=heavy)
out = core.std.Merge(src, late)
if hasattr(pipe_source, 'track_output'):
    out = pipe_source.track_output(out)
out.set_output()
