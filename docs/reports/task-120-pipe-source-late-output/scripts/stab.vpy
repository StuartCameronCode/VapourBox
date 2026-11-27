import sys, os, time
import vapoursynth as vs
core = vs.core
T = os.environ['VB_TEMPLATES']
sys.path.insert(0, T)
threads = int(os.environ.get('VB_THREADS', '0'))
if threads: core.num_threads = threads
cache = os.environ.get('VB_MAXCACHE')
if cache: core.max_cache_size = int(cache)
import pipe_source as ps
_orig = ps._PipeReader._frame_data
_seen = set()
_t0 = time.monotonic()
_log = open(os.environ['VB_LOG'], 'w')
def _fd(self, n):
    first = n not in _seen
    _seen.add(n)
    before_next, before_low = self._next, self._low
    try:
        return _orig(self, n)
    finally:
        _log.write(f"{time.monotonic()-_t0:.4f} {n} {'first' if first else 'again'} next={before_next} low={before_low}\n")
        _log.flush()
ps._PipeReader._frame_data = _fd
clip = ps.create_pipe_clip(720, 576, 79, 25, 1, 'yuv422p', cache_frames=int(os.environ.get('VB_WINDOW','42')))
from stabilize import weave
mode = os.environ.get('VB_MODE', 'weave')
if mode == 'weave':
    clip = weave(clip, dxmax=4, dymax=4, mirror=3)
def _done(n, f):
    _log.write(f"{time.monotonic()-_t0:.4f} OUT {n}\n"); _log.flush()
    return f
clip = core.std.ModifyFrame(clip, clip, _done)
clip.set_output()
