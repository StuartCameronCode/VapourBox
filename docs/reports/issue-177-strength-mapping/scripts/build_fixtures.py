"""Build the probe's fixtures in $SCRATCH/fixtures.

Clean sources (lossless FFV1, cut from committed test footage, retimed to 25 fps):
  cam    small_clip.mp4, 60 frames from 20 s (320x240 camera footage, 4:2:0)
  film   colorize_test.mp4, frames 30-89 (640x480 film, 4:2:0)
  dvbt   pal-dvbt-fieldcoded-25i.ts, top fields of the first 60 frames
         (720x288 progressive broadcast picture, 4:2:0)
  vhs    interlaced_test.avi, its first 60 frames (720x576 interlaced 4:2:2;
         only for QTGMC's built-in denoiser, which needs deinterlacing on)

Noisy copies: each clean source through the worker's own Grain pass
(core.grain.Add, animated, uncorrelated), luma sigma S and chroma sigma S/2,
for S in NOISE_SIGMAS. `var` is a variance, so var = S^2.

Soft copies (Sharpen): each progressive clean source blurred with ffmpeg's
gblur at sigma B px on every plane, for B in BLUR_SIGMAS.

Writes data/fixtures.json: the measured noise (PSNR of noisy vs clean, and the
worker's noise score) of every fixture.
"""
import concurrent.futures as cf
import os
import subprocess

from probelib import FFMPEG, RES, compare, noise_halo, run_job, save, scratch, stream_info

NOISE_SIGMAS = [2, 4, 6, 9]
BLUR_SIGMAS = [0.5, 0.8, 1.2, 1.6]

SOURCES = {
    'cam': dict(src='small_clip.mp4', pre=['-ss', '20'], post=['-frames:v', '60'], vf=None, fo=None),
    'film': dict(src='colorize_test.mp4', pre=[], post=[],
                 vf='trim=start_frame=30:end_frame=90,setpts=PTS-STARTPTS', fo=None),
    'dvbt': dict(src='pal-dvbt-fieldcoded-25i.ts', pre=[], post=['-frames:v', '60'], vf='field=top', fo=None),
    'vhs': dict(src='interlaced_test.avi', pre=[], post=['-frames:v', '60'], vf=None, fo='tt'),
}
PROGRESSIVE = ['cam', 'film', 'dvbt']


def clean(name):
    s = SOURCES[name]
    out = scratch('fixtures', f'{name}_clean.mkv')
    if os.path.exists(out):
        return out
    args = [FFMPEG, '-y', '-v', 'error', *s['pre'], '-i', os.path.join(RES, s['src']),
            '-map', '0:v:0', *s['post']]
    # Every fixture is retimed to exactly 25 fps from 0: Matroska's 1 ms time
    # base can't hold 29.97 or 24 fps exactly, and the uneven timestamps made
    # the worker's source grid repeat and drop frames against ffmpeg's own
    # frame-by-frame reading (passthrough read 33 dB on `cam` before this).
    vf = ','.join(([s['vf']] if s['vf'] else []) + ['setpts=N/25/TB'])
    args += ['-vf', vf, '-r', '25']
    if s['fo']:
        args += ['-field_order', s['fo']]
    args += ['-an', '-c:v', 'ffv1', out]
    subprocess.run(args, check=True)
    return out


def noisy(name, sigma):
    out = scratch('fixtures', f'{name}_n{sigma}.mkv')
    if os.path.exists(out):
        return out
    src = clean(name)
    info = stream_info(src)
    pipeline = {
        'deinterlace': {'enabled': False},
        'grain': {'enabled': True, 'method': 'addGrain', 'var': float(sigma * sigma),
                  'uvar': float((sigma / 2) ** 2), 'corr': 0.0, 'constant': False},
    }
    return run_job(src, info, out, pipeline,
                   field_order='tff' if SOURCES[name]['fo'] else None)


def soft(name, b):
    out = scratch('fixtures', f'{name}_b{b}.mkv')
    if os.path.exists(out):
        return out
    subprocess.run([FFMPEG, '-y', '-v', 'error', '-i', clean(name), '-vf',
                    f'gblur=sigma={b}:steps=6:planes=15', '-c:v', 'ffv1', out], check=True)
    return out


def main():
    for n in SOURCES:
        clean(n)
    jobs = [(n, s) for n in SOURCES for s in NOISE_SIGMAS]
    with cf.ThreadPoolExecutor(4) as ex:
        list(ex.map(lambda a: noisy(*a), jobs))
        list(ex.map(lambda a: soft(*a), [(n, b) for n in PROGRESSIVE for b in BLUR_SIGMAS]))

    out = {}
    for n in SOURCES:
        c = clean(n)
        info = stream_info(c)
        fo = 'tff' if SOURCES[n]['fo'] else 'progressive'
        out[n] = {'info': info, 'clean_noise': noise_halo(c, info, fo).get('noise'), 'noisy': {}}
        for s in NOISE_SIGMAS:
            f = noisy(n, s)
            m = compare(f, c)
            # PSNR of added noise of RMS r is 20 log10(255 / r): recover r.
            rms = 255 / (10 ** (m['psnr_y'] / 20))
            out[n]['noisy'][str(s)] = {'psnr_y': m['psnr_y'], 'ssim_y': m['ssim_y'],
                                       'rms_y': round(rms, 3),
                                       'noise_score': noise_halo(f, info, fo).get('noise')}
            print(n, s, out[n]['noisy'][str(s)], flush=True)
        if n in PROGRESSIVE:
            out[n]['soft'] = {}
            for b in BLUR_SIGMAS:
                f = soft(n, b)
                m = compare(f, c)
                nh = noise_halo(f, info, fo)
                out[n]['soft'][str(b)] = {'psnr_y': m['psnr_y'], 'ssim_y': m['ssim_y'],
                                          'halo': nh.get('halo')}
                print(n, b, out[n]['soft'][str(b)], flush=True)
    save('fixtures.json', out)


if __name__ == '__main__':
    main()
