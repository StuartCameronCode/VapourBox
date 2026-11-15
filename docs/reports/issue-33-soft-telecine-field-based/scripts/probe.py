"""Task #33 probe: Soft Telecine's _FieldBased marking, measured in VapourSynth.

    probe.py <soft_telecine_dvd.yuv> <vhs_fields_422.yuv> <testsrc_422.yuv> <img_dir>

The .yuv inputs are raw planar 8-bit files made by reproduce.sh with ffmpeg
(no source plugin needed). Prints every number in the report's tables and
writes the crops as raw .gray files for reproduce.sh to turn into PNGs.
"""
import ctypes
import math
import sys

import vapoursynth as vs

core = vs.core


def load(path, w, h, fmt):
    blank = core.std.BlankClip(width=w, height=h, format=fmt, length=1)
    fi = blank.format
    sizes = [(w >> (fi.subsampling_w if p else 0), h >> (fi.subsampling_h if p else 0)) for p in range(3)]
    fsize = sum(a * b for a, b in sizes)
    data = open(path, 'rb').read()
    n = len(data) // fsize
    blank = core.std.BlankClip(blank, length=n)

    def fill(n, f):
        o = f.copy()
        off = n * fsize
        for p, (pw, ph) in enumerate(sizes):
            base = ctypes.cast(o.get_write_ptr(p), ctypes.c_void_p).value
            st = o.get_stride(p)
            for y in range(ph):
                ctypes.memmove(base + y * st, data[off + y * pw: off + (y + 1) * pw], pw)
            off += pw * ph
        return o
    return core.std.ModifyFrame(blank, blank, fill)


def mad(a, b, plane):
    st = core.std.PlaneStats(a, b, plane=plane)
    return sum(st.get_frame(i).props['PlaneStatsDiff'] for i in range(a.num_frames)) / a.num_frames * 255


def maxdiff(a, b, plane):
    e = core.std.Expr([a, b], ['x y - abs'] * 3)
    st = core.std.PlaneStats(e, plane=plane)
    return max(st.get_frame(i).props['PlaneStatsMax'] for i in range(a.num_frames))


def psnr(a, b, plane):
    e = core.std.Expr([a, b], ['x y - dup *'] * 3, format=vs.YUV422PS if a.format.subsampling_w else vs.YUV444PS)
    st = core.std.PlaneStats(e, plane=plane)
    mse = sum(st.get_frame(i).props['PlaneStatsAverage'] for i in range(a.num_frames)) / a.num_frames
    return 10 * math.log10(255 * 255 / mse) if mse > 0 else float('inf')


def marked(c, fb):
    return core.std.SetFieldBased(c, fb)


st_path, vhs_path, ts_path, img = sys.argv[1:5]

# ---------------------------------------------------------------- 1. VDecimate
print('== 1. VDecimate and _FieldBased (soft_telecine_dvd.mkv, 150 decoded frames)')
src = load(st_path, 352, 240, vs.YUV420P8)
for depth, c in (('8-bit', src), ('10-bit', core.resize.Point(src, format=vs.YUV420P10))):
    d2 = core.vivtc.VDecimate(marked(c, 2))
    d0 = core.vivtc.VDecimate(marked(c, 0))
    st = core.std.PlaneStats(d2, d0)
    same = sum(1 for i in range(d2.num_frames) if st.get_frame(i).props['PlaneStatsDiff'] == 0)
    print(f'{depth}: frames {d2.num_frames}/{d0.num_frames}, identical {same}/{d2.num_frames}, '
          f'_FieldBased out of VDecimate {d2.get_frame(0).props.get("_FieldBased")}')

# ------------------------------------------------------------ 2. the fixture
print('\n== 2. 4:2:0 -> 4:2:2 resize.Bicubic on the 120 film frames, marked 2 vs unmarked')
film = core.vivtc.VDecimate(src)  # src is unmarked; the marking is applied below
film2 = marked(film, 2)
film0 = core.std.RemoveFrameProps(film, props='_FieldBased')
per_field = core.resize.Bicubic(film2, format=vs.YUV422P8)
progressive = core.resize.Bicubic(film0, format=vs.YUV422P8)
for p, name in ((0, 'Y'), (1, 'U'), (2, 'V')):
    print(f'{name}: mean |diff| {mad(per_field, progressive, p):.3f}, max {maxdiff(per_field, progressive, p):.0f}')
print('round trip 4:2:0 -> 4:2:2 -> 4:2:0 (progressive down), chroma vs source:')
for label, c in (('marked 2 ', per_field), ('unmarked ', progressive)):
    back = core.resize.Bicubic(core.std.RemoveFrameProps(c, props='_FieldBased'), format=vs.YUV420P8)
    print(f'  {label}: U {mad(back, film0, 1):.3f}, V {mad(back, film0, 2):.3f}')

# ------------------------------------------------------------ 3. ground truth
print('\n== 3. Against ground truth: progressive 4:2:2 pictures, 4:2:0 progressively, back up')
for label, path, w, h in (('VHS fields (720x288)', vhs_path, 720, 288),
                          ('testsrc2 (720x480)', ts_path, 720, 480)):
    truth = load(path, w, h, vs.YUV422P8)
    sub = core.resize.Bicubic(truth, format=vs.YUV420P8)       # progressive downsample
    up2 = core.resize.Bicubic(marked(sub, 2), format=vs.YUV422P8)
    up0 = core.resize.Bicubic(sub, format=vs.YUV422P8)
    up2 = core.std.RemoveFrameProps(up2, props='_FieldBased')
    print(f'{label}, {truth.num_frames} frames: chroma PSNR vs truth, '
          f'marked 2: U {psnr(up2, truth, 1):.2f} V {psnr(up2, truth, 2):.2f} dB; '
          f'unmarked: U {psnr(up0, truth, 1):.2f} V {psnr(up0, truth, 2):.2f} dB')

# ------------------------------------------------------------------- 4. crops
# V plane of film frame 30 (4:2:2: 176 wide), a coloured-edge region.
fn, x, y, cw, chh = 30, 40, 70, 64, 64
for label, c in (('per_field', per_field), ('progressive', progressive), ('source420', film0)):
    v = c.get_frame(fn)[2].tolist()
    if label == 'source420':
        # 4:2:0 chroma is half height: double each row so it lines up.
        rows = [bytes(v[y // 2 + r // 2][x:x + cw]) for r in range(chh)]
    else:
        rows = [bytes(v[y + r][x:x + cw]) for r in range(chh)]
    open(f'{img}/{label}.gray', 'wb').write(b''.join(rows))
print(f'\ncrops: V plane, film frame {fn}, chroma x {x} y {y}, {cw}x{chh}')
