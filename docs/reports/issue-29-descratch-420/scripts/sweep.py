"""Section 1: where the plugin fails, and which deinterlacers leave
_FieldBased set. BlankClips only; no input files."""
import vapoursynth as vs
core = vs.core


def ok(c, **kw):
    try:
        core.descratch.DeScratch(c, **kw).get_frame(0)
        return 'ok'
    except vs.Error as e:
        return 'FAILS (1027)' if '1027' in str(e) else 'FAILS: ' + str(e)[:50]


print('format height blurlen | field-based (TFF) | progressive')
for fmt in [vs.YUV420P8, vs.YUV422P8, vs.YUV444P8]:
    for h in [240, 288, 480, 486, 576, 1080]:
        for bl in [15, 5, 30, 50]:
            c = core.std.BlankClip(width=720, height=h, format=fmt, length=2)
            print(f'{c.format.name} {h} {bl} | {ok(core.std.SetFieldBased(c, 2), blurlen=bl)} | {ok(c, blurlen=bl)}')

print('\nformats the plugin accepts at all (progressive, 720x480)')
for fmt in [vs.YUV411P8, vs.YUV440P8, vs.GRAY8, vs.RGB24]:
    print(vs.core.get_video_format(fmt).name, ok(core.std.BlankClip(width=720, height=480, format=fmt, length=1)))

print('\n_FieldBased after each deinterlace method (input TFF = 2)')
c = core.std.SetFieldBased(core.std.BlankClip(width=720, height=480, format=vs.YUV420P8, length=20), 2)
fb = lambda x: x.get_frame(5).props.get('_FieldBased', 'absent')
v = core.vivtc.VFM(c, order=1)
print('Bwdif', fb(core.bwdif.Bwdif(c, field=3)))
print('VFM (IVTC)', fb(v), '/ VFM+VDecimate', fb(core.vivtc.VDecimate(v)))
print('VDecimate alone (Soft Telecine)', fb(core.vivtc.VDecimate(c)))
import havsfunc as haf
print('QTGMC Fast', fb(haf.QTGMC(c, Preset='Fast', TFF=True)))
