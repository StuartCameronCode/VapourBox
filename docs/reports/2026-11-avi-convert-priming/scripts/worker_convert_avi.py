"""Every worker job in the report: Convert into AVI, per codec, through a worker.

    python3 worker_convert_avi.py <worker> <out dir> [kbps]

Prints one JSON line per output: the AVI header's frame count (riff.py; the
same field as ffprobe's nb_frames, null frames included), the first picture
times, the flashes, the beep-minus-flash lag counted in decoded samples
(measure.py), and for AAC the packets larger than the block size avienc
declares (768 bytes per channel), which ffmpeg's reader times as two packets
(task #41; not this report's fault, listed so it is not mistaken for it).
"""
import json, os, subprocess, sys, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import measure, riff

REPO = os.path.abspath(os.path.join(HERE, '..', '..', '..', '..'))
RES = os.path.join(REPO, 'Tests', 'TestResources')
WORKER, OUT = sys.argv[1], sys.argv[2]
KBPS = int(sys.argv[3]) if len(sys.argv) > 3 else 192
os.makedirs(OUT, exist_ok=True)


def job(src, name, container='avi', codec='aac', trim=None, restore=False):
    out = os.path.join(OUT, f'{name}.{container}')
    es = dict(codec='ffv1', container=container, audioMode='convert', audioCodec=codec, audioQuality=KBPS)
    j = dict(id=str(uuid.uuid4()), inputPath=os.path.join(RES, src), outputPath=out,
             qtgmcParameters=dict(enabled=False), processingPipeline=dict(deinterlace=dict(enabled=False)),
             encodingSettings=es)
    if src.startswith('late_'):
        j.update(inputFrameRate=25.0, inputWidth=320, inputHeight=240, inputPixelFormat='yuv420p', totalFrames=100)
    else:
        j.update(inputFrameRate=29.97)
    if trim:
        j.update(startFrame=trim[0], endFrame=trim[1], totalFrames=trim[1] - trim[0] + 1)
    if restore:
        j['processingPipeline']['audio'] = dict(enabled=True, limiter=True)
    cfg = out + '.json'
    json.dump(j, open(cfg, 'w'))
    r = subprocess.run([WORKER, '--config', cfg], capture_output=True, text=True)
    open(out + '.log', 'w').write(r.stdout + r.stderr)
    return out if r.returncode == 0 and os.path.exists(out) else None


def oversized(path):
    a = json.loads(measure.run([measure.FP, '-v', 'error', '-select_streams', 'a:0', '-show_entries',
                                'stream=codec_name,channels:packet=size', '-of', 'json', path]))
    s = a['streams'][0]
    if s['codec_name'] != 'aac':
        return None
    return sum(1 for p in a['packets'] if int(p['size']) > 768 * int(s['channels']))


def row(case, out, flashes_wanted=True):
    if out is None:
        print(json.dumps(dict(case=case, failed=True)))
        return
    if out.endswith('.avi'):
        h = riff.header(out)
        stored = h['avih_total_frames']
        vlen = next((s['length'] for s in h['streams'] if s['type'] == 'vids'), None)
    else:
        stored = vlen = None
    d = dict(case=case, avih_total_frames=stored, video_strh_length=vlen)
    if flashes_wanted:
        m = measure.report(out)
        d.update(decoded=m['decoded'], first_pts=m['first_pts'], flashes=m['flashes'], lag_ms=m['lag_ms'],
                 audio_codec=m['audio_codec'])
    d['aac_packets_over_block_align'] = oversized(out)
    print(json.dumps(d))


for src in ('late_video.mp4', 'late_video_intra.ts', 'late_video.mkv'):
    stem = os.path.splitext(src)[0]
    for codec in ('aac', 'libmp3lame', 'ac3', 'flac', 'pcm_s16le'):
        row(f'{src} untrimmed {codec}', job(src, f'{stem}_{codec}', codec=codec))
    row(f'{src} untrimmed aac, restored', job(src, f'{stem}_aac_restored', restore=True))
    row(f'{src} trimmed 30..89 aac', job(src, f'{stem}_aac_trim', trim=(30, 89)))
    row(f'{src} untrimmed aac to MKV (control)', job(src, f'{stem}_aac', container='mkv'))

# small_clip has no flashes or beeps: only the stored count is checked.
for trim, name in (((0, 49), 'trim'), (None, 'full')):
    for codec in ('aac', 'ac3'):
        row(f'small_clip.mp4 {name} {codec}', job('small_clip.mp4', f'small_clip_{name}_{codec}', codec=codec, trim=trim),
            flashes_wanted=False)
