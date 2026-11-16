"""A. What a packet index costs to build, against today's reset scan.

  cost_probe.py cold <file> [<file> ...]
      One cold read per file, each probe on a different file (a file read once
      is in the page cache after; smbfs caches too). Use same-sized parts of
      one title, e.g. the VTS_01_n.VOB of a DVD on a share: results per GB.
  cost_probe.py one <probe> <file>
      A single cold run of one probe (named as in PROBES).
  cost_probe.py windows <label> <input>
      The per-seek probes only (time to the first 1000 packets, I-window).
  cost_probe.py warm <label> <input> [reps]
      Median of `reps` (3) warm runs of every probe on one input (a path or a
      `concat:a|b` URL), plus the index's size, the time to its first 1000
      packets and a windowed (per-seek) probe at 10/50/95 %.

Appends to data/cost.json. Times are wall clock on one machine.
"""
import json
import os
import resource
import statistics
import subprocess
import sys
import time

import pktlib as L

WORKER = os.path.join(L.REPO, 'worker', 'target', 'debug', 'vapourbox-worker')

IDX_VIDEO = ['-v', 'error', '-select_streams', 'v:0', '-show_entries', 'packet=pts,dts,flags,pos',
             '-of', 'csv=p=0']
# The reset scan's packet pass (source_continuity::PACKETS_PROBE_ARGS) widened
# by the index's fields: one pass that answers both.
IDX_MERGED = ['-v', 'error', '-show_entries', 'packet=stream_index,dts_time,pts,dts,flags,pos',
              '-of', 'csv=p=0']
# The same pass printing integer timestamps only (the scan would read each
# stream's time base once instead of every packet's formatted seconds).
IDX_MERGED_INT = ['-v', 'error', '-show_entries', 'packet=stream_index,pts,dts,flags,pos',
                  '-of', 'csv=p=0']
SCAN_PACKETS = ['-v', 'error', '-show_entries', 'packet=stream_index,dts_time', '-of', 'csv=p=0']


def size_of(inp):
    if inp.startswith('concat:'):
        return sum(os.path.getsize(p) for p in inp[7:].split('|'))
    return os.path.getsize(inp)


def timed(args, stdout=subprocess.DEVNULL):
    t = time.perf_counter()
    r = subprocess.run(args, stdout=stdout, stderr=subprocess.DEVNULL)
    return time.perf_counter() - t, r


def timed_cpu(args):
    """(wall, user + sys CPU of the child and its children). CPU time is what
    to compare on a busy machine: wall time includes waiting for a core."""
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    wall, _ = timed(args)
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    return wall, (after.ru_utime - before.ru_utime) + (after.ru_stime - before.ru_stime)


PROBES = {
    'read (cat)': lambda inp: ['cat', *(inp[7:].split('|') if inp.startswith('concat:') else [inp])],
    'reset scan today (--scan-timestamps)': lambda inp: [WORKER, '--scan-timestamps', inp],
    'index merged into the scan pass': lambda inp: [L.FP, *IDX_MERGED, inp],
    'index, video only': lambda inp: [L.FP, *IDX_VIDEO, inp],
    'index merged, integer timestamps': lambda inp: [L.FP, *IDX_MERGED_INT, inp],
    'reset scan packet pass only': lambda inp: [L.FP, *SCAN_PACKETS, inp],
}


def save(row):
    os.makedirs(L.DATA, exist_ok=True)
    path = os.path.join(L.DATA, 'cost.json')
    rows = json.load(open(path)) if os.path.exists(path) else []
    rows.append(row)
    json.dump(rows, open(path, 'w'), indent=1)


CACHED_BELOW = 5.0  # s/GB: faster than this, the read came from the page cache


def cold(files, rounds=3):
    """Round r runs probe i on file (i + r) mod n, so every probe reads a
    different file each round and nothing reads the file it read last. smbfs
    keeps some reads cached and drops others, so a run is classed by speed:
    below CACHED_BELOW s/GB it was served from cache and is reported apart."""
    names = list(PROBES)[:len(files)]
    for r in range(rounds):
        for i, probe in enumerate(names):
            f = files[(i + r) % len(files)]
            dt, res = timed(PROBES[probe](f))
            gb = size_of(f) / 1e9
            row = dict(kind='cold', round=r, probe=probe, file=os.path.basename(f), gb=gb, secs=dt,
                       s_per_gb=dt / gb, cached=dt / gb < CACHED_BELOW, ok=res.returncode == 0)
            print(json.dumps(row), flush=True)
            save(row)


def window(inp, frac, duration, width=4.0):
    """I-window: the packets of a window before a target, as a per-seek
    keyframe probe would read them."""
    t = max(0.0, duration * frac - width)
    args = [L.FP, '-v', 'error', '-select_streams', 'v:0', '-read_intervals', f'{t:.3f}%+{width:.3f}',
            '-show_entries', 'packet=pts,flags,pos', '-of', 'csv=p=0', inp]
    dt, r = timed(args, stdout=subprocess.PIPE)
    keys = sum(1 for line in r.stdout.decode().splitlines() if 'K' in line)
    return dt, keys


def warm(label, inp, reps=3):
    gb = size_of(inp) / 1e9
    dur = float(subprocess.run([L.FP, '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', inp],
                               capture_output=True, text=True).stdout.strip() or 0)
    for name, build in PROBES.items():
        runs = [timed_cpu(build(inp)) for _ in range(reps)]
        wall, cpu = [r[0] for r in runs], [r[1] for r in runs]
        row = dict(kind='warm', label=label, probe=name, gb=gb, secs=statistics.median(wall),
                   runs=wall, s_per_gb=statistics.median(wall) / gb, cpu_secs=statistics.median(cpu),
                   cpu_runs=cpu, cpu_s_per_gb=statistics.median(cpu) / gb,
                   load=os.getloadavg()[0])
        print(json.dumps(row), flush=True)
        save(row)
    # Size of the index, and of its keyframes-only form.
    r = subprocess.run([L.FP, *IDX_VIDEO, inp], capture_output=True)
    lines = r.stdout.decode().splitlines()
    keys = [l for l in lines if 'K' in l.split(',')[-1]]
    key_json = json.dumps([[int(l.split(',')[0]) if l.split(',')[0] != 'N/A' else None,
                            int(l.split(',')[2])] for l in keys])
    t1000 = statistics.median(timed([L.FP, *IDX_VIDEO[:-2], '-read_intervals', '%+#1000', '-of', 'csv=p=0', inp])[0]
                              for _ in range(reps))
    win = {f'{int(f * 100)}%': window(inp, f, dur) for f in (0.10, 0.50, 0.95)}
    row = dict(kind='size', label=label, gb=gb, duration=dur, packets=len(lines), keys=len(keys),
               csv_bytes=len(r.stdout), key_json_bytes=len(key_json),
               keys_without_pts=sum(1 for l in keys if l.startswith('N/A')),
               first_1000_secs=t1000, window={k: dict(secs=v[0], keys=v[1]) for k, v in win.items()})
    print(json.dumps(row), flush=True)
    save(row)


def windows_only(label, inp):
    """The per-seek probes alone (no whole-file read): for a big file on a
    share, where the whole-file probes are measured cold elsewhere."""
    dur = float(subprocess.run([L.FP, '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', inp],
                               capture_output=True, text=True).stdout.strip() or 0)
    t1000 = timed([L.FP, *IDX_VIDEO[:-2], '-read_intervals', '%+#1000', '-of', 'csv=p=0', inp])[0]
    win = {f'{int(f * 100)}%': window(inp, f, dur) for f in (0.10, 0.50, 0.95)}
    row = dict(kind='windows', label=label, gb=size_of(inp) / 1e9, duration=dur, first_1000_secs=t1000,
               window={k: dict(secs=v[0], keys=v[1]) for k, v in win.items()})
    print(json.dumps(row), flush=True)
    save(row)


if __name__ == '__main__':
    if sys.argv[1] == 'cold':
        cold(sys.argv[2:])
    elif sys.argv[1] == 'one':
        # one <probe name, as in PROBES> <file>: a single cold run
        f = sys.argv[3]
        dt, res = timed(PROBES[sys.argv[2]](f))
        gb = size_of(f) / 1e9
        row = dict(kind='cold', round='single', probe=sys.argv[2], file=os.path.basename(f), gb=gb, secs=dt,
                   s_per_gb=dt / gb, cached=dt / gb < CACHED_BELOW, ok=res.returncode == 0)
        print(json.dumps(row), flush=True)
        save(row)
    elif sys.argv[1] == 'windows':
        windows_only(sys.argv[2], sys.argv[3])
    else:
        warm(sys.argv[2], sys.argv[3], int(sys.argv[4]) if len(sys.argv) > 4 else 3)
