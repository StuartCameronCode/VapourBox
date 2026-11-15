"""Run the late-video fixtures through a worker binary to AVI (and MKV as the
control), untrimmed with Passthrough sound, and measure each output with
measure.py. Usage: worker_avi_late.py WORKER OUT_DIR. Needs VAPOURBOX_DEPS_DIR.

Each line is one output: its video time base and average rate, the frame count
stored in the file (null frames included), the frames decoded, the first
frames' times, and the lag of each beep after its white frame (ms).
"""
import json, os, subprocess, sys, uuid
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import measure

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..', '..'))
RES = os.path.join(REPO, 'Tests', 'TestResources')
WORKER, OUT = sys.argv[1], sys.argv[2]
os.makedirs(OUT, exist_ok=True)


def run_job(src, out, codec, container, restore, small=True):
    j = dict(id=str(uuid.uuid4()), inputPath=os.path.join(RES, src), outputPath=out,
             qtgmcParameters=dict(enabled=False),
             processingPipeline=dict(deinterlace=dict(enabled=False)),
             encodingSettings=dict(codec=codec, container=container, audioMode='passthrough'),
             inputFrameRate=25.0)
    if small:
        j.update(inputWidth=320, inputHeight=240, inputPixelFormat='yuv420p', totalFrames=100)
    if restore:
        j['processingPipeline']['audio'] = dict(enabled=True, limiter=True)
    cfg = out + '.json'
    with open(cfg, 'w') as f:
        json.dump(j, f)
    r = subprocess.run([WORKER, '--config', cfg], capture_output=True, text=True)
    notes = [json.loads(l)['message'] for l in r.stdout.splitlines()
             if l.startswith('{') and '"level":"info"' in l and 'AVI cannot' in l]
    return r.returncode == 0 and os.path.exists(out), notes


CASES = [(src, codec, container, restore)
         for src in ['late_video_intra.ts', 'late_video_gop.ts', 'late_video.mp4', 'late_video.mkv']
         for codec, container, restore in [('ffv1', 'avi', False), ('huffyuv', 'avi', False),
                                            ('ffv1', 'avi', True), ('ffv1', 'mkv', False)]]
CASES.append(('pal-dvbt-fieldcoded-25i.ts', 'ffv1', 'avi', False))

for src, codec, container, restore in CASES:
    stem = os.path.splitext(src)[0] + '_' + src.rsplit('.', 1)[1]
    out = os.path.join(OUT, f'{stem}_{codec}_{"restored" if restore else "copy"}.{container}')
    ok, notes = run_job(src, out, codec, container, restore, small=not src.startswith('pal-'))
    if not ok:
        print(json.dumps(dict(source=src, file=os.path.basename(out), failed=True)))
        continue
    r = measure.report(out)
    r.pop('beeps', None)
    print(json.dumps(dict(source=src, restored=restore, **r, notes=notes)))
