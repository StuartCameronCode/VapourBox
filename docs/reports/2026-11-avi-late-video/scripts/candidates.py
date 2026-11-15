"""Candidate layouts (ffmpeg only, not the worker) for a late-video source in AVI, with the encoder's argument shape:
input 0 = the picture from frame 0 (as the vspipe pipe delivers it), input 1 = the source's sound."""
import json, math, os, subprocess, sys
sys.path.insert(0, os.path.dirname(__file__))
import measure
FF, FP = measure.FF, measure.FP
RES = os.environ['RES']; OUT = os.environ['OUT']

def vstart(src):
    j = json.loads(measure.run([FP, '-v', 'error', '-select_streams', 'v:0', '-show_entries',
        'stream=start_time:format=start_time', '-of', 'json', src]))
    return float(j['streams'][0]['start_time']) - float(j['format']['start_time'])

def packet(src):
    j = json.loads(measure.run([FP, '-v', 'error', '-select_streams', 'a:0', '-read_intervals', '%+#64',
        '-show_entries', 'packet=duration_time', '-of', 'json', src]))
    return max(float(p['duration_time']) for p in j['packets'] if p.get('duration_time') not in (None, 'N/A'))

def enc(out, pic_filters, audio_in, audio_out):
    a = [FF, '-y', '-v', 'error', '-i', SRC, *audio_in, '-i', SRC, '-map', '0:v', '-map', '1:a',
         '-vf', ','.join(['setpts=PTS-STARTPTS'] + pic_filters), '-c:v', 'ffv1', *audio_out,
         out]
    subprocess.run(a, check=True)
    return measure.report(out)

for SRC_NAME in sys.argv[1:]:
    SRC = os.path.join(RES, SRC_NAME); stem = os.path.splitext(SRC_NAME)[0]
    off = vstart(SRC); P = packet(SRC)
    print(f'# {SRC_NAME}: video start {off:.4f} s, longest audio packet {P*1000:.1f} ms')
    rows = {}
    # A1: start with the picture, compressed copy cut at the nearest packet (#24's method)
    rows['A copy, nearest packet'] = enc(f'{OUT}/{stem}_A_copy.avi', [], ['-ss', f'{off - P/2:.6f}'], ['-c:a', 'copy', '-copypriorss:a', '0'])
    # A2: start with the picture, sound decoded and cut exactly (as the restored track / PCM path)
    rows['A pcm, exact'] = enc(f'{OUT}/{stem}_A_pcm.avi', [], ['-ss', f'{off:.6f}'], ['-c:a', 'pcm_s16le'])
    # B: pad the head at the source rate, sound copied from 0
    K = round(off * 25)
    rows[f'B pad {K} black'] = enc(f'{OUT}/{stem}_B_black.avi', [f'tpad=start={K}:color=black'], [], ['-c:a', 'copy'])
    rows[f'B pad {K} clone'] = enc(f'{OUT}/{stem}_B_clone.avi', [f'tpad=start={K}:start_mode=clone'], [], ['-c:a', 'copy'])
    # B exact: pad floor(off*fps) frames and cut the remainder from the sound
    # (Not on a TS: a plain -ss there has no seek plan, so the cut is meaningless.)
    Kf = math.floor(off * 25 + 1e-9); r = off - Kf / 25
    if not SRC_NAME.endswith('.ts'): rows[f'B pad {Kf} + cut {r*1000:.1f} ms, pcm'] = enc(f'{OUT}/{stem}_Bx_pcm.avi', [f'tpad=start={Kf}:color=black'], ['-ss', f'{r:.6f}'] if r > 0 else [], ['-c:a', 'pcm_s16le'])
    for k, v in rows.items():
        print(json.dumps({'case': k, **{x: v[x] for x in ('v_tb', 'v_avg', 'nb_frames', 'decoded', 'first_pts', 'flashes', 'lag_ms', 'audio_secs')}}))
