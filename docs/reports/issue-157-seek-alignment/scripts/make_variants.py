"""Build the source variants the probe runs on top of the committed fixtures,
into $SEEK_WORK/variants. Each is testsrc2 (every frame differs), so a picture
identifies its frame unambiguously. Not committed: rebuild with this script."""
import os
import subprocess
from seeklib import FF, WORK

OUT = os.path.join(WORK, 'variants')
os.makedirs(OUT, exist_ok=True)

SRC = ['-f', 'lavfi', '-i']
AUDIO = ['-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=6']

VARIANTS = {
    # Matroska, time base 1/1000, 25 fps H.264 with B-frames.
    'mkv_25.mkv': [*SRC, 'testsrc2=size=320x240:rate=25:duration=6', *AUDIO,
                   '-map', '0:v', '-map', '1:a', '-c:v', 'libx264', '-preset', 'veryfast',
                   '-g', '25', '-bf', '2', '-pix_fmt', 'yuv420p', '-c:a', 'aac'],
    # A PAL DVD-style MPEG-2 program stream: open GOPs, B-frames, MP2 audio.
    'dvd_pal.mpg': [*SRC, 'testsrc2=size=720x576:rate=25:duration=6', *AUDIO,
                    '-map', '0:v', '-map', '1:a', '-c:v', 'mpeg2video', '-b:v', '6M',
                    '-g', '12', '-bf', '2', '-flags', '-cgop', '-pix_fmt', 'yuv420p',
                    '-c:a', 'mp2', '-f', 'vob'],
    # MPEG-TS, time base 1/90000, video and audio starting together.
    'ts_25_video_first.ts': [*SRC, 'testsrc2=size=720x576:rate=25:duration=6', *AUDIO,
                             '-map', '0:v', '-map', '1:a', '-c:v', 'libx264',
                             '-preset', 'veryfast', '-g', '25', '-bf', '2',
                             '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-f', 'mpegts'],
    # 29.97 ProRes in MOV with a 1/11988 video time base, like the user's clip.
    'prores_11988.mov': [*SRC, 'testsrc2=size=720x480:rate=30000/1001:duration=6', *AUDIO,
                         '-map', '0:v', '-map', '1:a', '-c:v', 'prores_ks', '-profile:v', '0',
                         '-c:a', 'pcm_s16le', '-video_track_timescale', '11988'],
    # Noisy sources for the noise score (temporal noise, sigma ~6 levels), in
    # two affected time bases. Lightly compressed so the noise survives.
    'noisy_prores_11988.mov': [*SRC, 'testsrc2=size=720x480:rate=30000/1001:duration=6,'
                               'noise=alls=10:allf=t', *AUDIO, '-map', '0:v', '-map', '1:a',
                               '-c:v', 'prores_ks', '-profile:v', '3', '-c:a', 'pcm_s16le',
                               '-video_track_timescale', '11988'],
    'noisy_h264_2997.mp4': [*SRC, 'testsrc2=size=720x480:rate=30000/1001:duration=6,'
                            'noise=alls=10:allf=t', *AUDIO, '-map', '0:v', '-map', '1:a',
                            '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '8',
                            '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-video_track_timescale', '2997'],
}


def build():
    paths = []
    for name, args in VARIANTS.items():
        path = os.path.join(OUT, name)
        if not os.path.exists(path):
            subprocess.run([FF, '-y', '-v', 'error', *args, path], check=True)
        paths.append(path)
    return paths


if __name__ == '__main__':
    for p in build():
        print(p)
