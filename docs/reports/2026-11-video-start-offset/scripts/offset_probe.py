"""The video start offset of every fixture, and the DVB-T clip's leading packets.

  python3 offset_probe.py [--json out.json]

For each file in Tests/TestResources with a video stream: the container's
start_time, the video stream's start_time, the first picture's PTS (the
smallest PTS among the first 64 video packets) and so the offset
(first picture - container start, the quantity the fix adds to every seek).
Used to choose the threshold at which the pass list suggests Audio
Restoration's "start the sound with the picture": ffmpeg's own MPEG-TS muxer
leaves 10-21 ms between streams, which must not badge.
Then the DVB-T clip's first ten video packets in file order, with type."""
import glob
import json
import os
import subprocess
import sys
from probe_lib import FP, RES, DVBT, first_pts

EXTS = ('.ts', '.mts', '.m2ts', '.mp4', '.mov', '.mkv', '.avi', '.mpg', '.vob', '.m4v', '.webm')


def facts(path):
    out = subprocess.run([FP, '-v', 'error', '-show_entries', 'format=start_time:stream=codec_type,start_time',
                          '-of', 'json', path], capture_output=True, text=True)
    if out.returncode:
        return None
    j = json.loads(out.stdout)
    video = [s for s in j.get('streams', []) if s.get('codec_type') == 'video']
    if not video:
        return None
    audio = [s for s in j['streams'] if s.get('codec_type') == 'audio']
    cstart = float(j['format'].get('start_time', 0) or 0)
    vstart = float(video[0].get('start_time', 0) or 0)
    first = first_pts(path)
    return {'file': os.path.basename(path), 'container_start': cstart, 'video_start': vstart,
            'first_picture': first, 'offset': round(max(0.0, first - cstart), 6),
            'audio_streams': len(audio)}


def main():
    out = sys.argv[sys.argv.index('--json') + 1] if '--json' in sys.argv else None
    rows = []
    for path in sorted(glob.glob(os.path.join(RES, '*'))):
        if not path.lower().endswith(EXTS):
            continue
        try:
            f = facts(path)
        except Exception as e:  # a fixture ffprobe can't read is not ours to judge
            f = None
        if f:
            rows.append(f)
            print(f"{f['file']:40s} container {f['container_start']:8.3f}  video {f['video_start']:8.3f}  "
                  f"first picture {f['first_picture']:8.3f}  offset {f['offset']:.3f}  audio streams {f['audio_streams']}")
    pk = subprocess.run([FP, '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                         'frame=pts_time,pict_type,pkt_pos', '-read_intervals', '%+#10', '-of', 'json',
                         os.path.join(RES, DVBT)], capture_output=True, text=True).stdout
    frames = json.loads(pk)['frames']
    by_pos = sorted(frames, key=lambda f: int(f.get('pkt_pos', 0)))
    print(f'\n{DVBT}: first ten pictures in file order')
    for f in by_pos:
        print(f"  pos {f.get('pkt_pos'):>8}  pts {f['pts_time']}  {f.get('pict_type')}")
    if out:
        with open(out, 'w') as fh:
            json.dump({'fixtures': rows, 'dvbt_head': by_pos}, fh, indent=1)


if __name__ == '__main__':
    main()
