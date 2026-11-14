"""The same failed seek on the sound: an input -ss under 3/23 s on an AVI whose
video has a decoder delay. Compares the samples an input-seeked audio decode
returns with an exact output-side trim of the same file.

  python3 audio_window.py [source]   (default: make_avi_variants' mpeg4_bframes_mp3.avi)"""
import os
import subprocess
import sys
import wave
from avilib import FF, WORK
import make_avi_variants

make_avi_variants.build()
src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(WORK, 'mpeg4_bframes_mp3.avi')


def wav(pre, post, name):
    out = os.path.join(WORK, name)
    err = subprocess.run([FF, '-y', '-v', 'warning', *pre, '-i', src, *post, '-map', '0:a',
                          '-c:a', 'pcm_s16le', out], capture_output=True, text=True).stderr
    w = wave.open(out)
    return w.getnframes(), w.getframerate(), 'could not seek' in err


for t in (0.0667, 0.1, 0.2, 1.0):
    n, rate, failed = wav(['-ss', f'{t}'], [], f'in_{t}.wav')
    ref, _, _ = wav([], ['-ss', f'{t}'], f'out_{t}.wav')
    print(f'in-point {t:6.4f} s: input seek {n} samples, exact trim {ref}, '
          f'{(ref - n) / rate:+.3f} s missing{"  (could not seek)" if failed else ""}')
