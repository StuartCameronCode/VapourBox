"""Run `vapourbox-worker --detect-crop` on one video and print the report.

usage: python3 detect.py VIDEO [tff|bff|progressive] [--json]

The worker is $WORKER, else the repo's release build, else its debug build.
Prints the time taken, the recommended crop and each edge as measured; with
--json, the report itself on one line.
"""
import json
import os
import subprocess
import sys
import tempfile
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..', '..', '..'))
DEPS = os.environ.get('DEPS', os.path.join(ROOT, 'deps', 'macos-arm64'))
FFPROBE = os.path.join(DEPS, 'ffmpeg', 'ffprobe')


def worker():
    if os.environ.get('WORKER'):
        return os.environ['WORKER']
    for build in ('release', 'debug'):
        p = os.path.join(ROOT, 'worker', 'target', build, 'vapourbox-worker')
        if os.path.exists(p):
            return p
    sys.exit('build the worker first (cargo build --release)')


def detect(path, field='progressive'):
    info = json.loads(subprocess.check_output([
        FFPROBE, '-v', 'error', '-select_streams', 'v:0', '-count_packets', '-show_entries',
        'stream=width,height,pix_fmt,r_frame_rate,nb_read_packets,color_range', '-of', 'json', path]))['streams'][0]
    num, den = map(int, info['r_frame_rate'].split('/'))
    fps = num / den
    if field != 'progressive' and fps > 30:
        fps /= 2  # a field-coded stream reports its field rate
    job = {
        'id': str(uuid.uuid4()), 'inputPath': path, 'outputPath': os.path.join(tempfile.gettempdir(), 'unused.mkv'),
        'qtgmcParameters': {'enabled': False}, 'encodingSettings': {},
        'processingPipeline': {'deinterlace': {'enabled': False}},
        'detectedFieldOrder': field,
        'totalFrames': int(info.get('nb_read_packets') or 100), 'inputFrameRate': fps,
        'inputWidth': info['width'], 'inputHeight': info['height'],
        'inputPixelFormat': info['pix_fmt'], 'inputColorRange': info.get('color_range'),
    }
    with tempfile.TemporaryDirectory() as d:
        cfg = os.path.join(d, 'job.json')
        with open(cfg, 'w') as f:
            json.dump(job, f)
        start = time.perf_counter()
        out = subprocess.run([worker(), '--detect-crop', '--config', cfg], capture_output=True, text=True, timeout=900)
        dt = time.perf_counter() - start
    line = [l for l in out.stdout.splitlines() if l.startswith('{')][-1]
    return json.loads(line), dt


if __name__ == '__main__':
    path = sys.argv[1]
    field = sys.argv[2] if len(sys.argv) > 2 and not sys.argv[2].startswith('--') else 'progressive'
    report, dt = detect(path, field)
    if '--json' in sys.argv:
        print(json.dumps(report))
        sys.exit(0)
    print(f'{os.path.basename(path)}: {dt * 1000:.0f} ms, usable {report.get("usableFrames")}/{len(report.get("frames", []))}')
    if 'error' in report:
        print('  error:', report['error'])
        sys.exit(1)
    print(f'  crop {report["crop"]}  bars {report.get("cropWithBars")}  repair {report.get("edgeRepair")}')
    for side, e in report['edges'].items():
        print(f'  {side:6s} {e["kind"]:13s} measured {e["crop"]:3d} (with bars {e["cropWithBars"]:3d}) '
              f'blank {e["blank"]} ramp {e["ramp"]} band {e["band"]} conf {e["confidence"]:.2f}')
