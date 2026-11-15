"""Candidate encoder arguments for Convert into AVI (ffmpeg only, not the worker).

    RES=<Tests/TestResources> OUT=<dir> python3 candidates.py late_video_intra.ts late_video.mp4

The encoder's shape: input 0 is the picture from the first frame (as the vspipe
pipe delivers it, here a Y4M made once per source), input 1 the source's sound
seeked to the first picture (the video start offset, as for any AVI since task
#30). P is each encoder's priming in samples (priming.py) at 48 kHz.
"""
import json, math, os, subprocess, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import measure, riff

FF, FP = measure.FF, measure.FP
RES, OUT = os.environ['RES'], os.environ['OUT']
os.makedirs(OUT, exist_ok=True)
PRIME = {'aac': 1024, 'libmp3lame': 1105, 'ac3': 256}


def up(t):
    """Rounded up to the microsecond, as source_decode::seek_arg."""
    return '%.6f' % (math.ceil(t * 1e6 - 1e-3) / 1e6)


def starts(src):
    j = json.loads(measure.run([FP, '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                                'stream=start_time:format=start_time', '-of', 'json', src]))
    return float(j['streams'][0]['start_time']), float(j['format']['start_time'])


for name in sys.argv[1:]:
    src = os.path.join(RES, name)
    vst, cst = starts(src)
    off = vst - cst
    y4m = os.path.join(OUT, name + '.y4m')
    if not os.path.exists(y4m):
        subprocess.run([FF, '-v', 'error', '-y', '-copyts', '-i', src, '-map', '0:v:0', '-vf',
                        f'setpts=PTS-{vst}/TB,fps=25/1,trim=start_pts=0,setpts=PTS-STARTPTS',
                        '-frames:v', '100', '-pix_fmt', 'yuv420p', y4m], check=True)
    for codec, p in PRIME.items():
        secs = p / 48000
        variants = {
            'current (-ss off)': (['-ss', up(off)], []),
            '-avoid_negative_ts disabled only': (['-ss', up(off)], ['-avoid_negative_ts', 'disabled']),
            '-bsf:a setts=ts=TS+P only': (['-ss', up(off)], ['-bsf:a', f'setts=ts=TS+{p}']),
            '-ss off+P -itsoffset P': (['-ss', up(off + secs), '-itsoffset', up(secs)], []),
            '-ss off+P + -avoid_negative_ts disabled': (['-ss', up(off + secs)], ['-avoid_negative_ts', 'disabled']),
            '-ss off+P + -bsf:a setts=ts=TS+P': (['-ss', up(off + secs)], ['-bsf:a', f'setts=ts=TS+{p}']),
        }
        for k, (label, (inp, outopt)) in enumerate(variants.items()):
            out = os.path.join(OUT, f'{name}_{codec}_{k}.avi')
            r = subprocess.run([FF, '-v', 'error', '-y', '-f', 'yuv4mpegpipe', '-i', y4m, *inp, '-i', src,
                                '-map', '0:v', '-map', '1:a', '-c:v', 'ffv1', '-c:a', codec, '-b:a', '128k',
                                *outopt, out], capture_output=True, text=True)
            if r.returncode:
                print(json.dumps(dict(src=name, codec=codec, variant=label, error=r.stderr[-300:])))
                continue
            m = measure.report(out)
            print(json.dumps(dict(src=name, codec=codec, variant=label,
                                  avih_total_frames=riff.header(out)['avih_total_frames'],
                                  first_pts=m['first_pts'], flashes=m['flashes'], lag_ms=m['lag_ms'])))
