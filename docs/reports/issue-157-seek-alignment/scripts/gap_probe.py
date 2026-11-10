"""Review correction (§6, §7): how the PTS reset, the old decoder and a fixed
half-frame shift handle null frames, measured against the untrimmed
constant-rate decode (the app's frame numbering).

  python3 gap_probe.py

Two sources: interlaced_test.avi (leading null frames: stored pts 0, then 5)
and an FFV1 AVI built here from testsrc2 with stored frames 100-104 dropped
(the avi muxer writes them as null frames, like a dropped-frame capture).
Prints each start's first 8 pictures as slot indices, and whether all 14
decoded frames match the untrimmed slots ('ALL'), only the last 6 ('tail'),
or neither."""
import os
import subprocess
from seeklib import FF, RES, WORK, probe, sequential, indices, _raw, _hashes

MODES = {
    'old': lambda s: None,
    'reset': lambda s: 'setpts=PTS-STARTPTS',
    'half': lambda s: f'setpts=PTS-{0.5 / s["fps"]:.9f}/TB',
}
COUNT = 14


def decode(path, start, vf):
    s = probe(path)
    ss = max(0.0, (start - 0.5) / s['fps'])
    v = vf(s)
    return _hashes(_raw(['-ss', f'{ss:.6f}', '-apply_cropping', 'codec', '-i', path,
                         '-map', '0:v:0', '-frames:v', str(COUNT)] + (['-vf', v] if v else [])),
                   s['width'], s['height'])


def mid_gap_avi():
    out = os.path.join(WORK, 'mid_gap.avi')
    subprocess.run([FF, '-v', 'error', '-y', '-f', 'lavfi',
                    '-i', 'testsrc2=size=320x240:rate=25:duration=12',
                    '-vf', "select='not(between(n,100,104))'", '-fps_mode', 'passthrough',
                    '-c:v', 'ffv1', out], check=True)
    return out


def run(path, starts):
    slots = sequential(path, 100000, timing='default')
    print(f'== {os.path.basename(path)}  {len(slots)} slots')
    for st in starts:
        want = indices(slots[st:st + COUNT], slots)
        cells = []
        for name, vf in MODES.items():
            got = indices(decode(path, st, vf), slots)
            verdict = 'ALL ' if got == want else ('tail' if got[-6:] == want[-6:] else 'BAD ')
            cells.append(f'{name}:{verdict} {got[:8]}')
        print(f'  {st:4d} want {want[:8]}\n       ' + '\n       '.join(cells))


if __name__ == '__main__':
    run(os.path.join(RES, 'interlaced_test.avi'), range(1, 8))
    run(mid_gap_avi(), [50, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 150])
