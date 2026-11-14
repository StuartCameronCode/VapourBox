"""Shared helpers for the SRestore / Unblend probe (docs/reports/2026-11-srestore).

Runs inside the deps bundle's own Python (see run.sh). No source plugin is
bundled, so videos are decoded to raw files with the bundled ffmpeg and read
back with ModifyFrame, the way pipe_source does from a pipe.
"""

import ctypes
import math
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..', '..', '..'))
SCRATCH = os.environ.get('SRESTORE_PROBE_DIR') or sys.exit('set SRESTORE_PROBE_DIR to a scratch directory')
DEPS = os.environ['VAPOURBOX_DEPS']
FFMPEG = os.path.join(DEPS, 'ffmpeg', 'ffmpeg')
RES = os.path.join(REPO, 'Tests', 'TestResources')

sys.path.insert(0, os.path.join(REPO, 'worker', 'templates'))

import vapoursynth as vs  # noqa: E402

core = vs.core

import havsfunc as haf  # noqa: E402
import srestore  # noqa: E402  (worker/templates/srestore.py, the shipped port)

# Ground truth: small_clip.mp4 frames from here on (generate_blended_test.sh).
FIRST = 1350

_FMT = {
    'yuv420p': (vs.YUV420P8, 1, 1, 1),
    'yuv422p10le': (vs.YUV422P10, 2, 1, 0),
}


def decode_raw(video, pix_fmt, name, extra_vf=None):
    """Decode ``video`` to ``SCRATCH/name.raw`` once; return its path."""
    out = os.path.join(SCRATCH, name + '.raw')
    if not os.path.exists(out):
        vf = ['-vf', extra_vf] if extra_vf else []
        subprocess.run([FFMPEG, '-v', 'error', '-y', '-i', video, *vf, '-pix_fmt', pix_fmt, '-fps_mode', 'passthrough',
                        '-f', 'rawvideo', out], check=True)
    return out


def raw_clip(path, width, height, pix_fmt, fpsnum, fpsden):
    fmt, bps, sw, sh = _FMT[pix_fmt]
    cw, ch = width >> sw, height >> sh
    planes = [(width, height), (cw, ch), (cw, ch)]
    frame_size = sum(w * h * bps for w, h in planes)
    n = os.path.getsize(path) // frame_size
    blank = core.std.BlankClip(format=fmt, width=width, height=height, length=n,
                               fpsnum=fpsnum, fpsden=fpsden)

    def fill(n, f):
        fo = f.copy()
        with open(path, 'rb') as fh:
            fh.seek(n * frame_size)
            data = fh.read(frame_size)
        off = 0
        for p, (w, h) in enumerate(planes):
            ptr = fo.get_write_ptr(p).value
            st = fo.get_stride(p)
            row = w * bps
            for y in range(h):
                ctypes.memmove(ptr + y * st, data[off:off + row], row)
                off += row
        return fo

    return core.std.ModifyFrame(blank, blank, fill)


def fixture_film_50i():
    """blended_film_50i.mkv as a 25i TFF clip."""
    raw = decode_raw(os.path.join(RES, 'blended_film_50i.mkv'), 'yuv420p', 'film50i')
    return raw_clip(raw, 320, 240, 'yuv420p', 25, 1)


def fixture_pal_5994i():
    raw = decode_raw(os.path.join(RES, 'blended_pal_5994i.mkv'), 'yuv422p10le', 'pal5994i')
    return raw_clip(raw, 320, 240, 'yuv422p10le', 30000, 1001)


def truth(count, pix_fmt='yuv420p'):
    """small_clip frames FIRST .. FIRST+count-1, the frames before blending."""
    name = f'truth_{count}_{pix_fmt}'
    raw = decode_raw(os.path.join(RES, 'small_clip.mp4'), pix_fmt, name,
                     extra_vf=f"select='between(n\\,{FIRST}\\,{FIRST + count - 1})',setpts=N/TB")
    return raw_clip(raw, 320, 240, pix_fmt, 24000, 1001)


def bob(clip, tff=True, preset='Slower'):
    """Double-rate QTGMC, as the Deinterlace pass runs it by default."""
    clip = core.std.SetFieldBased(clip, 2 if tff else 1)
    out = haf.QTGMC(clip, Preset=preset, TFF=tff, FPSDivisor=1)
    return core.std.SetFieldBased(out, 0)


def luma8(clip):
    if clip.format.bits_per_sample != 8:
        clip = core.resize.Point(clip, format=vs.YUV420P8 if clip.format.subsampling_h else vs.YUV422P8)
    return core.std.ShufflePlanes(clip, 0, vs.GRAY)


def mad(a, b):
    """Per-frame luma mean absolute difference, in 8-bit levels."""
    stats = core.std.PlaneStats(luma8(a), luma8(b))
    return [f.props['PlaneStatsDiff'] * 255 for f in stats.frames()]


def nearest_truth(out, gt, expected_ratio, search=4):
    """For each output frame, the ground-truth frame it is closest to (luma
    MAD), searched within +-search of where it should be. Returns
    [(best_index, best_mad, second_mad)]."""
    out_l, gt_l = luma8(out), luma8(gt)
    n_out = len(out_l)
    res = []
    rows = []
    for d in range(-search, search + 1):
        idx = [min(max(int(round(m * expected_ratio)) + d, 0), len(gt_l) - 1) for m in range(n_out)]
        shifted = core.std.Splice([gt_l[i] for i in idx])
        stats = core.std.PlaneStats(out_l, shifted)
        rows.append((idx, [f.props['PlaneStatsDiff'] * 255 for f in stats.frames()]))
    for m in range(n_out):
        cands = sorted((rows[k][1][m], rows[k][0][m]) for k in range(len(rows)))
        # Collapse clamped duplicates.
        seen, uniq = set(), []
        for v, i in cands:
            if i not in seen:
                seen.add(i)
                uniq.append((v, i))
        res.append((uniq[0][1], uniq[0][0], uniq[1][0] if len(uniq) > 1 else float('inf')))
    return res


def summarise(label, picks, clean_limit):
    """picks: nearest_truth() output. Clean = within the calibrated limit."""
    n = len(picks)
    clean = sum(1 for _, v, _ in picks if v <= clean_limit)
    idx = [i for i, _, _ in picks]
    distinct = len(set(i for i, v, _ in picks if v <= clean_limit))
    steps = sum(1 for a, b in zip(idx, idx[1:]) if b == a + 1)
    dups = sum(1 for a, b in zip(idx, idx[1:]) if b == a)
    skips = sum(1 for a, b in zip(idx, idx[1:]) if b > a + 1)
    mean = sum(v for _, v, _ in picks) / n
    return {'label': label, 'frames': n, 'clean': clean, 'clean_pct': round(100 * clean / n, 1),
            'distinct_clean': distinct, 'steps': steps, 'dups': dups, 'skips': skips,
            'mean_mad': round(mean, 3)}


def cache_raw(clip, name):
    """Render ``clip`` once to SCRATCH/name.raw (slow steps like QTGMC) and
    return a reader over the file."""
    pix = {vs.YUV420P8: 'yuv420p', vs.YUV422P10: 'yuv422p10le'}[clip.format.id]
    out = os.path.join(SCRATCH, name + '.raw')
    if not os.path.exists(out):
        tmp = out + '.part'
        with open(tmp, 'wb') as fh:
            for f in clip.frames():
                for p in range(f.format.num_planes):
                    w = f.width >> (f.format.subsampling_w if p else 0)
                    h = f.height >> (f.format.subsampling_h if p else 0)
                    row = w * f.format.bytes_per_sample
                    ptr = f.get_read_ptr(p).value
                    st = f.get_stride(p)
                    for y in range(h):
                        fh.write(ctypes.string_at(ptr + y * st, row))
        os.replace(tmp, out)
    return raw_clip(out, clip.width, clip.height, pix, clip.fps_num, clip.fps_den)


def bobbed(fixture):
    """The fixture after double-rate QTGMC (cached)."""
    if fixture == 'film':
        return cache_raw(bob(fixture_film_50i()), 'film50p_qtgmc')
    if fixture == 'pal':
        return cache_raw(bob(fixture_pal_5994i()), 'pal5994p_qtgmc')
    raise ValueError(fixture)


TARGETS = {'film': (24000, 1001), 'pal': (25, 1)}
TRUTH_COUNT = {'film': 144, 'pal': 125}


def props(clip, name):
    """srestore.stats_clip measurements for every frame (cached as JSON)."""
    import json
    out = os.path.join(SCRATCH, name + '.props.json')
    if not os.path.exists(out):
        st = srestore.stats_clip(clip)
        json.dump([srestore.props_of(f) for f in st.frames()], open(out, 'w'))
    return [tuple(p) for p in json.load(open(out))]


def decisions_linear(pr, frfac, numr, denm, origin=0):
    det = srestore._Detector(frfac, numr, denm)
    out = [(0, False)] * len(pr)
    for n in range(origin, len(pr)):
        out[n] = det.step(n, *pr[n])
    return out


def decisions_window(pr, frfac, numr, denm, window, origin=0):
    out = [(0, False)] * len(pr)
    for n in range(origin, len(pr)):
        s = srestore.window_start(n, origin, window)
        out[n] = srestore.decide(n, pr[s:n + 1], s, frfac, numr, denm)
    return out


def render(clip, decisions, num, den):
    """The output those decisions give, built the way srestore.unblend
    builds it (shifted copies + SelectEvery)."""
    from fractions import Fraction
    nodes = {}

    def pick(n):
        o, _ = decisions[n]
        if o not in nodes:
            nodes[o] = srestore._shift(clip, o)
        return nodes[o]

    sel = core.std.FrameEval(clip, pick)
    r = Fraction(num, den) / Fraction(clip.fps_num, clip.fps_den)
    offs = [k * r.denominator // r.numerator for k in range(r.numerator)]
    out = core.std.SelectEvery(sel, cycle=r.denominator, offsets=offs)
    return out[:len(clip) * r.numerator // r.denominator]
