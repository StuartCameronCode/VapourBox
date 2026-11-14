"""Shared helpers for the issue #169 MPEG-PS/TS seek probes.

Paths come from the repo (found from this file's location) or the environment,
never from a personal path:

  VAPOURBOX_DEPS_DIR  deps/<platform> to take ffmpeg/ffprobe from
                      (default: <repo>/deps/<platform>)
  SEEK_WORK           scratch directory for variants, frames and encodes
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
WORK = os.environ.get('SEEK_WORK') or tempfile.mkdtemp(prefix='seek169_')
os.makedirs(WORK, exist_ok=True)

RESET_PTS = 'setpts=PTS-STARTPTS'

# The worker's source_decode constants (SEEK_PROBE_ARGS, SEEK_PREROLL_*).
SEEK_PROBE_ARGS = ['-v', 'error', '-select_streams', 'v:0', '-show_entries',
                   'packet=pts_time,dts_time,flags:format=format_name,start_time',
                   '-read_intervals', '%+20', '-of', 'json']
TIMESTAMP_SEARCH_FORMATS = ('mpegts', 'mpeg')
MARGIN, FLOOR, WINDOW = 0.5, 1.0, 20.0


def _rate(s):
    n, d = (int(x) for x in s.split('/'))
    return n / d if d else 0.0


def probe(path):
    """Size, pix_fmt, codec and the frame rate the app would send (the picture
    rate for a field-coded stream, FieldOrderDetector.selectFrameRate)."""
    out = subprocess.run(
        [FP, '-v', 'error', '-select_streams', 'v:0', '-show_entries',
         'stream=width,height,pix_fmt,r_frame_rate,avg_frame_rate,field_order,codec_name'
         ':format=format_name,start_time', '-of', 'json', path],
        capture_output=True, text=True, check=True).stdout
    j = json.loads(out)
    s = j['streams'][0]
    r, a = _rate(s['r_frame_rate']), _rate(s['avg_frame_rate'])
    s['fps'] = a if r > 0 and a > 0 and 1.8 < r / a < 2.2 else (r if r > 0 else a)
    s['format_name'] = j['format'].get('format_name', '')
    s['container_start'] = float(j['format'].get('start_time', 0) or 0)
    return s


def video_start(path):
    """source_decode::video_start_from_probe (#168)."""
    out = subprocess.run([FP, '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                          'packet=pts_time:stream=start_time:format=start_time',
                          '-read_intervals', '%+#64', '-of', 'json', path],
                         capture_output=True, text=True).stdout
    j = json.loads(out)
    num = lambda v: float(v) if v not in (None, 'N/A') else None
    c = num(j.get('format', {}).get('start_time'))
    st = num((j.get('streams') or [{}])[0].get('start_time'))
    pts = [num(p.get('pts_time')) for p in j.get('packets', [])]
    first = min([t for t in [st, *pts] if t is not None], default=None)
    return first - c if c is not None and first is not None and first > c else 0.0


def seek_plan(path):
    """source_decode::seek_plan_from_probe: (preroll, container_start, gop,
    reorder) or None for a format that seeks by index."""
    j = json.loads(subprocess.run([FP, *SEEK_PROBE_ARGS, path], capture_output=True,
                                  text=True, check=True).stdout)
    fmt = j.get('format', {})
    if not any(n.strip() in TIMESTAMP_SEARCH_FORMATS for n in fmt.get('format_name', '').split(',')):
        return None
    num = lambda v: float(v) if v not in (None, 'N/A') else None
    keys, reorder = [], 0.0
    for p in j.get('packets', []):
        pts, dts = num(p.get('pts_time')), num(p.get('dts_time'))
        if pts is not None and dts is not None:
            reorder = max(reorder, pts - dts)
        t = pts if pts is not None else dts
        if p.get('flags', '').startswith('K') and t is not None:
            keys.append(t)
    gop = max((b - a for a, b in zip(keys, keys[1:])), default=WINDOW) if len(keys) > 1 else WINDOW
    return {'preroll': max(FLOOR, gop + reorder + MARGIN),
            'container_start': num(fmt.get('start_time')) or 0.0,
            'gop': gop, 'reorder': reorder}


def _raw(args):
    return subprocess.run([FF, '-v', 'quiet', *args, '-f', 'rawvideo', '-pix_fmt', 'gray', '-'],
                          capture_output=True).stdout


def hashes(data, w, h):
    n = w * h
    return [hashlib.md5(data[i:i + n]).hexdigest() for i in range(0, len(data) - n + 1, n)]


def sequential(path, count=100000):
    """The independent reference: every stored picture once, from the start,
    no seek (`-fps_mode passthrough`), named by its luma MD5."""
    s = probe(path)
    return hashes(_raw(['-apply_cropping', 'codec', '-i', path, '-map', '0:v:0',
                        '-frames:v', str(count), '-fps_mode', 'passthrough']),
                  s['width'], s['height'])


def target(n, fps, vstart):
    """source_decode::seek_time: container-relative, half a frame before N."""
    return (n - 0.5) / fps + vstart


def decode(path, n, count, mode, preroll=0.0):
    """`count` pictures from frame `n`, seeking one way:
      plain    the worker before #169: -ss target, PTS reset
      relative -ss (target - preroll), trim at preroll (no -copyts)
      copyts   the fix: -copyts -ss (target - preroll), trim at the absolute target
    """
    s = probe(path)
    t = target(n, s['fps'], video_start(path))
    if mode == 'plain':
        pre, vf = ['-ss', f'{t:.6f}'], RESET_PTS
    else:
        early = t - preroll
        pre = ['-ss', f'{early:.6f}'] if early > 0 else []
        if mode == 'relative':
            vf = f'trim=start={t - max(early, 0.0):.6f},{RESET_PTS}'
        else:
            pre = ['-copyts', *pre]
            vf = f'trim=start={s["container_start"] + t:.6f},{RESET_PTS}'
    return hashes(_raw([*pre, '-apply_cropping', 'codec', '-i', path, '-map', '0:v:0',
                        '-frames:v', str(count), '-vf', vf]), s['width'], s['height'])


def indices(got, reference):
    first = {}
    for i, h in enumerate(reference):
        first.setdefault(h, i)
    return [first.get(h, '?') for h in got]
