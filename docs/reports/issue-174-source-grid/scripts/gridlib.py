"""Shared helpers for the issue #174 source-grid probes.

Paths come from the repo (found from this file's location) or the
environment, never a personal path:

  VAPOURBOX_DEPS_DIR  deps/<platform> to take ffmpeg/ffprobe from
                      (default: <repo>/deps/<platform>)
  GRID_WORK           scratch directory (default: a fresh temporary one)

Pictures are named by the MD5 of their luma plane in an independent
`-fps_mode passthrough` decode (every stored frame once, no seek), so "which
stored picture came out" is exact. That says nothing about colour.
"""
import hashlib
import json
import os
import platform
import subprocess
import tempfile
from fractions import Fraction

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..', '..', '..'))
RES = os.path.join(REPO, 'Tests', 'TestResources')


def _platform_id():
    machine = platform.machine().lower()
    arch = 'arm64' if machine in ('arm64', 'aarch64') else 'x64'
    system = platform.system()
    if system == 'Darwin':
        return f'macos-{arch}'
    if system == 'Windows':
        return 'windows-x64'
    return f'linux-{arch}'


DEPS = os.environ.get('VAPOURBOX_DEPS_DIR') or os.path.join(REPO, 'deps', _platform_id())
EXE = '.exe' if platform.system() == 'Windows' else ''
FF = os.path.join(DEPS, 'ffmpeg', 'ffmpeg' + EXE)
FP = os.path.join(DEPS, 'ffmpeg', 'ffprobe' + EXE)
WORK = os.environ.get('GRID_WORK') or tempfile.mkdtemp(prefix='grid174_')
os.makedirs(WORK, exist_ok=True)

LOOKBACK = 8  # source_decode::GRID_LOOKBACK_SLOTS

# The committed fixtures (Tests/TestResources), plus the variants
# make_variants.py builds (WORK).
FIXTURES = [
    'interlaced_test.avi', 'null_frames_mid.avi', 'soft_telecine_test.mkv',
    'soft_telecine_dvd.vob', 'soft_telecine_dvd.mkv', 'small_clip.mp4',
    'seek_timebase_2997.mov', 'colorize_test.mp4', 'face_restore_test.mp4',
    'late_video.mkv', 'late_video.mp4', 'late_video_intra.ts',
    'pal-dvbt-fieldcoded-25i.ts', 'prores422_10bit_telecine.mov',
    'hard_telecine_test.avi',
]


def resource(name):
    return os.path.join(RES, name)


def probe(path):
    """What the grid probe (source_decode::grid_from_probe) sees: size, the
    rate the app sends (selectFrameRate) as an exact fraction, the first
    picture, the container start, whether every probed packet has a PTS."""
    j = json.loads(subprocess.run(
        [FP, '-v', 'error', '-select_streams', 'v:0', '-show_entries',
         'packet=pts_time:stream=start_time,r_frame_rate,avg_frame_rate,width,height:'
         'format=start_time,format_name', '-read_intervals', '%+#64', '-of', 'json', path],
        capture_output=True, text=True, check=True).stdout)
    s = j['streams'][0]
    cs = float(j['format'].get('start_time') or 0)
    pk = [p.get('pts_time') for p in j.get('packets', [])]
    has_pts = all(x not in (None, 'N/A') for x in pk) and bool(pk)
    first = min([float(s.get('start_time') or cs)] + [float(x) for x in pk if x not in (None, 'N/A')])
    r = Fraction(s['r_frame_rate'])
    a = Fraction(s['avg_frame_rate']) if s['avg_frame_rate'] != '0/0' else Fraction(0)
    rate = a if (a > 0 and 1.8 < r / a < 2.2) else r
    fmt = j['format']['format_name']
    return dict(w=s['width'], h=s['height'], rate=rate, origin=max(first, cs),
                offset=max(0.0, first - cs), cs=cs, has_pts=has_pts,
                ts=any(x in ('mpegts', 'mpeg') for x in fmt.split(',')),
                r=s['r_frame_rate'], avg=s['avg_frame_rate'])


def hashes(args, w, h):
    """Luma MD5 per output frame of `ffmpeg <args>`, written as `rawvideo`
    like the worker's decoders, so ffmpeg's own constant-rate output timing
    applies exactly as it does there."""
    data = subprocess.run([FF, '-v', 'error', *args, '-f', 'rawvideo', '-pix_fmt', 'gray', '-'],
                          capture_output=True).stdout
    n = w * h
    return [hashlib.md5(data[i:i + n]).hexdigest() for i in range(0, len(data) - n + 1, n)]


def stored(path, p):
    return hashes(['-apply_cropping', 'codec', '-i', path, '-map', '0:v:0',
                   '-fps_mode', 'passthrough'], p['w'], p['h'])


def frame_times(path):
    out = subprocess.run([FP, '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                          'frame=pts_time,best_effort_timestamp_time', '-of', 'csv=p=0', path],
                         capture_output=True, text=True).stdout
    times = []
    for line in out.split():
        vals = [x for x in line.split(',') if x and x != 'N/A']
        times.append(float(vals[0]) if vals else None)
    return times


def timeline(path, p):
    """The independent reference: each stored frame placed on the grid by its
    timestamp; slot i shows the last frame whose round((t - origin) * rate) <= i.
    None when a frame has no timestamp."""
    times = frame_times(path)
    if not times or None in times:
        return None
    t0 = min(times)
    rate = float(p['rate'])
    slot = [round((t - t0) * rate) for t in times]
    out, k = [], 0
    for i in range(slot[-1] + 1):
        while k + 1 < len(slot) and slot[k + 1] <= i:
            k += 1
        out.append(k)
    return out


def grid_filters(p, first):
    """source_decode::SourceGrid::filters."""
    return [f'setpts=PTS-{p["origin"]:.6f}/TB', f'fps={p["rate"].numerator}/{p["rate"].denominator}',
            f'trim=start_pts={max(first, 0)}', 'setpts=PTS-STARTPTS']


def grid_decode(path, p, first=0, count=None, preroll=None):
    """The worker's grid decoder from frame `first` (source_decode::decode_start)."""
    if preroll is None:
        preroll = 2.0 if p['ts'] else 0.0
    back = first - LOOKBACK
    args = ['-copyts']
    if back > 0:
        ss = (back - 0.5) / float(p['rate']) + p['offset'] - preroll
        if ss > 0:
            args += ['-ss', f'{ss:.6f}']
    args += ['-apply_cropping', 'codec', '-i', path, '-map', '0:v:0',
             '-vf', ','.join(grid_filters(p, first))]
    if count:
        args += ['-frames:v', str(count)]
    return hashes(args, p['w'], p['h'])


def cfr_decode(path, p, first=0, count=None):
    """The decoder before this fix, for a source with no seek plan: rawvideo's
    constant-rate output; a seek to (first - 0.5) / fps with the #157 reset."""
    args, vf = [], []
    if first > 0:
        args = ['-ss', f'{(first - 0.5) / float(p["rate"]) + p["offset"]:.6f}']
        vf = ['setpts=PTS-STARTPTS']
    elif p['offset'] > 0:
        vf = ['setpts=PTS-STARTPTS']
    args += ['-apply_cropping', 'codec', '-i', path, '-map', '0:v:0']
    if vf:
        args += ['-vf', ','.join(vf)]
    if count:
        args += ['-frames:v', str(count)]
    return hashes(args, p['w'], p['h'])


def name(got, ref):
    """Each picture as its index in the stored-frame reference ('?' if absent)."""
    first = {}
    for i, h in enumerate(ref):
        first.setdefault(h, i)
    return [first.get(h, '?') for h in got]
