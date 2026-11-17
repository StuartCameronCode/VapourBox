#!/usr/bin/env python3
"""Task #56 F8: the preview's YUV -> RGB conversion, 8-bit vs 10-bit 4:2:0.

One picture with noisy chroma (testsrc2 + temporal noise on every plane, made
at 4:4:4 and then subsampled with the same filter at both depths), stored as
8-bit and as 10-bit 4:2:0. Each is converted to 16-bit RGB the way the
worker's preview does (`scale=in_range=tv:out_range=pc`), without and with
`flags=accurate_rnd+full_chroma_int`, and the two depths are compared: mean
|8-bit - 10-bit| per RGB sample, in 8-bit levels. The 10-bit picture is the
8-bit one plus its low bits, so a conversion that treats both alike gives a
difference near the 8-bit rounding (~0.3 levels or less).

    preview_chroma.py --ffmpeg <deps/.../ffmpeg/ffmpeg>

Pure Python + ffmpeg, no NumPy. Limits: one synthetic picture, one frame;
the app's before frame (a JPEG that stays YUV) is not measured here.
"""
import argparse
import array
import subprocess

W, H = 352, 240


def rgb48(ffmpeg, pix_fmt, flags):
    src = (f'testsrc2=size={W}x{H}:rate=25,format=yuv444p,'
           f'noise=alls=20:allf=t+u:all_seed=56,format={pix_fmt}')
    opts = 'in_range=tv:out_range=pc' + (':flags=' + flags if flags else '')
    out = subprocess.run(
        [ffmpeg, '-v', 'error', '-f', 'lavfi', '-i', src, '-frames:v', '1',
         '-vf', 'scale=' + opts + ',format=rgb48le', '-f', 'rawvideo', '-'],
        capture_output=True, check=True).stdout
    a = array.array('H')
    a.frombytes(out)
    return a


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ffmpeg', required=True)
    a = ap.parse_args()
    print('conversion                               mean |8-bit - 10-bit|, 8-bit levels   max')
    for name, flags in (('scale (before task #56)', ''),
                        ('scale, accurate_rnd+full_chroma_int', 'accurate_rnd+full_chroma_int')):
        p8 = rgb48(a.ffmpeg, 'yuv420p', flags)
        p10 = rgb48(a.ffmpeg, 'yuv420p10le', flags)
        diffs = [abs(x - y) / 257 for x, y in zip(p8, p10)]
        print('%-40s %8.3f %30.1f' % (name, sum(diffs) / len(diffs), max(diffs)))


if __name__ == '__main__':
    main()
