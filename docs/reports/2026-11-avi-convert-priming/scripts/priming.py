"""Each audio encoder's priming: its first packet's timestamp, from framecrc.

The worker runs the same probe (audio_restoration::priming_probe_args).
Prints one JSON line per encoder and input rate.
"""
import json, os, subprocess

DEPS = os.environ['VAPOURBOX_DEPS_DIR']
FF = os.path.join(DEPS, 'ffmpeg', 'ffmpeg')
CODECS = [('aac', ['-b:a', '192k']), ('libmp3lame', ['-b:a', '192k']), ('ac3', ['-b:a', '192k']),
          ('flac', []), ('pcm_s16le', [])]

for codec, extra in CODECS:
    for rate in (48000, 44100, 32000, 96000):
        r = subprocess.run([FF, '-v', 'error', '-f', 'lavfi', '-i', f'anullsrc=r={rate}:cl=stereo', '-t', '0.2',
                            '-c:a', codec, *extra, '-f', 'framecrc', '-'], capture_output=True, text=True)
        if r.returncode:
            print(json.dumps(dict(codec=codec, input_rate=rate, error=r.stderr.strip()[-200:])))
            continue
        tb = next(l.split(':', 1)[1].strip() for l in r.stdout.splitlines() if l.startswith('#tb 0:'))
        pts = int(next(l for l in r.stdout.splitlines() if l and not l.startswith('#')).split(',')[1])
        num, den = map(int, tb.split('/'))
        print(json.dumps(dict(codec=codec, input_rate=rate, time_base=tb, first_pts=pts,
                              priming_samples=max(0, -pts), priming_ms=round(max(0, -pts) * num / den * 1000, 3))))
