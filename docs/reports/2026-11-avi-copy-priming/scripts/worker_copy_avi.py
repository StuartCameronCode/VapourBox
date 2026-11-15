"""Every worker job in the report: Passthrough into AVI of a primed source.

    VAPOURBOX_DEPS_DIR=<deps> python3 worker_copy_avi.py <worker> <out dir> <fixtures dir>

<fixtures dir> holds fixtures.sh's sources; the committed primed_aac.mkv /
primed_mp3.mp4 and small_clip.mp4 come from Tests/TestResources. One JSON line
per output: the AVI header's frame count (riff.py, null frames included), the
first picture times, the beep-minus-flash lag in decoded samples (measure.py),
and whether the job log says the head was cut.
"""
import json, os, subprocess, sys, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import measure, riff

REPO = os.path.abspath(os.path.join(HERE, '..', '..', '..', '..'))
RES = os.path.join(REPO, 'Tests', 'TestResources')
WORKER, OUT, FX = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(OUT, exist_ok=True)


def job(src, name, container='avi', trim=None):
    out = os.path.join(OUT, f'{name}.{container}')
    es = dict(codec='ffv1', container=container, audioMode='passthrough')
    j = dict(id=str(uuid.uuid4()), inputPath=src, outputPath=out,
             qtgmcParameters=dict(enabled=False), processingPipeline=dict(deinterlace=dict(enabled=False)),
             encodingSettings=es)
    if 'small_clip' in src:
        j.update(inputFrameRate=29.97)
    else:
        j.update(inputFrameRate=25.0, inputWidth=320, inputHeight=240, inputPixelFormat='yuv420p', totalFrames=100)
    if trim:
        j.update(startFrame=trim[0], endFrame=trim[1], totalFrames=trim[1] - trim[0] + 1)
    cfg = out + '.json'
    json.dump(j, open(cfg, 'w'))
    r = subprocess.run([WORKER, '--config', cfg], capture_output=True, text=True)
    log = r.stdout + r.stderr
    open(out + '.log', 'w').write(log)
    ok = r.returncode == 0 and os.path.exists(out)
    return (out if ok else None), 'packet nearest the first picture' in log


def row(case, res, flashes_wanted=True):
    out, cut = res
    if out is None:
        print(json.dumps(dict(case=case, failed=True)))
        return
    d = dict(case=case, head_cut_logged=cut)
    if out.endswith('.avi'):
        d['avih_total_frames'] = riff.header(out)['avih_total_frames']
    m = measure.report(out)
    d['first_pts'] = m['first_pts']
    if flashes_wanted:
        d.update(flashes=m['flashes'], lag_ms=m['lag_ms'])
    print(json.dumps(d))


sources = [os.path.join(RES, 'primed_aac.mkv'), os.path.join(RES, 'primed_mp3.mp4')] + [
    os.path.join(FX, f) for f in ('aac.mkv', 'aac.mp4', 'aac44.mkv', 'mp3.mkv', 'mp3.mp4', 'ac3.mkv', 'mp2.mkv',
                                  'master48000.mkv')]
for src in sources:
    stem = os.path.basename(src).replace('.', '_')
    row(f'{os.path.basename(src)} untrimmed', job(src, stem))
    row(f'{os.path.basename(src)} trimmed 30..89', job(src, stem + '_trim', trim=(30, 89)))
    row(f'{os.path.basename(src)} untrimmed to MKV (control)', job(src, stem, container='mkv'))
row('small_clip.mp4 untrimmed', job(os.path.join(RES, 'small_clip.mp4'), 'small_clip'), flashes_wanted=False)
