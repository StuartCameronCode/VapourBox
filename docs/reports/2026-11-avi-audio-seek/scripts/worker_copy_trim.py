"""The worker end to end: a stream-copy trim (Passthrough, FFV1) of the chirp
copy of avi_h264_bframes.avi, from frames 1-3 (the fix's window) and 20 (the
control), to MKV and AVI. Reports each stream's start, the frame count (of
the trim's END - start + 1) and where the sound sits against the picture (+ = sound late).

Needs a built worker (cargo build in worker/) that finds the deps bundle:
a debug build searches upward for deps/, as in a normal checkout."""
import json
import os
import platform
import subprocess
import uuid
from audiolib import variants, probe, work, samples, find, RATE, FPS, REPO

EXE = '.exe' if platform.system() == 'Windows' else ''
WORKER = next(p for p in (os.path.join(REPO, 'worker', 'target', b, 'vapourbox-worker' + EXE)
                          for b in ('debug', 'release')) if os.path.exists(p))
END = 61

v = variants()
src, _ = samples([], v['chirp'], [])
print('| in-point | container | video start | audio start | frames | sound vs picture |')
print('|---|---|---|---|---|---|')
for start in (1, 2, 3, 20):
    for ext in ('mkv', 'avi'):
        out = work(f'worker_{start}.{ext}')
        job = {
            'id': str(uuid.uuid4()), 'inputPath': v['chirp'], 'outputPath': out,
            'qtgmcParameters': {'enabled': False},
            'processingPipeline': {'deinterlace': {'enabled': False}},
            'encodingSettings': {'container': ext, 'codec': 'ffv1', 'audioMode': 'passthrough'},
            'inputFrameRate': FPS, 'inputWidth': 320, 'inputHeight': 240,
            'inputPixelFormat': 'yuv420p', 'startFrame': start, 'endFrame': END,
            'totalFrames': END - start + 1,
        }
        cfg = work('job.json')
        with open(cfg, 'w') as f:
            json.dump(job, f)
        if os.path.exists(out):
            os.remove(out)
        subprocess.run([WORKER, '--config', cfg], capture_output=True, check=True)
        j = probe(out, '-count_packets', '-show_entries', 'stream=codec_type,start_time,nb_read_packets')
        s = {x['codec_type']: x for x in j['streams']}
        vs, as_ = float(s['video']['start_time']), float(s['audio']['start_time'])
        got, _ = samples([], out, [], af='aresample=first_pts=0')
        k = find(got, src)
        lag = None if k is None else round(start / FPS * RATE) - (round(vs * RATE) + k)
        print(f'| {start} | {ext} | {vs:.3f} | {as_:.3f} | {s["video"]["nb_read_packets"]} of {END - start + 1} | '
              + ('not found' if lag is None else f'{lag:+d} samples ({lag / RATE * 1000:+.1f} ms)') + ' |')
