"""Shared helpers for the issue #157 seek-alignment probes.

Paths come from the repo (found from this file's location) or the environment,
never from a personal path:

  VAPOURBOX_DEPS_DIR  deps/<platform> to take ffmpeg/ffprobe from
                      (default: <repo>/deps/<platform>)
  SEEK_WORK           scratch directory for variants, raw frames and encodes
                      (default: a fresh temporary directory)
"""
import hashlib
import json
import os
import platform
import subprocess
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..', '..', '..'))
RES = os.path.join(REPO, 'Tests', 'TestResources')


def _platform_id():
    system = platform.system()
    machine = platform.machine().lower()
    arch = 'arm64' if machine in ('arm64', 'aarch64') else 'x64'
    if system == 'Darwin':
        return f'macos-{arch}'
    if system == 'Windows':
        return 'windows-x64'
    return f'linux-{arch}'


DEPS = os.environ.get('VAPOURBOX_DEPS_DIR') or os.path.join(REPO, 'deps', _platform_id())
EXE = '.exe' if platform.system() == 'Windows' else ''
FF = os.path.join(DEPS, 'ffmpeg', 'ffmpeg' + EXE)
FP = os.path.join(DEPS, 'ffmpeg', 'ffprobe' + EXE)
WORK = os.environ.get('SEEK_WORK') or tempfile.mkdtemp(prefix='seek157_')
os.makedirs(WORK, exist_ok=True)

# The PTS reset the worker's seeking decoders now carry (source_decode.rs).
RESET_PTS = 'setpts=PTS-STARTPTS'


def _rate(s):
    n, d = (int(x) for x in s.split('/'))
    return n / d if d else 0.0


def probe(path):
    """Width, height, pix_fmt, time base, field order and the frame rate the
    app would send (FieldOrderDetector.selectFrameRate: avg when r is ~2x avg,
    the field-coded case, else r)."""
    out = subprocess.run(
        [FP, '-v', 'error', '-select_streams', 'v:0', '-show_entries',
         'stream=width,height,pix_fmt,r_frame_rate,avg_frame_rate,time_base,'
         'field_order,start_time,codec_name', '-of', 'json', path],
        capture_output=True, text=True, check=True).stdout
    s = json.loads(out)['streams'][0]
    r, a = _rate(s['r_frame_rate']), _rate(s['avg_frame_rate'])
    fps = r if r > 0 else a
    if r > 0 and a > 0 and 1.8 < r / a < 2.2:
        fps = a
    s['fps'] = fps
    return s


def _raw(args):
    return subprocess.run([FF, '-v', 'quiet', *args, '-f', 'rawvideo', '-pix_fmt', 'gray', '-'],
                          capture_output=True).stdout


def _hashes(data, w, h):
    n = w * h
    return [hashlib.md5(data[i:i + n]).hexdigest() for i in range(0, len(data) - n + 1, n)]


def sequential(path, count, timing='passthrough'):
    """The first `count` pictures, decoded from the start with no seek.
    `passthrough`: every stored frame once (the independent reference).
    `default`: rawvideo's own constant-rate timing, which is exactly what an
    untrimmed encode feeds the script (pulldown repeats included)."""
    s = probe(path)
    extra = ['-fps_mode', 'passthrough'] if timing == 'passthrough' else []
    return _hashes(_raw(['-apply_cropping', 'codec', '-i', path, '-map', '0:v:0',
                         '-frames:v', str(count), *extra]), s['width'], s['height'])


def seek_decode(path, start, count, mode):
    """`count` frames from source frame `start`, seeking the way the worker
    does ((start - 0.5) / fps before -i). `mode`: 'default' (the worker before
    #157), 'passthrough', or 'setpts' (the worker after #157)."""
    s = probe(path)
    ss = max(0.0, (start - 0.5) / s['fps'])
    extra = {'default': [], 'passthrough': ['-fps_mode', 'passthrough'],
             'setpts': ['-vf', RESET_PTS]}[mode]
    return _hashes(_raw(['-ss', f'{ss:.6f}', '-apply_cropping', 'codec', '-i', path,
                         '-map', '0:v:0', '-frames:v', str(count), *extra]),
                   s['width'], s['height'])


def indices(got, reference):
    """Each decoded picture as its index in the reference decode ('?' if absent).
    The first match wins, so a repeated reference picture reads as its first slot."""
    first = {}
    for i, h in enumerate(reference):
        first.setdefault(h, i)
    return [first.get(h, '?') for h in got]
