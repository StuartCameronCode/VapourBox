"""Shared helpers for the issue #173 AVI seek probes.

Paths come from the repo (found from this file's location) or the environment,
never from a personal path:

  VAPOURBOX_DEPS_DIR  deps/<platform> to take ffmpeg/ffprobe from
                      (default: <repo>/deps/<platform>)
  AVI_SEEK_WORK       scratch directory for variants, frames and encodes
                      (default: a fresh temporary directory)
"""
import hashlib
import json
import math
import os
import platform
import subprocess
import tempfile
from fractions import Fraction

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..', '..', '..'))
RES = os.path.join(REPO, 'Tests', 'TestResources')


def _platform_id():
    system = platform.system()
    arch = 'arm64' if platform.machine().lower() in ('arm64', 'aarch64') else 'x64'
    if system == 'Darwin':
        return f'macos-{arch}'
    if system == 'Windows':
        return 'windows-x64'
    return f'linux-{arch}'


DEPS = os.environ.get('VAPOURBOX_DEPS_DIR') or os.path.join(REPO, 'deps', _platform_id())
EXE = '.exe' if platform.system() == 'Windows' else ''
FF = os.path.join(DEPS, 'ffmpeg', 'ffmpeg' + EXE)
FP = os.path.join(DEPS, 'ffmpeg', 'ffprobe' + EXE)
WORK = os.environ.get('AVI_SEEK_WORK') or tempfile.mkdtemp(prefix='avi173_')
os.makedirs(WORK, exist_ok=True)

RESET = 'setpts=PTS-STARTPTS'
BACKOFF = 3 / 23        # fftools/ffmpeg_demux.c: seek_timestamp -= 3*AV_TIME_BASE/23
COUNT_BELOW = 0.5       # source_decode::COUNT_SEEK_BELOW


def ffprobe_json(*args):
    return json.loads(subprocess.run([FP, '-v', 'error', *args, '-of', 'json'],
                                     capture_output=True, text=True, check=True).stdout)


def probe(path):
    s = ffprobe_json('-select_streams', 'v:0', '-show_entries',
                     'stream=width,height,r_frame_rate,avg_frame_rate,time_base,has_b_frames,codec_name',
                     path)['streams'][0]
    n, d = (int(x) for x in s['avg_frame_rate'].split('/'))
    s['rate'] = Fraction(n, d)
    s['fps'] = n / d
    return s


def decoder_delay(path):
    """The worker's measurement (source_decode::decoder_delay_from_probe):
    only when a first packet carries no PTS, the first decoded picture's
    timestamp in whole frames."""
    pk = ffprobe_json('-select_streams', 'v:0', '-show_entries', 'packet=pts_time',
                      '-read_intervals', '%+#64', path)['packets']
    if all('pts_time' in p for p in pk):
        return 0
    j = ffprobe_json('-select_streams', 'v:0', '-show_entries',
                     'frame=best_effort_timestamp_time:stream=r_frame_rate:format=start_time',
                     '-read_intervals', '%+#16', path)
    n, d = (int(x) for x in j['streams'][0]['r_frame_rate'].split('/'))
    first = float(j['frames'][0]['best_effort_timestamp_time'])
    k = round((first - float(j['format'].get('start_time', 0))) * n / d)
    return k if 1 <= k <= 4 else 0


def raw(args, w, h):
    data = subprocess.run([FF, '-v', 'quiet', *args, '-f', 'rawvideo', '-pix_fmt', 'gray', '-'],
                          capture_output=True).stdout
    n = w * h
    return [hashlib.md5(data[i:i + n]).hexdigest() for i in range(0, len(data) - n + 1, n)]


def sequential(path):
    """Every stored picture once, in display order: the independent reference
    (the same numbering as `select=eq(n,N)`)."""
    s = probe(path)
    return raw(['-i', path, '-map', '0:v:0', '-fps_mode', 'passthrough'], s['width'], s['height'])


def fmt_old(t):
    return f'{t:.6f}'


def fmt_ceil(t):
    """source_decode::seek_arg: up to the microsecond, 1 ns allowance."""
    return f'{math.ceil(t * 1e6 - 1e-3) / 1e6:.6f}'


def seek_args(n, fps, mode, delay):
    """The decoder's input options and filters for start frame `n`.
    old:   (n - 0.5)/fps, %.6f (the worker before #173)
    delay: + the decoder delay, %.6f
    ceil:  + the delay, rounded up
    fix:   + the delay, rounded up, counted from the start below 0.5 s (the worker after #173)"""
    d = 0 if mode == 'old' else delay
    t = (n + d - 0.5) / fps
    if mode == 'fix' and d > 0 and t < COUNT_BELOW:
        return [], f'trim=start_frame={n},{RESET}'
    ss = fmt_old(t) if mode in ('old', 'delay') else fmt_ceil(t)
    return ['-ss', ss], RESET


def indices(got, ref):
    first = {}
    for i, h in enumerate(ref):
        first.setdefault(h, i)
    return [first.get(h, '?') for h in got]
