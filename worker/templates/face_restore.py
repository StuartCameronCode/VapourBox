"""
Face restoration for VapourSynth, on ONNX Runtime from the ai-runtime add-on.

    import face_restore
    clip = face_restore.restore_faces(clip, detector=..., parser=..., restorer=...,
                                      model="restoreformer", ...)

For every frame: RetinaFace finds the faces and their five landmarks (eyes,
nose, mouth corners); each face is aligned to the FFHQ 512x512 template by a
similarity transform, restored by RestoreFormer++, GFPGAN or CodeFormer, and
parsed by BiSeNet into a mask of the face itself (skin, brows, eyes, glasses,
ears, nose, mouth and lips; not hair, neck or clothes), which is feathered,
warped back and used to blend the restored face into the frame at the clip's
own resolution.

The pass is a pure function of its input frames, as VapourSynth requires
(frames are requested in parallel and out of order):

- **Temporal smoothing** reads the detections of the `temporal_radius` frames
  either side (std.ModifyFrame over clips shifted by -r..r, never get_frame()
  from inside a request). Each face's landmarks are averaged with the faces it
  matches in its neighbours (triangular weights), a face detected just under
  the threshold is kept when a neighbour has it above the threshold
  (hysteresis), and a face missing from one frame between two that have it is
  filled in. Per-frame detections jitter by a pixel or two, and a restorer
  turns that jitter into flicker; smoothing removes most of it.
- **Bit-exact outside the faces.** The restored faces are composited with
  std.MaskedMerge in the source's own format, so every pixel the face mask
  does not reach (and every frame with no face) is the input, unchanged.

Detection runs once per frame (shared through a FrameMemo), on a copy scaled
to fit 640x640 and padded, so every model has a static input shape — which is
what lets Core ML take the whole graph.

Pure NumPy: OpenCV is not in the deps bundle or the ai-runtime add-on, and
nothing here needs it.
"""

import threading

import numpy as np

import ai_runtime

# FFHQ's five-point template at 512x512 (facexlib's FaceRestoreHelper, the
# alignment every one of these restorers was trained on).
FFHQ_TEMPLATE = np.array(
    [
        [192.98138, 239.94708],
        [318.90277, 240.1936],
        [256.63416, 314.01935],
        [201.26117, 371.41043],
        [313.08905, 371.15118],
    ],
    np.float64,
)
FACE_SIZE = 512
# What facexlib fills outside the frame when it crops a face near an edge.
BORDER_RGB = np.array([132.0, 133.0, 135.0], np.float32) / 255.0

# RetinaFace (biubug6/Pytorch_Retinaface's configuration for both backbones).
DET_SIZE = 640
DET_MEAN_BGR = np.array([104.0, 117.0, 123.0], np.float32)
DET_MIN_SIZES = [[16, 32], [64, 128], [256, 512]]
DET_STEPS = [8, 16, 32]
DET_VARIANCE = (0.1, 0.2)
DET_NMS = 0.4

# BiSeNet (CelebAMask-HQ labels): 1 skin, 2-3 brows, 4-5 eyes, 6 glasses,
# 7-9 ears and earrings, 10 nose, 11 mouth, 12-13 lips. Not 14 neck,
# 15 necklace, 16 cloth, 17 hair, 18 hat.
FACE_CLASSES = list(range(1, 14))
PARSE_MEAN = np.array([0.485, 0.456, 0.406], np.float32)[:, None, None]
PARSE_STD = np.array([0.229, 0.224, 0.225], np.float32)[:, None, None]
# facexlib feathers its parse mask with two 101-tap Gaussian blurs of sigma 11
# and clears a 10-pixel border; one blur of sigma 11 * sqrt(2) is the same.
MASK_SIGMA = 11.0 * np.sqrt(2.0)
MASK_BORDER = 10
# Mask values below this count as zero (so the blend's reach is finite).
MASK_FLOOR = 1.0 / 1024.0

MODELS = ("restoreformer", "gfpgan", "codeformer")


# ----------------------------------------------------------------------------
# Detection
# ----------------------------------------------------------------------------

_priors = None


def priors():
    """RetinaFace's anchors for a DET_SIZE square input, (N, 4) as
    (cx, cy, w, h) in [0, 1], in the network's output order."""
    global _priors
    if _priors is None:
        rows = []
        for k, step in enumerate(DET_STEPS):
            f = -(-DET_SIZE // step)
            cy, cx = np.meshgrid((np.arange(f) + 0.5) * step / DET_SIZE, (np.arange(f) + 0.5) * step / DET_SIZE,
                                 indexing="ij")
            for size in DET_MIN_SIZES[k]:
                s = np.full_like(cx, size / DET_SIZE)
                rows.append(np.stack([cx, cy, s, s], -1))
            # Interleave the two sizes per cell, as PriorBox does.
            a, b = rows[-2], rows[-1]
            rows[-2:] = [np.stack([a, b], 2).reshape(-1, 4)]
        _priors = np.concatenate(rows).astype(np.float32)
    return _priors


def nms(boxes, scores, threshold):
    """Greedy non-maximum suppression (Pytorch_Retinaface's py_cpu_nms)."""
    x1, y1, x2, y2 = boxes.T
    areas = (x2 - x1 + 1) * (y2 - y1 + 1)
    order = scores.argsort()[::-1]
    keep = []
    while order.size:
        i = order[0]
        keep.append(i)
        xx1 = np.maximum(x1[i], x1[order[1:]])
        yy1 = np.maximum(y1[i], y1[order[1:]])
        xx2 = np.minimum(x2[i], x2[order[1:]])
        yy2 = np.minimum(y2[i], y2[order[1:]])
        inter = np.maximum(0.0, xx2 - xx1 + 1) * np.maximum(0.0, yy2 - yy1 + 1)
        iou = inter / (areas[i] + areas[order[1:]] - inter)
        order = order[1:][iou <= threshold]
    return np.array(keep, np.int64)


def detect(session, rgb, scale, floor):
    """Faces in one frame. `rgb` is the detection copy, (3, h, w) float RGB in
    [0, 1] with h, w <= DET_SIZE; `scale` (x, y) maps its pixels to the
    clip's (clip = (det + 0.5) / scale - 0.5). Returns (scores (k,), boxes (k, 4)
    x1 y1 x2 y2, landmarks (k, 5, 2)) in clip pixels, every face scoring at
    least `floor`, best first."""
    _, h, w = rgb.shape
    x = np.zeros((1, 3, DET_SIZE, DET_SIZE), np.float32)
    # BGR, 0-255, minus the mean; the padding is the mean (zero after it).
    x[0, :, :h, :w] = rgb[::-1] * 255.0 - DET_MEAN_BGR[:, None, None]
    loc, conf, landm = session.run(None, {session.get_inputs()[0].name: x})
    loc, scores, landm = loc[0], conf[0][:, 1], landm[0]
    keep = scores >= floor
    if not keep.any():
        return np.zeros(0, np.float32), np.zeros((0, 4)), np.zeros((0, 5, 2))
    p, loc, scores, landm = priors()[keep], loc[keep], scores[keep], landm[keep]
    v0, v1 = DET_VARIANCE
    centre = p[:, :2] + loc[:, :2] * v0 * p[:, 2:]
    size = p[:, 2:] * np.exp(loc[:, 2:] * v1)
    boxes = np.concatenate([centre - size / 2, centre + size / 2], 1) * DET_SIZE
    marks = (p[:, None, :2] + landm.reshape(-1, 5, 2) * v0 * p[:, None, 2:]) * DET_SIZE
    k = nms(boxes, scores, DET_NMS)
    scale = np.asarray(scale, np.float64)
    boxes = (boxes[k] + 0.5) / np.tile(scale, 2) - 0.5
    marks = (marks[k] + 0.5) / scale - 0.5
    return scores[k], boxes.astype(np.float64), marks.astype(np.float64)


# ----------------------------------------------------------------------------
# Temporal smoothing: a pure function of the detections in frames n-r..n+r
# ----------------------------------------------------------------------------


def _match(box, boxes):
    """Index of the box in `boxes` overlapping `box` most (IoU > 0.3), or None."""
    if not len(boxes):
        return None
    x1 = np.maximum(box[0], boxes[:, 0])
    y1 = np.maximum(box[1], boxes[:, 1])
    x2 = np.minimum(box[2], boxes[:, 2])
    y2 = np.minimum(box[3], boxes[:, 3])
    inter = np.maximum(0, x2 - x1) * np.maximum(0, y2 - y1)
    area = (box[2] - box[0]) * (box[3] - box[1])
    areas = (boxes[:, 2] - boxes[:, 0]) * (boxes[:, 3] - boxes[:, 1])
    iou = inter / np.maximum(area + areas - inter, 1e-6)
    i = int(iou.argmax())
    return i if iou[i] > 0.3 else None


def select_faces(dets, radius, threshold, min_face, max_faces):
    """The faces to restore in the centre frame of `dets` (a list of 2r+1
    detections, frame n-r first), as (box, landmarks) with smoothed
    landmarks. `radius` 0 is per-frame detection, unsmoothed."""
    centre = dets[radius]
    low = threshold * 0.75
    faces = []

    def confirmed(box, score):
        """Above the threshold here, or near it here and above it in a neighbour."""
        if score >= threshold:
            return True
        if score < low:
            return False
        for d in (dets[radius - 1], dets[radius + 1]) if radius else ():
            j = _match(box, d[1])
            if j is not None and d[0][j] >= threshold:
                return True
        return False

    for i in range(len(centre[0])):
        if confirmed(centre[1][i], centre[0][i]):
            faces.append((centre[1][i], centre[2][i]))

    if radius:
        # A face in the frames either side but not this one: a dropout.
        prev, nxt = dets[radius - 1], dets[radius + 1]
        for i in range(len(prev[0])):
            if prev[0][i] < threshold:
                continue
            j = _match(prev[1][i], nxt[1])
            if j is None or nxt[0][j] < threshold:
                continue
            box = (prev[1][i] + nxt[1][j]) / 2
            if any(_match(box, np.array([f[0]])) is not None for f in faces):
                continue
            faces.append((box, (prev[2][i] + nxt[2][j]) / 2))

        smoothed = []
        for box, marks in faces:
            total, wsum = np.zeros((5, 2)), 0.0
            for k, d in enumerate(dets):
                weight = radius + 1 - abs(k - radius)
                if k == radius:
                    total += weight * marks
                    wsum += weight
                    continue
                j = _match(box, d[1])
                if j is not None and d[0][j] >= low:
                    total += weight * d[2][j]
                    wsum += weight
            smoothed.append((box, total / wsum))
        faces = smoothed

    faces = [f for f in faces if max(f[0][2] - f[0][0], f[0][3] - f[0][1]) >= min_face]
    faces.sort(key=lambda f: -(f[0][2] - f[0][0]) * (f[0][3] - f[0][1]))
    return faces[:max_faces]


# ----------------------------------------------------------------------------
# Alignment and warping
# ----------------------------------------------------------------------------


def similarity(src, dst):
    """The least-squares similarity transform (rotation, uniform scale,
    translation; Umeyama) taking points `src` to `dst`, as a 2x3 matrix."""
    mu_s, mu_d = src.mean(0), dst.mean(0)
    s, d = src - mu_s, dst - mu_d
    cov = d.T @ s / len(src)
    u, sv, vt = np.linalg.svd(cov)
    sign = np.eye(2)
    if np.linalg.det(u) * np.linalg.det(vt) < 0:
        sign[1, 1] = -1
    rot = u @ sign @ vt
    scale = np.trace(np.diag(sv) @ sign) / ((s ** 2).sum() / len(src))
    t = mu_d - scale * rot @ mu_s
    return np.hstack([scale * rot, t[:, None]])


def invert(m):
    a = np.vstack([m, [0.0, 0.0, 1.0]])
    return np.linalg.inv(a)[:2]


def bilinear(img, xs, ys, fill):
    """Sample `img` (c, h, w) at float pixel coordinates (pixel centres at
    integers, as OpenCV's warpAffine), `fill` (c,) outside it."""
    c, h, w = img.shape
    x0 = np.floor(xs).astype(np.int64)
    y0 = np.floor(ys).astype(np.int64)
    fx = (xs - x0).astype(np.float32)
    fy = (ys - y0).astype(np.float32)
    out = np.zeros((c,) + xs.shape, np.float32)
    for dy, wy in ((0, 1 - fy), (1, fy)):
        for dx, wx in ((0, 1 - fx), (1, fx)):
            xi, yi = x0 + dx, y0 + dy
            inside = (xi >= 0) & (xi < w) & (yi >= 0) & (yi < h)
            v = img[:, np.clip(yi, 0, h - 1), np.clip(xi, 0, w - 1)]
            v = np.where(inside, v, fill[:, None, None] if v.ndim == 3 else fill[:, None])
            out += v * (wx * wy)
    return out


_grid = None


def face_grid():
    global _grid
    if _grid is None:
        ys, xs = np.mgrid[0:FACE_SIZE, 0:FACE_SIZE].astype(np.float64)
        _grid = (xs, ys)
    return _grid


def align(rgb, m):
    """The FACE_SIZE square face `m` (frame -> face) picks out of `rgb`."""
    xs, ys = face_grid()
    inv = invert(m)
    sx = inv[0, 0] * xs + inv[0, 1] * ys + inv[0, 2]
    sy = inv[1, 0] * xs + inv[1, 1] * ys + inv[1, 2]
    return bilinear(rgb, sx, sy, BORDER_RGB)


_blur = None


def _blur_matrix():
    """A FACE_SIZE x FACE_SIZE matrix applying a Gaussian of MASK_SIGMA with
    reflected edges (OpenCV's default border), so blur(M) = G @ M @ G.T."""
    global _blur
    if _blur is None:
        r = int(np.ceil(3 * MASK_SIGMA))
        taps = np.exp(-0.5 * (np.arange(-r, r + 1) / MASK_SIGMA) ** 2)
        taps /= taps.sum()
        g = np.zeros((FACE_SIZE, FACE_SIZE))
        for i in range(FACE_SIZE):
            for k, t in enumerate(taps):
                j = i + k - r
                if j < 0:
                    j = -j
                if j >= FACE_SIZE:
                    j = 2 * (FACE_SIZE - 1) - j
                g[i, j] += t
        _blur = g.astype(np.float32)
    return _blur


def face_mask(parsing):
    """The feathered blend mask (FACE_SIZE square, [0, 1]) for BiSeNet's
    logits (1, 19, FACE_SIZE, FACE_SIZE)."""
    labels = parsing[0].argmax(0)
    mask = np.isin(labels, FACE_CLASSES).astype(np.float32)
    g = _blur_matrix()
    mask = g @ mask @ g.T
    b = MASK_BORDER
    mask[:b] = 0
    mask[-b:] = 0
    mask[:, :b] = 0
    mask[:, -b:] = 0
    mask[mask < MASK_FLOOR] = 0
    return mask


# ----------------------------------------------------------------------------
# The pass
# ----------------------------------------------------------------------------


class FaceRestorer:
    """The models for one restore_faces() call."""

    def __init__(self, detector, parser, restorer, model, fidelity):
        if model not in MODELS:
            raise ValueError("face_restore: unknown model %r" % model)
        self.det = ai_runtime.session(detector)
        self.parse = ai_runtime.session(parser)
        self.restore = ai_runtime.session(restorer)
        self.model = model
        self.fidelity = float(fidelity)
        self.restore_input = self.restore.get_inputs()[0].name
        self.parse_input = self.parse.get_inputs()[0].name

    def restore_face(self, face):
        """A (3, 512, 512) RGB face in [0, 1], restored."""
        feeds = {self.restore_input: (face * 2.0 - 1.0)[None].astype(np.float32)}
        if self.model == "codeformer":
            feeds["w"] = np.array([self.fidelity], np.float32)
        out = self.restore.run(None, feeds)[0][0]
        return np.clip((out + 1.0) * 0.5, 0.0, 1.0)

    def mask_for(self, face):
        x = ((face - PARSE_MEAN) / PARSE_STD)[None].astype(np.float32)
        return face_mask(self.parse.run(None, {self.parse_input: x})[0])


def paste(rgb, out, alpha, restored, mask, m):
    """Write `restored`/`mask` (face space, `m` frame -> face) into `out` /
    `alpha` (frame space) where this face's mask is the strongest so far."""
    _, h, w = rgb.shape
    inv = invert(m)
    corners = inv @ np.array([[0, 0, 1], [FACE_SIZE, 0, 1], [0, FACE_SIZE, 1], [FACE_SIZE, FACE_SIZE, 1]], np.float64).T
    x0 = max(int(np.floor(corners[0].min())) - 1, 0)
    x1 = min(int(np.ceil(corners[0].max())) + 2, w)
    y0 = max(int(np.floor(corners[1].min())) - 1, 0)
    y1 = min(int(np.ceil(corners[1].max())) + 2, h)
    if x1 <= x0 or y1 <= y0:
        return
    ys, xs = np.mgrid[y0:y1, x0:x1].astype(np.float64)
    fx = m[0, 0] * xs + m[0, 1] * ys + m[0, 2]
    fy = m[1, 0] * xs + m[1, 1] * ys + m[1, 2]
    a = bilinear(mask[None], fx, fy, np.zeros(1, np.float32))[0]
    a[a < MASK_FLOOR] = 0
    take = a > alpha[y0:y1, x0:x1]
    if not take.any():
        return
    face = bilinear(restored, fx, fy, BORDER_RGB)
    region = out[:, y0:y1, x0:x1]
    region[:, take] = face[:, take]
    alpha[y0:y1, x0:x1][take] = a[take]


# Temporal blending of the restored faces (see restore_faces). Motion is
# judged on the aligned *input* crops, luma averaged over 4x4 blocks: where a
# neighbour's crop differs from this frame's by MOTION_LIMIT (8-bit levels: 15)
# the neighbour contributes nothing, so a moving mouth or eye is not ghosted.
MOTION_BLOCK = 4
MOTION_LIMIT = 15.0 / 255.0


def motion_crop(face):
    """A face crop's luma at 1/MOTION_BLOCK size, for comparing neighbours."""
    y = 0.299 * face[0] + 0.587 * face[1] + 0.114 * face[2]
    b = MOTION_BLOCK
    return y.reshape(FACE_SIZE // b, b, FACE_SIZE // b, b).mean((1, 3)).astype(np.float32)


def motion_weight(a, b):
    """Per-pixel weight (FACE_SIZE square) for blending a neighbour whose
    motion crop is `b` into a face whose motion crop is `a`."""
    d = np.abs(a - b)
    # 3x3 box blur, edges repeated: one noisy block is not motion.
    p = np.pad(d, 1, mode="edge")
    d = sum(p[i:i + d.shape[0], j:j + d.shape[1]] for i in range(3) for j in range(3)) / 9.0
    w = np.clip(1.0 - d / MOTION_LIMIT, 0.0, 1.0)
    return np.repeat(np.repeat(w, MOTION_BLOCK, 0), MOTION_BLOCK, 1)


def restore_faces(
    clip,
    detector,
    parser,
    restorer,
    model="restoreformer",
    strength=1.0,
    fidelity=0.7,
    threshold=0.8,
    min_face=32,
    max_faces=8,
    temporal_radius=1,
    temporal_blend=True,
    matrix="709",
    color_range="limited",
):
    """Restore the faces in `clip` (any format) and return it in its own
    format.

    `strength` (0-1) scales the blend; `fidelity` is CodeFormer's w.
    `threshold` is the detector score a face needs, `min_face` the size (in
    pixels, the larger side of its box) below which a face is left alone,
    `max_faces` how many of the largest are restored per frame. `matrix` /
    `color_range` are the source's (zimg names), for the conversion to RGB and
    back.

    `temporal_radius` r > 0 stabilises the faces over time, in two steps: each
    face's landmarks are smoothed over the detections r frames either side
    (select_faces), and each restored face is averaged, in the aligned 512x512
    space where neighbouring frames' faces line up, with the restored faces
    it matches in the r frames either side — weighted down to nothing where
    the input itself moved (motion_weight). A restorer re-invents fine
    texture for every frame from noisy input; the average keeps what the
    frames agree on. `temporal_blend=False` keeps only the landmark smoothing.
    Each output frame reads 2r frames either side (r for the blend, and r
    more for those frames' landmark smoothing)."""
    import vapoursynth as vs

    core = vs.core
    fmt = clip.format
    if fmt is None:
        raise ValueError("face_restore needs a constant-format clip")
    r = max(0, int(temporal_radius))
    blend_r = r if temporal_blend else 0
    strength = min(max(float(strength), 0.0), 1.0)
    models = FaceRestorer(detector, parser, restorer, model, fidelity)

    rgbs = ai_runtime.to_rgbs(clip, matrix, color_range)
    scale = min(1.0, DET_SIZE / max(clip.width, clip.height))
    dw, dh = max(1, round(clip.width * scale)), max(1, round(clip.height * scale))
    small = rgbs if (dw, dh) == (clip.width, clip.height) else core.resize.Bicubic(rgbs, width=dw, height=dh)
    det_scale = (dw / clip.width, dh / clip.height)
    floor = threshold * 0.75
    last = clip.num_frames - 1

    def clamp(i):
        return min(max(i, 0), last)

    # The frames each request reads: the RGB frames the blend needs (n-b..n+b)
    # and the detection copies their landmark smoothing needs (n-b-r..n+b+r).
    det_reach = blend_r + r
    rgb_offsets = list(range(-blend_r, blend_r + 1))
    det_offsets = list(range(-det_reach, det_reach + 1))
    inputs = [ai_runtime.shifted(rgbs, k) for k in rgb_offsets] + [ai_runtime.shifted(small, k) for k in det_offsets]

    detections = ai_runtime.FrameMemo(capacity=64)
    faces_memo = ai_runtime.FrameMemo(capacity=48)
    results = ai_runtime.FrameMemo(capacity=16)

    def rgb_frame(frames, n, k):
        return frames[rgb_offsets.index(k)]

    def det_frame(frames, n, k):
        return frames[len(rgb_offsets) + det_offsets.index(k)]

    def detections_for(index, frame):
        def run():
            rgb = np.stack([np.asarray(frame[p]) for p in range(3)])
            return detect(models.det, rgb, det_scale, floor)

        return detections.get(index, run)

    def faces_for(n, frames, k):
        """Stage 1 for frame clamp(n + k): its faces, each aligned, restored
        and parsed, from that frame and the detections r either side of it."""
        index = clamp(n + k)

        def run():
            dets = [detections_for(clamp(index + j), det_frame(frames, n, k + j)) for j in range(-r, r + 1)]
            chosen = select_faces(dets, r, threshold, min_face, max_faces)
            src = rgb_frame(frames, n, k)
            rgb = np.stack([np.asarray(src[p]) for p in range(3)]).astype(np.float32)
            out = []
            for box, marks in chosen:
                m = similarity(marks, FFHQ_TEMPLATE)
                face = align(rgb, m)
                restored = models.restore_face(face)
                out.append({
                    "box": box,
                    "m": m,
                    "motion": motion_crop(face),
                    "restored": restored.astype(np.float16),
                    "mask": models.mask_for(restored).astype(np.float16),
                })
            return out

        return faces_memo.get(index, run)

    def compute(n, frames):
        def run():
            here = faces_for(n, frames, 0)
            src = rgb_frame(frames, n, 0)
            rgb = np.stack([np.asarray(src[p]) for p in range(3)]).astype(np.float32)
            out = rgb.copy()
            alpha = np.zeros(rgb.shape[1:], np.float32)
            neighbours = [(k, faces_for(n, frames, k)) for k in rgb_offsets if k != 0 and clamp(n + k) != n]
            for face in here:
                restored = face["restored"].astype(np.float32)
                if neighbours:
                    total = restored * float(blend_r + 1)
                    weight = np.full(restored.shape[1:], float(blend_r + 1), np.float32)
                    for k, faces in neighbours:
                        j = _match(face["box"], np.array([f["box"] for f in faces])) if faces else None
                        if j is None:
                            continue
                        w = (blend_r + 1 - abs(k)) * motion_weight(face["motion"], faces[j]["motion"])
                        total += w * faces[j]["restored"].astype(np.float32)
                        weight += w
                    restored = total / weight
                paste(rgb, out, alpha, restored, face["mask"].astype(np.float32), face["m"])
            return out, alpha * strength, len(here)

        return results.get(n, run)

    def restored_frame(n, f):
        out_rgb, _alpha, count = compute(n, f[1:])
        dst = f[0].copy()
        for p in range(3):
            np.copyto(np.asarray(dst[p]), out_rgb[p])
        dst.props["FaceRestoreFaces"] = count
        return dst

    def mask_frame(n, f):
        _out, alpha, _count = compute(n, f[1:])
        dst = f[0].copy()
        plane = np.asarray(dst[0])
        if mask_fmt.sample_type == vs.FLOAT:
            np.copyto(plane, alpha)
        else:
            peak = (1 << mask_fmt.bits_per_sample) - 1
            np.copyto(plane, np.rint(alpha * peak).astype(plane.dtype))
        return dst

    mask_fmt = core.query_video_format(vs.GRAY, fmt.sample_type, fmt.bits_per_sample, 0, 0)
    blank = core.std.BlankClip(clip, format=mask_fmt.id, keep=True)
    restored = core.std.ModifyFrame(rgbs, [rgbs] + inputs, restored_frame)
    mask = core.std.ModifyFrame(blank, [blank] + inputs, mask_frame)
    restored = ai_runtime.from_rgbs(restored, fmt, matrix, color_range)
    # Composited in the source's format, so the mask's zeros leave the input
    # bit-exact. The mask is luma-sized; MaskedMerge resamples it for
    # subsampled chroma.
    merged = core.std.MaskedMerge(clip, restored, mask, first_plane=True)
    return core.std.CopyFrameProps(merged, clip)
