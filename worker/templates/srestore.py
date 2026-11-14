"""
Unblend (SRestore) - VapourBox's port of srestore 2.7e.

srestore (an AviSynth script, ported to VapourSynth in havsfunc r31)
recovers the original frames of footage that was frame-rate converted by
*blending*: a 23.976 fps film shown on PAL through a standards converter, or a
PAL programme converted to NTSC. After a double-rate deinterlace every output
frame is either a clean original or a mix of two; srestore measures each
frame's "blendedness" against its neighbours, tracks the conversion's phase,
and picks the cleanest frame near each output position.

Why a port rather than ``havsfunc.srestore``
--------------------------------------------
havsfunc's version keeps its detection history in ~30 ``nonlocal`` variables
that only advance when ``FrameEval`` is called for consecutive frames. It relied
on ``std.Cache(make_linear=True)`` to make that happen, and VapourSynth R55+
(R78 is bundled) ignores ``make_linear``. Its final ``ChangeFPS`` only requests
the frames it keeps (0, 2, 5, 7, ... for 59.94 -> 23.976), so on R78 the
history is reset on *every* frame and the result is identical to plain
decimation (docs/reports/2026-11-srestore).

The detector is also a phase tracker that does not forget where it started, so
a preview that starts mid-clip with fresh state does not reproduce the encode.
This port therefore makes every decision a **pure function of a fixed window**:
the decision for frame n replays the upstream per-frame arithmetic, with fresh
state, over frames ``max(origin, n - window) .. n``. Encode and preview run the
same function, so thread count and request order cannot change the output and
a preview frame is the encode's frame whenever its window is decoded.

The per-frame arithmetic (``_Detector.step``) is upstream's ``srestore_inside``
for an integer ``omode`` (the default 6), line for line; only the clip output
was taken out. The string ``omode`` post-processors ("pp0".."pp3") synthesize
pixels and are not ported.

Ported from havsfunc r31's "srestore v2.7e" (havsfunc is released under the
Unlicense, licenses/NOTICES.txt). Port written for VapourBox.
"""

import math

import vapoursynth as vs

core = vs.core

# Expressions go through akarin's JIT where it exists (ARM), as everywhere in
# the templates. The detector thresholds its measurements, so this was checked:
# akarin and VapourSynth's own Expr give bit-identical measurements on both of
# the report's fixtures (docs/reports/2026-11-srestore, depth_speed.py).
_akarin_expr = getattr(getattr(core, 'akarin', None), 'Expr', None)


def _expr(clips, expr, **kwargs):
    if _akarin_expr is not None:
        return _akarin_expr(clips, expr, **kwargs)
    return core.std.Expr(clips, expr, **kwargs)

# Upstream's 8-bit "distance from neutral" expressions, unchanged.
_EXPR_BLEND = ('x 128 - y 128 - * 0 > x 128 - abs y 128 - abs < x 128 - 128 x - * '
               'y 128 - 128 y - * ? x y + 256 - dup * ? 0.25 * 128 +')

# Measurements kept in the stats clip's cache (1x1 frames, so this is cheap).
_STATS_CACHE_FRAMES = 4096

# The measurements each detector step reads, as frame properties.
_PROP_KEYS = ('SrBMin', 'SrBMax', 'SrDMax', 'SrMDiff')


def ratio(in_num, in_den, out_num, out_den, omode=6):
    """srestore's own (frfac, numr, denm) for a conversion, as upstream computes
    it from the floating-point rates. ``frfac == 1`` means srestore would not
    decimate at all (an upward or out-of-range target).

    worker/src/models/unblend_parameters.rs ports this function; the two must
    agree for every rate pair the app can send (asserted by the tests).
    """
    irate = in_num / in_den
    frate = out_num / out_den
    if abs(omode - 3) < 2.5:
        frfac = 1
    elif frate * 5 < irate or frate > irate:
        frfac = 1
    else:
        frfac = abs(frate) / irate

    if abs(frfac * 1001 - math.floor(frfac * 1001 + 0.5)) < 0.01:
        numr = math.floor(frfac * 1001 + 0.5)
    elif abs(1001 / frfac - math.floor(1001 / frfac + 0.5)) < 0.01:
        numr = 1001
    else:
        numr = math.floor(frfac * 9000 + 0.5)
    if abs(irate * numr / math.floor(numr / frfac + 0.5) - frate) > \
            abs(irate * math.floor(frate * 100 + 0.5) / math.floor(irate * 100 + 0.5) - frate):
        numr = math.floor(frate * 100 + 0.5)
    denm = math.floor(numr / frfac + 0.5)
    return frfac, numr, denm


class _Detector:
    """Upstream ``srestore_inside``'s state and arithmetic (integer omode)."""

    def __init__(self, frfac, numr, denm, thresh=16, omode=6, mode=2):
        self.frfac, self.numr, self.denm = frfac, numr, denm
        self.thr = abs(thresh) + 0.01
        self.omode, self.mode = omode, mode
        self.lfr = -100
        self.offs = 0
        self.ldet = -100
        self.lpos = 0
        self.d32 = self.d21 = self.d10 = self.d01 = self.d12 = self.d23 = self.d34 = None
        self.m42 = self.m31 = self.m20 = self.m11 = self.m02 = self.m13 = self.m24 = None
        self.bp2 = self.bp1 = self.bn0 = self.bn1 = self.bn2 = self.bn3 = None
        self.cp2 = self.cp1 = self.cn0 = self.cn1 = self.cn2 = self.cn3 = None

    def step(self, n, b_min, b_max, d_max, m_diff):
        """One frame. Returns (opos, mer): the output is source frame
        ``n + opos``, or (``mer``) the 50/50 merge of that frame and the next."""
        frfac, numr, denm, thr = self.frfac, self.numr, self.denm, self.thr
        omode, mode = self.omode, self.mode

        ### preparation ###
        jmp = self.lfr + 1 == n
        cfo = ((n % denm) * numr * 2 + denm + numr) % (2 * denm) - denm
        bfo = cfo > -numr and cfo <= numr
        self.lfr = n
        offs = self.offs
        offs = offs + 2 * denm if bfo and offs <= -4 * numr else offs - 2 * denm if bfo and offs >= 4 * numr else offs
        pos = 0 if frfac == 1 else -math.floor((cfo + offs) / (2 * numr) + 0.5) if bfo else self.lpos
        cof = cfo + offs + 2 * numr * pos
        self.ldet = -1 if n + pos == self.ldet else n + pos

        ### diff value shifting ###
        d_v = d_max + 0.015625
        if jmp:
            d43 = self.d32
            self.d32 = self.d21
            self.d21 = self.d10
            self.d10 = self.d01
            self.d01 = self.d12
            self.d12 = self.d23
            self.d23 = self.d34
        else:
            d43 = self.d32 = self.d21 = self.d10 = self.d01 = self.d12 = self.d23 = d_v
        self.d34 = d_v
        d32, d21, d10, d01, d12, d23, d34 = self.d32, self.d21, self.d10, self.d01, self.d12, self.d23, self.d34

        m_v = m_diff * 255 + 0.015625 if abs(omode) > 5 else 1
        if jmp:
            m53 = self.m42
            self.m42 = self.m31
            self.m31 = self.m20
            self.m20 = self.m11
            self.m11 = self.m02
            self.m02 = self.m13
            self.m13 = self.m24
        else:
            m53 = self.m42 = self.m31 = self.m20 = self.m11 = self.m02 = self.m13 = m_v
        self.m24 = m_v
        m42, m31, m20, m11, m02, m13, m24 = self.m42, self.m31, self.m20, self.m11, self.m02, self.m13, self.m24

        ### get blend and clear values ###
        b_v = 128 - b_min
        if b_v < 1:
            b_v = 0.125
        c_v = b_max - 128
        if c_v < 1:
            c_v = 0.125

        ### blend value shifting ###
        if jmp:
            bp3 = self.bp2
            self.bp2 = self.bp1
            self.bp1 = self.bn0
            self.bn0 = self.bn1
            self.bn1 = self.bn2
            self.bn2 = self.bn3
        else:
            bp3 = b_v
            self.bp2 = self.bp1 = self.bn0 = self.bn1 = self.bn2 = bp3
        self.bn3 = b_v
        bp2, bp1, bn0, bn1, bn2, bn3 = self.bp2, self.bp1, self.bn0, self.bn1, self.bn2, self.bn3

        ### clear value shifting ###
        if jmp:
            cp3 = self.cp2
            self.cp2 = self.cp1
            self.cp1 = self.cn0
            self.cn0 = self.cn1
            self.cn1 = self.cn2
            self.cn2 = self.cn3
        else:
            cp3 = self.cp2 = self.cp1 = self.cn0 = self.cn1 = self.cn2 = c_v
        self.cn3 = c_v
        cp2, cp1, cn0, cn1, cn2, cn3 = self.cp2, self.cp1, self.cn0, self.cn1, self.cn2, self.cn3

        ### used detection values ###
        bb = [bp3, bp2, bp1, bn0, bn1][pos + 2]
        bc = [bp2, bp1, bn0, bn1, bn2][pos + 2]
        bn = [bp1, bn0, bn1, bn2, bn3][pos + 2]

        cb = [cp3, cp2, cp1, cn0, cn1][pos + 2]
        cc = [cp2, cp1, cn0, cn1, cn2][pos + 2]
        cn = [cp1, cn0, cn1, cn2, cn3][pos + 2]

        dbb = [d43, d32, d21, d10, d01][pos + 2]
        dbc = [d32, d21, d10, d01, d12][pos + 2]
        dcn = [d21, d10, d01, d12, d23][pos + 2]
        dnn = [d10, d01, d12, d23, d34][pos + 2]
        dn2 = [d01, d12, d23, d34, d34][pos + 2]

        mb1 = [m53, m42, m31, m20, m11][pos + 2]
        mb = [m42, m31, m20, m11, m02][pos + 2]
        mc = [m31, m20, m11, m02, m13][pos + 2]
        mn = [m20, m11, m02, m13, m24][pos + 2]
        mn1 = [m11, m02, m13, m24, 0.01][pos + 2]

        ### basic calculation ###
        bbool = 0.8 * bc * cb > bb * cc and 0.8 * bc * cn > bn * cc and bc * bc > cc
        blend = bbool and bc * 5 > cc and dbc + dcn > 1.5 * thr and (dbb < 7 * dbc or dbb < 8 * dcn) and (dnn < 8 * dcn or dnn < 7 * dbc) and (mb < mb1 and mb < mc or mn < mn1 and mn < mc or (dbb + dnn) * 4 < dbc + dcn or (bb * cc * 5 < bc * cb or mb > thr) and (bn * cc * 5 < bc * cn or mn > thr) and bc > thr)
        clear = dbb + dbc > thr and dcn + dnn > thr and (bc < 2 * bb or bc < 2 * bn) and (dbb + dnn) * 2 > dbc + dcn and (mc < 0.96 * mb and mc < 0.96 * mn and (bb * 2 > cb or bn * 2 > cn) and cc > cb and cc > cn or frfac > 0.45 and frfac < 0.55 and 0.8 * mc > mb1 and 0.8 * mc > mn1 and mb > 0.8 * mn and mn > 0.8 * mb)
        highd = dcn > 5 * dbc and dcn > 5 * dnn and dcn > thr and dbc < thr and dnn < thr
        lowd = dcn * 5 < dbc and dcn * 5 < dnn and dbc > thr and dnn > thr and dcn < thr and frfac > 0.35 and (frfac < 0.51 or dcn * 5 < dbb)
        res = d43 < thr and d32 < thr and d21 < thr and d10 < thr and d01 < thr and d12 < thr and d23 < thr and d34 < thr or dbc * 4 < dbb and dcn * 4 < dbb and dnn * 4 < dbb and dn2 * 4 < dbb or dcn * 4 < dbc and dnn * 4 < dbc and dn2 * 4 < dbc

        ### offset calculation ###
        if blend:
            odm = denm
        elif clear:
            odm = 0
        elif highd:
            odm = denm - numr
        elif lowd:
            odm = 2 * denm - numr
        else:
            odm = cof
        odm += math.floor((cof - odm) / (2 * denm) + 0.5) * 2 * denm

        if blend:
            odr = denm - numr
        elif clear or highd:
            odr = numr
        elif frfac < 0.5:
            odr = 2 * numr
        else:
            odr = 2 * (denm - numr)
        odr *= 0.9

        if self.ldet >= 0:
            if cof > odm + odr:
                if cof - offs - odm - odr > denm and res:
                    cof = odm + 2 * denm - odr
                else:
                    cof = odm + odr
            elif cof < odm - odr:
                if offs > denm and res:
                    cof = odm - 2 * denm + odr
                else:
                    cof = odm - odr
            elif offs < -1.15 * denm and res:
                cof += 2 * denm
            elif offs > 1.25 * denm and res:
                cof -= 2 * denm

        offs = 0 if frfac == 1 else cof - cfo - 2 * numr * pos
        self.offs = offs
        lpos = self.lpos = pos
        opos = 0 if frfac == 1 else -math.floor((cfo + offs + (denm if bfo and offs <= -4 * numr else 0)) / (2 * numr) + 0.5)
        pos = min(max(opos, -2), 2)

        ### frame output calculation - resync - dup ###
        dbb = [d43, d32, d21, d10, d01][pos + 2]
        dbc = [d32, d21, d10, d01, d12][pos + 2]
        dcn = [d21, d10, d01, d12, d23][pos + 2]
        dnn = [d10, d01, d12, d23, d34][pos + 2]

        ### dup_hq - merge ###
        if opos != pos or abs(mode) < 2 or abs(mode) == 3:
            dup = 0
        elif dcn * 5 < dbc and dnn * 5 < dbc and (dcn < 1.25 * thr or bn < bc and pos == lpos) or (dcn * dcn < dbc or dcn * 5 < dbc) and bn < bc and pos == lpos and dnn < 0.9 * dbc or dnn * 9 < dbc and dcn * 3 < dbc:
            dup = 1
        elif (dbc * dbc < dcn or dbc * 5 < dcn) and bb < bc and pos == lpos and dbb < 0.9 * dcn or dbb * 9 < dcn and dbc * 3 < dcn or dbb * 5 < dcn and dbc * 5 < dcn and (dbc < 1.25 * thr or bb < bc and pos == lpos):
            dup = -1
        else:
            dup = 0
        mer = opos == pos and dup == 0 and abs(mode) > 2 and (dbc * 8 < dcn or dbc * 8 < dbb or dcn * 8 < dbc or dcn * 8 < dnn or dbc * 2 < thr or dcn * 2 < thr or dnn * 9 < dbc and dcn * 3 < dbc or dbb * 9 < dcn and dbc * 3 < dcn)

        ### deblend - doubleblend removal ###
        add = bp1 * cn2 > bn2 * cp1 * (1 + thr * 0.01) and bn0 * cn2 > bn2 * cn0 * (1 + thr * 0.01) and cn2 * bn1 > cn1 * bn2 * (1 + thr * 0.01)
        if dup == 0:
            if omode > 0 and omode < 5:
                if not bbool:
                    dup = 0
                elif omode == 4 and bp1 * cn1 < bn1 * cp1 or omode == 3 and d10 < d01 or omode == 1:
                    dup = -1
                else:
                    dup = 1
            elif omode == 5:
                if bp1 * cp2 > bp2 * cp1 * (1 + thr * 0.01) and bn0 * cp2 > bp2 * cn0 * (1 + thr * 0.01) and cp2 * bn1 > cn1 * bp2 * (1 + thr * 0.01) and (not add or cp2 * bn2 > cn2 * bp2):
                    dup = -2
                elif add:
                    dup = 2
                elif bn0 * cp1 > bp1 * cn0 and (bn0 * cn1 < bn1 * cn0 or cp1 * bn1 > cn1 * bp1):
                    dup = -1
                elif bn0 * cn1 > bn1 * cn0:
                    dup = 1
                else:
                    dup = 0
            else:
                dup = 0

        ### output ###
        merged = bool(mer and dup == 0)
        opos += dup - (1 if dup == 0 and mer and dbc < dcn else 0)
        return opos, merged


def stats_clip(source, speed=None):
    """The per-frame measurements the detector reads, as frame properties on a
    1x1 clip the length of ``source`` (upstream's three PlaneStats clips).

    Detection runs on an 8-bit copy of the luma, as upstream's does, whatever
    the source's depth.
    """
    srad = math.sqrt(abs(speed)) * 4 if speed is not None and abs(speed) >= 1 else 12
    bsize = 16 if speed is not None and speed > 0 else 32

    # Upstream reads past the end through clips trimmed by up to 4 frames,
    # where VapourSynth returns the last frame. Padding with copies of the
    # last frame gives the same values and lets a clip of 1-4 frames run.
    dclip = source + source[-1] * 8
    family = dclip.format.color_family
    if family == vs.GRAY:
        # Only the luma is measured; a grey clip is its own luma.
        dclip = core.resize.Bicubic(dclip, format=vs.GRAY8)
    elif family == vs.RGB:
        dclip = core.resize.Bicubic(dclip, format=vs.YUV420P8, matrix_s='709')
    elif dclip.format.id != vs.YUV420P8:
        dclip = core.resize.Bicubic(dclip, format=vs.YUV420P8)
    dclip = core.resize.Point(dclip,
                              dclip.width if srad == 4 else int(dclip.width / 2 / srad + 4) * 4,
                              dclip.height if srad == 4 else int(dclip.height / 2 / srad + 4) * 4).std.Trim(2)
    if dclip.format.color_family != vs.GRAY:
        dclip = core.std.ShufflePlanes(dclip, 0, vs.GRAY)

    diff = core.std.MakeDiff(dclip, core.std.Trim(dclip, 1))
    bclp = _expr([diff, core.std.Trim(diff, 1)], [_EXPR_BLEND]).resize.Bilinear(bsize, bsize)
    dclp = core.std.Trim(diff, 1).std.Lut(function=lambda x: max(math.floor(abs(x - 128) ** 1.1 - 1 + 0.5), 0)).resize.Bilinear(bsize, bsize)

    b_stats = core.std.PlaneStats(bclp)
    d_stats = core.std.PlaneStats(dclp)
    m_stats = core.std.PlaneStats(dclip, core.std.Trim(dclip, 2))

    n = len(source)

    def fit(c):
        # Upstream reads these through FrameEval's prop_src, where a request
        # past a shorter clip's end returns its last frame. Make that explicit.
        return c + c[-1] * (n - len(c)) if len(c) < n else c[:n]

    b_stats, d_stats, m_stats = fit(b_stats), fit(d_stats), fit(m_stats)
    blank = core.std.BlankClip(format=vs.GRAY8, width=1, height=1, length=n,
                               fpsnum=source.fps_num, fpsden=source.fps_den)

    def collect(n, f):
        out = f[0].copy()
        out.props['SrBMin'] = f[1].props['PlaneStatsMin']
        out.props['SrBMax'] = f[1].props['PlaneStatsMax']
        out.props['SrDMax'] = f[2].props['PlaneStatsMax']
        out.props['SrMDiff'] = f[3].props['PlaneStatsDiff']
        return out

    stats = core.std.ModifyFrame(blank, [blank, b_stats, d_stats, m_stats], collect)
    # Every decision reads a window of these, through one shifted copy per
    # frame of the window. VapourSynth's automatic cache sizing does not keep
    # up with that fan-out: frames were evicted and recomputed, and with them
    # the deinterlacer's frames behind them (879 QTGMC frames computed for 300
    # at SD, 3x the time). They are 1x1, so keep plenty.
    core.std.SetVideoCache(stats, mode=1, fixedsize=1, maxsize=_STATS_CACHE_FRAMES,
                           maxhistory=_STATS_CACHE_FRAMES)
    return stats


def props_of(frame):
    return tuple(frame.props[k] for k in _PROP_KEYS)


def decide(n, props, start, frfac, numr, denm, thresh=16, mode=2):
    """The decision for frame ``n``: replay the detector with fresh state over
    ``props`` (the measurements of frames ``start .. n``, in order)."""
    det = _Detector(frfac, numr, denm, thresh=thresh, mode=mode)
    result = (0, False)
    for i, p in enumerate(props):
        result = det.step(start + i, *p)
    return result


def window_start(n, origin, window):
    return max(origin, n - window, 0)


def _shift(clip, offset):
    """``clip`` with frame n replaced by frame ``n + offset``, clamped to the
    clip's ends (what upstream's per-frame Trim / DuplicateFrames give)."""
    if offset == 0:
        return clip
    if offset > 0:
        if offset >= len(clip):
            return clip[-1] * len(clip)
        return clip[offset:] + clip[-1] * offset
    offset = -offset
    if offset >= len(clip):
        return clip[0] * len(clip)
    return clip[0] * offset + clip[:len(clip) - offset]


def unblend(clip, num, den, origin=0, window=48, thresh=16, mode=2, speed=None):
    """Restore the frames of a blend-converted ``clip`` at ``num/den`` fps.

    ``origin`` is the index in ``clip`` of the encode's first frame: frames
    before it (the preview's alignment padding) never feed the detector.
    ``window`` is how many frames each decision replays. The output has exactly
    ``len(clip) * r.numerator // r.denominator`` frames, r being the reduced
    target/input ratio, and the script raises rather than run a ratio srestore
    would compute differently.
    """
    from fractions import Fraction

    frfac, numr, denm = ratio(clip.fps_num, clip.fps_den, num, den)
    exact = Fraction(num, den) / Fraction(clip.fps_num, clip.fps_den)
    if frfac == 1 or Fraction(numr, denm) != exact:
        raise vs.Error(
            f'Unblend: cannot convert {clip.fps_num}/{clip.fps_den} fps to {num}/{den} fps '
            f'(srestore ratio {numr}/{denm}, exact {exact})')

    r = exact
    length = len(clip) * r.numerator // r.denominator
    if length < 1:
        raise vs.Error(f'Unblend: {len(clip)} frames is too short to convert to {num}/{den} fps')

    stats = stats_clip(clip, speed=speed)
    # Shifted copies of the stats: frame n of shifted[k] carries frame n-k's
    # measurements, so one ModifyFrame sees the whole window at once.
    shifted = [_shift(stats, -k) for k in range(window + 1)]
    blank = core.std.BlankClip(stats)
    memo = {}

    def decide_frame(n, f):
        key = n
        if key not in memo:
            start = window_start(n, origin, window)
            props = [props_of(f[n - i]) for i in range(start, n + 1)]
            if len(memo) > 4096:
                memo.clear()
            memo[key] = decide(n, props, start, frfac, numr, denm, thresh=thresh, mode=mode)
        opos, mer = memo[key]
        out = f[0].copy()
        out.props['UnblendOffset'] = opos
        out.props['UnblendMerge'] = int(mer)
        return out

    decisions = core.std.ModifyFrame(blank, shifted, decide_frame)

    # Output frames are taken from the encode's own frames only: in a preview
    # the padding and anything before the in-point are replaced by the first
    # real frame, which is what the encode's clip returns before its start.
    base = clip[origin] * origin + clip[origin:] if 0 < origin < len(clip) else clip
    merged = None
    if abs(mode) > 2:
        merged = core.std.Merge(base, _shift(base, 1), weight=0.5)

    nodes = {}

    def pick(n, f):
        opos = f.props['UnblendOffset']
        mer = f.props['UnblendMerge']
        key = (opos, mer)
        node = nodes.get(key)
        if node is None:
            # One node per distinct offset (a handful), not one per frame.
            node = _shift(merged if mer else base, opos)
            nodes[key] = node
        return node

    selected = core.std.FrameEval(clip, pick, prop_src=decisions)

    cycle, keep = r.denominator, r.numerator
    offsets = [k * cycle // keep for k in range(keep)]
    out = core.std.SelectEvery(selected, cycle=cycle, offsets=offsets)
    if len(out) > length:
        out = out[:length]
    elif len(out) < length:
        out = out + out[-1] * (length - len(out))
    return core.std.AssumeFPS(out, fpsnum=num, fpsden=den)
