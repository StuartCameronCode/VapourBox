"""Before / after on the two reset fixtures (task #21).

For the original (clock back at picture 150) and the worker's joined copy:
- ffprobe's durations and the count the app derives from them;
- a sequential constant-rate decode with and without -copyts;
- #14's seek decoder (-copyts, -ss a preroll early, absolute trim, PTS
  reset), from frame N, asking for 101 frames: how many came out and which
  pictures of the original (sequential decode) the first and last are.
"""
from resetlib import FF, FIXTURES, RES, joined_copy, luma_md5s, probe
import os

FPS = 25.0
PREROLL = 1.5   # what seek_plan_from_probe gives these GOPs, rounded up
WANT = 101


def info(path):
    j = probe(path, 'format=duration,start_time:stream=codec_type,start_time,duration')
    v = next(s for s in j['streams'] if s['codec_type'] == 'video')
    return (float(j['format']['duration']), float(v.get('duration', 'nan')),
            float(j['format']['start_time']), float(v['start_time']))


def main():
    for name in FIXTURES:
        src = os.path.join(RES, name)
        ref = luma_md5s(['-i', src, '-map', '0:v:0'])
        index = {}
        for i, m in enumerate(ref):
            index.setdefault(m, i)
        print(f'== {name}: {len(ref)} pictures in a sequential decode')
        for label, path in (('original', src), ('joined copy', joined_copy(src))):
            fdur, vdur, cstart, vstart = info(path)
            seq = len(luma_md5s(['-i', path, '-map', '0:v:0']))
            seq_copyts = len(luma_md5s(['-copyts', '-i', path, '-map', '0:v:0']))
            print(f'  {label}: format duration {fdur:.3f} s, video {vdur:.3f} s '
                  f'-> app count ~{round(vdur * FPS)}; sequential decode {seq}, '
                  f'with -copyts {seq_copyts}')
            offset = vstart - cstart
            for n in (0, 100, 140, 149, 150, 151, 160, 290):
                t = n / FPS + offset
                ss = max(t - PREROLL, 0)
                got = luma_md5s(['-copyts', '-ss', f'{ss:.6f}', '-i', path, '-map', '0:v:0',
                                 '-vf', f'trim=start={cstart + t:.6f},setpts=PTS-STARTPTS',
                                 '-frames:v', str(WANT)])
                first = index.get(got[0], '?') if got else '-'
                last = index.get(got[-1], '?') if got else '-'
                expect = min(WANT, len(ref) - n)
                print(f'    from {n:3d}: {len(got):3d} frames (want {expect}), '
                      f'first is picture {first}, last {last}')


if __name__ == '__main__':
    main()
