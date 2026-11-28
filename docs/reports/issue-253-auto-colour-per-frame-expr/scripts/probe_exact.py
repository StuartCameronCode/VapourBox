"""Issue #253: does the rewritten automatic white balance give the same
picture as the one it replaced?

Takes `_auto_white` verbatim from two copies of pipeline_template.vpy (the one
before the change, and the one after) and runs both on the same clips through
the deps bundle's VapourSynth. The new function runs twice: with akarin (the
path every bundle but macOS x64 takes) and with `_akarin_expr = None` (macOS
x64's fallback, a std.Expr per frame).

Clips: 706x480 (the issue's size), 60 frames of AddGrain noise plus a chroma
cast that changes every frame, at 8/10/12/16 bits, 4:2:0/4:2:2/4:4:4, four
strengths. The fixtures use akarin.Expr (X, Y, N), so run it on a bundle that
has akarin. probe_white_rate.py runs the akarin path over more frames.

Usage (macOS/Linux; the bundle's own Python):
  PYTHONHOME=<deps>/python PYTHONPATH=<deps> XDG_CONFIG_HOME=<deps>/config \
    <deps>/python/bin/python3 -I probe_exact.py <deps> <old.vpy> <new.vpy> [--quick]
Prints one line per case and exits non-zero on any difference.
"""
import functools
import re
import sys

deps, old_path, new_path = sys.argv[1:4]
quick = '--quick' in sys.argv
sys.path.insert(0, deps)
import vapoursynth as vs  # noqa: E402

core = vs.core


def extract(path, name):
    text = open(path, encoding='utf-8').read().replace('\r\n', '\n')
    m = re.search(rf'^def {name}\(.*?(?=^\S)', text, re.S | re.M)
    if not m:
        raise SystemExit(f'{name} not found in {path}')
    return m.group(0)


def load(path, name, akarin):
    """The template's function, bound to akarin or (akarin=False) to std.Expr."""
    akarin_expr = getattr(getattr(core, 'akarin', None), 'Expr', None) if akarin else None

    def _expr(clips, expr, **kw):
        if akarin_expr is not None:
            return akarin_expr(clips, expr, **kw)
        return core.std.Expr(clips, expr, **kw)

    ns = {'core': core, 'vs': vs, 'functools': functools,
          '_akarin_expr': akarin_expr, '_expr': _expr}
    exec(extract(path, name), ns)
    return ns[name], ns


def maxdiff(a, b):
    worst = 0
    d = core.std.Expr([a, b], 'x y - abs')
    for p in range(a.format.num_planes):
        for f in core.std.PlaneStats(d, plane=p).frames():
            worst = max(worst, f.props['PlaneStatsMax'])
    return worst


def white_source(bits, sub, n):
    fmt = core.query_video_format(vs.YUV, vs.INTEGER, bits, min(sub, 1), 1 if sub == 2 else 0).id
    peak = (1 << bits) - 1
    c = core.std.BlankClip(width=706, height=480, format=fmt, length=n,
                           color=[peak // 2, 1 << (bits - 1), 1 << (bits - 1)])
    c = core.grain.Add(c, var=40, uvar=20, seed=1)
    s = peak / 255.0
    return core.akarin.Expr([c], ['',
                                  f'x N 13 % 1.37 * X 0.01 * + {s} * +',
                                  f'x N 11 % 0.91 * Y 0.02 * - {s} * +'])


if __name__ == '__main__':
    failures = 0
    for bits in (8, 10, 12, 16):
        for sub, name in ((2, '4:2:0'), (1, '4:2:2'), (0, '4:4:4')):
            c = white_source(bits, sub, 20 if quick else 60)
            for strength in (0.0, 0.37, 0.8, 1.0):
                ref = load(old_path, '_auto_white', akarin=True)[0](c, strength)
                for akarin in (True, False):
                    d = maxdiff(ref, load(new_path, '_auto_white', akarin=akarin)[0](c, strength))
                    failures += d != 0
                    print(f'auto_white bits={bits} {name} strength={strength} '
                          f'path={"akarin" if akarin else "fallback"} maxdiff={d}'
                          f'{"" if d == 0 else "  <-- DIFFERS"}', flush=True)
    print('FAILURES', failures)
    sys.exit(1 if failures else 0)
