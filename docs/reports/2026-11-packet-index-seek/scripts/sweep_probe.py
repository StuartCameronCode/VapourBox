"""B. Correctness: every start frame of every fixture, today's arguments
(the control) against the packet-index methods, 3 pictures each, named
against the untrimmed decode (frame N as the app numbers it).

Writes data/sweep.json. Usage: sweep_probe.py [fixture ...]
"""
import json
import os
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

import pktlib as L
import today_args as today

SHOW = 3  # pictures decoded per start


def worker():
    exe = os.path.join(L.REPO, 'worker', 'target', 'debug', 'vapourbox-worker')
    return exe if os.path.exists(exe) else None


def joined_copy(name):
    """The joined copy the app decodes a reset fixture from (task #21)."""
    out = os.path.join(L.WORK, 'continuous_' + name)
    if not os.path.exists(out):
        r = subprocess.run([worker(), '--make-continuous', L.resource(name), '--output', out],
                           capture_output=True, text=True)
        assert r.returncode == 0 and os.path.exists(out), r.stdout[-500:] + r.stderr[-500:]
    return out


def methods(info, raw_reset=False):
    """The methods that apply to this source: (name, builder(index, tb, n))."""
    out = [('today', lambda idx, tb, n: (*L.today_args(info, n), None))]
    if info['grid']:
        out.append(('M1', lambda idx, tb, n: L.m1_grid(info, idx, tb, n)))
        if info['ts']:
            out.append(('M2', lambda idx, tb, n: L.m2_grid(info, idx, tb, n)))
    elif info['ts']:
        # A PS whose packets don't all carry a PTS has no grid today: frame N
        # is ffmpeg's constant-rate numbering, reached by an absolute trim.
        def trim_args(idx, tb, n, byte):
            k = ps_key(info, idx, tb, n)
            a, f = L.today_args(info, n)
            f = [x for x in f]
            if k is None or k == L.first_key(idx):
                start = []
            elif byte:
                start = ['-skip_initial_bytes', str(idx[k]['pos'])]
            else:
                start = ['-ss', L.floor_us(float(idx[k]['pts'] * tb) - info['cs'])]
            if n == 0:
                return a, f, k
            return ['-copyts'] + start, f, k
        out.append(('M1-trim', lambda idx, tb, n: trim_args(idx, tb, n, False)))
        out.append(('M2-trim', lambda idx, tb, n: trim_args(idx, tb, n, True)))
    else:
        out.append(('count', lambda idx, tb, n: L.count_from_key(info, idx, n, True)))
        out.append(('count-raw', lambda idx, tb, n: L.count_from_key(info, idx, n, False)))
    if raw_reset:
        out.append(('M2-seg', lambda idx, tb, n: m2_seg(info, idx, tb, n)))
    return out


def segments(idx, tb):
    """Split the index where the video's DTS resets (source_continuity's rule:
    more than 0.1 s back or 10 s forward): [(first packet, end, first picture
    PTS, first frame number)]. Frame numbers count pictures (packets), which
    holds for the progressive constant-rate reset fixtures."""
    cuts = [0]
    for i in range(1, len(idx)):
        a, b = idx[i - 1]['dts'], idx[i]['dts']
        if a is not None and b is not None and ((b - a) * tb < -0.1 or (b - a) * tb > 10):
            cuts.append(i)
    cuts.append(len(idx))
    out, frame = [], 0
    for a, b in zip(cuts, cuts[1:]):
        first = min(p['pts'] for p in idx[a:b] if p['pts'] is not None)
        out.append((a, b, first, frame))
        frame += b - a
    return out


def m2_seg(info, idx, tb, n):
    """M2 on the raw reset file, segment-aware: K is searched in the segment
    holding frame n only, and the selection counts from that segment's first
    picture. Answers whether a byte start reaches a later segment at all."""
    seg = [s for s in segments(idx, tb) if s[3] <= n][-1]
    a, b, first, f0 = seg
    t = float(first * tb) + (n - f0 - 0.5) / info['fps']
    k = None
    for i in range(a, b):
        p = idx[i]
        if p['key'] and p['pts'] is not None and float(p['pts'] * tb) <= t:
            k = i
    if k is None:
        k = next(i for i in range(a, b) if idx[i]['key'])
    start = [] if k == L.first_key(idx) else ['-skip_initial_bytes', str(idx[k]['pos'])]
    if info['grid']:
        g = dict(info['grid'], origin=float(first * tb))
        return ['-copyts'] + start, today.grid_filters(g, n - f0), k
    return ['-copyts'] + start, [f'trim=start={today.seek_arg(t)}', 'setpts=PTS-STARTPTS'], k


def ps_key(info, idx, tb, n):
    """K for frame n of a source with no grid: the last key packet whose PTS
    is at or before frame n's time, (n - 0.5)/fps after the first picture.
    Key packets carry a PTS in every fixture (checked in the result)."""
    t = info['cs'] + info['offset'] + (n - 0.5) / info['fps']
    best = None
    for i, p in enumerate(idx):
        if p['key'] and p['pts'] is not None and float(p['pts'] * tb) <= t:
            best = i
    return best


def sweep(name, path=None, label=None, raw_reset=False):
    path = path or L.resource(name)
    info = L.source_info(path)
    ref = L.reference(info)
    seq = ref['seq']
    idx, tb = L.packet_index(path)
    total = len(seq)
    res = dict(fixture=label or name, frames=total, fps=info['fps'], offset=info['offset'],
               delay=info['delay'], plan=info['plan'], grid=info['grid'], fmt=info['fmt'],
               packets=len(idx), keys=sum(p['key'] for p in idx),
               keys_without_pts=sum(1 for p in idx if p['key'] and p['pts'] is None),
               packets_without_pts=sum(1 for p in idx if p['pts'] is None),
               placed_agrees=None, methods={})
    if ref['placed'] is not None:
        pl = ref['placed']
        res['placed_agrees'] = pl[:total] == seq[:len(pl)] and len(pl) >= total
    for mname, build in methods(info, raw_reset):
        def one(n):
            a, f, k = build(idx, tb, n)
            got, err = L.decode(info, a, f, SHOW)
            want = seq[n:n + SHOW]
            return n, got[:len(want)] == want, L.name(got, seq), k, a, err if not got else ''
        with ThreadPoolExecutor(max_workers=8) as ex:
            rows = list(ex.map(one, range(total)))
        bad = [dict(n=n, got=g, key=k, args=a, err=e) for n, ok, g, k, a, e in rows if not ok]
        res['methods'][mname] = dict(exact=total - len(bad), wrong=len(bad), bad=bad[:40],
                                     seeks=sum(1 for r in rows if '-ss' in r[4] or '-skip_initial_bytes' in r[4]))
        print(f'{res["fixture"]:34s} {mname:9s} exact {total - len(bad):4d}/{total}', flush=True)
    return res


def main():
    L.pin_constants()
    names = sys.argv[1:] or L.SEEK_SUITE + L.GRID_SUITE
    out = []
    for n in names:
        if n in L.RESET_FIXTURES:
            out.append(sweep(n, joined_copy(n), n + ' (joined copy)'))
            out.append(sweep(n, None, n + ' (raw, as the file is)', raw_reset=True))
        else:
            out.append(sweep(n))
    os.makedirs(L.DATA, exist_ok=True)
    dest = os.path.join(L.DATA, 'sweep.json' if not sys.argv[1:] else 'sweep_partial.json')
    json.dump(out, open(dest, 'w'), indent=1, default=str)
    print('wrote', dest)


if __name__ == '__main__':
    main()
