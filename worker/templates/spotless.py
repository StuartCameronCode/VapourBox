"""
SpotLess - Temporal spot/dirt removal using motion-compensated median filtering.

Removes dust, dirt spots, and temporal noise from video by:
1. Analyzing motion between frames using MVTools
2. Motion-compensating neighboring frames to align with current frame
3. Applying temporal median to reject outlier pixels (spots/dirt)

Best for live-action film restoration. Not suitable for animation.

Written for VapourBox. Algorithm based on the well-known technique
by Didée (Doom9 forums, 2010).
"""

import vapoursynth as vs

core = vs.core


def SpotLess(clip, chroma=True, rec=False, blksize=None, overlap=None, pel=None):
    """
    Remove temporal spots and dirt using motion-compensated median.

    Args:
        clip:     Input clip (YUV integer or float).
        chroma:   Process chroma planes (default True).
        rec:      Recalculate motion vectors for more precision (default False).
        blksize:  Block size for motion analysis (default: auto by resolution).
        overlap:  Block overlap (default: blksize // 2).
        pel:      Sub-pixel accuracy: 1=pixel, 2=half, 4=quarter (default: auto).

    Returns:
        Clip with temporal spots removed.
    """
    is_float = clip.format.sample_type == vs.FLOAT
    is_gray = clip.format.color_family == vs.GRAY
    chroma = False if is_gray else chroma
    planes = [0, 1, 2] if chroma else [0]

    # Select MVTools variant (float vs integer)
    Analyse = core.mvsf.Analyse if is_float else core.mv.Analyse
    Compensate = core.mvsf.Compensate if is_float else core.mv.Compensate
    Super = core.mvsf.Super if is_float else core.mv.Super
    Recalculate = core.mvsf.Recalculate if is_float else core.mv.Recalculate

    # Auto block size based on resolution
    if blksize is None:
        blksize = 32 if clip.width > 2400 else 16 if clip.width > 960 else 8
    if overlap is None:
        overlap = blksize // 2
    if pel is None:
        pel = 1 if clip.width > 960 else 2

    sup = Super(clip, pel=pel, sharp=1, rfilter=4)

    # Analyze motion forward and backward
    bv1 = Analyse(sup, isb=True, delta=1, blksize=blksize, overlap=overlap, search=5)
    fv1 = Analyse(sup, isb=False, delta=1, blksize=blksize, overlap=overlap, search=5)

    # Optional: recalculate vectors at finer block size for precision
    if rec:
        rec_blksize = max(4, blksize // 2)
        rec_overlap = rec_blksize // 2
        bv1 = Recalculate(sup, bv1, blksize=rec_blksize, overlap=rec_overlap, search=5)
        fv1 = Recalculate(sup, fv1, blksize=rec_blksize, overlap=rec_overlap, search=5)

    # Motion-compensate neighbors to align with current frame
    bc1 = Compensate(clip, sup, bv1)
    fc1 = Compensate(clip, sup, fv1)

    # Interleave: [forward-compensated, original, backward-compensated]
    interleaved = core.std.Interleave([fc1, clip, bc1])

    # Temporal median picks the middle value, rejecting outlier spots
    cleaned = interleaved.tmedian.TemporalMedian(1, planes)

    # Select every 3rd frame (the originals, now cleaned)
    return cleaned[1::3]
