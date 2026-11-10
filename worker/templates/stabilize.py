"""
Stabilize - vertical pitch correction for VapourBox's Stabilize pass (issue #150).

The pass makes two independent corrections, in this order:

1. Weave / shake: havsfunc ``Stab`` (``mv.DepanEstimate`` /
   ``DepanCompensate`` against a temporal average), called directly from the
   templates.

2. Vertical pitch ("frame height breathing"), this module: pull-through film
   scanners let the film slip in the gate, so from one frame to the next the
   picture is stretched or squashed vertically by a fraction of a percent. A
   translation stabiliser cannot remove that. Each frame is resampled
   vertically about its centre by a per-frame factor, at sub-pixel precision
   and at a constant frame size.

   The factor comes either from a file (one value per source frame) or is
   measured here (``auto``): the relative vertical scale and shift between
   every pair of adjacent frames is measured, and each frame is corrected to
   the mean of the ±radius frames around it. A symmetric mean leaves a steady
   or linearly changing pitch alone, so slow intentional zooms and tilts are
   kept and only the frame-to-frame jitter is removed. Each frame reads only
   the measurements in its own window, so there is no sequential pre-pass and
   a single-frame preview measures exactly what the encode does.

Factor convention: a factor is the *measured* height of the picture relative to
nominal. 1.004 means the frame came out 0.4% too tall, and it is corrected by
compressing it by 1/1.004. ``invert=True`` accepts files written the other way
round (the stretch to apply).

Written for VapourBox.
"""

import math
from collections import OrderedDict

import vapoursynth as vs

core = vs.core

# Quantisation of per-frame corrections. Every distinct correction needs its
# own resize node inside FrameEval, so values are rounded to a grid (0.01% of
# height for the scale, 1/32 px for the offset) and the most recently used
# nodes are kept. 0.01% is 0.1 px at 1080 lines — well below what can be seen.
_SCALE_QUANTUM = 1e-4
_SHIFT_QUANTUM = 1.0 / 32.0
_NODE_CACHE_SIZE = 256

# Mean absolute difference (0-1) between a frame pair's measurement strips,
# after the best alignment, above which the pair is not trusted. The strip
# averages ~100 columns into each sample, so grain barely registers; what's
# left above this is real content change. Measured on small_clip.mp4: steady
# pairs align to < 0.01, pairs with fast motion stay above 0.02.
_UNRELIABLE_DIFF = 3.0 / 255.0


def _black(fmt):
    """Black for any format: limited-range black for YUV, 0 for RGB/Gray.

    Computed from the format rather than written as 8-bit constants, so a
    10-bit or float clip isn't filled with dark green.
    """
    if fmt.sample_type == vs.FLOAT:
        return [0.0] * fmt.num_planes
    shift = fmt.bits_per_sample - 8
    if fmt.color_family == vs.YUV:
        return [16 << shift, 128 << shift, 128 << shift]
    if fmt.color_family == vs.GRAY:
        return [16 << shift]
    return [0] * fmt.num_planes


def _to_working(clip, integer=False):
    """Carry an RGB clip through 4:4:4 YUV (and float through 16-bit when
    ``integer``), so the measurement works on luma.

    Returns the converted clip plus the original format to restore, or None
    when nothing changed.
    """
    fmt = clip.format
    family = vs.YUV if fmt.color_family == vs.RGB else fmt.color_family
    sample_type, bits = fmt.sample_type, fmt.bits_per_sample
    if integer and sample_type == vs.FLOAT:
        sample_type, bits = vs.INTEGER, 16
    if family == fmt.color_family and sample_type == fmt.sample_type:
        return clip, None
    work = core.query_video_format(family, sample_type, bits,
                                   fmt.subsampling_w, fmt.subsampling_h)
    if fmt.color_family == vs.RGB:
        return core.resize.Point(clip, format=work.id, matrix_s="709"), fmt
    return core.resize.Point(clip, format=work.id), fmt


def _from_working(clip, orig_fmt):
    if orig_fmt is None:
        return clip
    if orig_fmt.color_family == vs.RGB:
        return core.resize.Point(clip, format=orig_fmt.id, matrix_in_s="709")
    return core.resize.Point(clip, format=orig_fmt.id)


def correct_frame(clip, factor, shift=0.0, black=False):
    """Undo a vertical stretch of ``factor`` and a downward shift of ``shift``
    pixels, keeping the frame size.

    Output row y samples input row ``c + factor*(y - c) + shift`` (c = centre),
    i.e. ``src_height = factor*H`` and ``src_top = (1 - factor)*H/2 + shift``.
    Rows that would come from outside the frame are edge-extended by zimg, or
    blacked out when ``black`` is set.
    """
    h = clip.height
    src_height = factor * h
    src_top = (1.0 - factor) * h / 2.0 + shift
    out = core.resize.Spline36(clip, width=clip.width, height=h,
                               src_left=0, src_width=clip.width,
                               src_top=src_top, src_height=src_height)
    if not black:
        return out

    # Rows sampled from outside [0, h): top ones have y < (-src_top)/factor,
    # bottom ones have y > (h - src_top)/factor. Round outwards and to the
    # chroma subsampling so Crop/AddBorders stay legal.
    mod = 1 << out.format.subsampling_h
    top = max(0.0, -src_top / factor)
    bottom = max(0.0, h - (h - src_top) / factor)
    top = int(math.ceil(top / mod)) * mod
    bottom = int(math.ceil(bottom / mod)) * mod
    if top == 0 and bottom == 0:
        return out
    if top + bottom >= h:
        return core.std.BlankClip(out, color=_black(out.format))
    out = core.std.Crop(out, top=top, bottom=bottom)
    return core.std.AddBorders(out, top=top, bottom=bottom, color=_black(out.format))


def _apply_per_frame(clip, lookup, black, prop_src=None):
    """FrameEval wrapper: ``lookup(n, f) -> (factor, shift)``.

    Corrected nodes are cached per quantised correction (LRU, so a long reel
    can't accumulate thousands of nodes). Every output frame carries
    ``VapourBox_PitchFactor`` / ``VapourBox_PitchShift`` — what was applied —
    for diagnostics and tests.
    """
    cache = OrderedDict()

    def _select(n, f=None):
        factor, shift = lookup(n, f)
        key = (round((factor - 1.0) / _SCALE_QUANTUM), round(shift / _SHIFT_QUANTUM))
        node = cache.get(key)
        if node is not None:
            cache.move_to_end(key)
            return node
        factor = 1.0 + key[0] * _SCALE_QUANTUM
        shift = key[1] * _SHIFT_QUANTUM
        node = clip if key == (0, 0) else correct_frame(clip, factor, shift, black)
        node = core.std.SetFrameProps(node, VapourBox_PitchFactor=factor,
                                      VapourBox_PitchShift=shift)
        cache[key] = node
        if len(cache) > _NODE_CACHE_SIZE:
            cache.popitem(last=False)
        return node

    if prop_src is None:
        return core.std.FrameEval(clip, lambda n: _select(n))
    return core.std.FrameEval(clip, _select, prop_src=prop_src)


def pitch_from_file(clip, factors_path, frame_offset=0, rate_num=1, rate_den=1,
                    invert=False, max_deviation=0.01, black=False):
    """Pitch correction from a file of per-source-frame factors.

    The file is the worker's normalised copy: one float per line, already
    validated. ``n`` is the frame number *in this clip*, which is not the
    source frame number — a preview decodes a window starting at
    ``frame_offset`` and a trimmed encode starts at the trim point — and a
    preceding deinterlace pass may have changed the rate. The source frame is
    ``frame_offset + n * rate_den // rate_num``.
    """
    with open(factors_path, "r", encoding="utf-8") as fh:
        factors = [float(line) for line in fh if line.strip()]

    lo, hi = 1.0 - max_deviation, 1.0 + max_deviation

    def _lookup(n, f=None):
        idx = frame_offset + (n * rate_den) // rate_num
        factor = factors[idx] if 0 <= idx < len(factors) else 1.0
        if invert and factor > 0:
            factor = 1.0 / factor
        return min(hi, max(lo, factor)), 0.0

    return _apply_per_frame(clip, _lookup, black)


def _measure_strip(clip, strip_width):
    """Luma, centre 60% of the width, squeezed to a narrow strip.

    A vertical scale doesn't depend on horizontal detail, so averaging columns
    together costs nothing in precision and cuts the search cost ~40x. Kept at
    float for exact diffs.
    """
    luma = core.std.ShufflePlanes(clip, 0, vs.GRAY) if clip.format.num_planes > 1 else clip
    x0 = int(luma.width * 0.2)
    w = luma.width - 2 * x0
    return core.resize.Bicubic(luma, width=strip_width, height=luma.height,
                               src_left=x0, src_width=w, format=vs.GRAYS)


def _parabola(a, b, c):
    """Vertex offset (-0.5..0.5 steps) of a parabola through 3 equally spaced points."""
    denom = a - 2.0 * b + c
    if denom <= 0:
        return 0.0
    return max(-0.5, min(0.5, 0.5 * (a - c) / denom))


def _shifted(clip, offset):
    """Frame n of the result is frame n+offset of ``clip``, clamped at the ends."""
    if offset == 0:
        return clip
    n = clip.num_frames
    if abs(offset) >= n:
        return clip[0] * n if offset < 0 else clip[-1] * n
    if offset > 0:
        return clip[offset:] + clip[-1] * offset
    return clip[0] * (-offset) + clip[:offset]


def _pair_motion(strip, max_scale, step, max_shift, shift_step):
    """Per-frame relative vertical motion between frame k and frame k+1.

    Frame k of the returned (tiny) clip carries ``PairScale``/``PairShift``:
    the (s, t) for which ``correct_frame(strip[k+1], s, t)`` best matches
    ``strip[k]``, i.e. frame k+1 is stretched by s relative to frame k and
    shifted down by t. Adjacent frames are nearly identical, so this is far
    more precise than matching against a temporal average, which motion and
    the breathing itself both blur. ``PairCut`` marks a scene change between
    k and k+1, across which nothing is measured.
    """
    h = strip.height
    # Compare only the central rows: the outer ones are edge-extended in some
    # candidates and not others, which would bias the search toward 1.0.
    margin = int(math.ceil(h * max_scale)) + int(math.ceil(max_shift)) + 4
    margin = min(margin, h // 4)

    def _core_rows(c):
        return core.std.Crop(c, top=margin, bottom=margin)

    nxt = _shifted(strip, 1)
    ref_core = _core_rows(strip)

    n_scale = max(1, int(round(max_scale / step)))
    scales = [1.0 + i * step for i in range(-n_scale, n_scale + 1)]
    n_shift = int(round(max_shift / shift_step)) if shift_step > 0 else 0
    shifts = [i * shift_step for i in range(-n_shift, n_shift + 1)]
    n_t = len(shifts)

    stats = []
    for s in scales:
        for t in shifts:
            stats.append(core.std.PlaneStats(_core_rows(correct_frame(nxt, s, t)), ref_core))
    # Scene change detection on the strip itself: _SceneChangeNext on frame k.
    cuts = core.misc.SCDetect(strip, threshold=0.1)

    last = strip.num_frames - 1

    def _measure(n, f):
        fout = f[0].copy()
        diffs = [fr.props["PlaneStatsDiff"] for fr in f[1:]]
        best = min(range(len(diffs)), key=diffs.__getitem__)
        i, j = divmod(best, n_t)
        di = 0.0
        if 0 < i < len(scales) - 1:
            di = _parabola(diffs[best - n_t], diffs[best], diffs[best + n_t])
        dj = 0.0
        if 0 < j < n_t - 1:
            dj = _parabola(diffs[best - 1], diffs[best], diffs[best + 1])
        fout.props["PairScale"] = scales[i] + di * step
        fout.props["PairShift"] = shifts[j] + dj * shift_step
        fout.props["PairDiff"] = diffs[best]
        # A pair whose best match still differs a lot is changing for reasons
        # other than gate geometry (fast motion, a flash, a cut): its
        # measurement is noise, so the chain is broken there like at a cut.
        unreliable = diffs[best] > _UNRELIABLE_DIFF
        cut = n >= last or f[0].props.get("_SceneChangeNext", 0) or unreliable
        fout.props["PairCut"] = 1 if cut else 0
        return fout

    tiny = core.std.BlankClip(strip, width=8, height=8, format=vs.GRAY8)
    tiny = core.std.CopyFrameProps(tiny, cuts)
    return core.std.ModifyFrame(tiny, [tiny] + stats, _measure)


def pitch_auto(clip, max_deviation=0.01, radius=10, step=0.002,
               max_shift=2.0, shift_step=0.25, strip_width=48, black=False):
    """Measure and correct vertical pitch and vertical jitter, frame by frame.

    1. Relative (scale, shift) between every pair of adjacent frames, by grid
       search on a narrow luma strip with parabolic sub-step refinement.
    2. For frame n, chain those relative measurements across the ±radius
       window (stopping at scene changes) to get every frame's position
       relative to frame n, and correct n to the window's mean. A symmetric
       mean leaves a constant or linearly changing pitch or position alone, so
       slow zooms and tilts survive; only the jitter is removed.

    Each frame only reads the pair measurements in its own window, so there is
    no sequential state and preview frames match the encode.
    """
    if clip.format.color_family == vs.RGB:
        work, orig = _to_working(clip)
        out = pitch_auto(work, max_deviation, radius, step, max_shift,
                         shift_step, strip_width, black)
        return _from_working(out, orig)

    radius = max(1, int(radius))
    strip = _measure_strip(clip, strip_width)
    # Adjacent frames can differ by up to twice the allowed deviation. The
    # grid is capped at ±10 steps so a large limit costs coarser steps (the
    # parabolic refinement still interpolates between them), not a search
    # that grows without bound: at the default 1% it is 21 scales x 17 shifts.
    pair_range = 2.0 * max_deviation
    step = max(step, pair_range / 10.0)
    pairs = _pair_motion(strip, pair_range, step, max_shift, shift_step)
    # prop_src[i] is the pair (n + i - radius, n + i - radius + 1).
    window = [_shifted(pairs, o) for o in range(-radius, radius)]

    lo, hi = 1.0 - max_deviation, 1.0 + max_deviation
    nframes = clip.num_frames

    def _lookup(n, f):
        # Position of frame k relative to frame n: log-scale L[k], shift T[k].
        # Walk outwards from n, stopping at the clip ends and at scene changes.
        L = {0: 0.0}
        T = {0: 0.0}
        # forward: pair (n+d, n+d+1) is f[radius + d]
        for d in range(0, radius):
            k = n + d
            p = f[radius + d].props
            if k + 1 >= nframes or p["PairCut"]:
                break
            s = p["PairScale"]
            L[d + 1] = L[d] + math.log(s)
            T[d + 1] = T[d] * s + p["PairShift"]
        # backward: pair (n-d-1, n-d) is f[radius - d - 1]
        for d in range(0, radius):
            k = n - d - 1
            p = f[radius - d - 1].props
            if k < 0 or p["PairCut"]:
                break
            s = p["PairScale"]
            # frame n-d = correct(frame n-d-1) relation inverted
            L[-(d + 1)] = L[-d] - math.log(s)
            T[-(d + 1)] = (T[-d] - p["PairShift"]) / s
        if len(L) < 3:
            return 1.0, 0.0
        mean_l = sum(L.values()) / len(L)
        mean_t = sum(T.values()) / len(T)
        # Frame n relative to the window mean.
        factor = math.exp(-mean_l)
        shift = -mean_t
        return min(hi, max(lo, factor)), max(-max_shift, min(max_shift, shift))

    return _apply_per_frame(clip, _lookup, black, prop_src=window)


def correct_pitch(clip, mode="off", factors_path=None, frame_offset=0,
                  rate_num=1, rate_den=1, invert=False, max_deviation_pct=1.0,
                  radius=10, black=False):
    """Entry point used by the VapourBox templates' Stabilize pass.

    ``mode`` is ``"auto"`` or ``"file"`` (the worker drops the call for
    ``"off"``); file mode needs ``factors_path``, the worker's validated copy.
    """
    max_dev = max(0.0001, float(max_deviation_pct) / 100.0)
    if mode == "file" and factors_path:
        return pitch_from_file(clip, factors_path, frame_offset=frame_offset,
                               rate_num=rate_num, rate_den=rate_den, invert=invert,
                               max_deviation=max_dev, black=black)
    if mode == "auto":
        return pitch_auto(clip, max_deviation=max_dev, radius=radius, black=black)
    return clip
