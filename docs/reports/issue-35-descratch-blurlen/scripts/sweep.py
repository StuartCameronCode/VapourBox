"""The plugin alone on BlankClips (720 wide): for each height, format and
_FieldBased value, the largest blurlen in 0..200 it accepts, every refusal's
message, and whether the template's clamp, min(blurlen, height // 2 - 1),
gives the limit's picture exactly. No source plugin, no NumPy."""
import vapoursynth as vs

core = vs.core
HEIGHTS = (120, 144, 200, 240, 288, 360, 400, 402, 480, 486, 576, 1080)
CASES = ((vs.YUV422P8, 0, '4:2:2 progressive'),
         (vs.YUV422P8, 2, '4:2:2 TFF (the 4:2:0 luma carrier)'),
         (vs.YUV420P8, 0, '4:2:0 progressive (the chroma-mode call)'),
         (vs.YUV444P8, 1, '4:4:4 BFF'))


def call(c, bl):
    try:
        core.descratch.DeScratch(c, blurlen=bl).get_frame(0)
        return None
    except vs.Error as e:
        return str(e).splitlines()[0]


def frame_bytes(c):
    f = c.get_frame(0)
    return b''.join(bytes(f[p]) for p in range(f.format.num_planes))


print('height | case | max accepted | height // 2 - 1 | refusals')
for h in HEIGHTS:
    for fmt, fb, label in CASES:
        c = core.std.SetFieldBased(core.std.BlankClip(width=720, height=h, format=fmt, length=1), fb)
        errs = {}
        ok = []
        for bl in range(0, 201):
            e = call(c, bl)
            if e is None:
                ok.append(bl)
            else:
                errs.setdefault(e, []).append(bl)
        msgs = '; '.join(f'{m} ({v[0]}..{v[-1]})' for m, v in errs.items()) or 'none'
        print(f'{h} | {label} | {max(ok)} | {h // 2 - 1} | {msgs}')

# The clamp: a scratched-looking pattern (a dark column on grey) so the blur
# length matters, compared at 200 vs the limit and the limit vs 15.
print()
print('height | clamp(200) == limit picture | limit differs from 15')
for h in (240, 288, 360):
    base = core.std.BlankClip(width=720, height=h, format=vs.YUV422P8, color=[128, 128, 128], length=1)
    line = core.std.BlankClip(width=2, height=h, format=vs.YUV422P8, color=[100, 128, 128], length=1)
    grad = core.std.BlankClip(width=720, height=h // 2, format=vs.YUV422P8, color=[150, 128, 128], length=1)
    pic = core.std.StackVertical([grad, core.std.CropAbs(base, 720, h - h // 2)])
    pic = core.std.StackHorizontal([core.std.CropAbs(pic, 300, h), line, core.std.CropAbs(pic, 418, h, 302)])
    pic = core.std.SetFieldBased(pic, 2)
    lim = h // 2 - 1
    clamped = min(200, lim)
    a = frame_bytes(core.descratch.DeScratch(pic, blurlen=clamped, mindif=3))
    b = frame_bytes(core.descratch.DeScratch(pic, blurlen=lim, mindif=3))
    d = frame_bytes(core.descratch.DeScratch(pic, blurlen=15, mindif=3))
    print(f'{h} | {a == b} | {b != d}')
