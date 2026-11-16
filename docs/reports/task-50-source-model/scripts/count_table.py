#!/usr/bin/env python3
"""Frame counts of every committed fixture, four ways (task #50 report).

  model   the worker's SourceModel count (the app's rule, ported)
  nb      the container's stored count (ffprobe nb_frames)
  read    ffprobe -count_frames (what a job without totalFrames used)
  grid    pictures the worker's untrimmed decode produces: its frame-0
          filters (source_decode::decode_start) run through ffmpeg to null

Usage: count_table.py <worker> <deps-platform-dir>   (writes JSON to stdout)
"""
import json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.join(HERE, '..', '..', '..', '..', 'Tests', 'TestResources')
worker, deps = sys.argv[1], sys.argv[2]
ffmpeg = os.path.join(deps, 'ffmpeg', 'ffmpeg')
ffprobe = os.path.join(deps, 'ffmpeg', 'ffprobe')
EXT = ('mp4', 'mkv', 'mov', 'avi', 'ts', 'mpg', 'vob')


def probe(args, path):
    out = subprocess.run([ffprobe, '-v', 'error', '-select_streams', 'v:0'] + args + [path],
                         capture_output=True, text=True).stdout
    v = out.strip().split('\n')[0].strip().rstrip(',')
    return int(v) if v.isdigit() else None


def grid_count(path, m):
    g, plan = m['video'].get('sourceGrid'), m['video'].get('seekPlan')
    if g is None:
        return None
    fps = f"fps={g['rateNum']}/{g['rateDen']}"
    if plan is not None:  # frame 0 of a TS/PS: no -copyts, anchored at STARTPTS
        pre, vf = [], f"setpts=PTS-STARTPTS,{fps},trim=start_pts=0,setpts=PTS-STARTPTS"
    else:
        pre, vf = ['-copyts'], f"setpts=PTS-{g['origin']:.6f}/TB,{fps},trim=start_pts=0,setpts=PTS-STARTPTS"
    r = subprocess.run([ffmpeg, '-v', 'error'] + pre + ['-apply_cropping', 'codec', '-i', path,
                        '-map', '0:v:0', '-vf', vf, '-f', 'framecrc', '-'],
                       capture_output=True, text=True)
    return sum(1 for l in r.stdout.splitlines() if l and not l.startswith('#'))


rows = []
for f in sorted(os.listdir(RES)):
    if f.rsplit('.', 1)[-1] not in EXT:
        continue
    path = os.path.join(RES, f)
    m = json.loads(subprocess.run([worker, '--probe-source', path], capture_output=True, text=True).stdout)
    rows.append({
        'file': f,
        'model': m['video']['frameCount'],
        'nb': probe(['-show_entries', 'stream=nb_frames', '-of', 'csv=p=0'], path),
        'read': probe(['-count_frames', '-show_entries', 'stream=nb_read_frames', '-of', 'csv=p=0'], path),
        'grid': grid_count(path, m),
    })
json.dump(rows, sys.stdout, indent=1)
