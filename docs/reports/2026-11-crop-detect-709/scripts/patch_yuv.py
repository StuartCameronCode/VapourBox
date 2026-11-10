"""Print the Y/U/V samples at each patch centre of the BT.709 test's files.

usage: python3 patch_yuv.py FILE...   (e.g. Tests/TestOutput/bt709_conversion/*.mkv)

Decodes the first frame to yuv444p (chroma upsampled, which is exact on a
flat patch) and prints the centre sample of each of the 4x2 patches. Used to
check that the unconverted output stores the source's own samples, and to see
how the converted one differs.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..', '..', '..'))
DEPS = os.environ.get('DEPS', os.path.join(ROOT, 'deps', 'macos-arm64'))
FF = os.path.join(DEPS, 'ffmpeg', 'ffmpeg')
FP = os.path.join(DEPS, 'ffmpeg', 'ffprobe')

for path in sys.argv[1:]:
    w, h = map(int, subprocess.check_output([FP, '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                                             'stream=width,height', '-of', 'csv=p=0', path]).decode().split(','))
    raw = subprocess.check_output([FF, '-v', 'error', '-i', path, '-frames:v', '1', '-f', 'rawvideo',
                                   '-pix_fmt', 'yuv444p', '-'])
    n = w * h
    samples = []
    for i in range(8):
        cx, cy = int(((i % 4) + 0.5) * w / 4), int(((i // 4) + 0.5) * h / 2)
        o = cy * w + cx
        samples.append((raw[o], raw[n + o], raw[2 * n + o]))
    print(f'{os.path.basename(path)} {w}x{h}: {samples}')
