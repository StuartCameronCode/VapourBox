"""Decode 8 frames from several start frames, the way the worker's decoders
seek, under three output timings, and name each picture by its index in an
independent sequential decode (MD5 of the luma plane).

  python3 dup_probe.py [--json out.json] [source ...]

With no sources: every committed fixture plus make_variants.py's variants.
Reference: the sequential `-fps_mode passthrough` decode (every stored frame
once). `slots` adds the comparison against the untrimmed constant-rate decode,
which is what an untrimmed encode feeds the script (the right reference for
soft telecine, whose pulldown repeats are slots of their own)."""
import json
import os
import sys
from seeklib import RES, probe, sequential, seek_decode, indices
import make_variants

FIXTURES = ['small_clip.mp4', 'seek_timebase_2997.mov', 'interlaced_test.avi',
            'colorize_test.mp4', 'face_restore_test.mp4', 'pal-sd-25.mov',
            'prores422_10bit_telecine.mov', 'hard_telecine_test.avi',
            'soft_telecine_test.mkv', 'pal-dvbt-fieldcoded-25i.ts']
COUNT = 8


def starts_for(n):
    s = [1, 10, 40, 41, 42, 43, 77]
    return [x for x in s if x + COUNT < n] + ([n - COUNT - 2] if n > 30 else [])


def run(path):
    s = probe(path)
    seq = sequential(path, 100000)
    slots = sequential(path, 100000, timing='default')
    rows = []
    for start in starts_for(len(seq)):
        row = {'start': start}
        for mode in ('default', 'passthrough', 'setpts'):
            got = seek_decode(path, start, COUNT, mode)
            row[mode] = indices(got, seq)
            row[mode + '_slots'] = indices(got, slots)
            row[mode + '_ok'] = got == seq[start:start + COUNT]
            row[mode + '_slots_ok'] = got == slots[start:start + COUNT]
        rows.append(row)
    return {'source': os.path.basename(path), 'time_base': s['time_base'],
            'codec': s['codec_name'], 'fps': round(s['fps'], 3),
            'start_time': s.get('start_time'), 'frames': len(seq),
            'slots': len(slots), 'rows': rows}


def main():
    args = sys.argv[1:]
    out = None
    if args[:1] == ['--json']:
        out, args = args[1], args[2:]
    paths = args or [os.path.join(RES, f) for f in FIXTURES] + make_variants.build()
    results = []
    for p in paths:
        r = run(p)
        results.append(r)
        print(f"== {r['source']}  tb {r['time_base']}  {r['codec']}  {r['fps']} fps  "
              f"start_time {r['start_time']}  {r['frames']} frames ({r['slots']} slots)")
        for row in r['rows']:
            for mode in ('default', 'passthrough', 'setpts'):
                flag = 'ok ' if row[mode + '_ok'] else 'BAD'
                sflag = 'ok ' if row[mode + '_slots_ok'] else 'BAD'
                print(f"  start {row['start']:4d} {mode:11s} vs seq {flag} {row[mode]}"
                      f"   vs slots {sflag} {row[mode + '_slots']}")
    if out:
        with open(out, 'w') as f:
            json.dump(results, f, indent=1)


if __name__ == '__main__':
    main()
