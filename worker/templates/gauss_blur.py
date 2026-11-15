"""TCanny's Gaussian blur (`tcanny.TCanny(mode=-1)`), without TCanny.

TCanny r14 (every bundle) allocates its per-thread buffers on a thread's
first frame by inserting into an `std::unordered_map` that every thread
shares, with no lock. Two threads starting together corrupt the map, and
the lookup that follows throws `std::out_of_range`, which TCanny does not
catch: vspipe aborts ("unordered_map::at: key not found", a native crash
with no Python error). It hit the nightly's MCDegrainSharp encode on macOS
x64 (2026-11-15) and can hit any job that blurs through it.

`gaussian_blur` computes the same blur with `std.Convolution`, which keeps
no per-thread state:

- the same weights: exp(-k^2 / 2 sigma^2), normalised, over
  radius = max(int(sigma * 3 + 0.5), 1);
- the same per-plane sigma when one is given: chroma's is divided by the
  subsampling in each direction;
- the same edges: mirrored without repeating the edge sample. Convolution
  itself mirrors *with* the edge sample (x = -1 reads x = 0), so each plane
  is padded TCanny's way first and the padding cropped off after;
- separable, vertical then horizontal, at 32-bit float, rounded once at
  the end, as TCanny does. Integer samples go to float and back through
  an `Expr` of `x` (`hybrid_mv._expr`: akarin where it is bundled), which
  copies the values raw (no range scaling), so a plane left out of
  `planes` comes back bit for bit.

`std.Convolution` takes at most 25 taps a direction (radius 12, sigma
just under 4.17). A wider blur runs as several equal narrower ones: Gaussian
variances add, so k passes of sigma / sqrt(k) are one of sigma, up to the
truncation of each kernel's tails.
"""

import math

import vapoursynth as vs

from hybrid_mv import _expr

core = vs.core

_MAX_RADIUS = 12


def _radius(sigma):
    return max(int(sigma * 3.0 + 0.5), 1)


def _weights(sigma):
    r = _radius(sigma)
    w = [math.exp(-(k * k) / (2.0 * sigma * sigma)) for k in range(-r, r + 1)]
    s = sum(w)
    return [x / s for x in w]


def _pad_v(plane, r):
    """Rows -r..-1 and h..h+r-1 as TCanny reads them: row -i is row i."""
    h = plane.height
    top = core.std.FlipVertical(core.std.Crop(plane, top=1, bottom=h - 1 - r))
    bottom = core.std.FlipVertical(core.std.Crop(plane, top=h - 1 - r, bottom=1))
    return core.std.StackVertical([top, plane, bottom])


def _pad_h(plane, r):
    w = plane.width
    left = core.std.FlipHorizontal(core.std.Crop(plane, left=1, right=w - 1 - r))
    right = core.std.FlipHorizontal(core.std.Crop(plane, left=w - 1 - r, right=1))
    return core.std.StackHorizontal([left, plane, right])


def _blur_plane(plane, sigma_h, sigma_v):
    if sigma_v > 0:
        r = _radius(sigma_v)
        if plane.height < r + 1:
            raise vs.Error(f'gaussian_blur: a plane {plane.height} high is too short for sigma {sigma_v}')
        plane = core.std.Convolution(_pad_v(plane, r), matrix=_weights(sigma_v), mode='v')
        plane = core.std.Crop(plane, top=r, bottom=r)
    if sigma_h > 0:
        r = _radius(sigma_h)
        if plane.width < r + 1:
            raise vs.Error(f'gaussian_blur: a plane {plane.width} wide is too narrow for sigma {sigma_h}')
        plane = core.std.Convolution(_pad_h(plane, r), matrix=_weights(sigma_h), mode='h')
        plane = core.std.Crop(plane, left=r, right=r)
    return plane


def _blur_float(clip, sigmas_h, sigmas_v, planes):
    """One separable pass on a float clip, per plane (Convolution takes one
    matrix for every plane it processes, and chroma has its own sigma)."""
    if clip.format.num_planes == 1:
        return _blur_plane(clip, sigmas_h[0], sigmas_v[0]) if 0 in planes else clip
    out_planes = []
    for p in range(clip.format.num_planes):
        plane = core.std.ShufflePlanes(clip, p, vs.GRAY)
        if p in planes:
            plane = _blur_plane(plane, sigmas_h[p], sigmas_v[p])
        out_planes.append(plane)
    return core.std.ShufflePlanes(out_planes, [0, 0, 0], clip.format.color_family)


def gaussian_blur(clip, sigma, planes=None):
    """`core.tcanny.TCanny(clip, sigma=sigma, mode=-1, planes=planes)`."""
    fmt = clip.format
    n = fmt.num_planes
    if planes is None:
        planes = list(range(n))
    elif isinstance(planes, int):
        planes = [planes]
    planes = [p for p in planes if 0 <= p < n]

    sigmas_h = [float(sigma)] + [sigma / (1 << fmt.subsampling_w)] * (n - 1)
    sigmas_v = [float(sigma)] + [sigma / (1 << fmt.subsampling_h)] * (n - 1)

    passes = 1
    while max(_radius(s / math.sqrt(passes)) for s in sigmas_h + sigmas_v) > _MAX_RADIUS:
        passes += 1
    sigmas_h = [s / math.sqrt(passes) for s in sigmas_h]
    sigmas_v = [s / math.sqrt(passes) for s in sigmas_v]

    is_int = fmt.sample_type == vs.INTEGER
    work = clip
    if is_int:
        work = _expr(clip, 'x', format=fmt.replace(sample_type=vs.FLOAT, bits_per_sample=32))
    for _ in range(passes):
        work = _blur_float(work, sigmas_h, sigmas_v, planes)
    if is_int:
        # Expr rounds to nearest and clamps to the format's range, as
        # TCanny's discretizeGM does.
        work = _expr(work, 'x', format=fmt)
    # A float clip is left unclamped, as TCanny leaves mode -1's.
    return core.std.CopyFrameProps(work, clip)
