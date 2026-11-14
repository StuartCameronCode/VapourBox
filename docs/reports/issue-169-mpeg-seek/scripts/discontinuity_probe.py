"""Trimmed decodes across a backward timestamp reset (added at review).

Two copies of the same 6 s MPEG-2 program stream are joined byte for byte, so
the clock goes back to its start at picture 150, as on a VOB set whose clock
resets between cells. Each decode starts at frame N and asks for up to 150
frames, with the old plain seek and with the fix's arguments (-copyts, early
seek, absolute trim), and prints how many frames came out. Both segments hold
the same pictures, so this counts frames rather than naming them.
"""
import os
import subprocess

from seeklib import FF, FP, WORK

FPS = 25.0
WANT = 150


def make():
    segs = []
    for i in (1, 2):
        out = os.path.join(WORK, f'disc_seg{i}.mpg')
        subprocess.run([FF, '-y', '-v', 'error',
                        '-f', 'lavfi', '-i', 'testsrc2=size=352x288:rate=25:duration=6',
                        '-f', 'lavfi', '-i', 'sine=d=6',
                        '-c:v', 'mpeg2video', '-g', '12', '-bf', '2', '-b:v', '600k',
                        '-c:a', 'mp2', '-f', 'vob', out], check=True)
        segs.append(out)
    joined = os.path.join(WORK, 'disc_joined.mpg')
    with open(joined, 'wb') as f:
        for s in segs:
            f.write(open(s, 'rb').read())
    return joined


def first_pts(path, entry):
    out = subprocess.run([FP, '-v', 'error', '-select_streams', 'v:0', '-show_entries', entry,
                          '-read_intervals', '%+0.5', '-of', 'csv=p=0', path],
                         capture_output=True, text=True, check=True).stdout
    return min(float(x.strip(',')) for x in out.split() if x.strip(',') not in ('', 'N/A'))


def count(args):
    out = subprocess.run([FF, '-v', 'error'] + args +
                         ['-f', 'rawvideo', '-pix_fmt', 'gray', '-s', '44x36', '-'],
                         capture_output=True).stdout
    return len(out) // (44 * 36)


def main():
    path = make()
    cstart = float(subprocess.run([FP, '-v', 'error', '-show_entries', 'format=start_time',
                                   '-of', 'csv=p=0', path], capture_output=True, text=True,
                                  check=True).stdout.strip())
    offset = first_pts(path, 'frame=pts_time') - cstart
    preroll = 1.0  # the plan's floor; a 12-frame GOP measures less
    print('start N | frames before reset | old seek | fix (-copyts + trim)')
    for n in (100, 140, 160):
        t = (n - 0.5) / FPS + offset
        old = count(['-ss', f'{t:.6f}', '-i', path, '-map', '0:v:0', '-frames:v', str(WANT),
                     '-vf', 'setpts=PTS-STARTPTS'])
        early = t - preroll
        new = count(['-copyts'] + (['-ss', f'{early:.6f}'] if early > 0 else []) +
                    ['-i', path, '-map', '0:v:0', '-frames:v', str(WANT),
                     '-vf', f'trim=start={cstart + t:.6f},setpts=PTS-STARTPTS'])
        print(f'{n:7d} | {max(0, 150 - n):19d} | {old:8d} | {new:d}')


if __name__ == '__main__':
    main()
