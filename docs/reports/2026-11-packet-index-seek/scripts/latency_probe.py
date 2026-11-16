"""C. What one preview start costs: wall time of an 11-frame decode (the
preview's window) from a frame at 10/50/95 % of a long title, today's
arguments against the index methods. Median of 5 warm runs; with `--cold`,
the first run only (on a share, read once).

  latency_probe.py <label> <input> [--cold]

The index (I-full) is built once beforehand, as analysis would; for
I-window the window probe's own time is added to the decode's. Every start
is also checked against today's pictures (they must agree).
Appends to data/latency.json.
"""
import json
import os
import resource
import statistics
import subprocess
import sys
import time

import pktlib as L
import today_args as today

FRAMES = 11


def run(info, args, filters):
    """(wall, CPU of the decoder, pictures). CPU time is the comparable one on
    a shared machine; a seek that starts further back decodes more."""
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    t = time.perf_counter()
    got, err = L.decode(info, args, filters, FRAMES)
    wall = time.perf_counter() - t
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    return wall, (after.ru_utime - before.ru_utime) + (after.ru_stime - before.ru_stime), got


def ps_key(info, idx, tb, n):
    t = info['cs'] + info['offset'] + (n - 0.5) / info['fps']
    best = None
    for i, p in enumerate(idx):
        if p['key'] and p['pts'] is not None and float(p['pts'] * tb) <= t:
            best = i
    return best


def index_start(info, idx, tb, n, byte):
    """The index method for this source: grid sources M1/M2, a PS with no
    grid M1/M2 with today's absolute trim."""
    if info['grid']:
        return (L.m2_grid if byte else L.m1_grid)(info, idx, tb, n)[:2]
    a, f = L.today_args(info, n)
    k = ps_key(info, idx, tb, n)
    if byte:
        return ['-copyts', '-skip_initial_bytes', str(idx[k]['pos'])], f
    return ['-copyts', '-ss', L.floor_us(float(idx[k]['pts'] * tb) - info['cs'])], f


def window_start(info, n, width=4.0):
    """I-window: probe the packets of a `width` s window before frame n for
    the last key packet, then M2 from it. Returns (args, filters, probe secs)."""
    t_abs = info['cs'] + info['offset'] + (n - 0.5) / info['fps']
    t0 = time.perf_counter()
    r = subprocess.run([L.FP, '-v', 'error', '-select_streams', 'v:0', '-read_intervals',
                        f'{max(0.0, t_abs - info["cs"] - width):.3f}%+{width:.3f}',
                        '-show_entries', 'packet=pts,flags,pos', '-of', 'csv=p=0', info['path']],
                       capture_output=True, text=True)
    dt = time.perf_counter() - t0
    best = None
    for line in r.stdout.splitlines():
        pts, pos, flags = (line.split(',') + ['', '', ''])[:3]
        if 'K' in flags and pts != 'N/A' and float(int(pts) * info['tb']) <= t_abs:
            best = int(pos)
    if best is None:
        return None, None, dt
    if info['grid']:
        f = today.grid_filters(info['grid'], n)
    else:
        f = L.today_args(info, n)[1]
    return ['-copyts', '-skip_initial_bytes', str(best)], f, dt


def main():
    label, inp = sys.argv[1], sys.argv[2]
    cold = '--cold' in sys.argv
    reps = 1 if cold else 5
    info = L.source_info(inp)
    t0 = time.perf_counter()
    idx, tb = L.packet_index(inp)
    index_secs = time.perf_counter() - t0
    dur = len([p for p in idx]) / info['fps']
    rows = []
    for frac in (0.10, 0.50, 0.95):
        n = int(dur * frac * info['fps'])
        res = {}
        ta, tf = L.today_args(info, n)
        variants = [('today', lambda: (ta, tf, 0.0))]
        if info['ts']:
            variants.append(('M2 (byte start, I-full)', lambda: (*index_start(info, idx, tb, n, True), 0.0)))
            variants.append(('I-window + M2', lambda: window_start(info, n)))
        variants.append(('M1 (time seek to K, I-full)', lambda: (*index_start(info, idx, tb, n, False), 0.0)))
        ref = None
        for name, build in variants:
            times, cpus, pics, extra = [], [], None, []
            for _ in range(reps):
                a, f, probe_secs = build()
                if a is None:
                    break
                dt, cpu, got = run(info, a, f)
                times.append(dt + probe_secs)
                cpus.append(cpu)
                extra.append(probe_secs)
                pics = got
            if not times:
                res[name] = dict(failed=True)
                continue
            if name == 'today':
                ref = pics
            res[name] = dict(secs=statistics.median(times), cpu_secs=statistics.median(cpus),
                             probe_secs=statistics.median(extra), same_as_today=pics == ref, args=a,
                             load=os.getloadavg()[0])
            print(f'{label} {frac:.0%} frame {n}: {name:30s} {statistics.median(times):.3f} s'
                  f' (decoder CPU {statistics.median(cpus):.3f} s)'
                  f'{"" if pics == ref else "  DIFFERENT PICTURES"}', flush=True)
        rows.append(dict(frac=frac, frame=n, methods=res))
    out = dict(label=label, cold=cold, index_secs=index_secs, packets=len(idx), rows=rows)
    path = os.path.join(L.DATA, 'latency.json')
    allrows = json.load(open(path)) if os.path.exists(path) else []
    allrows.append(out)
    json.dump(allrows, open(path, 'w'), indent=1, default=str)


if __name__ == '__main__':
    main()
