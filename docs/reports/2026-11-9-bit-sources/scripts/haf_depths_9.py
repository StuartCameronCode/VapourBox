"""Which havsfunc paths run on a 9-bit clip?

Runs each case on the same grainy YUV420 clip at 9 and 10 bits, at SD
(352x288) and HD (1280x720), and prints ok / FAIL(<last line of the error>)
per depth. Every case is a havsfunc call (or CTMF itself) that one of
VapourBox's passes can reach. Run with a deps bundle's own Python (see
reproduce.sh).
"""
import vapoursynth as vs
import havsfunc as haf

core = vs.core
DEPTHS = (9, 10)
SIZES = ((352, 288), (1280, 720))


def src(bits, w, h):
    c = core.std.BlankClip(width=w, height=h, format=vs.YUV420P8, length=30,
                           fpsnum=25, fpsden=1, color=[110, 128, 128])
    if hasattr(core, 'grain'):
        c = core.grain.Add(c, var=40, constant=False)
    fmt = core.query_video_format(vs.YUV, vs.INTEGER, bits, 1, 1)
    return core.std.SetFieldBased(core.resize.Bicubic(c, format=fmt.id), 0)


CASES = {
    'YAHR': lambda c: haf.YAHR(c),
    'HQDeringmod (defaults)': lambda c: haf.HQDeringmod(c),
    'FineDehalo (contra=1)': lambda c: haf.FineDehalo(c, contra=1.0),
    'FineDehalo (defaults)': lambda c: haf.FineDehalo(c),
    'MCTemporalDenoise (pfMode=2)': lambda c: haf.MCTemporalDenoise(c, pfMode=2),
    'MCTemporalDenoise (defaults)': lambda c: haf.MCTemporalDenoise(c),
    'ContraSharpening (radius=2)': lambda c: haf.ContraSharpening(c, core.std.BoxBlur(c), radius=2),
    'SMDegrain (contrasharp=True)': lambda c: haf.SMDegrain(c, tr=2, contrasharp=True),
    'SMDegrain (prefilter=2)': lambda c: haf.SMDegrain(c, tr=2, prefilter=2),
    'QTGMC Slower': lambda c: haf.QTGMC(core.std.SetFieldBased(c, 2), Preset='Slower', TFF=True),
    'LSFmod': lambda c: haf.LSFmod(c),
    'EdgeCleaner': lambda c: haf.EdgeCleaner(c),
    'ctmf.CTMF (radius=1)': lambda c: core.ctmf.CTMF(c, radius=1, opt=2),
}

print('size\tcase\t' + '\t'.join(f'{d}-bit' for d in DEPTHS), flush=True)
for w, h in SIZES:
    for name, run in CASES.items():
        row = []
        for bits in DEPTHS:
            try:
                run(src(bits, w, h)).get_frame(10)
                row.append('ok')
            except Exception as e:  # noqa: BLE001 - the message is the result
                row.append('FAIL(' + str(e).strip().splitlines()[-1][:80] + ')')
        print(f'{w}x{h}\t{name}\t' + '\t'.join(row), flush=True)
