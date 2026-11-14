"""A last picture with no PTS (task #26): the app's frame count before and
after the fix, against a sequential decode, for every TS/PS fixture and the
joined copies of the reset fixtures.

"before" is FieldOrderDetector.frameCountFromDuration (stream duration plus
leading pictures, at the app's rate). "after" adds untimedLastPicture: the
last 3 s decoded, a frame with no timestamp stamped previous + previous
duration (as ffmpeg's decoder does), counted as its slot + 1, never fewer
than before. "decoded" is ffprobe -count_frames: pictures, which is the
grid's length except on a soft-telecine source (soft_telecine_dvd.vob: 120
pictures, 149 slots; integration_source_grid_test.dart checks that one).
"""
import json
import os

from resetlib import FF, FP, RES, WORK, run

FILES = ['seek_dvd_pal.mpg', 'seek_gop_late_video.ts', 'late_video_gop.ts',
         'late_video_intra.ts', 'pal-dvbt-fieldcoded-25i.ts',
         'soft_telecine_dvd.vob']


def joined(name, muxer):
    out = os.path.join(WORK, 'joined_' + name)
    run([FF, '-y', '-v', 'error', '-i', os.path.join(RES, name), '-map', '0:v',
         '-map', '0:a?', '-c', 'copy', '-map_metadata', '0', '-f', muxer, out])
    return out


def j(path, *args):
    return json.loads(run([FP, '-v', 'error', *args, '-of', 'json', path]).stdout or '{}')


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def rate(s):
    n, d = (float(x) for x in s.split('/'))
    return n / d


def counts(path):
    s = j(path, '-select_streams', 'v:0', '-show_entries',
          'stream=duration,start_time,r_frame_rate,avg_frame_rate')['streams'][0]
    r, a = rate(s['r_frame_rate']), rate(s['avg_frame_rate'])
    fps = a if 1.8 < r / a < 2.2 else r  # FieldOrderDetector.selectFrameRate
    start, dur = num(s['start_time']), num(s['duration'])
    head = j(path, '-select_streams', 'v:0', '-show_entries', 'packet=pts_time',
             '-read_intervals', '%+#64').get('packets', [])
    first = min([start] + [num(p['pts_time']) for p in head if 'pts_time' in p])
    leading = max(0.0, start - first)
    before = round((dur + leading) * fps)
    frames = j(path, '-select_streams', 'v:0', '-show_entries',
               'frame=best_effort_timestamp_time,duration_time',
               '-read_intervals', f'{max(0.0, start + dur - 3):.6f}%').get('frames', [])
    prev, untimed = None, None
    for f in frames:
        t, d = num(f.get('best_effort_timestamp_time')), num(f.get('duration_time'))
        d = d if d and d > 0 else 1 / fps
        if t is None:
            if prev is None:
                continue
            t = prev[0] + prev[1]
            untimed = t if untimed is None else max(untimed, t)
        prev = (t, d)
    after = before if untimed is None else max(
        before, round((untimed - (start - leading)) * fps) + 1)
    decoded = j(path, '-select_streams', 'v:0', '-count_frames', '-show_entries',
                'stream=nb_read_frames')['streams'][0]['nb_read_frames']
    return before, after, untimed, decoded


paths = [os.path.join(RES, f) for f in FILES] + [
    joined('seek_reset_dvd_pal.mpg', 'vob'), joined('seek_reset_h264.ts', 'mpegts')]
print(f"{'file':34} {'before':>6} {'after':>6} {'untimed last':>12} {'decoded':>7}")
for p in paths:
    b, a, u, d = counts(p)
    print(f"{os.path.basename(p):34} {b:6} {a:6} {('%.3f' % u) if u else '-':>12} {d:>7}")
