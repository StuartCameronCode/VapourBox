"""Build the AVI variants the probes run on, into $AVI_SEEK_WORK (they are not
committed; the two committed fixtures come from
Tests/TestResources/generate_avi_seek_test.sh). Each is testsrc2 at 29.97 fps
(every frame differs) unless named otherwise, 90-100 frames.

  python3 make_avi_variants.py      -> prints the paths"""
import os
import subprocess
from avilib import FF, WORK

SRC = 'testsrc2=size=720x480:rate=30000/1001:duration=3.003'
VARIANTS = {
    # name: (input options, encoder options)
    'huffyuv_ntsc.avi': ([], ['-c:v', 'huffyuv']),
    'dv_ntsc.avi': ([], ['-pix_fmt', 'yuv411p', '-c:v', 'dvvideo']),
    'mpeg4_bframes_ntsc.avi': ([], ['-c:v', 'mpeg4', '-bf', '2', '-g', '30', '-q:v', '4']),
    'h264_bframes_ntsc.avi': ([], ['-c:v', 'libx264', '-bf', '2', '-g', '30', '-pix_fmt', 'yuv420p']),
    'mpeg2_bframes_pal.avi': (['-r', '25'], ['-c:v', 'mpeg2video', '-bf', '2', '-g', '15', '-q:v', '4']),
    'h264_bframes_ntsc.mkv': ([], ['-c:v', 'libx264', '-bf', '2', '-g', '30', '-pix_fmt', 'yuv420p']),
    'ffv1_ntsc.mkv': ([], ['-c:v', 'ffv1']),
}
SRC_PAL = 'testsrc2=size=720x576:rate=25:duration=4'


def build():
    paths = []
    for name, (pre, enc) in VARIANTS.items():
        out = os.path.join(WORK, name)
        src = SRC_PAL if 'pal' in name else SRC
        if not os.path.exists(out):
            subprocess.run([FF, '-y', '-v', 'error', '-f', 'lavfi', '-i', src, *enc, out], check=True)
        paths.append(out)
    # The audio probe's source: MPEG-4 with B-frames and an MP3 tone.
    out = os.path.join(WORK, 'mpeg4_bframes_mp3.avi')
    if not os.path.exists(out):
        subprocess.run([FF, '-y', '-v', 'error', '-f', 'lavfi', '-i', SRC,
                        '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=4',
                        '-c:v', 'mpeg4', '-bf', '2', '-g', '30', '-q:v', '4',
                        '-c:a', 'libmp3lame', '-b:a', '128k', '-shortest', out], check=True)
    return paths


if __name__ == '__main__':
    for p in build():
        print(p)
