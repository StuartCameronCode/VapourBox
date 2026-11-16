#!/usr/bin/env python3
"""What counting an MP4 with an edit list costs, four ways (task #54 report).

Makes a 2 h MP4 with an edit list in a temporary directory (small_clip.mp4,
stream-copied 70 times with -stream_loop: its first copy keeps the edit
list's three discarded pre-roll packets) and times, each the median of 5
runs on a warm cache:

  tail    the worker's tail probe: video packets of the last 3 s, with flags
  head    the video-start probe's first 64 packets, with flags
  probe   the worker's whole --probe-source (every probe it runs, in parallel)
  packets every video packet's flags (a whole-file read, no decoding)
  decode  ffprobe -count_frames (a whole decode; one run only)

and checks the counts agree: the last kept picture's slot + 1 (the tail),
the packets not marked discard, and the model's frameCount.

Usage: edit_list_cost.py <worker> <deps-platform-dir>   (JSON to stdout)
"""
import json, os, statistics, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
CLIP = os.path.join(HERE, '..', '..', '..', '..', 'Tests', 'TestResources', 'small_clip.mp4')
worker, deps = sys.argv[1], sys.argv[2]
ffmpeg = os.path.join(deps, 'ffmpeg', 'ffmpeg')
ffprobe = os.path.join(deps, 'ffmpeg', 'ffprobe')


def run(args):
    t = time.perf_counter()
    out = subprocess.run(args, capture_output=True, text=True, check=True).stdout
    return time.perf_counter() - t, out


def timed(args, n=5):
    runs = [run(args) for _ in range(n)]
    return statistics.median(t for t, _ in runs), runs[0][1]


with tempfile.TemporaryDirectory() as tmp:
    long = os.path.join(tmp, 'long.mp4')
    subprocess.run([ffmpeg, '-v', 'error', '-y', '-stream_loop', '69', '-i', CLIP, '-c', 'copy', long], check=True)
    size = os.path.getsize(long)
    fmt = json.loads(run([ffprobe, '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                          'stream=nb_frames,r_frame_rate:format=duration', '-of', 'json', long])[1])
    duration = float(fmt['format']['duration'])
    n, d = map(int, fmt['streams'][0]['r_frame_rate'].split('/'))
    probe = [ffprobe, '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'packet=pts_time,flags', '-of', 'csv=p=0']

    tail_t, tail = timed(probe + ['-read_intervals', f'{duration - 3:.3f}%', long])
    kept = [float(l.split(',')[0]) for l in tail.splitlines() if l and 'D' not in l.split(',')[1]]
    head_t, head = timed(probe + ['-read_intervals', '%+#64', long])
    probe_t, model = timed([worker, '--probe-source', long])
    packets_t, packets = timed([ffprobe, '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                                'packet=flags', '-of', 'csv=p=0', long])
    decode_t, decoded = run([ffprobe, '-v', 'error', '-select_streams', 'v:0', '-count_frames',
                             '-show_entries', 'stream=nb_read_frames', '-of', 'csv=p=0', long])
    json.dump({
        'file': {'bytes': size, 'duration': duration, 'nb_frames': int(fmt['streams'][0]['nb_frames'])},
        'seconds': {'tail': tail_t, 'head': head_t, 'probe': probe_t, 'packets': packets_t, 'decode': decode_t},
        'counts': {
            'tail_slot_plus_one': round(max(kept) * n / d) + 1,
            'head_discards': sum(1 for l in head.splitlines() if 'D' in l),
            'kept_packets': sum(1 for l in packets.splitlines() if l.strip() and 'D' not in l),
            'decoded': int(decoded.strip().rstrip(',')),
            'model': json.loads(model)['video']['frameCount'],
        },
    }, sys.stdout, indent=1)
