"""Candidate encoder arguments for an untrimmed Passthrough into AVI (ffmpeg only).
    VAPOURBOX_DEPS_DIR=<deps> FX=<fixtures> OUT=<dir> [ONLY=AG] python3 candidates.py aac.mkv ...
Input 0 is the picture from the first frame (a Y4M, as the vspipe pipe delivers it),
input 1 the source, its sound copied (-c:a copy), as the worker's encode does."""
import json, os, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import measure, riff
FF, FP = measure.FF, measure.FP
FX, OUT = os.environ['FX'], os.environ['OUT']
os.makedirs(OUT, exist_ok=True)

def first_packets(src):
    j = json.loads(measure.run([FP, '-v', 'error', '-select_streams', 'a:0', '-read_intervals', '%+#3',
                                '-show_entries', 'packet=pts_time,duration_time', '-of', 'json', src]))
    return [(float(p['pts_time']), float(p.get('duration_time') or 0)) for p in j['packets']]

only = os.environ.get('ONLY')
for name in sys.argv[1:]:
    src = os.path.join(FX, name)
    pk = first_packets(src)
    half = max(d for _, d in pk) / 2
    y4m = os.path.join(OUT, name + '.y4m')
    if not os.path.exists(y4m):
        subprocess.run([FF, '-v', 'error', '-y', '-i', src, '-map', '0:v:0', '-pix_fmt', 'yuv420p', y4m], check=True)
    variants = {
        'A current': ([], []),
        'B -avoid_negative_ts disabled': ([], ['-avoid_negative_ts', 'disabled']),
        'C -copypriorss:a 0': ([], ['-copypriorss:a', '0']),
        'D C + disabled': ([], ['-copypriorss:a', '0', '-avoid_negative_ts', 'disabled']),
        'E -itsoffset half + C + disabled': (['-itsoffset', '%.6f' % half], ['-copypriorss:a', '0', '-avoid_negative_ts', 'disabled']),
        'F -ss 0 + C + disabled': (['-ss', '0'], ['-copypriorss:a', '0', '-avoid_negative_ts', 'disabled']),
        'G -itsoffset half + C': (['-itsoffset', '%.6f' % half], ['-copypriorss:a', '0']),
        'H G + make_zero -start_at_zero (IVTC job)': (['-itsoffset', '%.6f' % half], ['-copypriorss:a', '0', '-avoid_negative_ts', 'make_zero', '-start_at_zero']),
        'I G + disabled -start_at_zero (IVTC job, #38 form)': (['-itsoffset', '%.6f' % half], ['-copypriorss:a', '0', '-avoid_negative_ts', 'disabled', '-start_at_zero']),
    }
    for k, (label, (inp, outopt)) in enumerate(variants.items()):
        if only and label[0] not in only:
            continue
        out = os.path.join(OUT, f'{name}_{label[0]}.avi')
        r = subprocess.run([FF, '-v', 'error', '-y', '-f', 'yuv4mpegpipe', '-i', y4m, *inp, '-i', src,
                            '-map', '0:v', '-map', '1:a', '-c:v', 'ffv1', '-c:a', 'copy', *outopt, out],
                           capture_output=True, text=True)
        if r.returncode:
            print(json.dumps(dict(src=name, variant=label, error=r.stderr[-300:]))); continue
        m = measure.report(out)
        apk = first_packets(out)
        print(json.dumps(dict(src=name, variant=label, frames=riff.header(out)['avih_total_frames'],
                              v_pts=m['first_pts'][:2], lag_ms=m['lag_ms'], a_first=[round(p, 4) for p, _ in apk[:2]],
                              src_first=[round(p, 4) for p, _ in pk[:2]], warn=r.stderr.strip()[-120:])))
