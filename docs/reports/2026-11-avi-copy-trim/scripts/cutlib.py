"""Shared helpers for the AVI copy-trim probes (task 24).

Paths come from the repo (found from this file's location) or the environment,
never from a personal path:

  VAPOURBOX_DEPS_DIR  deps/<platform> to take ffmpeg/ffprobe from
                      (default: <repo>/deps/<platform>)
  AVI_CUT_WORK        scratch directory for fixtures and outputs
                      (default: a fresh temporary directory)

Plain Python (the deps Python has no NumPy): sync is found by
cross-correlation at 8 kHz (0.125 ms steps), exactness by comparing samples
at the source rate.
"""
import array
import json
import operator
import os
import platform
import subprocess
import tempfile

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
WORK = os.environ.get('AVI_CUT_WORK') or tempfile.mkdtemp(prefix='avi_cut_')
os.makedirs(WORK, exist_ok=True)

FPS = 30000 / 1001
RATE = 48000            # the fixtures' sound
LAG_RATE = 8000         # correlation rate
DUR = 12.0
# Rises from 150 Hz to 3030 Hz over 12 s: never repeats, below 4 kHz.
CHIRP = f'aevalsrc=0.5*sin(2*PI*(150*t+120*t*t)):s={RATE}:d={DUR}'
FRAMES = (20, 100, 251)


def ff(*args):
    r = subprocess.run([FF, '-hide_banner', '-nostdin', '-y', '-v', 'error', *args],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f'ffmpeg {" ".join(args)}\n{r.stderr}')
    return r.stderr


def probe(path, *entries):
    return json.loads(subprocess.run([FP, '-v', 'error', *entries, '-of', 'json', path],
                                     capture_output=True, text=True, check=True).stdout)


def work(name):
    return os.path.join(WORK, name)


def fixtures():
    """small_clip.mp4's picture (H.264, a keyframe every 0.4 s, the first at
    0.3 s), its first 12 s stream-copied, with the chirp in each codec and
    container; and a two-stream AVI (PCM + AC-3)."""
    clip = os.path.join(RES, 'small_clip.mp4')
    out = {}
    for name, ext, codec in (
        ('PCM s16 in AVI', 'avi', ['-c:a', 'pcm_s16le']),
        ('MP3 in AVI', 'avi', ['-c:a', 'libmp3lame', '-b:a', '192k']),
        ('AC-3 in AVI', 'avi', ['-c:a', 'ac3', '-b:a', '192k']),
        ('AAC in MP4', 'mp4', ['-c:a', 'aac', '-b:a', '192k']),
        ('AC-3 in MKV', 'mkv', ['-c:a', 'ac3', '-b:a', '192k']),
    ):
        p = work(name.split()[0].lower().replace('-', '') + '.' + ext)
        if not os.path.exists(p):
            ff('-t', str(DUR), '-i', clip, '-f', 'lavfi', '-i', CHIRP, '-map', '0:v', '-c:v', 'copy',
               '-map', '1:a', *codec, '-t', str(DUR), p)
        out[name] = p
    two = work('two.avi')
    if not os.path.exists(two):
        ff('-i', out['PCM s16 in AVI'], '-i', out['AC-3 in AVI'], '-map', '0:v', '-map', '0:a',
           '-map', '1:a', '-c', 'copy', two)
    out['PCM + AC-3 in AVI'] = two
    return out


def codec(path, stream=0):
    return probe(path, '-select_streams', f'a:{stream}', '-show_entries',
                 'stream=codec_name')['streams'][0]['codec_name']


def video_start(path):
    j = probe(path, '-show_entries', 'stream=codec_type,start_time:format=start_time')
    v = next(s for s in j['streams'] if s['codec_type'] == 'video')
    return float(v['start_time']) - float(j['format'].get('start_time') or 0)


def decode(path, stream=0, rate=LAG_RATE):
    """Mono float samples, sample 0 at the container's start (a stream that
    starts later is padded with silence, as a player leaves it)."""
    out = work('s.raw')
    ff('-i', path, '-map', f'0:a:{stream}', '-af', 'aresample=first_pts=0', '-ac', '1',
       '-ar', str(rate), '-f', 'f32le', out)
    a = array.array('f')
    with open(out, 'rb') as f:
        a.frombytes(f.read())
    return a


def lag(ref, out, start, vstart, rate=LAG_RATE, search=0.5):
    """Where the source's sound at the in-point plays against the output's
    first picture, in seconds (+ = late), and the normalised peak. Half a
    second of chirp, from half a second after the in-point, searched within
    `search` seconds either way."""
    i0 = round((start / FPS + 0.5) * rate)
    n = rate // 2
    seg = ref[i0:i0 + n]
    base = round((vstart + 0.5) * rate)
    m = round(search * rate)
    e_seg = sum(x * x for x in seg) ** 0.5
    # Running energy of the output, for each window's norm.
    sq = [0.0]
    for x in out:
        sq.append(sq[-1] + x * x)
    best, best_l = -2.0, None
    for l in range(-m, m + 1):
        a = base + l
        if a < 0 or a + n > len(out):
            continue
        dot = sum(map(operator.mul, seg, out[a:a + n]))
        e = max(sq[a + n] - sq[a], 0.0) ** 0.5
        score = dot / (e_seg * e + 1e-12)
        if score > best:
            best, best_l = score, l
    return (None if best_l is None else best_l / rate), best


def sample_rate(path, stream=0):
    return int(probe(path, '-select_streams', f'a:{stream}', '-show_entries',
                     'stream=sample_rate')['streams'][0]['sample_rate'])


def exact_from(ref, out, start, vstart, rate, seconds=1.0):
    """Largest sample difference between the output from its first picture
    and the source from the in-point, both decoded at the source's own rate
    `rate` (a resample would hide or invent a difference)."""
    i0, j0, n = round(start / FPS * rate), round(vstart * rate), round(seconds * rate)
    return max(abs(a - b) for a, b in zip(ref[i0:i0 + n], out[j0:j0 + n]))


def packet_ms(path, stream=0):
    j = probe(path, '-select_streams', f'a:{stream}', '-read_intervals', '%+#32',
              '-show_entries', 'packet=duration_time')
    d = [float(p['duration_time']) for p in j['packets'] if p.get('duration_time') not in (None, 'N/A')]
    return max(d) * 1000 if d else None


def time_base(path, stream=0):
    return probe(path, '-select_streams', f'a:{stream}', '-show_entries',
                 'stream=time_base')['streams'][0]['time_base']
