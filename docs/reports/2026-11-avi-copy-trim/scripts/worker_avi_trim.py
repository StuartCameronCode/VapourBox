"""Table 2: the worker end to end. A Passthrough trim (FFV1) of each fixture
from frames 20, 100 and 251, to MKV and AVI; and the chirp copy of
avi_h264_bframes.avi (a decoder delay, one keyframe; task 22) from frames
1-3 and 20, as PCM and as MP3. Reports the output's audio codec(s), where the in-point's sound
plays against the first picture (+ = late) and, for PCM, the largest sample
difference from the source.

Needs a built worker (cargo build in worker/) that finds the deps bundle."""
import json
import os
import platform
import subprocess
import uuid
from cutlib import (fixtures, ff, probe, work, decode, lag, exact_from, video_start, codec, sample_rate,
                    FPS, FRAMES, RES)

EXE = '.exe' if platform.system() == 'Windows' else ''
WORKER = next(p for p in (os.path.join(os.path.dirname(RES), '..', 'worker', 'target', b, 'vapourbox-worker' + EXE)
                          for b in ('debug', 'release')) if os.path.exists(p))


def run(source, start, end, ext):
    out = work(f'worker_{start}.{ext}')
    job = {
        'id': str(uuid.uuid4()), 'inputPath': source, 'outputPath': out,
        'qtgmcParameters': {'enabled': False},
        'processingPipeline': {'deinterlace': {'enabled': False}},
        'encodingSettings': {'container': ext, 'codec': 'ffv1', 'audioMode': 'passthrough'},
        'inputFrameRate': FPS, 'inputWidth': 320, 'inputHeight': 240,
        'inputPixelFormat': 'yuv420p', 'startFrame': start, 'endFrame': end,
        'totalFrames': end - start + 1,
    }
    cfg = work('job.json')
    with open(cfg, 'w') as f:
        json.dump(job, f)
    if os.path.exists(out):
        os.remove(out)
    r = subprocess.run([WORKER, '--config', cfg], capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(out):
        raise RuntimeError(r.stdout[-3000:] + r.stderr[-3000:])
    return out


def rows(name, source, starts, end):
    streams = len(probe(source, '-select_streams', 'a', '-show_entries', 'stream=index')['streams'])
    rates = [sample_rate(source, k) for k in range(streams)]
    refs = [(decode(source, k), decode(source, k, rates[k])) for k in range(streams)]
    for start in starts:
        for ext in ('mkv', 'avi'):
            out = run(source, start, end, ext)
            vs = video_start(out)
            for k in range(streams):
                l, peak = lag(refs[k][0], decode(out, k), start, vs)
                c = codec(out, k)
                diff = ''
                if c.startswith('pcm'):
                    diff = f'{exact_from(refs[k][1], decode(out, k, rates[k]), start, vs, rates[k]):.1e}'
                ls = 'not found' if l is None else f'{l * 1000:+.1f} ms'
                label = name if streams == 1 else f'{name}, stream {k}'
                print(f'| {label} | {start} | {ext} | {c} | {ls} | {peak:.3f} | {diff} |', flush=True)


print('| source | in-point | container | audio codec | sound vs picture | peak | max diff from in-point |')
print('|---|---|---|---|---|---|---|')
for name, path in fixtures().items():
    rows(name, path, FRAMES, 340)

# Task 22's case: the delayed AVI's picture, stream-copied, with a chirp
# (the committed fixture's sine cannot show an offset).
chirp = work('chirp_h264_bframes.avi')
if not os.path.exists(chirp):
    ff('-i', os.path.join(RES, 'avi_h264_bframes.avi'), '-f', 'lavfi', '-i',
       'aevalsrc=0.5*sin(2*PI*(200*t+300*t*t)):s=32000:d=3.003', '-map', '0:v', '-c:v', 'copy',
       '-map', '1:a', '-c:a', 'pcm_s16le', chirp)
rows('avi_h264_bframes.avi chirp (PCM 32 kHz)', chirp, (1, 2, 3, 20), 61)

# Review correction: the same picture with an MP3 chirp. Frames 1-3 read
# their sound from the NUT copy, which counts MP3 in samples, not packets.
mp3 = work('mp3_h264_bframes.avi')
if not os.path.exists(mp3):
    ff('-i', os.path.join(RES, 'avi_h264_bframes.avi'), '-f', 'lavfi', '-i',
       'aevalsrc=0.5*sin(2*PI*(200*t+300*t*t)):s=44100:d=3.003', '-map', '0:v', '-c:v', 'copy',
       '-map', '1:a', '-c:a', 'libmp3lame', '-b:a', '192k', mp3)
rows('avi_h264_bframes.avi chirp (MP3 44.1 kHz)', mp3, (1, 2, 3, 20), 61)
