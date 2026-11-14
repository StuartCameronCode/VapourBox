"""Untrimmed decodes of a program stream whose clock resets (added at review).

Two copies of a 6 s MPEG-2 program stream (150 pictures each) are joined byte
for byte, so the clock goes back to its start at picture 150, as on a DVD
title whose cells the import writes back to back with a reset between them.
Each decoder reads the whole file from frame 0 and the script prints how many
pictures came out:

  grid   the grid decoder from frame 0 (-copyts + the grid filters), which the
         first version of the fix used for every source
  fixed  frame 0 of a source with a seek plan as decode_start now runs it:
         no -copyts (discontinuity correction on), the grid anchored with
         setpts=PTS-STARTPTS (SourceGrid::filters_from_first_picture)

It also compares the two decoders slot by slot on the TS/PS fixtures, where
they must agree.

-copyts switches ffmpeg's timestamp discontinuity correction off, so after the
backward reset every picture is behind the grid and `fps` drops it.
"""
import os
import subprocess

from gridlib import FF, WORK, grid_decode, grid_filters, hashes, probe, resource

W, H = 352, 288


def make():
    segs = []
    for i in (1, 2):
        out = os.path.join(WORK, f'reset_seg{i}.mpg')
        subprocess.run([FF, '-y', '-v', 'error',
                        '-f', 'lavfi', '-i', f'testsrc2=size={W}x{H}:rate=25:duration=6',
                        '-f', 'lavfi', '-i', 'sine=d=6',
                        '-c:v', 'mpeg2video', '-g', '12', '-bf', '2', '-b:v', '600k',
                        '-c:a', 'mp2', '-f', 'vob', out], check=True)
        segs.append(out)
    joined = os.path.join(WORK, 'reset_joined.mpg')
    with open(joined, 'wb') as f:
        for s in segs:
            with open(s, 'rb') as seg:
                f.write(seg.read())
    return joined


def fixed(path, p):
    f = grid_filters(p, 0)
    f[0] = 'setpts=PTS-STARTPTS'
    return hashes(['-apply_cropping', 'codec', '-i', path, '-map', '0:v:0', '-vf', ','.join(f)],
                  p['w'], p['h'])


def main():
    path = make()
    p = probe(path)
    print('joined program stream, from frame 0 | pictures out of 300')
    print(f'grid (-copyts) | {len(grid_decode(path, p))}')
    print(f'fixed          | {len(fixed(path, p))}')
    print()
    print('TS/PS fixture | grid slots | fixed slots | slots that differ')
    for name in ('soft_telecine_dvd.vob', 'pal-dvbt-fieldcoded-25i.ts', 'late_video_intra.ts'):
        path = resource(name)
        p = probe(path)
        g, x = grid_decode(path, p), fixed(path, p)
        diff = [i for i in range(min(len(g), len(x))) if g[i] != x[i]]
        print(f'{name} | {len(g)} | {len(x)} | {diff or "none"}')


if __name__ == '__main__':
    main()
