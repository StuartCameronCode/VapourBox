"""Shared helpers for the Strength mapping probe (issue #177).

Standard library only. Every filtered output is made by the worker itself
(`vapourbox-worker --config job.json`, FFV1 in MKV, lossless), so the numbers
are for exactly what the app runs. Fixtures are made with the bundle's vspipe
and ffmpeg; scores come from ffmpeg's `psnr` / `ssim` filters and the worker's
`--detect-noise-halo`.

Paths: the repo is found from this file's location; the bundle is
deps/<platform> (override with $DEPS); the worker is
worker/target/debug/vapourbox-worker (override with $WORKER); scratch files go
to $SCRATCH.
"""
import json
import os
import platform
import re
import subprocess
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
REPORT = os.path.dirname(HERE)
REPO = os.path.abspath(os.path.join(REPORT, '..', '..', '..'))
RES = os.path.join(REPO, 'Tests', 'TestResources')
DATA = os.path.join(REPORT, 'data')


def _platform_id():
    m = platform.machine().lower()
    arch = 'arm64' if m in ('arm64', 'aarch64') else 'x64'
    sysname = {'Darwin': 'macos', 'Linux': 'linux', 'Windows': 'windows'}[platform.system()]
    return f'{sysname}-{arch}'


DEPS = os.environ.get('DEPS', os.path.join(REPO, 'deps', _platform_id()))
FFMPEG = os.path.join(DEPS, 'ffmpeg', 'ffmpeg')
FFPROBE = os.path.join(DEPS, 'ffmpeg', 'ffprobe')
WORKER = os.environ.get('WORKER', os.path.join(REPO, 'worker', 'target', 'debug', 'vapourbox-worker'))


def scratch(*parts):
    s = os.environ.get('SCRATCH')
    if not s:
        raise SystemExit('set SCRATCH to a scratch directory')
    p = os.path.join(s, *parts)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    return p


def env():
    """The worker's environment, as WorkerHarness.workerEnv builds it (macOS/Linux)."""
    e = dict(os.environ)
    d = DEPS
    py = os.path.join(d, 'python')
    if os.path.isdir(py):
        e['PYTHONHOME'] = py
    e['PYTHONPATH'] = ':'.join([d, os.path.join(d, 'python-packages')])
    e['PYTHONNOUSERSITE'] = '1'
    e['XDG_CONFIG_HOME'] = os.path.join(d, 'config')
    paths = ([os.path.join(py, 'bin')] if os.path.isdir(py) else []) + [
        os.path.join(d, 'vapoursynth'), os.path.join(d, 'ffmpeg')]
    e['PATH'] = ':'.join(paths + [e.get('PATH', '')])
    lib = 'DYLD_LIBRARY_PATH' if platform.system() == 'Darwin' else 'LD_LIBRARY_PATH'
    libs = [os.path.join(d, 'vapoursynth'), os.path.join(py, 'lib')]
    if platform.system() == 'Linux':
        libs.append(os.path.join(d, 'lib'))
    e[lib] = ':'.join(libs + ([e[lib]] if e.get(lib) else []))
    return e


def vspipe_to_ffv1(script_text, out_path, field_order=None):
    """Render a VapourSynth script to a lossless FFV1 MKV."""
    vpy = out_path + '.vpy'
    with open(vpy, 'w') as f:
        f.write(script_text)
    vs = subprocess.Popen([os.path.join(DEPS, 'vapoursynth', 'vspipe'), '-c', 'y4m', vpy, '-'],
                          stdout=subprocess.PIPE, env=env())
    args = [FFMPEG, '-y', '-v', 'error', '-f', 'yuv4mpegpipe', '-i', '-']
    if field_order:
        args += ['-field_order', field_order]
    args += ['-c:v', 'ffv1', out_path]
    ff = subprocess.run(args, stdin=vs.stdout, capture_output=True, text=True)
    vs.stdout.close()
    if vs.wait() != 0 or ff.returncode != 0:
        raise RuntimeError(f'rendering {out_path}: {ff.stderr}')
    os.remove(vpy)
    return out_path


def stream_info(path):
    out = subprocess.run([FFPROBE, '-v', 'error', '-select_streams', 'v:0', '-count_frames',
                          '-show_entries', 'stream=width,height,pix_fmt,nb_read_frames,r_frame_rate',
                          '-of', 'json', path], capture_output=True, text=True, check=True).stdout
    s = json.loads(out)['streams'][0]
    num, den = s['r_frame_rate'].split('/')
    return dict(width=s['width'], height=s['height'], pix_fmt=s['pix_fmt'],
                frames=int(s['nb_read_frames']), fps=int(num) / int(den))


def run_job(src, info, out_path, pipeline, field_order=None, timeout=1800):
    """Encode `src` through the worker with `pipeline` (a ProcessingPipeline
    JSON fragment) to lossless FFV1."""
    job = {
        'id': str(uuid.uuid4()),
        'inputPath': src,
        'outputPath': out_path,
        'qtgmcParameters': {'enabled': False},
        'processingPipeline': pipeline,
        'encodingSettings': {'codec': 'ffv1', 'container': 'mkv', 'audioMode': 'none'},
        'inputWidth': info['width'],
        'inputHeight': info['height'],
        'inputPixelFormat': info['pix_fmt'],
        'inputFrameRate': info['fps'],
        'totalFrames': info['frames'],
    }
    if field_order:
        job['detectedFieldOrder'] = field_order
    cfg = out_path + '.json'
    with open(cfg, 'w') as f:
        json.dump(job, f)
    r = subprocess.run([WORKER, '--config', cfg], capture_output=True, text=True, env=env(),
                       cwd=os.path.dirname(WORKER), timeout=timeout)
    ok = any('"success":true' in l.replace(' ', '') for l in r.stdout.splitlines())
    if r.returncode != 0 or not ok or not os.path.exists(out_path):
        raise RuntimeError(f'job {out_path} failed:\n{r.stdout[-2000:]}\n{r.stderr[-2000:]}')
    os.remove(cfg)
    return out_path


_PSNR = re.compile(r'PSNR y:([\d.inf]+) u:([\d.inf]+) v:([\d.inf]+) average:([\d.inf]+)')
_SSIM = re.compile(r'SSIM Y:([\d.]+) .*?U:([\d.]+) .*?V:([\d.]+) .*?All:([\d.]+)')


def compare(dist, ref, skip=0):
    """PSNR (dB) and SSIM of `dist` against `ref`, per plane, over every frame
    from `skip`. Both are decoded as stored (no conversion)."""
    sel = f'trim=start_frame={skip},setpts=PTS-STARTPTS'
    fc = (f'[0:v]{sel}[a];[1:v]{sel}[b];[a]split[a1][a2];[b]split[b1][b2];'
          f'[a1][b1]psnr;[a2][b2]ssim')
    r = subprocess.run([FFMPEG, '-v', 'info', '-nostats', '-i', dist, '-i', ref,
                        '-filter_complex', fc, '-f', 'null', '-'],
                       capture_output=True, text=True)
    p = _PSNR.search(r.stderr)
    s = _SSIM.search(r.stderr)
    if not p or not s:
        raise RuntimeError(f'compare {dist}: {r.stderr[-1500:]}')
    f = lambda x: 99.0 if x == 'inf' else float(x)
    return dict(psnr_y=f(p.group(1)), psnr_u=f(p.group(2)), psnr_v=f(p.group(3)),
                psnr=f(p.group(4)), ssim_y=float(s.group(1)), ssim=float(s.group(4)))


def mean_abs_change(a, b, skip=0):
    """Mean absolute luma difference (8-bit levels) between two clips, via
    ffmpeg's `blend=difference` and `signalstats`."""
    sel = f'trim=start_frame={skip},setpts=PTS-STARTPTS'
    fc = (f'[0:v]{sel},extractplanes=y[a];[1:v]{sel},extractplanes=y[b];'
          f'[a][b]blend=all_mode=difference,signalstats,metadata=print:key=lavfi.signalstats.YAVG')
    r = subprocess.run([FFMPEG, '-v', 'info', '-nostats', '-i', a, '-i', b,
                        '-filter_complex', fc, '-f', 'null', '-'], capture_output=True, text=True)
    vals = [float(m) for m in re.findall(r'YAVG=([\d.]+)', r.stderr)]
    if not vals:
        raise RuntimeError(f'mean_abs_change {a}: {r.stderr[-1500:]}')
    return sum(vals) / len(vals)


def noise_halo(path, info, field_order='progressive'):
    """The worker's `--detect-noise-halo` report for `path`."""
    job = {
        'id': str(uuid.uuid4()), 'inputPath': path, 'outputPath': path + '.unused.mkv',
        'qtgmcParameters': {}, 'encodingSettings': {},
        'detectedFieldOrder': field_order, 'totalFrames': info['frames'],
        'inputFrameRate': info['fps'], 'inputWidth': info['width'],
        'inputHeight': info['height'], 'inputPixelFormat': info['pix_fmt'],
    }
    cfg = path + '.nh.json'
    with open(cfg, 'w') as f:
        json.dump(job, f)
    r = subprocess.run([WORKER, '--detect-noise-halo', '--config', cfg], capture_output=True,
                       text=True, env=env(), cwd=os.path.dirname(WORKER))
    os.remove(cfg)
    lines = [l for l in r.stdout.splitlines() if l.strip().startswith('{')]
    return json.loads(lines[-1]) if lines else {'error': r.stderr[-500:]}


def save(name, obj):
    os.makedirs(DATA, exist_ok=True)
    with open(os.path.join(DATA, name), 'w') as f:
        json.dump(obj, f, indent=1, sort_keys=True)
        f.write('\n')


def load(name):
    with open(os.path.join(DATA, name)) as f:
        return json.load(f)
