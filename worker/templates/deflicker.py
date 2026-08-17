"""
Deflicker - two complementary temporal brightness stabilisers.

`global_deflicker()` removes *global* brightness/contrast pumping: the whole
frame breathing lighter and darker, as produced by auto-exposure hunting, mains
beat on film transfers, and shutter/frame-rate mismatch. It measures each
frame's luma mean and standard deviation, compares them against the mean of a
temporal neighbourhood, and applies the affine correction (gain + offset) that
lands the frame back on the neighbourhood average. Gain alone leaves a
measurable residual on real footage, so both terms are fitted.

`reduce_flicker()` removes *local* frame-to-frame oscillation: a pixel that
alternates between two values while its +-2 (and optionally +-3) neighbours
agree. It is a per-pixel clamp of the temporal average, gated by how much the
current frame really differs from its more distant neighbours, so genuine
motion and detail are left alone.

Written for VapourBox.

`reduce_flicker()` reimplements the semantics of the well-known ReduceFlicker
filter (Rainer Wittmann's Avisynth original) as a VapourSynth expression over
temporally shifted clips. The ReduceFlicker *plugin* is deliberately not used:
its scalar C paths (`proc_c` / `proc_a_c` in `vapoursynth/src/proc_filter.h`)
read `prevp[0]` / `prevp[2]` where the SIMD path correctly reads `nextp[0]` /
`nextp[2]`, and the SIMD block is guarded by `#if defined(__SSE2__)` -- so
aarch64 has only the buggy path and the ARM bundles would render differently
from the x86 ones. An expression has one implementation everywhere.

`global_deflicker()` is not derived from any existing filter.
"""

import math

import vapoursynth as vs

core = vs.core


# VapourSynth's own std.Expr JIT is wrapped in #ifdef VS_TARGET_CPU_X86, so on
# ARM every expression is walked once per pixel by a scalar interpreter --
# measured ~48x slower than the JIT on this module's expressions. akarin has a
# real LLVM JIT that works on aarch64. Falls back to std.Expr wherever akarin is
# absent (notably macos-x64, whose only wheel would raise the Intel floor to
# macOS 14). Mirrors the `_expr()` helper in the two .vpy templates -- the
# fallback names core.std.Expr explicitly, because calling _expr() here would
# recurse forever.
_akarin_expr = getattr(getattr(core, 'akarin', None), 'Expr', None)
_akarin_propexpr = getattr(getattr(core, 'akarin', None), 'PropExpr', None)


def _expr(clips, expr, **kwargs):
    if _akarin_expr is not None:
        return _akarin_expr(clips, expr, **kwargs)
    return core.std.Expr(clips, expr, **kwargs)


# std.Expr / akarin.Expr name their inputs x, y, z, then a..w -- 26 in total.
_LETTERS = ['x', 'y', 'z'] + [chr(ord('a') + i) for i in range(23)]

# 2*window+1 shifted stat clips have to fit in one PropExpr call, and a 25-frame
# neighbourhood is already far longer than any flicker worth correcting.
_MAX_WINDOW = 12

# Gain is a ratio of two measured standard deviations, so a near-flat frame
# (a fade to black, a title card) can drive it arbitrarily high. Clamp it: a
# global brightness fault that needs more than +-25% is not flicker.
_GAIN_MIN = 0.8
_GAIN_MAX = 1.25
_TINY = 1.0 / 4096.0


def _peak(clip):
    """Value of full white in the clip's own sample range."""
    if clip.format.sample_type == vs.FLOAT:
        return 1.0
    return float((1 << clip.format.bits_per_sample) - 1)


def _plane_exprs(clip, luma_expr):
    """Apply `luma_expr` to plane 0 only; '' copies the plane through."""
    return [luma_expr] + [''] * (clip.format.num_planes - 1)


def _temporal_shift(clip, offset):
    """
    Return `clip` shifted in time, with the edges clamped.

    offset < 0 gives past frames (output frame i is input frame i+offset),
    offset > 0 gives future frames. Frame properties are carried along, which
    is what makes the statistics clips usable as neighbours.
    """
    if offset == 0:
        return clip
    n = abs(offset)
    if offset < 0:
        return core.std.Trim(core.std.DuplicateFrames(clip, [0] * n),
                             length=clip.num_frames)
    last = clip.num_frames - 1
    return core.std.Trim(core.std.DuplicateFrames(clip, [last] * n), first=n)


def _check_clip(clip, name):
    if not isinstance(clip, vs.VideoNode):
        raise TypeError('{}: clip must be a VideoNode'.format(name))
    if clip.format is None:
        raise ValueError('{}: variable-format clips are not supported'.format(name))
    if clip.format.color_family not in (vs.YUV, vs.GRAY):
        raise ValueError(
            '{}: only YUV and GRAY clips are supported, got {}'.format(
                name, clip.format.name))


# ============================================================================
# Global (whole-frame) deflicker
# ============================================================================

def global_deflicker(clip, strength=1.0, window=5):
    """
    Remove global brightness and contrast flicker.

    For every frame the luma mean `m` and standard deviation `s` are measured,
    together with the averages `M` and `S` of the same two statistics over the
    +-`window` frame neighbourhood. The frame is then remapped by the affine
    transform that takes (m, s) to the blended targets, i.e.

        out = (x - m) * g + Mt,   g = St / s

    with `Mt = m + strength*(M - m)` and `St = s + strength*(S - s)`.

    Fitting the offset as well as the gain matters: on a clip carrying a pure
    additive brightness oscillation the gain-only fit leaves a residual
    proportional to how dark the frame is, because a multiply cannot move
    black. Fitting both removes it.

    Only the luma plane is touched. Chroma is passed through unchanged --
    exposure flicker is a luma phenomenon, and scaling chroma with it would
    shift saturation.

    Args:
        clip:     Input clip (YUV or GRAY, integer or float).
        strength: 0.0 = no correction, 1.0 = land exactly on the neighbourhood
                  average (default 1.0). Values are clamped to [0, 1].
        window:   Half-width of the temporal neighbourhood in frames
                  (default 5, i.e. an 11 frame window). Maximum 12.

    Returns:
        Clip with global brightness/contrast flicker suppressed.
    """
    _check_clip(clip, 'global_deflicker')

    strength = min(1.0, max(0.0, float(strength)))
    window = int(window)
    if window < 1:
        raise ValueError('global_deflicker: window must be >= 1')
    if window > _MAX_WINDOW:
        raise ValueError(
            'global_deflicker: window must be <= {}'.format(_MAX_WINDOW))
    if strength == 0.0 or clip.num_frames < 2:
        return clip

    peak = _peak(clip)

    # Per-frame luma statistics. PlaneStatsAverage is normalised to [0, 1]
    # whatever the bit depth, so everything below is depth independent; only
    # the final bias is scaled back into the clip's own sample range.
    luma = clip
    if clip.format.color_family != vs.GRAY:
        luma = core.std.ShufflePlanes(clip, 0, vs.GRAY)
    mean_stats = core.std.PlaneStats(luma)

    # Second moment, needed because mean alone cannot separate gain from
    # offset. Computed at float so an 8-bit source does not quantise it.
    squared = _expr(luma, 'x {p} / x {p} / *'.format(p=peak), format=vs.GRAYS)
    sq_stats = core.std.PlaneStats(squared)

    if _akarin_propexpr is not None:
        coeffs = _global_props_akarin(mean_stats, sq_stats, window, strength, peak)
        src = core.std.CopyFrameProps(clip, coeffs, props=['_DfGain', '_DfBias'])
        out = _expr(src, _plane_exprs(clip, 'x x._DfGain * x._DfBias +'))
        return core.std.RemoveFrameProps(out, props=['_DfGain', '_DfBias'])

    return _global_frameeval(clip, mean_stats, sq_stats, window, strength, peak)


def _gain_rpn(strength):
    """St / s, clamped -- as postfix over a clip carrying _DfM/_DfS/_DfRM/_DfRS."""
    return ('x._DfS x._DfRS x._DfS - {s:.8f} * + '
            'x._DfS {tiny:.8f} max / {lo:.6f} max {hi:.6f} min'.format(
                s=strength, tiny=_TINY, lo=_GAIN_MIN, hi=_GAIN_MAX))


def _global_props_akarin(mean_stats, sq_stats, window, strength, peak):
    """
    Compute the per-frame gain/bias entirely inside the filter graph.

    No Python callback runs per frame on this path: the neighbourhood averages
    are an akarin.PropExpr over temporally shifted copies of the statistics
    clip, and the gain/bias fall out of a second PropExpr.
    """
    # One clip carrying both statistics, so the shifted neighbours cost one
    # input each rather than two.
    merged = _akarin_propexpr(
        [mean_stats, sq_stats],
        lambda: {'_DfSq': 'y.PlaneStatsAverage'})

    count = 2 * window + 1
    shifted = [_temporal_shift(merged, o) for o in range(-window, window + 1)]
    centre = _LETTERS[window]

    def mean_of(term):
        parts = [term(0)]
        for i in range(1, count):
            parts += [term(i), '+']
        parts += ['{:.1f}'.format(float(count)), '/']
        return ' '.join(parts)

    def sd_term(i):
        v = _LETTERS[i]
        return ('{v}._DfSq {v}.PlaneStatsAverage {v}.PlaneStatsAverage * - '
                '0 max sqrt'.format(v=v))

    stats = _akarin_propexpr(shifted, lambda: {
        '_DfM': '{}.PlaneStatsAverage'.format(centre),
        '_DfS': sd_term(window),
        '_DfRM': mean_of(lambda i: '{}.PlaneStatsAverage'.format(_LETTERS[i])),
        '_DfRS': mean_of(sd_term),
    })

    gain = _gain_rpn(strength)
    # bias = peak * (Mt - m * gain), with Mt = m + strength*(M - m).
    bias = ('x._DfM x._DfRM x._DfM - {s:.8f} * + '
            'x._DfM {g} * - {p:.8f} *'.format(s=strength, g=gain, p=peak))

    return _akarin_propexpr(stats, lambda: {'_DfGain': gain, '_DfBias': bias})


def _global_frameeval(clip, mean_stats, sq_stats, window, strength, peak):
    """
    akarin-less fallback: the same arithmetic in Python, once per frame.

    std.Expr cannot read frame properties, so the coefficients have to be baked
    into the expression -- which means a node per distinct correction. They are
    quantised and memoised so a clip with slowly varying brightness reuses a
    handful of nodes rather than building one per frame.
    """
    shifted = ([_temporal_shift(mean_stats, o) for o in range(-window, window + 1)] +
               [_temporal_shift(sq_stats, o) for o in range(-window, window + 1)])
    count = 2 * window + 1
    cache = {}
    def exprs_for(gain, bias):
        return _plane_exprs(clip, 'x {:.8f} * {:.6f} +'.format(gain, bias))

    def evaluate(n, f):
        means = [frame.props['PlaneStatsAverage'] for frame in f[:count]]
        sqs = [frame.props['PlaneStatsAverage'] for frame in f[count:]]
        sds = [math.sqrt(max(q - m * m, 0.0)) for m, q in zip(means, sqs)]

        m = means[window]
        s = sds[window]
        ref_m = sum(means) / count
        ref_s = sum(sds) / count

        target_s = s + strength * (ref_s - s)
        gain = min(_GAIN_MAX, max(_GAIN_MIN, target_s / max(s, _TINY)))
        target_m = m + strength * (ref_m - m)
        bias = peak * (target_m - m * gain)

        key = (int(round(gain * 20000.0)), int(round(bias * 2000.0 / peak)))
        node = cache.get(key)
        if node is None:
            node = _expr(clip, exprs_for(gain, bias))
            if len(cache) < 4096:
                cache[key] = node
        return node

    return core.std.FrameEval(clip, evaluate, prop_src=shifted)


# ============================================================================
# Local (per-pixel) flicker reduction
# ============================================================================

def reduce_flicker(clip, strength=2, aggressive=False):
    """
    Damp per-pixel temporal oscillation while protecting motion and detail.

    For each pixel the temporal average of the immediate neighbourhood,
    (prev1 + next1 + 2*cur) / 4, is clamped into a band around the current
    value whose width is set by how far the current frame differs from its
    more distant neighbours:

        d  = min(|cur-prev2|, |cur-next2|[, |cur-prev3|, |cur-next3|, ...])
        ul = max(min(prev1, next1) - d, cur)
        ll = min(max(prev1, next1) + d, cur)
        out = clamp((prev1 + next1 + 2*cur) / 4, ll, ul)

    `d` is a detail guard, and it runs the opposite way to intuition: where the
    current frame genuinely differs from frames +-2 and beyond (real motion) `d`
    is large, the band collapses onto `cur`, and nothing is changed. Where it
    agrees with them but differs from its immediate neighbours -- which is
    exactly what flicker looks like -- `d` is near zero and the pixel is pulled
    back towards them. `strength` therefore widens the *minimum*: each extra
    frame pair can only lower `d`, so a higher strength filters more.

    With `aggressive=True` the symmetric `d` is replaced by the signed pair

        dl = max(0, min(cur-prev2, cur-next2, ...))
        dh = max(0, min(prev2-cur, next2-cur, ...))
        ul = max(min(prev1, next1) - dh, cur)
        ll = min(max(prev1, next1) + dl, cur)

    At most one of `dl`/`dh` is ever non-zero, so each bound is guarded only
    against an excursion in its own direction and the other side is free to
    move -- a stronger correction that is more willing to touch real detail.

    All planes are processed, and the operation is a pure ratio of samples, so
    it is bit-depth and subsampling independent: nothing here is expressed in
    8-bit units.

    Args:
        clip:       Input clip (YUV or GRAY, integer or float).
        strength:   1, 2 or 3 (default 2). Frames +-1 always set the target;
                    strength adds the guard pairs +-2 (1), +-2/+-3 (2), and
                    +-2/+-3/+-4 (3), so higher values filter more.
        aggressive: Use the signed guard described above (default False).

    Returns:
        Clip with local temporal flicker reduced.
    """
    _check_clip(clip, 'reduce_flicker')

    strength = int(strength)
    if strength not in (1, 2, 3):
        raise ValueError('reduce_flicker: strength must be 1, 2 or 3')
    if clip.num_frames < 2:
        return clip

    # x=cur, y=prev1, z=next1, then the guard pairs a/b, c/d, e/f.
    offsets = [0, -1, 1]
    for k in range(2, strength + 2):
        offsets += [-k, k]
    clips = [_temporal_shift(clip, o) for o in offsets]
    names = _LETTERS[:len(offsets)]

    average = 'y z + x + x + 4 /'
    distant = names[3:]  # +-2 [, +-3 [, +-4]]
    if aggressive:
        low = _fold_min(['x {} -'.format(p) for p in distant])
        high = _fold_min(['{} x -'.format(p) for p in distant])
        upper = 'y z min {} 0 max - x max'.format(high)
        lower = 'y z max {} 0 max + x min'.format(low)
    else:
        guard = _fold_min(['x {} - abs'.format(p) for p in distant])
        upper = 'y z min {} - x max'.format(guard)
        lower = 'y z max {} + x min'.format(guard)

    expression = '{avg} {ll} max {ul} min'.format(avg=average, ll=lower, ul=upper)
    return _expr(clips, expression)


def _fold_min(terms):
    """Postfix `min` over a list of postfix sub-expressions."""
    out = terms[0]
    for term in terms[1:]:
        out = '{} {} min'.format(out, term)
    return out
