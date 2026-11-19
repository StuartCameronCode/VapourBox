"""Does QTGMC's output depend on frame stride padding? (task #70)

VapourSynth frames are allocated with a 64-byte-aligned stride, and nothing
initialises the bytes between a row's last sample and the next row. A filter
that lets those bytes reach a visible sample makes the output depend on
whatever a recycled buffer held. This harness fills the padding of every frame
the graph produces with a seed-dependent pattern and hashes the visible output:
if the hashes for different seeds agree, no filter in the graph reads padding
into the picture.

How: havsfunc's (and mvsfunc's and adjust's) module-level `core` is replaced by
a proxy whose every `core.<ns>.<fn>(...)` call returns its VideoNode through a
std.ModifyFrame that copies the frame and overwrites its row padding. The
source is poisoned the same way. Limits, printed with the result:
  - Calls made as clip methods (`clip.std.Transpose()`, `x.mv.Super(...)`)
    bypass the proxy: their outputs are not poisoned (their inputs are). The
    count of proxied calls is printed; valgrind's --malloc-fill runs in the
    report cover every buffer.
  - It proves "the visible output does not depend on padding", not "no other
    nondeterminism exists".
Positive control: the padding of one poisoned mv.Degrain1 output is read back
and must differ by seed, so a harness that poisons nothing cannot pass.

  python poison.py <preset> <WxH> <format> <seed> [<seed> ...]
(POISON_THREADS=n sets core.num_threads.)
Run with the deps bundle's Python and environment. Prints one JSON line:
  {"hashes": {seed: md5}, "control": {seed: md5 of a Degrain padding row},
   "proxied": QTGMC's calls poisoned, "functions": their names, "seconds": t}
Used by app/test/qtgmc_stride_padding_test.dart (push gate).
"""
import ctypes
import hashlib
import json
import math
import os
import sys
import time

import vapoursynth as vs

REAL = vs.core
LENGTH = 8           # source frames; QTGMC needs a few either side
HASH_FRAMES = (6, 7, 8, 9)  # double-rate output frames hashed


def _pad_fill(f, seed):
    """Overwrite each row's padding (stride - width*bytes) of every plane."""
    bps = f.format.bytes_per_sample
    for p in range(f.format.num_planes):
        stride = f.get_stride(p)
        w = f.width >> (f.format.subsampling_w if p else 0)
        h = f.height >> (f.format.subsampling_h if p else 0)
        gap = stride - w * bps
        if gap <= 0:
            continue
        base = ctypes.cast(f.get_write_ptr(p), ctypes.c_void_p).value
        for y in range(h):
            pat = _row_cache[(seed, p, gap, y & 1)]
            ctypes.memmove(base + y * stride + w * bps, pat, gap)


class _RowCache(dict):
    def __missing__(self, key):
        seed, p, gap, odd = key
        v = bytes(((seed * 151 + odd * 31 + i * 7 + p * 13) & 0xFF) for i in range(gap))
        self[key] = v
        return v


_row_cache = _RowCache()


def poisoned(node, seed):
    if not isinstance(node, vs.VideoNode) or node.format is None or node.width == 0:
        return node

    def fill(n, f):
        o = f.copy()
        _pad_fill(o, seed)
        return o
    return REAL.std.ModifyFrame(node, node, fill)


class _Fn:
    def __init__(self, fn, seed, stats):
        self._fn, self._seed, self._stats = fn, seed, stats

    def __call__(self, *a, **k):
        out = self._fn(*a, **k)
        self._stats['calls'].append(self._fn.plugin.namespace + '.' + self._fn.name
                                    if hasattr(self._fn, 'plugin') else repr(self._fn))
        if isinstance(out, list):
            return [poisoned(x, self._seed) for x in out]
        return poisoned(out, self._seed)

    def __getattr__(self, name):
        return getattr(self._fn, name)


class _Ns:
    def __init__(self, ns, seed, stats):
        self._ns, self._seed, self._stats = ns, seed, stats

    def __getattr__(self, name):
        v = getattr(self._ns, name)
        return _Fn(v, self._seed, self._stats) if callable(v) else v


class PoisonCore:
    """Stands in for `core` in a module; `inner` may itself be a proxy."""
    def __init__(self, inner, seed, stats):
        self._inner, self._seed, self._stats = inner, seed, stats

    def __getattr__(self, name):
        v = getattr(self._inner, name)
        # A plugin namespace (or havsfunc's akarin Expr wrapper around std).
        if isinstance(v, vs.Plugin) or type(v).__name__ == '_ExprStd':
            return _Ns(v, self._seed, self._stats)
        return v


def source(w, h, fmt, seed):
    """A moving, textured clip, its frames poisoned like everything else."""
    c = REAL.std.BlankClip(width=w, height=h, format=fmt, length=LENGTH)
    peak = (1 << c.format.bits_per_sample) - 1
    bps = c.format.bytes_per_sample
    rows = {}
    for p in range(c.format.num_planes):
        pw = w >> (c.format.subsampling_w if p else 0)
        ph = h >> (c.format.subsampling_h if p else 0)
        span = pw + 3 * LENGTH
        rows[p] = []
        for y in range(ph):
            vals = [min(peak, int((math.sin(x / 5) + math.cos(y / 7)) * peak / 5 + peak / 2
                                  + ((x * y + p) % 13) * peak / 64)) for x in range(span)]
            rows[p].append(b''.join(v.to_bytes(bps, 'little') for v in vals))

    def fill(n, f):
        o = f.copy()
        for p in range(o.format.num_planes):
            pw = o.width >> (o.format.subsampling_w if p else 0)
            stride = o.get_stride(p)
            base = ctypes.cast(o.get_write_ptr(p), ctypes.c_void_p).value
            for y, row in enumerate(rows[p]):
                ctypes.memmove(base + y * stride, row[3 * n * bps:(3 * n + pw) * bps], pw * bps)
        _pad_fill(o, seed)
        return o
    return REAL.std.SetFieldBased(REAL.std.ModifyFrame(c, c, fill), 0)


def digest(clip, frames):
    m = hashlib.md5()
    for n in frames:
        f = clip.get_frame(n)
        for p in range(f.format.num_planes):
            m.update(bytes(f[p]))
    return m.hexdigest()


def run(preset, w, h, fmt, seed):
    import havsfunc as haf
    import mvsfunc as mvf
    import adjust
    stats = {'calls': []}
    saved = {m: m.core for m in (haf, mvf, adjust) if hasattr(m, "core")}
    control = {}
    try:
        for m in saved:
            m.core = PoisonCore(saved[m], seed, stats)
        # The positive control: an mv.Degrain1 frame, poisoned, read back.
        mv = haf.core.mv
        c = source(w, h, fmt, seed)
        sup = mv.Super(c, pel=1, levels=1, hpad=8, vpad=8)
        srch = mv.Super(c, pel=1, hpad=8, vpad=8)
        bv, fv = (mv.Analyse(srch, isb=b, delta=1, blksize=16, overlap=4) for b in (True, False))
        deg = mv.Degrain1(c, sup, bv, fv, thsad=640)
        f = deg.get_frame(4)
        p = 1 if f.format.num_planes > 1 else 0
        pw = f.width >> (f.format.subsampling_w if p else 0)
        gap = f.get_stride(p) - pw * f.format.bytes_per_sample
        base = ctypes.cast(f.get_read_ptr(p), ctypes.c_void_p).value
        control = hashlib.md5(ctypes.string_at(base + pw * f.format.bytes_per_sample, gap)).hexdigest() \
            if gap > 0 else None
        stats['calls'].clear()
        out = haf.QTGMC(source(w, h, fmt, seed), Preset=preset, TFF=True)
        return digest(out, [n for n in HASH_FRAMES if n < out.num_frames]), control, stats['calls']
    finally:
        for m, v in saved.items():
            m.core = v


def main():
    preset, size, fmt = sys.argv[1:4]
    seeds = [int(s) for s in sys.argv[4:]] or [1, 2]
    w, h = map(int, size.split('x'))
    if os.environ.get('POISON_THREADS'):
        REAL.num_threads = int(os.environ['POISON_THREADS'])
    t0 = time.time()
    hashes, controls, calls = {}, {}, []
    for s in seeds:
        hashes[s], controls[s], calls = run(preset, w, h, getattr(vs, fmt), s)
    print(json.dumps({'case': '%s %s %s' % (preset, size, fmt), 'hashes': hashes,
                      'control': controls, 'proxied': len(calls),
                      'functions': sorted(set(calls)),
                      'seconds': round(time.time() - t0, 1)}))


if __name__ == '__main__':
    main()
