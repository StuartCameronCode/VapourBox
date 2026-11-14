"""Shared paths for the timestamp-reset probes (task #21).

ffmpeg/ffprobe come from $VAPOURBOX_DEPS_DIR, else the repo's deps/<platform>;
the worker is this checkout's debug build (cd worker && cargo build). Scratch
files go to $RESET_WORK (default: a new temporary directory).
"""
import hashlib
import os
import platform
import subprocess
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..', '..', '..'))
RES = os.path.join(REPO, 'Tests', 'TestResources')


def _deps():
    if os.environ.get('VAPOURBOX_DEPS_DIR'):
        return os.environ['VAPOURBOX_DEPS_DIR']
    arch = 'arm64' if platform.machine() in ('arm64', 'aarch64') else 'x64'
    plat = {'Darwin': 'macos', 'Linux': 'linux', 'Windows': 'windows'}[platform.system()]
    return os.path.join(REPO, 'deps', f'{plat}-{arch}')


EXE = '.exe' if platform.system() == 'Windows' else ''
FF = os.path.join(_deps(), 'ffmpeg', 'ffmpeg' + EXE)
FP = os.path.join(_deps(), 'ffmpeg', 'ffprobe' + EXE)
WORKER = os.environ.get('WORKER') or os.path.join(
    REPO, 'worker', 'target', 'debug', 'vapourbox-worker' + EXE)
WORK = os.environ.get('RESET_WORK') or tempfile.mkdtemp(prefix='vb_resets_')
os.makedirs(WORK, exist_ok=True)

FIXTURES = ['seek_reset_dvd_pal.mpg', 'seek_reset_h264.ts']


def run(args, **kw):
    return subprocess.run(args, capture_output=True, check=True, **kw)


def probe(path, entries):
    out = run([FP, '-v', 'error', '-show_entries', entries, '-of', 'json', path]).stdout
    import json
    return json.loads(out)


def worker_json(*args):
    import json
    out = subprocess.run([WORKER, *args], capture_output=True, text=True).stdout
    lines = [l for l in out.splitlines() if l.strip().startswith('{')]
    return [json.loads(l) for l in lines]


def joined_copy(src):
    """The worker's continuous copy of a fixture (made once)."""
    out = os.path.join(WORK, 'joined_' + os.path.basename(src))
    if not os.path.exists(out):
        msgs = worker_json('--make-continuous', src, '--output', out)
        assert msgs[-1].get('success'), msgs
    return out


def luma_md5s(args):
    """MD5 of each output picture's 64x48 luma, for naming frames."""
    w, h = 64, 48
    raw = run([FF, '-v', 'error', *args, '-f', 'rawvideo', '-pix_fmt', 'gray',
               '-s', f'{w}x{h}', '-']).stdout
    n = w * h
    return [hashlib.md5(raw[i:i + n]).hexdigest() for i in range(0, len(raw) - n + 1, n)]
