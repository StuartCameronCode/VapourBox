"""Build the uncommitted variants into $SEEK_WORK/variants (testsrc2: every
frame differs, so a picture names its frame). The committed fixtures come from
Tests/TestResources/generate_mpeg_seek_test.sh."""
import os
import subprocess
from seeklib import FF, WORK

OUT = os.path.join(WORK, 'variants')
os.makedirs(OUT, exist_ok=True)
SRC = ['-f', 'lavfi', '-i']
AUDIO = ['-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=6']

VARIANTS = {
    # Full-size PAL DVD program stream, as in the #157 report.
    'dvd_pal.mpg': [*SRC, 'testsrc2=size=720x576:rate=25:duration=6', *AUDIO,
                    '-map', '0:v', '-map', '1:a', '-c:v', 'mpeg2video', '-b:v', '6M',
                    '-g', '12', '-bf', '2', '-flags', '-cgop', '-pix_fmt', 'yuv420p',
                    '-c:a', 'mp2', '-f', 'vob'],
    # H.264 TS, video and audio together (the muxer still adds 1.4 s).
    'ts_25_video_first.ts': [*SRC, 'testsrc2=size=720x576:rate=25:duration=6', *AUDIO,
                             '-map', '0:v', '-map', '1:a', '-c:v', 'libx264',
                             '-preset', 'veryfast', '-g', '25', '-bf', '2',
                             '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-f', 'mpegts'],
    # Indexed control.
    'mkv_25.mkv': [*SRC, 'testsrc2=size=320x240:rate=25:duration=6', *AUDIO,
                   '-map', '0:v', '-map', '1:a', '-c:v', 'libx264', '-preset', 'veryfast',
                   '-g', '25', '-bf', '2', '-pix_fmt', 'yuv420p', '-c:a', 'aac'],
    # For the cost: 30 s of 1080p H.264 in TS with 2 s GOPs.
    'hd_gop50.ts': [*SRC, 'testsrc2=size=1920x1080:rate=25:duration=30', '-c:v', 'libx264',
                    '-preset', 'veryfast', '-g', '50', '-bf', '3', '-pix_fmt', 'yuv420p',
                    '-f', 'mpegts'],
}
# Raw elementary streams, cut from the above (out of scope; measured to say so).
RAW = {
    'raw.m2v': ('dvd_pal.mpg', ['-map', '0:v', '-c', 'copy', '-f', 'mpeg2video']),
    'raw.h264': ('mkv_25.mkv', ['-map', '0:v', '-c', 'copy', '-bsf:v', 'h264_mp4toannexb', '-f', 'h264']),
}


def build():
    paths = {}
    for name, args in VARIANTS.items():
        path = os.path.join(OUT, name)
        if not os.path.exists(path):
            subprocess.run([FF, '-y', '-v', 'error', *args, path], check=True)
        paths[name] = path
    for name, (src, args) in RAW.items():
        path = os.path.join(OUT, name)
        if not os.path.exists(path):
            subprocess.run([FF, '-y', '-v', 'error', '-i', paths[src], *args, path], check=True)
        paths[name] = path
    return paths


if __name__ == '__main__':
    for p in build().values():
        print(p)
