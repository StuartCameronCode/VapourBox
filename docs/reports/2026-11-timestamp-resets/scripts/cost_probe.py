"""Cost of the scan and the copy (task #21), against the number of resets,
and the rejected MKV proxy for comparison (it needs +genpts, and its time
grew with the square of the number of resets at planning).

A file of K+1 joined 4 s MPEG-2 program streams has K resets.
"""
import os
import time

from resetlib import FF, WORK, run, worker_json

SEG = 4


def build(k):
    seg = os.path.join(WORK, 'cost_seg.mpg')
    if not os.path.exists(seg):
        run([FF, '-y', '-v', 'error',
             '-f', 'lavfi', '-i', f'testsrc2=size=720x576:rate=25:duration={SEG}',
             '-f', 'lavfi', '-i', f'sine=sample_rate=48000:duration={SEG}',
             '-c:v', 'mpeg2video', '-b:v', '6M', '-g', '12', '-bf', '2',
             '-c:a', 'ac3', '-f', 'vob', seg])
    out = os.path.join(WORK, f'cost_{k}.mpg')
    data = open(seg, 'rb').read()
    with open(out, 'wb') as f:
        for _ in range(k + 1):
            f.write(data)
    return out


def timed(f):
    t = time.perf_counter()
    r = f()
    return time.perf_counter() - t, r


def main():
    print('resets | MB | scan s | PS copy s | MKV remux (+genpts) s')
    for k in (10, 30, 90):
        path = build(k)
        mb = os.path.getsize(path) / 1e6
        ts, s = timed(lambda: worker_json('--scan-timestamps', path)[0])
        found = sum(1 for r in s['resets'] if r['codecType'] == 'video')
        out = os.path.join(WORK, f'cost_{k}_joined.mpg')
        tc, _ = timed(lambda: worker_json('--make-continuous', path, '--output', out))
        tm, _ = timed(lambda: run([FF, '-y', '-v', 'error', '-fflags', '+genpts', '-i', path,
                                   '-map', '0', '-c', 'copy',
                                   os.path.join(WORK, f'cost_{k}.mkv')]))
        print(f'{k:6d} | {mb:5.0f} | {ts:6.2f} | {tc:9.2f} | {tm:6.2f}   '
              f'(video resets found: {found})')


if __name__ == '__main__':
    main()
