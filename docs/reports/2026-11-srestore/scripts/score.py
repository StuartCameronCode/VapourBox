"""Recovery on the ground-truth fixtures, for every variant.

Clean limit: each fixture has an unblended twin (same chain with frames
repeated or dropped instead of blended, generated here into the scratch
directory). After the same x264 + QTGMC chain, its frames are within the
"floor" MAD of their original; an output frame counts as clean when it is
within that floor's 99th percentile + 0.25 levels of an original.
"""
import json
import os
import subprocess

import probelib as P
from probelib import core, vs

core.num_threads = int(os.environ.get('PROBE_THREADS', '0')) or core.num_threads

TWIN_VF = {
    'film': "select='between(n\\,{a}\\,{b})',setpts=N/(24000/1001)/TB,fps=60000/1001,fps=50,tinterlace=mode=interleave_top,setfield=tff",
    'pal': "select='between(n\\,{a}\\,{b})',setpts=N/25/TB,format=yuv422p10le,fps=60000/1001,tinterlace=mode=interleave_top,setfield=tff",
}
PIX = {'film': 'yuv420p', 'pal': 'yuv422p10le'}


def twin(fx):
    path = os.path.join(P.SCRATCH, f'twin_{fx}.mkv')
    if not os.path.exists(path):
        n = P.TRUTH_COUNT[fx]
        vf = TWIN_VF[fx].format(a=P.FIRST, b=P.FIRST + n - 1)
        subprocess.run([P.FFMPEG, '-v', 'error', '-y', '-i', os.path.join(P.RES, 'small_clip.mp4'),
                        '-vf', vf, '-an', '-c:v', 'libx264', '-preset', 'slow', '-crf', '10',
                        '-pix_fmt', PIX[fx], '-flags', '+ildct+ilme', '-x264-params', 'tff=1', path],
                       check=True)
    raw = P.decode_raw(path, PIX[fx], f'twin_{fx}')
    fps = (25, 1) if fx == 'film' else (30000, 1001)
    return P.cache_raw(P.bob(P.raw_clip(raw, 320, 240, PIX[fx], *fps)), f'twin_{fx}_qtgmc')


def pct(vals, q):
    v = sorted(vals)
    return v[min(len(v) - 1, int(q * len(v)))]


results = {}
for fx in ('film', 'pal'):
    clip = P.bobbed(fx)
    gt = P.truth(P.TRUTH_COUNT[fx], 'yuv420p')
    num, den = P.TARGETS[fx]
    frfac, numr, denm = P.srestore.ratio(clip.fps_num, clip.fps_den, num, den)

    tw = twin(fx)
    tw_ratio = (num / den) / (tw.fps_num / tw.fps_den)
    floor = [v for _, v, _ in P.nearest_truth(tw, gt, tw_ratio, search=6)]
    limit = pct(floor, 0.99) + 0.25
    # How far a 50/50 blend of neighbours sits from either original.
    blends = core.std.Merge(gt[:-1], gt[1:], 0.5)
    blend_mad = sorted(v for _, v, _ in P.nearest_truth(blends, gt, 1.0, search=1))

    rows = []
    pr = P.props(clip, fx)
    variants = [('Plain decimation (Frame Rate: Duplicate)', P.render(clip, [(0, False)] * len(clip), num, den)),
                ('havsfunc srestore as shipped (R78)', P.haf.srestore(clip, frate=num / den)),
                ('Port, linear (every frame in order)', P.render(clip, P.decisions_linear(pr, frfac, numr, denm), num, den))]
    for k in (8, 16, 24, 32, 48, 64, 96, 128):
        variants.append((f'Port, window {k}', P.render(clip, P.decisions_window(pr, frfac, numr, denm, k), num, den)))
    for label, out in variants:
        picks = P.nearest_truth(out, gt, 1.0)
        s = P.summarise(label, picks, limit)
        rows.append(s)
        print(fx, s)
    results[fx] = {'clean_limit': round(limit, 3), 'floor_p50': round(pct(floor, 0.5), 3),
                   'floor_p99': round(pct(floor, 0.99), 3),
                   'blend_mad_p10': round(pct(blend_mad, 0.1), 3), 'blend_mad_p50': round(pct(blend_mad, 0.5), 3),
                   'truth_frames': P.TRUTH_COUNT[fx], 'rows': rows}
    print(fx, {k: v for k, v in results[fx].items() if k != 'rows'})
json.dump(results, open(os.path.join(P.SCRATCH, 'score.json'), 'w'), indent=1)
