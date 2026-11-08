"""
Colourisation for VapourSynth, on ONNX Runtime from the ai-runtime add-on.

    import colorize
    clip = colorize.colorize(clip, model_path=..., model="ddcolor", render_size=512,
                             strength=1.0, temporal_radius=2, matrix="709",
                             color_range="limited")

Two models predict colour from a grey picture:

- **DDColor** (piddnad/DDColor, the DDColor-T checkpoint) predicts CIELAB's a
  and b. As upstream's ColorizationPipeline does, they are scaled up to the
  frame and recombined with the frame's own lightness, then converted to RGB
  (sRGB, D65, OpenCV's constants), here with a chain of std.Expr stages at
  the luma's resolution.
- **DeOldify Video** (jantic/DeOldify, ColorizeVideo_gen) predicts an RGB
  picture. As upstream's ColorizerFilter does, it is scaled up to the frame
  and only its chroma is kept.

Both see the luma stretched to a square of `render_size` (upstream's
`input_size` / `render_factor x 16`), as one channel in [0, 1].

**The source's luma is kept bit-exact.** The predicted picture is converted
to YUV with the source's matrix, its chroma scaled by `strength` (0 is
neutral grey), converted to the source's format (bit depth and subsampling,
dithered), and only its chroma planes are taken: the Y plane of the output
is the input's, untouched. A source that already has colour is coloured
from its luma all the same: its own chroma is replaced.

**Temporal smoothing** (`temporal_radius` r > 0): a per-frame colouriser
guesses colour afresh for every frame, and its guesses flicker (DDColor's
especially). Each frame's prediction is averaged, at the render size, with
the predictions of the r frames either side, weighted by distance and down
to nothing where the grey picture itself differs there (MOTION_LIMIT, over
MOTION_BLOCK-pixel blocks) — so colour follows a moving object rather than
smearing behind it, and a cut takes nothing from the shot before it. The
pass is a pure function of frames n-r..n+r, as VapourSynth requires
(neighbours via ai_runtime.shifted, predictions shared through a FrameMemo),
so a preview is the encode's frame.

Model runs are serialised with a CPU retry (ai_runtime.Runner); each session
has the render size fixed (ai_runtime's `dims`), so Core ML gets static
shapes from one exported file.
"""

import numpy as np

import ai_runtime

MODELS = ("ddcolor", "deoldify")

# Models a preview (preview=True) runs on the CPU. Core ML compiles DDColor's
# transformer for 50-80 s when a session is created, which happens in every
# vspipe process, and a preview is a process of its own that colours only
# 2r+1 frames (0.8 s each on the CPU at 512). DeOldify compiles in about 5 s
# and is 6x slower on the CPU, so it keeps the preferred provider. The two
# providers' outputs differ by under 0.001 of a CIELAB unit. Measured in
# docs/reports/2026-11-colourisation.
PREVIEW_ON_CPU = {"ddcolor": True, "deoldify": False}

# Temporal smoothing: neighbours are compared on the render-size luma,
# averaged over MOTION_BLOCK x MOTION_BLOCK blocks; where a neighbour's block
# differs from this frame's by MOTION_LIMIT (8-bit levels: 10) it contributes
# nothing. Measured in docs/reports/2026-11-colourisation.
MOTION_BLOCK = 8
MOTION_LIMIT = 10.0 / 255.0

# OpenCV's float CIELAB <-> sRGB (D65) constants, as DDColor's pipeline uses
# them (cv2.COLOR_LAB2BGR on float32).
XN, ZN = 0.950456, 1.088754
XYZ_TO_RGB = (
    (3.240479, -1.53715, -0.498535),
    (-0.969256, 1.875991, 0.041556),
    (0.055648, -0.204043, 1.057311),
)
LAB_T = 0.008856  # cube-root threshold on Y
LAB_K = 7.787
LAB_F = 0.206893  # 6/29: the threshold on f

# The runner of the most recent colorize() call, for diagnostics.
last_runner = None


# See the identical helper in the two .vpy templates: VapourSynth's std.Expr
# JIT is x86-only, so on ARM every expression is walked once per pixel. akarin
# has a real LLVM JIT that works on aarch64 (and is in every bundle but macOS
# x64). The fallback names core.std.Expr explicitly -- calling _expr() would
# recurse forever. The expressions here use only the subset both share.
def _expr(clips, expr, **kwargs):
    import vapoursynth as vs
    core = vs.core
    _akarin_expr = getattr(getattr(core, "akarin", None), "Expr", None)
    if _akarin_expr is not None:
        return _akarin_expr(clips, expr, **kwargs)
    return core.std.Expr(clips, expr, **kwargs)


def lab_stages(core, y, a, b):
    """CIELAB with the lightness of `y` (GRAYS: the frame's luma, as a grey
    sRGB value in [0, 1]) and the colour of `a`, `b` (GRAYS, the same size),
    as an RGBS clip: OpenCV's Lab -> sRGB, out-of-gamut values clipped. In
    stages, so no expression repeats another's work.

    A grey pixel's L is the lightness of its own value, so the chain starts
    from the linear luminance: cv2 would take L back to the same Y."""
    expr = _expr
    ylin = expr([y], "x 0.04045 <= x 12.92 / x 0.055 + 1.055 / 2.4 pow ?")
    fy = expr([ylin], f"x {LAB_T} > x 0.0 max 0.3333333333 pow x {LAB_K} * 0.1379310345 + ?")

    def finv(f):
        return f"{f} {LAB_F} > {f} 3 pow {f} 0.1379310345 - {LAB_K} / ?"

    x = expr([fy, a], finv("x y 500 / +") + f" {XN} *")
    z = expr([fy, b], finv("x y 200 / -") + f" {ZN} *")

    def channel(row):
        c0, c1, c2 = row
        lin = f"x {c0} * y {c1} * + z {c2} * + 0 max 1 min"
        # sRGB encoding (OpenCV's gamma for float Lab conversions).
        return expr([x, ylin, z], f"{lin} 0.0031308 <= {lin} 12.92 * {lin} 0.4166666667 pow 1.055 * 0.055 - ?")

    r, g, bl = (channel(row) for row in XYZ_TO_RGB)
    import vapoursynth as vs

    return core.std.ShufflePlanes([r, g, bl], [0, 0, 0], vs.RGB)


def motion_crop(luma):
    """The render-size luma averaged over MOTION_BLOCK blocks (edges padded)."""
    b = MOTION_BLOCK
    h, w = luma.shape
    ph, pw = -(-h // b) * b, -(-w // b) * b
    if (ph, pw) != (h, w):
        luma = np.pad(luma, ((0, ph - h), (0, pw - w)), mode="edge")
    return luma.reshape(ph // b, b, pw // b, b).mean((1, 3)).astype(np.float32)


def motion_weight(a, b, shape, limit=MOTION_LIMIT):
    """Per-pixel weight (`shape`) for blending a neighbour whose motion crop
    is `b` into a frame whose motion crop is `a`: 1 where they agree, falling
    to 0 at `limit` (3x3-block mean of the difference, so one noisy block
    is not motion)."""
    d = np.abs(a - b)
    p = np.pad(d, 1, mode="edge")
    d = sum(p[i:i + d.shape[0], j:j + d.shape[1]] for i in range(3) for j in range(3)) / 9.0
    w = np.clip(1.0 - d / limit, 0.0, 1.0)
    w = np.repeat(np.repeat(w, MOTION_BLOCK, 0), MOTION_BLOCK, 1)
    return w[: shape[0], : shape[1]]


def colorize(
    clip,
    model_path,
    model="ddcolor",
    render_size=512,
    strength=1.0,
    temporal_radius=2,
    matrix="709",
    color_range="limited",
    preview=False,
    motion_limit=MOTION_LIMIT,
):
    """Colour `clip` (YUV, any depth and subsampling) and return it in its own
    format, its Y plane bit-exact.

    `model` is "ddcolor" (`model_path`: colorize-ddcolor-tiny.onnx, render
    size a multiple of 32) or "deoldify" (colorize-deoldify-video.onnx, a
    multiple of 16). `strength` scales the predicted chroma (0 grey, 1 as
    predicted, above 1 more saturated). `temporal_radius` is how many frames
    either side each frame's colour is averaged with (0: none). `matrix` /
    `color_range` are the source's (zimg names). `preview`: the preview
    script's call, which runs the models in PREVIEW_ON_CPU on the CPU.
    `motion_limit`: the neighbour-blend cut-off (the report compares it).
    """
    global last_runner
    limit = float(motion_limit)
    import sys

    import vapoursynth as vs

    core = vs.core
    fmt = clip.format
    if fmt is None or fmt.color_family != vs.YUV:
        raise ValueError("colorize needs a constant-format YUV clip")
    if model not in MODELS:
        raise ValueError("colorize: unknown model %r" % model)
    step = 32 if model == "ddcolor" else 16
    size = max(step, int(render_size) // step * step)
    r = max(0, int(temporal_radius))
    strength = max(0.0, float(strength))

    force_cpu = bool(preview) and PREVIEW_ON_CPU[model]
    if not force_cpu:
        sys.stderr.write("Colourisation: preparing %s (the first frame can take a minute or two while the "
                         "model is compiled for this machine)\n" % model)
    runner = ai_runtime.Runner(model_path, force_cpu=force_cpu, dims={"height": size, "width": size})
    last_runner = runner
    in_name = runner.get_inputs()[0].name
    sys.stderr.write("Colourisation: %s at %dx%d on %s%s\n" % (
        model, size, size, runner.provider, "" if not runner.fallback else " (%s)" % runner.fallback))

    # The luma as a grey picture in [0, 1], and the model's square copy of it.
    luma = core.std.ShufflePlanes(clip, 0, vs.GRAY)
    yf = core.resize.Point(luma, format=vs.GRAYS, range_in_s=color_range)
    small = core.resize.Bilinear(yf, width=size, height=size)
    last = clip.num_frames - 1

    def clamp(i):
        return min(max(i, 0), last)

    offsets = list(range(-r, r + 1))
    inputs = [ai_runtime.shifted(small, k) for k in offsets]
    predictions = ai_runtime.FrameMemo(capacity=4 * r + 8)
    results = ai_runtime.FrameMemo(capacity=8)

    def predict(index, frame):
        def run():
            g = np.asarray(frame[0]).astype(np.float32)
            out = runner.run(None, {in_name: np.clip(g, 0.0, 1.0)[None, None]})[0][0]
            return out.astype(np.float32), motion_crop(g)

        return predictions.get(index, run)

    def smoothed(n, frames):
        def run():
            pred, crop = predict(n, frames[r])
            if not r:
                return pred
            total = pred * float(r + 1)
            weight = np.full(pred.shape[1:], float(r + 1), np.float32)
            for i, k in enumerate(offsets):
                index = clamp(n + k)
                if k == 0 or index == n:
                    continue
                p, c = predict(index, frames[i])
                w = (r + 1 - abs(k)) * motion_weight(crop, c, pred.shape[1:], limit)
                total += w * p
                weight += w
            return total / weight

        return results.get(n, run)

    def write(n, f):
        out = f[0].copy()
        pred = smoothed(n, f[1:])
        for p in range(3):
            np.asarray(out[p])[:] = pred[p] if p < len(pred) else 0.0
        return out

    carrier = core.std.BlankClip(small, format=vs.RGBS, keep=True)
    pred = core.std.ModifyFrame(carrier, [carrier] + inputs, write)

    if model == "ddcolor":
        # a and b, scaled to the frame (bilinear: upstream's nearest-neighbour
        # interpolate leaves render-size blocks of colour at 1080p).
        a = core.resize.Bilinear(core.std.ShufflePlanes(pred, 0, vs.GRAY), width=clip.width, height=clip.height)
        b = core.resize.Bilinear(core.std.ShufflePlanes(pred, 1, vs.GRAY), width=clip.width, height=clip.height)
        rgb = lab_stages(core, yf, a, b)
    else:
        rgb = core.resize.Bilinear(pred, width=clip.width, height=clip.height)

    yuv = core.resize.Bilinear(rgb, format=vs.YUV444PS, matrix_in_s="rgb", matrix_s=matrix)
    s = "%.6f" % strength
    yuv = _expr(yuv, ["", "x %s *" % s, "x %s *" % s])
    yuv = core.std.ShufflePlanes([yf, yuv, yuv], [0, 1, 2], vs.YUV)
    out = core.resize.Bicubic(yuv, format=fmt.id, matrix_in_s=matrix, matrix_s=matrix, range_s=color_range,
                              dither_type="error_diffusion")
    out = core.std.ShufflePlanes([clip, out, out], [0, 1, 2], vs.YUV)
    return core.std.CopyFrameProps(out, clip)
