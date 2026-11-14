"""The report's images, into ../img/.

  python3 images.py --before WORKER --after WORKER

01-dvbt-head.png       the DVB-T clip's first four pictures in presentation
                       order (three leading B pictures, then the I picture the
                       stream's start_time names), half size, side by side
02-mkv-f60-*.png       late_video.mkv frame 60: the source picture, and the
                       worker preview of frame 60 before and after the fix
                       (plus source frame 35, which the old preview showed)
PNG, full resolution (320x240) except 01; the HTML scales them with
nearest-neighbour."""
import os
import subprocess
import sys
from probe_lib import FF, RES, DVBT, WORK, probe, job_file, run_worker

IMG = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'img')


def frame_png(src, n, out, scale=None):
    vf = f'select=eq(n\\,{n})' + (f',scale={scale}:flags=neighbor' if scale else '')
    subprocess.run([FF, '-y', '-v', 'error', '-i', src, '-vf', vf, '-frames:v', '1',
                    '-fps_mode', 'passthrough', out], check=True)


def main():
    a = dict(zip(sys.argv[1::2], sys.argv[2::2]))
    os.makedirs(IMG, exist_ok=True)
    dvbt = os.path.join(RES, DVBT)
    subprocess.run([FF, '-y', '-v', 'error', '-i', dvbt, '-vf',
                    'select=lt(n\\,4),scale=360:288:flags=neighbor,tile=4x1',
                    '-frames:v', '1', '-fps_mode', 'passthrough',
                    os.path.join(IMG, '01-dvbt-head.png')], check=True)
    mkv = os.path.join(RES, 'late_video.mkv')
    s = probe(mkv)
    frame_png(mkv, 60, os.path.join(IMG, '02-mkv-f60-source.png'))
    frame_png(mkv, 35, os.path.join(IMG, '02-mkv-f35-source.png'))
    for side in ('before', 'after'):
        r = run_worker(a[f'--{side}'], job_file(mkv, s, os.path.join(WORK, 'x.mkv')),
                       '--preview', '--frame', '60')
        with open(os.path.join(IMG, f'02-mkv-f60-preview-{side}.png'), 'wb') as f:
            f.write(r.stdout)
    print('images in', os.path.abspath(IMG))


if __name__ == '__main__':
    main()
