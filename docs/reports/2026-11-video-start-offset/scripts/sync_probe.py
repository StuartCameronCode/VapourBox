"""Are sound and picture in step in the output? Before and after the fix.

  python3 sync_probe.py --before WORKER --after WORKER [--json out.json]

Every late-video fixture has a white frame at source frames 25 and 75 and a
1 kHz beep at the same moments on its audio. The probe encodes it through the
worker (every pass off) and reads the OUTPUT file's own timestamps: the
presentation time of each white frame, and of each beep's first loud sample
(a frame's PTS plus its sample offset). Sync = beep - flash; 0 is right.
A stream that starts late in the output counts, as a player would play it.

Cases: untrimmed with the sound copied, untrimmed with Audio Restoration (a
limiter only), untrimmed with "start the sound with the picture" (after only),
trimmed 30..89 copied and restored, and the MP4 and AVI outputs.
The workers must be debug builds."""
import json
import os
import struct
import subprocess
import sys
from probe_lib import FF, FP, RES, WORK, FIXTURES, probe, job_file, run_worker

LOUD = 0.3


def frames(path, kind, entries):
    out = subprocess.run([FP, '-v', 'error', '-select_streams', f'{kind}:0', '-show_entries',
                          f'frame={entries}', '-of', 'json', path],
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)['frames']


def flash_times(path):
    s = probe(path)
    w, h = s['width'], s['height']
    pts = [float(f['pts_time']) for f in frames(path, 'v', 'pts_time')]
    data = subprocess.run([FF, '-v', 'quiet', '-i', path, '-map', '0:v:0', '-fps_mode', 'passthrough',
                           '-f', 'rawvideo', '-pix_fmt', 'gray', '-'], capture_output=True).stdout
    n = w * h
    means = [sum(data[i:i + n:97]) / len(range(0, n, 97)) for i in range(0, len(data) - n + 1, n)]
    hits = [pts[i] for i, m in enumerate(means) if m > 200 and i < len(pts)]
    return hits, (pts[0] if pts else None), len(means)


def beep_times(path):
    fr = frames(path, 'a', 'pts_time,nb_samples')
    if not fr:
        return [], None
    rate = int(json.loads(subprocess.run(
        [FP, '-v', 'error', '-select_streams', 'a:0', '-show_entries', 'stream=sample_rate',
         '-of', 'json', path], capture_output=True, text=True, check=True).stdout)['streams'][0]['sample_rate'])
    data = subprocess.run([FF, '-v', 'quiet', '-i', path, '-map', '0:a:0', '-ac', '1',
                           '-f', 'f32le', '-'], capture_output=True).stdout
    samples = struct.unpack(f'<{len(data) // 4}f', data)
    beeps, pos, last = [], 0, -10.0
    for f in fr:
        count, t0 = int(f['nb_samples']), float(f['pts_time'])
        for k in range(count):
            i = pos + k
            # An onset: loud after 5 ms of quiet. The first 5 ms of a stream
            # never count: a copied track can start inside a beep (copy mode
            # cuts on a packet boundary), and that tail is not an onset.
            q = rate // 200
            if (i >= q and i < len(samples) and abs(samples[i]) > LOUD
                    and max(abs(x) for x in samples[i - q:i]) < LOUD):
                t = t0 + k / rate
                if t - last > 0.5:
                    beeps.append(t)
                last = t
        pos += count
    return beeps, float(fr[0]['pts_time'])


CASES = [
    ('untrimmed, sound copied', {}, 'mkv'),
    ('untrimmed, Audio Restoration (limiter)', {'audio': {'enabled': True, 'limiter': True}}, 'mkv'),
    ('untrimmed, start the sound with the picture', {'audio': {'enabled': True, 'startWithPicture': True}}, 'mkv'),
    ('trimmed 30..89, sound copied', {'trim': True}, 'mkv'),
    ('trimmed 30..89, Audio Restoration (limiter)', {'trim': True, 'audio': {'enabled': True, 'limiter': True}}, 'mkv'),
]
EXTRA = [('late_video.mp4', 'untrimmed, sound copied, MP4 output', {}, 'mp4'),
         ('late_video_intra.ts', 'untrimmed, sound copied, AVI output', {}, 'avi')]


def run_case(worker, src, case, container):
    s = probe(src)
    out = os.path.join(WORK, f'sync.{container}')
    if os.path.exists(out):
        os.remove(out)
    codec = 'libx264' if container == 'mp4' else 'ffv1'
    extra = {'encodingSettings': {'codec': codec, 'container': container, 'audioMode': 'passthrough',
                                  'quality': 10}}
    pipe = {'deinterlace': {'enabled': False}}
    if 'audio' in case:
        pipe['audio'] = case['audio']
    extra['processingPipeline'] = pipe
    if case.get('trim'):
        extra.update(startFrame=30, endFrame=89, totalFrames=60)
    else:
        extra['totalFrames'] = 100
    r = run_worker(worker, job_file(src, s, out, **extra))
    if r.returncode or not os.path.exists(out):
        return {'error': r.stderr.decode(errors='replace')[-300:]}
    flashes, vstart, nframes = flash_times(out)
    beeps, astart = beep_times(out)
    # Each flash against the first beep from 0.5 s before it to 1.5 s after.
    # Beeps are 2 s apart and the fault being looked for is late sound, so the
    # window is unambiguous; a copied track can also keep a little sound from
    # before the cut (copy mode cuts on a packet boundary), whose beep has no
    # flash and must not be paired.
    pairs = []
    for f in flashes:
        near = [b for b in beeps if -0.5 <= b - f <= 1.5]
        pairs.append(round(near[0] - f, 4) if near else None)
    return {'video_start': vstart, 'audio_start': astart, 'frames': nframes,
            'flashes': flashes, 'beeps': beeps, 'sync': pairs}


def main():
    args = sys.argv[1:]
    workers, out = {}, None
    while args and args[0].startswith('--'):
        if args[0] in ('--before', '--after'):
            workers[args[0][2:]] = args[1]
        elif args[0] == '--json':
            out = args[1]
        args = args[2:]
    results = []
    plan = [(f, name, case, c) for f in FIXTURES for name, case, c in CASES]
    plan += [(f, name, case, c) for f, name, case, c in EXTRA]
    for f, name, case, container in plan:
        src = os.path.join(RES, f)
        row = {'source': f, 'case': name}
        for side, worker in workers.items():
            if side == 'before' and 'startWithPicture' in str(case):
                continue
            row[side] = run_case(worker, src, case, container)
        results.append(row)
        print(f'== {f}: {name}')
        for side in workers:
            v = row.get(side)
            if v is None:
                continue
            if 'error' in v:
                print(f'  {side}: ERROR {v["error"]}')
                continue
            print(f"  {side}: sync {v['sync']} s (video from {v['video_start']:.3f} s, "
                  f"audio from {v['audio_start']:.3f} s, {v['frames']} frames)")
    if out:
        with open(out, 'w') as fh:
            json.dump(results, fh, indent=1)


if __name__ == '__main__':
    main()
