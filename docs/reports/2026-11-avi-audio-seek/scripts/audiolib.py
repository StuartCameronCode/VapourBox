"""Shared helpers for the AVI audio seek probes (task 22, follow-up to #173).

Paths come from the repo (found from this file's location) or the environment,
never from a personal path:

  VAPOURBOX_DEPS_DIR  deps/<platform> to take ffmpeg/ffprobe from
                      (default: <repo>/deps/<platform>)
  AVI_AUDIO_WORK      scratch directory for variants and outputs
                      (default: a fresh temporary directory)
"""
import array
import json
import os
import platform
import subprocess
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..', '..', '..'))
RES = os.path.join(REPO, 'Tests', 'TestResources')
FIXTURE = os.path.join(RES, 'avi_h264_bframes.avi')


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
WORK = os.environ.get('AVI_AUDIO_WORK') or tempfile.mkdtemp(prefix='avi_audio_')
os.makedirs(WORK, exist_ok=True)

RATE = 32000            # the fixture's sound
FPS = 30000 / 1001
CHIRP = 'aevalsrc=0.5*sin(2*PI*(200*t+300*t*t)):s=32000:d=3.003'


def ff(*args):
    """Run ffmpeg; returns its stderr (warnings included)."""
    r = subprocess.run([FF, '-hide_banner', '-nostdin', '-y', '-v', 'warning', *args],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f'ffmpeg {" ".join(args)}\n{r.stderr}')
    return r.stderr


def probe(path, *entries):
    return json.loads(subprocess.run([FP, '-v', 'error', *entries, '-of', 'json', path],
                                     capture_output=True, text=True, check=True).stdout)


def work(name):
    return os.path.join(WORK, name)


def variants():
    """The sources the probes run on, built once into WORK:
    the fixture's picture (stream-copied, so its decode-order timestamps and
    the fault come along) with a chirp, the same remuxed to MOV and MP4, and
    an MPEG-4 ASP B-frame AVI with MP3 (from lavfi)."""
    out = {'fixture': FIXTURE}
    chirp = work('chirp.avi')
    if not os.path.exists(chirp):
        ff('-i', FIXTURE, '-f', 'lavfi', '-i', CHIRP, '-map', '0:v', '-c:v', 'copy',
           '-map', '1:a', '-c:a', 'pcm_s16le', chirp)
    out['chirp'] = chirp
    for ext in ('mov', 'mp4'):
        p = work(f'chirp.{ext}')
        if not os.path.exists(p):
            ff('-i', chirp, '-c', 'copy', p)
        out[ext] = p
    mp3 = work('mpeg4_bframes_mp3.avi')
    if not os.path.exists(mp3):
        ff('-f', 'lavfi', '-i', 'testsrc2=size=320x240:rate=30000/1001:duration=3.003',
           '-f', 'lavfi', '-i', 'aevalsrc=0.5*sin(2*PI*(200*t+300*t*t)):s=48000:d=3.003',
           '-c:v', 'mpeg4', '-bf', '2', '-g', '30', '-q:v', '4',
           '-c:a', 'libmp3lame', '-b:a', '192k', mp3)
    out['mp3'] = mp3
    return out


def samples(pre, src, post, rate=RATE, af=None):
    """Mono float samples of `src`'s first audio stream, with `pre` before -i
    and `post` after it; also whether ffmpeg said it could not seek."""
    out = work('s.raw')
    err = ff(*pre, '-i', src, *post, '-map', '0:a:0', *(['-af', af] if af else []),
             '-ac', '1', '-ar', str(rate), '-f', 'f32le', out)
    a = array.array('f')
    with open(out, 'rb') as f:
        a.frombytes(f.read())
    return a, 'could not seek' in err


def find(needle, hay, length=64, tol=1e-3, skip=0):
    """Where `needle`'s first non-silent `length` samples (after `skip`) sit
    in `hay`, as the offset of needle[0] in hay (None if nowhere). A lossy
    decode that starts somewhere else differs for its first frames (the
    decoder's warm-up), hence `skip`."""
    first = next((i for i, x in enumerate(needle) if i >= skip and abs(x) > tol), None)
    if first is None:
        return None
    seg = needle[first:first + length]
    for k in range(len(hay) - length):
        if all(abs(hay[k + j] - seg[j]) < tol for j in range(length)):
            return k - first
    return None
