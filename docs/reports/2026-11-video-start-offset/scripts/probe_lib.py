"""Shared helpers for the video-start-offset probes.

Paths come from the repo (found from this file's location) or the environment,
never from a personal path:

  VAPOURBOX_DEPS_DIR  deps/<platform> to take ffmpeg/ffprobe from
                      (default: <repo>/deps/<platform>)
  OFFSET_WORK         scratch directory for decodes and encodes
                      (default: a fresh temporary directory)

Same approach as the issue-157 report's seeklib.py (copied, not imported, so
each report stands alone): pictures are identified by the MD5 of their luma
plane, against an independent decode of the source.
"""
import hashlib
import json
import os
import platform
import subprocess
import tempfile
import uuid

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
WORK = os.environ.get('OFFSET_WORK') or tempfile.mkdtemp(prefix='vstart_')
os.makedirs(WORK, exist_ok=True)

FIXTURES = ['late_video_intra.ts', 'late_video.mkv', 'late_video.mp4']
DVBT = 'pal-dvbt-fieldcoded-25i.ts'


def _rate(s):
    n, d = (int(x) for x in s.split('/'))
    return n / d if d else 0.0


def probe(path):
    """The video stream's facts, plus the frame rate the app would send
    (FieldOrderDetector.selectFrameRate) and the container's start_time."""
    out = subprocess.run(
        [FP, '-v', 'error', '-select_streams', 'v:0', '-show_entries',
         'stream=width,height,pix_fmt,r_frame_rate,avg_frame_rate,time_base,'
         'field_order,start_time,duration,nb_frames,codec_name,color_space,color_primaries,'
         'color_transfer,color_range:format=start_time,duration',
         '-of', 'json', path],
        capture_output=True, text=True, check=True).stdout
    j = json.loads(out)
    s = j['streams'][0]
    r, a = _rate(s['r_frame_rate']), _rate(s['avg_frame_rate'])
    fps = r if r > 0 else a
    if r > 0 and a > 0 and 1.8 < r / a < 2.2:
        fps = a
    s['fps'] = fps
    s['format_start'] = float(j['format'].get('start_time', 0) or 0)
    s['format_duration'] = float(j['format'].get('duration', 0) or 0)
    return s


def first_pts(path, packets=64):
    """The first picture shown (source_decode::video_start_from_probe): the
    earlier of the stream's start_time and the smallest PTS among its first
    packets (MPEG-2 in AVI stores packets with no PTS)."""
    out = subprocess.run(
        [FP, '-v', 'error', '-select_streams', 'v:0', '-show_entries',
         'packet=pts_time:stream=start_time', '-read_intervals', f'%+#{packets}', '-of', 'json', path],
        capture_output=True, text=True, check=True).stdout
    j = json.loads(out)
    times = [float(p['pts_time']) for p in j['packets'] if p.get('pts_time') not in (None, 'N/A')]
    start = j['streams'][0].get('start_time') if j.get('streams') else None
    if start not in (None, 'N/A'):
        times.append(float(start))
    return min(times)


def video_start(path):
    s = probe(path)
    return max(0.0, first_pts(path) - s['format_start'])


def _raw(args):
    return subprocess.run([FF, '-v', 'quiet', *args, '-f', 'rawvideo', '-pix_fmt', 'gray', '-'],
                          capture_output=True).stdout


def hashes(data, w, h):
    n = w * h
    return [hashlib.md5(data[i:i + n]).hexdigest() for i in range(0, len(data) - n + 1, n)]


def sequential(path, count=100000):
    """Every stored picture once, in presentation order, decoded from the start
    with no seek: the independent reference."""
    s = probe(path)
    return hashes(_raw(['-apply_cropping', 'codec', '-i', path, '-map', '0:v:0',
                        '-frames:v', str(count), '-fps_mode', 'passthrough']),
                  s['width'], s['height'])


def constant_rate(path, count=100000, reset=False):
    """What an untrimmed encode feeds the script: rawvideo's constant-rate
    timing, no seek (and, with `reset`, the PTS reset a late video now gets)."""
    s = probe(path)
    vf = ['-vf', 'setpts=PTS-STARTPTS'] if reset else []
    return hashes(_raw(['-apply_cropping', 'codec', '-i', path, '-map', '0:v:0',
                        '-frames:v', str(count), *vf]), s['width'], s['height'])


def indices(got, reference):
    """Each decoded picture as its index in the reference ('?' if absent)."""
    first = {}
    for i, h in enumerate(reference):
        first.setdefault(h, i)
    return [first.get(h, '?') for h in got]


def before_frame_hash(src, n, fps, offset, w, h):
    """The picture the before-frame command shows, hashed like the decodes
    above: its exact arguments with the image output swapped for raw luma at
    passthrough timing (what an image output uses), since a PNG goes through
    RGB and would no longer hash the same."""
    args = before_frame_args(src, n, fps, offset, 'x')[1:-3]  # drop -y and the output
    got = hashes(_raw([*args, '-frames:v', '1', '-fps_mode', 'passthrough']), w, h)
    return got[0] if got else None


def before_frame_args(src, n, fps, offset, out):
    """PreviewGenerator.beforeFrameArgs (PNG output). `offset` 0 is the app
    before this change."""
    frame = max(0, n)
    ss = (frame - 0.5) / fps
    ss = 0.0 if ss < 0 else ss
    if frame > 0:
        ss += offset
    return ['-y', '-ss', f'{ss:.6f}', '-apply_cropping', 'codec', '-i', src,
            '-frames:v', '1', '-q:v', '2', out]


def job_file(src, s, out, **extra):
    fo = s.get('field_order') or ''
    order = 'tff' if fo in ('tt', 'tb') else 'bff' if fo in ('bb', 'bt') else 'progressive'
    j = {'id': str(uuid.uuid4()), 'inputPath': src, 'outputPath': out,
         'qtgmcParameters': {'enabled': False},
         'processingPipeline': {'deinterlace': {'enabled': False}},
         'encodingSettings': {'codec': 'ffv1', 'container': 'mkv', 'audioMode': 'none'},
         'detectedFieldOrder': order, 'inputFrameRate': s['fps'],
         'inputWidth': s['width'], 'inputHeight': s['height'], 'inputPixelFormat': s['pix_fmt']}
    # The colour tags, raw, as the app sends them (`colorTag`): the worker
    # clears a tag FFmpeg rejects (ProRes's `reserved`) only when it knows it.
    for key, field in (('color_space', 'inputColorMatrix'), ('color_primaries', 'inputColorPrimaries'),
                       ('color_transfer', 'inputColorTransfer'), ('color_range', 'inputColorRange')):
        if s.get(key) not in (None, '', 'unknown', 'N/A'):
            j[field] = s[key]
    for k, v in extra.items():
        if k == 'encodingSettings':
            j[k].update(v)
        else:
            j[k] = v
    path = os.path.join(WORK, f'job_{j["id"]}.json')
    with open(path, 'w') as f:
        json.dump(j, f)
    return path


def run_worker(worker, job, *args):
    return subprocess.run([worker, '--config', job, *args], capture_output=True)


def app_frame_count(path, new=True):
    """FieldOrderDetector's frame count for a constant-rate source, before
    (`new=False`: nb_frames, else the container's duration) and after this
    change (nb_frames, else the video stream's own duration plus its leading
    pictures, else the container's duration less the video start offset)."""
    s = probe(path)
    fps = s['fps']
    nb = s.get('nb_frames')
    if nb not in (None, 'N/A'):
        return int(nb)
    if not new:
        return round(s['format_duration'] * fps)
    dur = s.get('duration')
    if dur not in (None, 'N/A'):
        lead = max(0.0, float(s['start_time']) - first_pts(path))
        return round((float(dur) + lead) * fps)
    return round((s['format_duration'] - video_start(path)) * fps)
