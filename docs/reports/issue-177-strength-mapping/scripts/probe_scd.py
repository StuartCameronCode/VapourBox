"""SMDegrain's scene-change threshold (thSCD1): what it costs at a real cut.

The NR grid found SMDegrain doing nothing at noise sigma 9 at any thSAD: at
havsfunc's thSCD1=400 a block of that much noise alone counts as "changed",
so every frame reads as a scene cut and is left alone. Raising thSCD1 fixes
that; the risk is the opposite fault, a real cut not detected, so frames on
either side of it are blended with the other shot (ghosting).

Fixture `cut`: 30 frames of small_clip.mp4 from 20 s, then 30 from 70 s (a
hard cut to a different shot between frames 29 and 30), retimed to 25 fps,
lossless; and the same with sigma 6 and 9 noise from the worker's Grain pass.
Per frame, PSNR of the output against the clean cut fixture: the two frames
each side of the cut (27-32) against the rest. Ghosting shows as a dip there
that the input does not have.

Writes data/scd.json.
"""
import os
import re
import subprocess

from probelib import FFMPEG, RES, run_job, save, scratch, stream_info

CUT = 30


def cut_fixture(sigma):
    clean = scratch('fixtures', 'cut_clean.mkv')
    if not os.path.exists(clean):
        src = os.path.join(RES, 'small_clip.mp4')
        subprocess.run([FFMPEG, '-y', '-v', 'error', '-ss', '20', '-i', src, '-ss', '70', '-i', src,
                        '-filter_complex',
                        f'[0:v]trim=end_frame={CUT},setpts=PTS-STARTPTS[a];'
                        f'[1:v]trim=end_frame={CUT},setpts=PTS-STARTPTS[b];'
                        '[a][b]concat=n=2:v=1,setpts=N/25/TB[v]',
                        '-map', '[v]', '-r', '25', '-an', '-c:v', 'ffv1', clean], check=True)
    if sigma == 0:
        return clean
    out = scratch('fixtures', f'cut_n{sigma}.mkv')
    if not os.path.exists(out):
        run_job(clean, stream_info(clean), out, {
            'deinterlace': {'enabled': False},
            'grain': {'enabled': True, 'method': 'addGrain', 'var': float(sigma * sigma),
                      'uvar': float((sigma / 2) ** 2), 'corr': 0.0, 'constant': False}})
    return out


def psnr_per_frame(a, b):
    r = subprocess.run([FFMPEG, '-v', 'error', '-i', a, '-i', b, '-filter_complex',
                        '[0:v][1:v]psnr=stats_file=-', '-f', 'null', '-'],
                       capture_output=True, text=True)
    vals = [float(m) if m != 'inf' else 99.0 for m in re.findall(r'psnr_y:([\d.]+|inf)', r.stdout)]
    if not vals:
        raise RuntimeError(r.stderr[-1000:])
    return vals


def main():
    clean = cut_fixture(0)
    out = {}
    for sigma in [0, 6, 9]:
        src = cut_fixture(sigma)
        info = stream_info(src)
        base = psnr_per_frame(src, clean)
        out[f'input|{sigma}'] = {'frames': base}
        for scd in [400, 800, 1200, 2000, 4000]:
            for th in [800, 2000]:
                o = scratch('scd', f'cut_{sigma}_{scd}_{th}.mkv')
                run_job(src, info, o, {
                    'deinterlace': {'enabled': False},
                    'noiseReduction': {'enabled': True, 'method': 'smDegrain', 'smDegrainTr': 3,
                                       'smDegrainThSAD': th, 'smDegrainThSADC': th // 2,
                                       'smDegrainThSCD1': scd}})
                f = psnr_per_frame(o, clean)
                near = f[CUT - 3:CUT + 3]
                away = f[:CUT - 6] + f[CUT + 6:]
                out[f'{scd}|{th}|{sigma}'] = {
                    'frames': f, 'near_min': min(near), 'away_mean': sum(away) / len(away),
                    'dip': sum(away) / len(away) - min(near)}
                print(sigma, scd, th, round(min(near), 2), round(sum(away) / len(away), 2), flush=True)
                os.remove(o)
    save('scd.json', out)


if __name__ == '__main__':
    main()
