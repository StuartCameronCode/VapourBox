"""§4-§5: the worker itself, before and after. For each fixture, every pass
off, lossless FFV1 out:

  untrimmed  the whole source at the frame count the app sends (that app's
             rule), each output frame named against the timestamp timeline
  trims      a 12-frame trim from each start, same check
  telecine   the Soft Telecine method, untrimmed: film frames missing,
             frames out, output rate

  python3 worker_probe.py --worker PATH [--app before|after] [--json out.json]
"""
import json
import os
import subprocess
import sys
import uuid
from gridlib import FF, FP, WORK, resource, probe, stored, timeline, name, hashes

CASES = {
    'interlaced_test.avi': [1, 3, 4, 5, 40],
    'null_frames_mid.avi': [98, 100, 102, 105],
    'soft_telecine_test.mkv': [1, 10, 41],
    'soft_telecine_dvd.vob': [3, 10, 43],
    'soft_telecine_dvd.mkv': [3, 10, 43],
    'small_clip.mp4': [10, 41],
    'seek_timebase_2997.mov': [10, 41],
    'late_video.mkv': [10, 41],
}
TELECINE = ['soft_telecine_test.mkv', 'soft_telecine_dvd.vob', 'soft_telecine_dvd.mkv']


def ffprobe(args):
    return json.loads(subprocess.run([FP, '-v', 'error', *args, '-of', 'json'],
                                     capture_output=True, text=True).stdout)


def app_count(path, p, app):
    """FieldOrderDetector's count: nb_frames; else the stream's duration; else
    (after this fix) the last picture's slot + 1, (before) the container's
    duration less the video start offset."""
    j = ffprobe(['-select_streams', 'v:0', '-show_entries', 'stream=nb_frames,duration:format=duration', path])
    s, fmt = j['streams'][0], j['format']
    rate = float(p['rate'])
    if s.get('nb_frames') not in (None, 'N/A'):
        return int(s['nb_frames'])
    if s.get('duration') not in (None, 'N/A'):
        return round(float(s['duration']) * rate)  # + open-GOP leading pictures: none here
    cd = float(fmt['duration'])
    if app == 'after':
        pk = ffprobe(['-select_streams', 'v:0', '-show_entries', 'packet=pts_time',
                      '-read_intervals', f'{max(0.0, cd - 3):.3f}%', path])
        last = max(float(x['pts_time']) for x in pk['packets'] if 'pts_time' in x)
        return round((last - p['origin']) * rate) + 1
    return round((cd - p['offset']) * rate)


def run_job(worker, path, p, total, **extra):
    out = os.path.join(WORK, f'out_{uuid.uuid4().hex}.mkv')
    deint = extra.pop('deinterlace', {'enabled': False})
    j = {'id': str(uuid.uuid4()), 'inputPath': path, 'outputPath': out,
         'qtgmcParameters': deint, 'processingPipeline': {'deinterlace': deint},
         'encodingSettings': {'codec': 'ffv1', 'container': 'mkv', 'audioMode': 'none'},
         'detectedFieldOrder': 'progressive', 'inputFrameRate': float(p['rate']),
         'inputWidth': p['w'], 'inputHeight': p['h'], 'totalFrames': total}
    j.update(extra)
    cfg = os.path.join(WORK, f'job_{j["id"]}.json')
    json.dump(j, open(cfg, 'w'))
    r = subprocess.run([worker, '--config', cfg], capture_output=True)
    if r.returncode or not os.path.exists(out):
        return None, (r.stderr.decode(errors='replace') + r.stdout.decode(errors='replace'))[-300:] or 'failed'
    pp = probe(out)
    got = hashes(['-i', out, '-map', '0:v:0', '-fps_mode', 'passthrough'], pp['w'], pp['h'])
    rate = ffprobe(['-select_streams', 'v:0', '-show_entries', 'stream=r_frame_rate', out])['streams'][0]['r_frame_rate']
    os.remove(out)
    return (got, rate), None


def main():
    args = sys.argv[1:]
    worker = args[args.index('--worker') + 1]
    app = args[args.index('--app') + 1] if '--app' in args else 'after'
    results = []
    for f, starts in CASES.items():
        path = resource(f)
        p = probe(path)
        st = stored(path, p)
        tl = timeline(path, p)
        ref = [st[k] for k in tl]
        total = app_count(path, p, app)
        row = {'file': f, 'app_count': total, 'slots': len(ref)}
        res, err = run_job(worker, path, p, total)
        if err:
            row['untrimmed_error'] = err
        else:
            got = res[0]
            row['untrimmed_frames'] = len(got)
            row['untrimmed_exact'] = got == ref[:len(got)] and len(got) == len(ref)
            row['untrimmed_head'] = name(got[:8], st)
            row['untrimmed_slots_wrong'] = sum(a != b for a, b in zip(got, ref)) + abs(len(got) - len(ref))
        row['trims'] = {}
        for n in starts:
            end = min(n + 11, len(ref) - 1)
            res, err = run_job(worker, path, p, end - n + 1, startFrame=n, endFrame=end)
            if err:
                row['trims'][n] = 'error'
                continue
            got = res[0]
            row['trims'][n] = {'exact': got == ref[n:end + 1], 'head': name(got[:6], st),
                               'want': name(ref[n:n + 6], st)}
        if f in TELECINE:
            res, err = run_job(worker, path, p, total,
                               deinterlace={'enabled': True, 'method': 'softTelecine'})
            if err:
                row['telecine'] = err
            else:
                got, rate = res
                row['telecine'] = {'frames_out': len(got), 'rate': rate,
                                   'film_missing': [i for i, h in enumerate(st) if h not in got],
                                   'repeats_left': len(got) - len(set(got))}
        results.append(row)
        trims = ' '.join(f"{n}:{'ok' if isinstance(t, dict) and t['exact'] else 'WRONG'}"
                         for n, t in row['trims'].items())
        print(f"{f:26s} app {total:4d} slots {len(ref):4d}  untrimmed "
              f"{'exact' if row.get('untrimmed_exact') else 'WRONG (' + str(row.get('untrimmed_slots_wrong')) + ' slots)'} "
              f"head {row.get('untrimmed_head')}  trims {trims}")
        for n, t in row['trims'].items():
            if isinstance(t, dict) and not t['exact']:
                print(f"     trim {n}: got {t['head']} want {t['want']}")
        if 'telecine' in row:
            t = row['telecine']
            if isinstance(t, dict):
                print(f"     Soft Telecine: {t['frames_out']} out at {t['rate']}, "
                      f"{len(t['film_missing'])} film frames missing {t['film_missing'][:8]}, "
                      f"{t['repeats_left']} repeats left")
            else:
                print(f"     Soft Telecine: error {t}")
    if '--json' in args:
        json.dump(results, open(args[args.index('--json') + 1], 'w'), indent=1)


if __name__ == '__main__':
    main()
