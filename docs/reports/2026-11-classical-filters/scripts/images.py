"""The report's comparison images: crops side by side, 2x nearest-neighbour,
panels in the order each caption gives. Writes into the report's img/.

  SCRATCH=... ./run.sh images.py
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.argv = [sys.argv[0]]
os.environ.setdefault('NFR', '24')
S = os.environ['SCRATCH']
IMG = os.path.join(HERE, '..', 'img')
src = open(os.path.join(HERE, 'ports_compare.py')).read()
exec(src[:src.index('# ---- vine_dehalo')])
exec(src[src.index('def gauss('):src.index("out['vine'] = {}")])
exec(src[src.index('def stinx('):src.index("out['mpeg2stinx'] = {}")])
exec(src[src.index('def ivtc('):src.index('def stinx_rows(')])
exec(src[src.index('def fades('):src.index('def field_gap(')])
nr = open(os.path.join(HERE, 'nr_compare.py')).read()
exec(nr[nr.index('def bm3d_template'):nr.index('MULT = ')])


def panels(clips, frame, x, y, w, h, scale=2):
    out = []
    for c in clips:
        c = core.std.CropAbs(c[frame], w, h, x, y)
        c = core.resize.Point(c, w * scale, h * scale, format=vs.RGB24, matrix_in_s='170m')
        out.append(c)
        out.append(core.std.BlankClip(c, width=4, color=[255, 255, 255]))
    return core.std.StackHorizontal(out[:-1])


def save(clip, name):
    f = clip.get_frame(0)
    data = b''.join(bytes(f[p]) for p in (1, 2, 0))  # gbrp plane order
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', 'gbrp',
                    '-s', f'{clip.width}x{clip.height}', '-i', '-', os.path.join(IMG, name)],
                   input=data, check=True)
    print('wrote', name, clip.width, 'x', clip.height)


os.makedirs(IMG, exist_ok=True)

# 1. noise reduction, kodim08 sigma 8: clean | noisy | BM3D | NLMeans | WNNM r=1
clean = load(os.path.join(S, 'fx', 'kodim08_pan.mkv'), 'yuv420p', frames=6)
noisy = core.grain.Add(clean, var=64, uvar=64, seed=7)
save(panels([clean, noisy, bm3d_template(noisy, 16.0), nlm_vszip(noisy, 7.0), wnnm(noisy, 16.0, 1)],
            3, 300, 150, 150, 130), '01-nr-kodim08-sigma8.png')

# 2. dehalo, kodim23: clean | haloed | vine | DeHalo_alpha | FineDehalo
clean = load(os.path.join(S, 'fx', 'kodim23_pan.mkv'), 'yuv420p', frames=2)
halo = expr([clean, gauss(clean, 1.5)], 'x x y - 1.5 * +')
save(panels([clean, halo, vine(halo), haf.DeHalo_alpha(halo), haf.FineDehalo(halo)],
            0, 250, 120, 150, 130), '02-dehalo-kodim23.png')
clean = load(os.path.join(S, 'fx', 'kodim08_pan.mkv'), 'yuv420p', frames=2)
halo = expr([clean, gauss(clean, 1.5)], 'x x y - 1.5 * +')
save(panels([clean, halo, vine(halo), haf.DeHalo_alpha(halo), haf.FineDehalo(halo)],
            0, 260, 200, 150, 130), '03-dehalo-kodim08.png')

# 3. mpeg2stinx, kodim08 telecined @1000k after IVTC: clean | decoded | mpeg2stinx | Deblock_QED
clean = load(os.path.join(S, 'fx', 'kodim08_pan.mkv'), 'yuv420p', frames=24)
enc = ivtc(load(os.path.join(S, 'fx', 'kodim08_tc_1000.mkv'), 'yuv420p', frames=30))
save(panels([clean, enc, stinx(enc), haf.Deblock_QED(enc)], 10, 300, 150, 150, 130),
     '04-mpeg2stinx-kodim08-1000k.png')

# 4. anti-aliasing: a point-resampled (aliased) kodim23 | daa | santiag | SangNom AA
clean = load(os.path.join(S, 'fx', 'kodim23_pan.mkv'), 'yuv420p', frames=2)
aliased = core.resize.Point(core.resize.Point(clean, 320, 240), 640, 480)
aliased = core.std.SetFieldBased(aliased, 0)
save(panels([aliased, haf.daa(aliased), haf.santiag(aliased),
             run_block('AA_SANGNOM', aliased, {'AA_SANGNOM_AA': 48, 'AA_FIELD_BASED_VALUE': 0})],
            0, 250, 120, 150, 130), '05-aa-kodim23.png')

# 5. fades: a frame fading after the field split | fixed (average) | fixed (match)
c = load(os.path.join(S, 'fx', 'kodim23_pan.mkv'), 'yuv420p', frames=2)
fl = core.std.SeparateFields(core.std.SetFieldBased(core.resize.Point(c, format=vs.YUV420PS), 0), tff=True)
top = expr([fl[::2]], ['x 0.7 *'] * 3)
bot = expr([fl[1::2]], ['x 0.45 *'] * 3)
mixed = core.resize.Point(core.std.SetFieldBased(core.std.DoubleWeave(core.std.Interleave([top, bot]), tff=True)[::2], 0), format=c.format.id)
save(panels([mixed, fades(mixed), fades(mixed, 'match')], 0, 250, 120, 150, 130), '06-fades-kodim23.png')
