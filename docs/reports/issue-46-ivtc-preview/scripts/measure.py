"""Task #46: which picture does the preview show under IVTC / Soft Telecine,
and is it the encode's?

For every case below the worker encodes the job losslessly (FFV1 in MKV) and
previews each listed source frame. Three pictures are then named by the film
frame they hold:

  slot     the source frame (slot) itself, decoded independently of the worker
           (plain decode for the hard-telecined files, `fps` onto the 29.97
           grid for the soft-telecined ones), each FIELD separately: a
           hard-telecined slot can hold two film frames, one per field.
  preview  the worker's preview PNG.
  encode   the encode's frame closest to the preview.

Every fixture is testsrc2 at 24000/1001 (generate_telecine_test.sh,
generate_prores422_10bit_test.sh, generate_source_grid_test.sh), so the film
is regenerated here from lavfi and each picture is named by the nearest film
field (luma thumbnails, mean/std normalised, so range and matrix don't matter).

A preview is RIGHT when it is one of the encode's frames and holds the slot's
film frame, or the frame the encode shows in its place (see `verdict`). "film off" is how many film frames the preview's
lies outside the slot's (0: one of them; -1: one film frame early). "MAD" is the mean
absolute RGB difference, 0-255, between the preview PNG and that encode frame
decoded with ffmpeg's own YUV->RGB: about 1 for the same picture (the two
conversions differ), tens for a different one. It cannot say that two different
pictures are "close"; only the film naming does that.

  python3 measure.py --worker PATH [--json out.json] [--only NAME,...]

Paths: VAPOURBOX_DEPS_DIR (default <repo>/deps/<platform>) for ffmpeg,
IVTC_WORK for scratch (default: a new temporary directory).
"""
import json
import os
import platform
import re
import subprocess
import sys
import tempfile
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..', '..', '..'))
RES = os.path.join(REPO, 'Tests', 'TestResources')


def _platform_id():
    m = platform.machine().lower()
    arch = 'arm64' if m in ('arm64', 'aarch64') else 'x64'
    s = platform.system()
    return f'macos-{arch}' if s == 'Darwin' else 'windows-x64' if s == 'Windows' else f'linux-{arch}'


DEPS = os.environ.get('VAPOURBOX_DEPS_DIR') or os.path.join(REPO, 'deps', _platform_id())
EXE = '.exe' if platform.system() == 'Windows' else ''
FF = os.path.join(DEPS, 'ffmpeg', 'ffmpeg' + EXE)
WORK = os.environ.get('IVTC_WORK') or tempfile.mkdtemp(prefix='ivtc46_')
os.makedirs(WORK, exist_ok=True)

TW, TH = 88, 30          # one field's thumbnail
FULL_RGB = 'scale=in_range=tv:out_range=pc,format=rgb24'

# name: fixture, size, slots, film frames, how to decode the slots, deinterlace
FIXTURES = {
    'hard': dict(file='hard_telecine_test.avi', w=720, h=480, pix='yuv420p', slots=90, film=72,
                 slot_vf=''),
    'prores10': dict(file='prores422_10bit_telecine.mov', w=720, h=480, pix='yuv422p10le', slots=30, film=24,
                     slot_vf=''),
    'dvd_vob': dict(file='soft_telecine_dvd.vob', w=352, h=240, pix='yuv420p', slots=150, film=120,
                    slot_vf='setpts=PTS-STARTPTS,fps=30000/1001,'),
    'dvd_mkv': dict(file='soft_telecine_dvd.mkv', w=352, h=240, pix='yuv420p', slots=150, film=120,
                    slot_vf='setpts=PTS-STARTPTS,fps=30000/1001,'),
}

IVTC = {'enabled': True, 'method': 'ivtc', 'tff': True, 'ivtcCycle': 5}
SOFT = {'enabled': True, 'method': 'softTelecine'}


def deflicker(window):
    return {'enabled': True, 'method': 'global', 'window': window}


FPS_5994 = {'enabled': True, 'target': 'custom', 'customFps': 59.94, 'method': 'flowFps'}

# name: fixture, deinterlace, extra pipeline, targets, trim (start, end)
CASES = {
    'ivtc_r5': ('hard', IVTC, {}, list(range(0, 7)) + list(range(40, 50)) + list(range(83, 90)), None),
    'ivtc_r8': ('hard', IVTC, {'deflicker': deflicker(8)}, list(range(40, 50)), None),
    'ivtc_r12': ('hard', IVTC, {'deflicker': deflicker(12)}, list(range(40, 50)), None),
    'ivtc_trim': ('hard', IVTC, {}, list(range(23, 33)) + list(range(64, 71)), (23, 70)),
    'ivtc_prores10': ('prores10', IVTC, {}, list(range(0, 30)), None),
    # The independent `fps` decode of the VOB holds 149 slots (its last
    # picture has no timestamp; task #26), so its tail is checked on the MKV.
    'soft_vob_r5': ('dvd_vob', SOFT, {}, list(range(0, 7)) + list(range(60, 70)), None),
    'soft_mkv_r5': ('dvd_mkv', SOFT, {}, list(range(60, 70)) + list(range(143, 150)), None),
    'soft_vob_r8': ('dvd_vob', SOFT, {'deflicker': deflicker(8)}, list(range(60, 70)), None),
    'ivtc_fps5994': ('hard', IVTC, {'frameRate': FPS_5994}, list(range(40, 45)), None),
}


def ff(args, **kw):
    r = subprocess.run([FF, '-v', 'error', '-y', *args], capture_output=True, **kw)
    if r.returncode:
        raise RuntimeError(r.stderr.decode(errors='replace')[-500:])
    return r.stdout


def field_thumbs(inputs, vf_head, count=None):
    """[(top, bottom)] luma thumbnails of every picture, normalised."""
    out = []
    for parity in ('top', 'bottom'):
        raw = ff([*inputs, '-vf', f'{vf_head}{FULL_RGB},field={parity},scale={TW}:{TH}:flags=area,format=gray',
                  *(['-frames:v', str(count)] if count else []), '-f', 'rawvideo', '-'])
        n = len(raw) // (TW * TH)
        out.append([_norm(raw[i * TW * TH:(i + 1) * TW * TH]) for i in range(n)])
    return list(zip(*out))


def _norm(b):
    n = len(b)
    m = sum(b) / n
    sd = (sum((x - m) ** 2 for x in b) / n) ** 0.5 or 1.0
    return [(x - m) / sd for x in b]


def nearest(thumb, refs):
    best, bi = None, -1
    for i, r in enumerate(refs):
        d = sum(abs(a - b) for a, b in zip(thumb, r))
        if best is None or d < best:
            best, bi = d, i
    return bi


_film_cache = {}


def film_fields(fx):
    key = (fx['w'], fx['h'])
    if key not in _film_cache:
        _film_cache[key] = field_thumbs(
            ['-f', 'lavfi', '-i', f'testsrc2=size={fx["w"]}x{fx["h"]}:rate=24000/1001,format=yuv420p'],
            '', count=fx['film'] + 2)
    return _film_cache[key]


def name_picture(fields, film):
    return tuple(nearest(f, [ff_[i] for ff_ in film]) for i, f in enumerate(fields))


def rgb_frames(path, w, h):
    raw = ff(['-i', path, '-map', '0:v:0', '-vf', FULL_RGB, '-f', 'rawvideo', '-'])
    size = w * h * 3
    return [raw[i * size:(i + 1) * size] for i in range(len(raw) // size)]


def mad(a, b):
    return sum(abs(x - y) for x, y in zip(a, b)) / len(a)


def job_json(fx, deint, extra, trim, out):
    pipeline = {'deinterlace': deint, **extra}
    total = fx['slots'] if trim is None else trim[1] - trim[0] + 1
    j = {'id': str(uuid.uuid4()), 'inputPath': os.path.join(RES, fx['file']), 'outputPath': out,
         'qtgmcParameters': deint, 'processingPipeline': pipeline,
         'encodingSettings': {'codec': 'ffv1', 'container': 'mkv', 'audioMode': 'none'},
         'detectedFieldOrder': 'tff' if deint['method'] == 'ivtc' else 'progressive',
         'inputFrameRate': 30000 / 1001, 'inputWidth': fx['w'], 'inputHeight': fx['h'],
         'inputPixelFormat': fx['pix'], 'totalFrames': total}
    if trim:
        j['startFrame'], j['endFrame'] = trim
    return j


def run_case(worker, name):
    fxname, deint, extra, targets, trim = CASES[name]
    fx = FIXTURES[fxname]
    film = film_fields(fx)
    src = os.path.join(RES, fx['file'])
    slots = field_thumbs(['-i', src], fx['slot_vf'])
    slot_film = [name_picture(s, film) for s in slots]

    out = os.path.join(WORK, f'{name}.mkv')
    job = job_json(fx, deint, extra, trim, out)
    cfg = os.path.join(WORK, f'{name}.json')
    json.dump(job, open(cfg, 'w'))
    r = subprocess.run([worker, '--config', cfg], capture_output=True)
    if r.returncode or not os.path.exists(out):
        raise RuntimeError(f'{name}: encode failed: {r.stderr.decode(errors="replace")[-800:]}')
    enc_fields = field_thumbs(['-i', out], '')
    enc_film = [name_picture(e, film) for e in enc_fields]
    enc_rgb = rgb_frames(out, fx['w'], fx['h'])
    retime = 'frameRate' in extra

    rows = []
    for t in targets:
        n_sub = 1
        k = 0
        while k < n_sub:
            r = subprocess.run([worker, '--config', cfg, '--preview', '--frame', str(t), '--sub-frame', str(k)],
                               capture_output=True)
            logs = r.stderr.decode(errors='replace')
            if r.returncode or not r.stdout:
                rows.append({'target': t, 'sub': k, 'error': logs[-400:]})
                break
            info = re.search(r'PREVIEW_INFO:frame=\d+ sub_frame=(\d+) sub_frames=(\d+)', logs)
            n_sub = int(info.group(2)) if (retime and info) else 1
            line = re.search(r'Preview: source frame .*', logs)
            png = os.path.join(WORK, f'{name}_{t}_{k}.png')
            open(png, 'wb').write(r.stdout)
            pv_fields = field_thumbs(['-i', png], '')[0]
            pv_film = name_picture(pv_fields, film)
            pv_rgb = ff(['-i', png, '-vf', 'format=rgb24', '-f', 'rawvideo', '-'])
            # The encode frame it equals: nearest by thumbnail, then measured.
            cand = sorted(range(len(enc_fields)),
                          key=lambda j: sum(abs(a - b) for f1, f2 in zip(pv_fields, enc_fields[j])
                                            for a, b in zip(f1, f2)))[:2]
            d = [round(mad(pv_rgb, enc_rgb[j]), 2) for j in cand]
            row = {'target': t, 'sub': k, 'sub_frames': n_sub, 'slot_film': list(slot_film[t]),
                   'preview_film': list(pv_film), 'encode_frame': cand[0], 'mad': d[0],
                   'next_encode': cand[1], 'next_mad': d[1],
                   'worker': line.group(0) if line else ''}
            if retime:
                # 23.976 -> 59.94 is x5/2: film frame f's outputs start at
                # encode frame ceil(5f/2).
                row['want_encode'] = sorted({-(-5 * f // 2) + k for f in slot_film[t]})
            else:
                lo, hi = min(slot_film[t]), max(slot_film[t])
                row['film_off'] = pv_film[0] - lo if pv_film[0] < lo else max(0, pv_film[0] - hi)
            rows.append(row)
            k += 1
    return {'case': name, 'fixture': fx['file'], 'encode_frames': len(enc_rgb),
            'encode_film': [list(e) for e in enc_film], 'rows': rows}


SAME = 1.5  # MAD below which the preview is taken to be that encode frame


def verdict(row, encode_film):
    """Whether the preview showed what the encode shows for its slot.

    It must be one of the encode's frames (MAD < SAME), and:
      - after a retime, the k-th output of one of the slot's film frames;
      - otherwise hold one of the slot's film frames (top field: the encode's
        first frame after an in-point is combed, VFM having no frame before
        it, and the preview's is too), or, when the encode kept none of them
        (VDecimate dropped it), the kept frame before them, as the preview
        always shows for a frame with no output of its own.
    """
    if 'error' in row:
        return False
    if 'want_encode' in row:
        return row['encode_frame'] in row['want_encode']
    if row['mad'] >= SAME:
        return False
    slot, top = set(row['slot_film']), row['preview_film'][0]
    if top in slot:
        return True
    tops = [e[0] for e in encode_film]
    if any(f in tops for f in slot):
        return False
    before = [f for f in tops if f < min(slot)]
    return top == (max(before) if before else min(tops))


def main():
    args = sys.argv[1:]
    worker = args[args.index('--worker') + 1]
    only = args[args.index('--only') + 1].split(',') if '--only' in args else list(CASES)
    results = []
    for name in only:
        res = run_case(worker, name)
        results.append(res)
        print(f'== {name} ({res["fixture"]}, {res["encode_frames"]} frames out)')
        for r in res['rows']:
            if 'error' in r:
                print(f'  {r["target"]:3d}: ERROR {r["error"]}')
                continue
            r['right'] = verdict(r, res['encode_film'])
            mark = 'ok ' if r['right'] else 'BAD'
            off = (f'film off {r["film_off"]:+d}' if 'film_off' in r
                   else f'sub {r["sub"]}/{r["sub_frames"]} want encode {r["want_encode"]}')
            print(f'  {mark} {r["target"]:3d}: slot film {r["slot_film"]} preview {r["preview_film"]} '
                  f'{off}  = encode {r["encode_frame"]} (MAD {r["mad"]}; next {r["next_encode"]} {r["next_mad"]})')
        sys.stdout.flush()
    if '--json' in args:
        json.dump(results, open(args[args.index('--json') + 1], 'w'), indent=1)


if __name__ == '__main__':
    main()
