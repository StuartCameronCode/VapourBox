"""Which havsfunc functions run on a 14-bit clip?

Runs each case on the same grainy 352x288 YUV420 clip at 9, 12, 14 and 16
bits and prints ok / FAIL(<last line of the error>) per depth. Run with a
deps bundle's own Python (see reproduce.sh).
"""
import sys
import vapoursynth as vs
import havsfunc as haf

core = vs.core
DEPTHS = (9, 12, 14, 16)
FORMATS = {9: vs.YUV420P9, 12: vs.YUV420P12, 14: vs.YUV420P14, 16: vs.YUV420P16}


def src(bits, field_based=2):
    c = core.std.BlankClip(width=352, height=288, format=vs.YUV420P8,
                           length=30, fpsnum=25, fpsden=1, color=[110, 128, 128])
    if hasattr(core, 'grain'):
        c = core.grain.Add(c, var=40, constant=False)
    c = core.resize.Bicubic(c, format=FORMATS[bits])
    return core.std.SetFieldBased(c, field_based)


def prog(c):
    return core.std.SetFieldBased(c, 0)


CASES = {
    'QTGMC Slower': lambda c: haf.QTGMC(c, Preset='Slower', TFF=True),
    'QTGMC Fast': lambda c: haf.QTGMC(c, Preset='Fast', TFF=True),
    'QTGMC Draft': lambda c: haf.QTGMC(c, Preset='Draft', TFF=True),
    'QTGMC Fast, FPSDivisor=2': lambda c: haf.QTGMC(c, Preset='Fast', TFF=True, FPSDivisor=2),
    'Bob': lambda c: haf.Bob(c, tff=True),
    'Resize': lambda c: haf.Resize(c, 704, 576),
    'santiag': lambda c: haf.santiag(prog(c)),
    'Deblock_QED': lambda c: haf.Deblock_QED(prog(c)),
    'daa': lambda c: haf.daa(prog(c)),
    'DeHalo_alpha': lambda c: haf.DeHalo_alpha(c),
    'FineDehalo': lambda c: haf.FineDehalo(c),
    'HQDeringmod': lambda c: haf.HQDeringmod(c),
    'EdgeCleaner': lambda c: haf.EdgeCleaner(c),
    'SMDegrain': lambda c: haf.SMDegrain(prog(c), tr=2),
    'MCTemporalDenoise': lambda c: haf.MCTemporalDenoise(prog(c)),
    'LSFmod': lambda c: haf.LSFmod(c),
    'ContraSharpening': lambda c: haf.ContraSharpening(c, core.std.BoxBlur(c)),
    'GrainFactory3': lambda c: haf.GrainFactory3(c),
    'STPresso': lambda c: haf.STPresso(c),
    'Vinverse': lambda c: haf.Vinverse(c),
    'YAHR': lambda c: haf.YAHR(c),
    'FixChromaBleedingMod': lambda c: haf.FixChromaBleedingMod(c),
    'MinBlur(r=2)': lambda c: haf.MinBlur(c, r=2),
    'Stab': lambda c: haf.Stab(prog(c)),
}

print('case\t' + '\t'.join(f'{d}-bit' for d in DEPTHS), flush=True)
for name, run in CASES.items():
    if sys.argv[1:] and name not in sys.argv[1:]:
        continue
    row = []
    for bits in DEPTHS:
        try:
            run(src(bits)).get_frame(10)
            row.append('ok')
        except Exception as e:  # noqa: BLE001 - the message is the result
            row.append('FAIL(' + str(e).strip().splitlines()[-1][:80] + ')')
    print(name + '\t' + '\t'.join(row), flush=True)
