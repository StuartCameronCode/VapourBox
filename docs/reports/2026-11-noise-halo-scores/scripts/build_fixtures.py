"""Build every fixture the probe measures into $SCRATCH/fx, plus fx/manifest.json.

Sources ($SCRATCH/src, fetched by fetch_sources.sh):
  * Kodak PhotoCD images kodim01/03/05/08/13/19/23, panned 2 px a frame.
  * NASA JSC "Anne McClain Talks with Fox13 News" (public domain, 1080p).
  * "Night of the Living Dead" (1968, public domain; 1440x1080 10-bit AV1).
  * The repo's own fixtures in Tests/TestResources.

Each fixture is 8 frames (real clips: 8 consecutive frames from a chosen
point), stored as lossless FFV1. Degradations are applied to luma in float and
then quantised; chroma is neutral for the built ones. Every fixture carries
its ground truth: the noise sigma added (8-bit levels) and the sharpening
applied, and the class it ought to land in:

  noise: "high" (clearly needs Noise Reduction), "clean", or "grey" (between:
         the score may land either side and neither is wrong);
  halo:  the same for Dehalo.
"""
import json
import math
import os
import subprocess

import numpy as np

import probelib as L

N = 8
SRC = L.scratch('src')
FX = L.scratch('fx')
os.makedirs(FX, exist_ok=True)
manifest = []


def add(name, frames, *, group, noise_class, halo_class, sigma=0.0, sharpen='', bits=8,
        interlaced=None, note=''):
    path = os.path.join(FX, name + '.mkv')
    if not os.path.exists(path):
        L.write_ffv1(L.quantize(frames, bits), path, bits=bits, interlaced=interlaced)
    manifest.append(dict(name=name, path=path, group=group, noise_class=noise_class,
                         halo_class=halo_class, sigma=sigma, sharpen=sharpen, bits=bits,
                         interlaced=bool(interlaced), note=note))


def add_file(name, src, start, *, group, noise_class, halo_class, interlaced=False, note=''):
    """N consecutive frames of a real clip, stored losslessly in its own format."""
    path = os.path.join(FX, name + '.mkv')
    if not os.path.exists(path):
        w, h, fmt = L.probe(src)
        args = [L.FFMPEG, '-v', 'error', '-y']
        if start > 0:
            args += ['-ss', str(start)]
        args += ['-i', src, '-map', '0:v:0', '-frames:v', str(N), '-c:v', 'ffv1', '-level', '3',
                 '-pix_fmt', fmt]
        if interlaced:
            args += ['-field_order', 'tt']
        subprocess.run(args + [path], check=True)
    manifest.append(dict(name=name, path=path, group=group, noise_class=noise_class,
                         halo_class=halo_class, sigma=None, sharpen='', bits=None,
                         interlaced=interlaced, note=note))


def roundtrip_x264(frames, crf, name):
    """Encode with x264 and decode again: noise as a viewer actually gets it."""
    tmp = os.path.join(FX, f'_tmp_{name}.mkv')
    L.write_ffv1(L.quantize(frames), tmp)
    enc = os.path.join(FX, f'_tmp_{name}.mp4')
    subprocess.run([L.FFMPEG, '-v', 'error', '-y', '-i', tmp, '-c:v', 'libx264', '-preset', 'medium',
                    '-crf', str(crf), '-pix_fmt', 'yuv420p', enc], check=True)
    out = L.luma(enc, 0, len(frames))
    os.remove(tmp)
    os.remove(enc)
    return out


def lanczos2x(a):
    """2x Lanczos-3 upscale, separable, centre-aligned (as zimg/ffmpeg do)."""
    def kern(x):
        x = np.abs(x)
        return np.where(x < 3, np.sinc(x) * np.sinc(x / 3), 0.0)

    def up(m):
        h, w = m.shape
        out = np.zeros((h, 2 * w), np.float32)
        p = np.pad(m, ((0, 0), (3, 3)), mode='edge')
        for o in range(2 * w):
            src = (o + 0.5) / 2 - 0.5
            i0 = int(math.floor(src))
            taps = np.arange(i0 - 2, i0 + 4)
            wts = kern(src - taps)
            wts = wts / wts.sum()
            out[:, o] = (p[:, taps + 3] * wts[None, :]).sum(axis=1)
        return out
    return up(up(a).T).T


def cel(n, w=720, h=480, ss=4):
    """Flat animation: flat fills with 3 px dark outlines, antialiased by
    supersampling, moving 3 px a frame. No noise, no sharpening."""
    frames = []
    H, W = h * ss, w * ss
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32) / ss
    for t in range(n):
        img = np.full((H, W), 175.0, np.float32)
        img[yy > 330] = 140.0  # ground
        shapes = [
            ('ellipse', 220 + 3 * t, 230, 120, 90, 110.0),
            ('ellipse', 480 - 2 * t, 200, 70, 70, 205.0),
            ('rect', 80 + 3 * t, 300, 180, 120, 60.0),
            ('ellipse', 560, 380 - t, 60, 40, 225.0),
        ]
        for kind, cx, cy, rx, ry, level in shapes:
            if kind == 'ellipse':
                d = np.sqrt(((xx - cx) / rx) ** 2 + ((yy - cy) / ry) ** 2)
                inside = d <= 1.0
                outline = (d > 1.0) & (d <= 1.0 + 3.0 / min(rx, ry))
            else:
                inside = (np.abs(xx - cx) <= rx / 2) & (np.abs(yy - cy) <= ry / 2)
                outer = (np.abs(xx - cx) <= rx / 2 + 3) & (np.abs(yy - cy) <= ry / 2 + 3)
                outline = outer & ~inside
            img[inside] = level
            img[outline] = 30.0
        frames.append(img.reshape(h, ss, w, ss).mean(axis=(1, 3)))
    return frames


def main():
    kodak = {}
    for k in ['01', '03', '05', '08', '13', '19', '23']:
        img = L.kodak_luma(os.path.join(SRC, f'kodim{k}.png'))
        if img.shape[0] > img.shape[1]:
            img = img.T.copy()
        kodak[k] = img

    def kpan(k, w=640, h=480, step=2):
        return L.pan(kodak[k], w, h, N, step=step, y0=(kodak[k].shape[0] - h) // 2)

    # --- Clean references -------------------------------------------------
    for k in kodak:
        add(f'kodak{k}_clean', kpan(k), group='clean photo', noise_class='clean', halo_class='clean',
            note='Kodak PhotoCD scan (fine film grain of its own)')

    anim = cel(N)
    add('cel_clean', anim, group='flat animation', noise_class='clean', halo_class='clean',
        note='synthetic cels: flat fills, 3 px dark outlines')
    add('cel_x264', roundtrip_x264(anim, 18, 'cel'), group='flat animation', noise_class='clean',
        halo_class='clean', note='the same, through x264 CRF 18 (ringing / mosquito noise)')
    add('kodak23_lanczos2x', [lanczos2x(f) for f in kpan('23', 480, 360)], group='upscaled',
        noise_class='clean', halo_class='clean', note='640x360 pan, Lanczos-3 2x to 960x720 (ringing)')
    add('kodak08_lanczos2x', [lanczos2x(f) for f in kpan('08', 480, 360)], group='upscaled',
        noise_class='clean', halo_class='clean', note='Lanczos-3 2x')

    # --- Noise ladders ----------------------------------------------------
    bases = {'kodak08': kpan('08'), 'kodak23': kpan('23'), 'kodak05': kpan('05'), 'cel': anim}
    nasa = L.luma(os.path.join(SRC, 'nasa.webm'), 50.0, N)
    bases['nasa'] = nasa
    for b, fr in bases.items():
        for s in [1, 2, 3, 4, 6, 8]:
            cls = 'clean' if s <= 1 else ('grey' if s <= 2 else 'high')
            add(f'{b}_n{s}', L.add_noise(fr, s, seed=s), group='white noise', noise_class=cls,
                halo_class='clean', sigma=s)
        for s in [2, 4, 6]:
            cls = 'grey' if s <= 2 else 'high'
            add(f'{b}_tape{s}', L.add_noise(fr, s, seed=10 + s, corr_x=1.2), group='tape-like noise',
                noise_class=cls, halo_class='clean', sigma=s,
                note='noise blurred along the line (sigma 1.2 px), rescaled')
        for s in [3, 6]:
            add(f'{b}_grain{s}', L.add_noise(fr, s, seed=20 + s, corr_xy=0.7, luma_dependent=True),
                group='synthetic grain', noise_class='high', halo_class='clean', sigma=s,
                note='noise blurred 0.7 px both ways, strongest in the mid-tones')
    for b in ['kodak08', 'kodak23']:
        noisy = L.add_noise(bases[b], 4, seed=99)
        add(f'{b}_n4_x264', roundtrip_x264(noisy, 23, b), group='compressed noise', noise_class='grey',
            halo_class='clean', sigma=4, note='sigma 4 then x264 CRF 23: the encoder removes much of it')

    # --- Sharpening ladders -----------------------------------------------
    hbases = {'kodak08': bases['kodak08'], 'kodak23': bases['kodak23'], 'kodak05': bases['kodak05'],
              'cel': anim, 'nasa': nasa}
    for b, fr in hbases.items():
        for r in [1.0, 2.0]:
            for a in [0.5, 1.0, 2.0]:
                cls = 'grey' if a <= 0.5 else 'high'
                add(f'{b}_usm{r:g}_{a:g}', [L.unsharp(f, r, a) for f in fr], group='unsharp mask',
                    noise_class='clean', halo_class=cls, sharpen=f'USM radius {r:g} amount {a:g}')
        for a in [0.5, 1.0, 2.0]:
            cls = 'grey' if a <= 0.5 else 'high'
            add(f'{b}_peak2_{a:g}', [L.unsharp(f, 2.0, a, horizontal_only=True) for f in fr],
                group='line peaking', noise_class='clean', halo_class=cls,
                sharpen=f'horizontal-only USM radius 2 amount {a:g} (tape/camcorder peaking)')
    for b in ['kodak08', 'kodak23']:
        sh = [L.unsharp(f, 1.5, 1.0) for f in bases[b]]
        add(f'{b}_usm1.5_1_n3', L.add_noise(sh, 3, seed=7), group='sharpened + noise', noise_class='high',
            halo_class='high', sigma=3, sharpen='USM 1.5 / 1.0, then sigma 3')
        add(f'{b}_n3_usm1.5_1', [L.unsharp(f, 1.5, 1.0) for f in L.add_noise(bases[b], 3, seed=8)],
            group='sharpened + noise', noise_class='high', halo_class='high', sigma=3,
            sharpen='sigma 3, then USM 1.5 / 1.0 (sharpening the noise too)')

    # --- Traps ------------------------------------------------------------
    for k in ['13', '05', '08']:
        sp = L.subpixel_pan(kodak[k], 640, 480, N, 1.37, y0=(kodak[k].shape[0] - 480) // 2)
        add(f'kodak{k}_subpix', sp, group='sub-pixel pan', noise_class='clean', halo_class='clean',
            note='panned 1.37 px a frame (cubic), so texture never lines up on whole pixels')
        add(f'kodak{k}_subpix_tape4', L.add_noise(sp, 4, seed=70, corr_x=1.2), group='sub-pixel pan',
            noise_class='high', halo_class='clean', sigma=4, note='the same with tape-like noise')
    for b in ['kodak08', 'kodak23']:
        dark =[16 + (f - 16) * 0.2 for f in bases[b]]
        add(f'{b}_dark', dark, group='dark scene', noise_class='clean', halo_class='clean',
            note='luma scaled to 20% (peaks ~60)')
        add(f'{b}_dark_n3', L.add_noise(dark, 3, seed=31), group='dark scene', noise_class='high',
            halo_class='clean', sigma=3)
    for b in ['kodak08', 'kodak23']:
        pic = kpan(b[-2:], 640, 360)
        def box(frames):
            out = []
            for f in frames:
                c = np.full((480, 640), 16.0, np.float32)
                c[60:420] = f
                out.append(c)
            return out
        add(f'{b}_letterbox', box(pic), group='letterbox', noise_class='clean', halo_class='clean',
            note='640x360 picture in 640x480, digital black bars')
        add(f'{b}_letterbox_n3', box(L.add_noise(pic, 3, seed=41)), group='letterbox',
            noise_class='high', halo_class='clean', sigma=3, note='noise in the picture, clean bars')
        add(f'{b}_letterbox_usm', box([L.unsharp(f, 1.5, 1.0) for f in pic]), group='letterbox',
            noise_class='clean', halo_class='high', sharpen='USM 1.5 / 1.0 inside the bars')
    for b in ['kodak08', 'kodak05']:
        # Interlaced: each frame's two fields are 4 px apart on the pan.
        src = kodak[b[-2:]]
        y0 = (src.shape[0] - 480) // 2
        def weave(noise=0.0, sharpen=False, seed=0):
            rng = np.random.default_rng(seed)
            out = []
            for t in range(N):
                a = src[y0:y0 + 480, 8 * t:8 * t + 640].copy()
                b2 = src[y0:y0 + 480, 8 * t + 4:8 * t + 644].copy()
                f = a.copy()
                f[1::2] = b2[1::2]
                if sharpen:
                    top, bot = L.unsharp(f[0::2], 1.5, 1.0), L.unsharp(f[1::2], 1.5, 1.0)
                    f[0::2], f[1::2] = top, bot
                if noise:
                    f = f + rng.standard_normal(f.shape).astype(np.float32) * noise
                out.append(f)
            return out
        add(f'{b}_woven', weave(), group='interlaced', noise_class='clean', halo_class='clean',
            interlaced='tff', note='fields 4 px apart: combing on every edge')
        add(f'{b}_woven_n3', weave(3.0, seed=51), group='interlaced', noise_class='high',
            halo_class='clean', sigma=3, interlaced='tff')
        add(f'{b}_woven_usm', weave(sharpen=True), group='interlaced', noise_class='clean',
            halo_class='high', interlaced='tff', sharpen='USM 1.5 / 1.0 per field')
    for s in [0, 2, 4]:
        cls = 'clean' if s == 0 else ('grey' if s <= 2 else 'high')
        add(f'kodak08_10bit_n{s}', L.add_noise(bases['kodak08'], s, seed=60 + s) if s else bases['kodak08'],
            group='10-bit', noise_class=cls, halo_class='clean', sigma=s, bits=10)
    add('kodak08_10bit_usm1_1', [L.unsharp(f, 1.0, 1.0) for f in bases['kodak08']], group='10-bit',
        noise_class='clean', halo_class='high', bits=10, sharpen='USM 1 / 1.0')

    # --- Real footage (truth by eye; see the report) ------------------------
    real = [
        ('real_vhs', os.path.join(L.RES, 'interlaced_test.avi'), 0.5, 'grey', 'grey', True,
         'VHS capture (Lagarith 4:2:2, interlaced)'),
        ('real_dvbt', os.path.join(L.RES, 'pal-dvbt-fieldcoded-25i.ts'), 1.0, 'grey', 'grey', True,
         'DVB-T broadcast, H.264 interlaced'),
        ('real_bars10', os.path.join(L.RES, 'pal-sd-25.mov'), 1.0, 'clean', 'clean', False,
         'SMPTE bars, ProRes 10-bit (synthetic)'),
        ('real_testsrc_mpeg2', os.path.join(L.RES, 'hard_telecine_test.avi'), 0.5, 'clean', 'clean',
         True, 'ffmpeg testsrc as telecined MPEG-2'),
        ('real_small_clip', os.path.join(L.RES, 'small_clip.mp4'), 30.0, 'grey', 'grey', False,
         '320x240 H.264'),
        ('real_face_test', os.path.join(L.RES, 'face_restore_test.mp4'), 1.0, 'grey', 'clean', False,
         'NASA clip degraded VHS-like: noise=8 temporal, then soft H.264'),
        ('real_colorize_test', os.path.join(L.RES, 'colorize_test.mp4'), 1.0, 'grey', 'grey', False,
         'black-and-white H.264 test clip'),
        ('real_nasa_mc', os.path.join(SRC, 'nasa.webm'), 10.0, 'clean', 'grey', False,
         'NASA 1080p, mission control (AV1)'),
        ('real_nasa_iss', os.path.join(SRC, 'nasa.webm'), 50.0, 'clean', 'grey', False,
         'NASA 1080p, ISS downlink (AV1)'),
        ('real_notld_road', os.path.join(SRC, 'notld.webm'), 30.0, 'grey', 'clean', False,
         'Night of the Living Dead, 1968 35 mm, 10-bit AV1: heavy grain'),
        ('real_notld_car', os.path.join(SRC, 'notld.webm'), 100.0, 'grey', 'clean', False,
         'Night of the Living Dead, cemetery'),
    ]
    for name, src, start, nc, hc, il, note in real:
        add_file(name, src, start, group='real', noise_class=nc, halo_class=hc, interlaced=il, note=note)

    with open(os.path.join(FX, 'manifest.json'), 'w') as f:
        json.dump(manifest, f, indent=1)
    print(len(manifest), 'fixtures in', FX)


if __name__ == '__main__':
    main()
