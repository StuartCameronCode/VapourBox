"""
AutoChromaFix - measure and correct chroma-to-luma misalignment automatically.

Composite captures, cheap TBCs and some DVD encoders leave the chroma planes
displaced from the luma by a fraction of a pixel to a couple of pixels, usually
horizontally (the classic Y/C delay). VapourBox already exposes a manual Chroma
Shift; this measures the shift instead of asking the user to eyeball it.

Method: bring the chroma planes up to luma resolution once, take a directional
Prewitt edge magnitude of luma and chroma along the axis being searched, and
score how well the two agree at each whole-pixel lag with a normalised
cross-correlation. The peak of that score curve, refined to sub-pixel by fitting
a parabola through it, is the displacement; it is applied with a `resize.Bicubic`
sub-pixel shift in the same units and with the same sign convention as the
manual Chroma Shift control -- whole *luma* pixels, positive moving the chroma
planes left/up.

Written for VapourBox. The idea of scoring chroma displacement against a luma
edge mask is not new -- `autoChromaFix.py` in Selur's
VapoursynthScriptsInHybrid does the same thing -- but that file carries no
licence of any kind, so nothing here is taken from it: the search strategy, the
scoring function, the sub-pixel handling and the chroma-siting handling below
were all worked out and measured against this project's own fixtures.
"""

import math

import vapoursynth as vs

core = vs.core


# See the identical helper in the two .vpy templates: VapourSynth's std.Expr
# JIT is x86-only, so on ARM every expression is walked once per pixel. akarin
# has a real LLVM JIT that works on aarch64. The fallback names core.std.Expr
# explicitly -- calling _expr() would recurse forever.
_akarin_expr = getattr(getattr(core, 'akarin', None), 'Expr', None)


def _expr(clips, expr, **kwargs):
    if _akarin_expr is not None:
        return _akarin_expr(clips, expr, **kwargs)
    return core.std.Expr(clips, expr, **kwargs)


# A search wider than this is not a misalignment, it is a different picture.
_MAX_SHIFT = 16


def _peak(clip):
    if clip.format.sample_type == vs.FLOAT:
        return 1.0
    return float((1 << clip.format.bits_per_sample) - 1)


def _check(clip):
    if not isinstance(clip, vs.VideoNode):
        raise TypeError('auto_chroma_fix: clip must be a VideoNode')
    if clip.format is None:
        raise ValueError(
            'auto_chroma_fix: variable-format clips are not supported')
    if clip.format.color_family != vs.YUV:
        raise ValueError(
            'auto_chroma_fix: only YUV clips have chroma planes to align, '
            'got {}'.format(clip.format.name))


def _shift_chroma(clip, dx, dy):
    """
    Displace both chroma planes by (dx, dy) *luma* pixels.

    Same convention as the manual Chroma Shift block in the pipeline template:
    `src_left` is in the plane's own samples, so a luma-pixel shift is divided
    by the subsampling factor. Positive moves the picture left / up.
    """
    if dx == 0 and dy == 0:
        return clip
    cx = dx / float(1 << clip.format.subsampling_w)
    cy = dy / float(1 << clip.format.subsampling_h)
    planes = [core.std.ShufflePlanes(clip, i, vs.GRAY) for i in range(3)]
    planes[1] = core.resize.Bicubic(planes[1], src_left=cx, src_top=cy)
    planes[2] = core.resize.Bicubic(planes[2], src_left=cx, src_top=cy)
    return core.std.ShufflePlanes(planes, [0, 0, 0], vs.YUV)


def _chroma_at_luma_res(clip):
    """
    Both chroma planes brought up to luma resolution, sited correctly.

    The siting term is what stops a correctly aligned clip being "corrected".
    Chroma in 4:2:0, 4:2:2 and 4:1:1 is co-sited with the left luma sample
    horizontally and centred vertically, so a naive per-plane upscale puts it
    part of a luma pixel to the right of where it belongs and the search would
    dutifully measure that as a real fault. Calibrated against zimg's own 4:4:4
    conversion, which reads the clip's chroma location: the equivalent
    per-plane offset is exactly `0.5 - 0.5/factor` horizontally -- 0.25 for
    4:2:0 and 4:2:2, 0.375 for 4:1:1 -- and 0 vertically, on all three.
    """
    left = 0.5 - 0.5 / float(1 << clip.format.subsampling_w)
    return [core.resize.Bicubic(core.std.ShufflePlanes(clip, i, vs.GRAY),
                                clip.width, clip.height, src_left=left)
            for i in (1, 2)]


def _gradient(plane, axis, peak):
    """
    Prewitt edge magnitude along one axis only, at float.

    One axis, not `std.Prewitt`'s combined magnitude: the horizontal search
    wants to know where vertical edges are, and folding the perpendicular
    gradient in adds structure that no horizontal displacement can move,
    flattening the profile.

    The magnitude is taken *after* the directional difference rather than
    correlating the signed gradients, because the sign of the luma-to-chroma
    relationship is a property of the content, not of the alignment -- a red
    object on a grey background has chroma rising where luma falls. Correlating
    signed gradients produces a curve whose peak is a maximum on some sources
    and a minimum on others, with no way to tell which; the magnitude has no
    such ambiguity.

    Prewitt is separable into a 3-tap average across the axis and a central
    difference along it. The difference is two offset crops of the same clip,
    which needs no signed convolution -- `std.Convolution` clamps negative
    results away -- at the cost of one pixel at each end of the axis.
    """
    norm = _expr(plane, 'x {:.8f} /'.format(peak), format=vs.GRAYS)
    smooth = core.std.Convolution(norm, matrix=[1, 1, 1],
                                  mode='v' if axis == 0 else 'h')
    if axis == 0:
        ahead = core.std.Crop(smooth, left=2)
        behind = core.std.Crop(smooth, right=2)
    else:
        ahead = core.std.Crop(smooth, top=2)
        behind = core.std.Crop(smooth, bottom=2)
    return _expr([ahead, behind], 'x y - abs')


def _window(grad, axis, border, lag):
    """
    The scoring window, displaced by `lag` whole pixels.

    Taking the displacement as a *crop offset* is the reason this measures
    whole-pixel shifts exactly. The obvious alternative -- resample the chroma
    by each candidate and score the result -- puts a different amount of
    interpolator softening on each candidate, since a shift that happens to
    land on a whole chroma sample resamples nothing while a half-sample one is
    maximally softened. That ripple rides on top of the score curve with a
    period of one chroma sample and drags the peak by up to a quarter of a
    pixel: measured over four real 720x576 sources it lost every 1-pixel answer
    on a subsampled axis while leaving the 2-pixel ones correct. A crop
    interpolates nothing, so every lag is scored on identical pixels.
    """
    if axis == 0:
        return core.std.Crop(grad, border + lag, border - lag, border, border)
    return core.std.Crop(grad, border, border, border + lag, border - lag)


def _score_nodes(luma_grad, chroma_grad):
    """
    The three moments a normalised cross-correlation needs, as stat nodes.

    Normalising is not optional: the chroma gradient's own energy varies with
    the window, and a bare product sum tracks that rather than the alignment.
    Dividing by its standard deviation and subtracting the two means leaves
    only the agreement.
    """
    return (core.std.PlaneStats(_expr([luma_grad, chroma_grad], 'x y *')),
            core.std.PlaneStats(chroma_grad),
            core.std.PlaneStats(_expr(chroma_grad, 'x x *')))


# A score curve this flat carries no alignment information -- the peak is
# noise. Measured over four real 720x576 sources, a plane whose chroma still
# has edges spans 25-60% of its peak from end to end of the search, while a
# heavily low-passed VHS chroma plane spans 1.3% and its "peak" wanders with
# every injection. Below the threshold the honest answer is no shift at all.
_MIN_CONTRAST = 0.05

# Residual bias in the vertex estimate, treated as a whole-pixel answer. The
# five-point fit gets a correctly aligned source down to 0.06 px, so this is
# comfortably clear of it, and a genuine quarter-pixel misalignment produces a
# vertex several times larger. Swept over 81 known-shift measurements across
# seven real source formats: 0.12 loses 4:1:1 entirely, 0.15 and 0.18 score
# identically, so the value that keeps the most sub-pixel sensitivity wins.
_VERTEX_DEADZONE = 0.15

# Extra lags scored either side of the requested range, purely so the peak
# refinement has its full five points even when the answer sits at the edge of
# what the user asked for.
_PAD = 2


def _refine(scores, lags, accuracy, limit):
    """
    Peak of the score curve, to sub-pixel, quantised to `accuracy`.

    Five points, fitted by least squares, rather than the usual three-point
    parabola vertex. The three-point formula is exact only for a curve that is
    genuinely quadratic, and a correlation peak over real edges is not: on
    correctly aligned broadcast footage it reports a displacement of 0.12 to
    0.25 px where the true answer is 0, which at the default quantisation is
    the difference between the right answer and a spurious quarter-pixel
    shift. Fitting five points brings the same measurements down to 0.06 px.

    `scores` and `lags` carry `_PAD` extra entries at each end, so the fit has
    its full window even for a peak at the edge of the requested range; the
    peak itself is only looked for inside that range.
    """
    # If the curve is still climbing at the far end of the padded range, the
    # real peak is outside everything that was searched and the edge value
    # would be a guess. Say nothing rather than displace the chroma by the
    # width of the search window -- that is what a source with no measurable
    # alignment does, and it is also the honest answer for a genuine shift
    # bigger than max_shift, which the user can widen.
    outermost = max(range(len(scores)), key=lambda i: scores[i])
    if outermost in (0, len(scores) - 1):
        return 0.0

    inner = range(_PAD, len(scores) - _PAD)
    best = max(inner, key=lambda i: scores[i])
    peak = scores[best]
    span = max(scores[i] for i in inner) - min(scores[i] for i in inner)
    if span <= _MIN_CONTRAST * max(abs(peak), 1e-12):
        return 0.0

    window = scores[best - 2:best + 3]
    # Least-squares parabola over x = -2..2: the normal equations collapse to
    # these two coefficients, and the vertex is -b / 2a.
    a = (2.0 * (window[0] + window[4])
         - (window[1] + window[3]) - 2.0 * window[2]) / 14.0
    b = (2.0 * (window[4] - window[0]) + (window[3] - window[1])) / 10.0
    delta = 0.0
    if a < 0.0:
        delta = -b / (2.0 * a)
        delta = 0.0 if abs(delta) < _VERTEX_DEADZONE else min(1.0, max(-1.0, delta))

    quantised = round((lags[best] + delta) / accuracy) * accuracy
    return round(min(limit, max(-limit, quantised)), 6)


class _Search(object):
    """Builds, and later reads, the score nodes for one clip."""

    def __init__(self, clip, lags, border):
        self.lags = lags
        peak = _peak(clip)
        luma = core.std.ShufflePlanes(clip, 0, vs.GRAY)
        chroma = _chroma_at_luma_res(clip)

        # Horizontal and vertical are searched independently rather than over
        # the full 2D grid: 2n windows instead of n^2, and the two axes are
        # separable for the small displacements this corrects.
        self.luma_stat = []
        self.nodes = []
        for axis in (0, 1):
            luma_grad = _gradient(luma, axis, peak)
            self.luma_stat.append(
                core.std.PlaneStats(_window(luma_grad, axis, border, 0)))
            chroma_grad = [_gradient(p, axis, peak) for p in chroma]
            for lag in lags:
                for grad in chroma_grad:
                    self.nodes.append(_score_nodes(
                        _window(luma_grad, axis, border, 0),
                        _window(grad, axis, border, lag)))

    def prop_src(self):
        return self.luma_stat + [n for triple in self.nodes for n in triple]

    def solve(self, values, accuracy, limit):
        """values: the flat list of PlaneStatsAverage in prop_src() order."""
        mean_a = values[:2]
        moments = values[2:]
        count = len(self.lags)

        def ncc(index, axis):
            mean_ab, mean_b, mean_bb = moments[3 * index:3 * index + 3]
            sd_b = max(mean_bb - mean_b * mean_b, 0.0) ** 0.5
            if sd_b <= 0.0:
                return 0.0
            return (mean_ab - mean_a[axis] * mean_b) / sd_b

        result = []
        for axis in (0, 1):
            base = axis * 2 * count
            # One answer for both planes, from the sum of their correlations.
            # A Y/C timing error displaces U and V identically, and dividing by
            # each plane's own deviation has already put the two on the same
            # scale -- so a plane with little colour variation contributes a
            # near-zero curve rather than an answer that is pure noise.
            scores = [ncc(base + 2 * i, axis) + ncc(base + 2 * i + 1, axis)
                      for i in range(count)]
            result.append(_refine(scores, self.lags, accuracy, limit))
        return result[0], result[1]

    def read(self, frame):
        return [node.get_frame(frame).props['PlaneStatsAverage']
                for node in self.prop_src()]


def auto_chroma_fix(clip, max_shift=2, accuracy=0.25, reference_frame=0):
    """
    Measure the chroma-to-luma misalignment and correct it.

    Args:
        clip:            Input clip (YUV, integer or float, any subsampling).
        max_shift:       Largest displacement to search for, in luma pixels
                         (default 2, maximum 16). The score curve is sampled at
                         whole pixels out to this distance on both axes.
        accuracy:        Quantisation of the sub-pixel answer, in luma pixels
                         (default 0.25). Whole-pixel misalignments come out
                         exactly whatever this is set to; it only decides how
                         finely a fractional one is reported.
        reference_frame: Frame to measure on (default 0). -1 measures every
                         frame, which is only worth it on a source whose
                         misalignment actually drifts: measured at 720x576 the
                         default costs 0.07 s once and then runs at 1020 fps,
                         while per-frame runs at 44 fps.

    The measured displacement is attached to every output frame as the
    `_AutoChromaShiftH` / `_AutoChromaShiftV` frame properties, in luma pixels.
    Nothing is drawn into the picture.

    Note on `reference_frame`: the measurement is made when the filter chain is
    built, so with VapourBox's pipe source the reference frame is read out of
    the pipe at script-evaluation time. 0 is the safe value; a large one would
    consume the pipe ahead of the encode.

    Returns:
        Clip with the chroma planes realigned to the luma.
    """
    _check(clip)

    max_shift = float(max_shift)
    accuracy = float(accuracy)
    if accuracy <= 0.0:
        raise ValueError('auto_chroma_fix: accuracy must be positive')
    if max_shift < 1.0:
        raise ValueError('auto_chroma_fix: max_shift must be at least 1')
    reach = int(math.ceil(max_shift))
    if reach > _MAX_SHIFT:
        raise ValueError(
            'auto_chroma_fix: max_shift must be at most {}'.format(_MAX_SHIFT))

    lags = list(range(-(reach + _PAD), reach + _PAD + 1))
    # Two pixels beyond the widest lag, so no window ever reaches the columns
    # or rows the gradient could not be computed on.
    border = reach + _PAD + 2
    if clip.width <= 4 * border or clip.height <= 4 * border:
        raise ValueError(
            'auto_chroma_fix: clip is too small to search a {} pixel shift'
            .format(max_shift))

    search = _Search(clip, lags, border)

    if reference_frame >= 0:
        frame = min(int(reference_frame), clip.num_frames - 1)
        dx, dy = search.solve(search.read(frame), accuracy, max_shift)
        out = _shift_chroma(clip, dx, dy)
        return core.std.SetFrameProps(out, _AutoChromaShiftH=float(dx),
                                      _AutoChromaShiftV=float(dy))

    cache = {}

    def evaluate(n, f):
        dx, dy = search.solve([x.props['PlaneStatsAverage'] for x in f],
                              accuracy, max_shift)
        node = cache.get((dx, dy))
        if node is None:
            node = core.std.SetFrameProps(_shift_chroma(clip, dx, dy),
                                          _AutoChromaShiftH=float(dx),
                                          _AutoChromaShiftV=float(dy))
            cache[(dx, dy)] = node
        return node

    return core.std.FrameEval(clip, evaluate, prop_src=search.prop_src())
