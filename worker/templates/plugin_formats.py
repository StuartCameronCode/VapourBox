"""The format limits of the plugins the script template calls, and the one
way the template runs a plugin outside them (task #48).

A plugin that refuses part of what a pass can be handed -- {4:2:0, 4:2:2,
4:4:4} x {8, 10, 12, 16} bits x {progressive, field-flagged}, at any mod-2
size -- has a Contract here, and the template calls it through run_within():

    clip = _pf.run_within(clip, 'dedot.Dedot', _dedot, label='Dedot')

Each limit is measured, not remembered: Scripts/probe-plugin-formats.py runs
every plugin call in the template against the deps bundle at every format
and writes Tests/TestResources/plugin_format_table.json. Change a Contract
only together with that table; app/test/plugin_format_contracts_test.dart
fails when they disagree, when the bundle stops agreeing with the table, and
worker/tests/filter_integration_test.rs (test_252) when a limited plugin is
called anywhere but inside a run_within() function.

The recurring mistake this replaces (tasks #34 and #37): running a plugin on
a low-depth copy and up-converting its whole result quantised every sample of
a deeper source, though the plugin changed a fraction of them. run_within()
adds only the plugin's change (delta_only, the default), so every sample it
leaves alone stays bit-exact.
"""
import math
from collections import namedtuple

import vapoursynth as vs

core = vs.core

# A frame-size step meaning "that axis of the chroma plane even": 2 <<
# subsampling of the clip (4 luma samples on a subsampled axis, else 2). A
# 4:2:0 frame whose height is 2 mod 4 has an odd number of chroma rows, so it
# cannot be split into fields (SeparateFields) or resampled per field (zimg,
# "Resize error 1027"), which a field-flagged clip asks of every resize, even a
# depth change (task #57). Width 2 mod 4 is the same on the other axis (#56).
CHROMA = 'chroma'

# depths / subsampling: what the plugin accepts, within the reachable set.
# min_width / min_height: the smallest frame it accepts (0: no limit found).
# width_step / height_step: the frame must be a whole number of these (luma
# samples, or CHROMA); run_within() pads to them with pad_around().
Contract = namedtuple('Contract', 'depths subsampling min_width min_height width_step height_step')
Contract.__new__.__defaults__ = (('420', '422', '444'), 0, 0, 1, 1)
ALL_DEPTHS = (8, 10, 12, 16)

CONTRACTS = {
    # Bifrost v3.0 writes chroma one whole 4x4 luma block at a time (per field
    # with interlaced=True) and never initialises the rest of the output's
    # chroma, so the columns and rows past the last whole block held whatever
    # memory it got: different run to run at width 98, and at 720x486 4:2:2
    # (task #56 F6, docs/reports/task-56-format-sweep-findings). Padded to whole
    # blocks, every sample it returns is defined. Task #60 (Bifrost v4.0, which
    # starts chroma from altclip) can drop the steps.
    'bifrost.Bifrost': Contract(depths=(8,), width_step=4, height_step=8),
    'dedot.Dedot': Contract(depths=(8,)),
    'descratch.DeScratch': Contract(depths=(8,)),
    'havsfunc.LUTDeCrawl': Contract(depths=(8, 10)),
    'havsfunc.LUTDeRainbow': Contract(depths=(8, 10)),
    # Whole field chroma rows (task #57): a 4:2:0 frame whose height is 2 mod
    # 4 (720x486) has an odd number of chroma rows, which SeparateFields and a
    # field-flagged resize refuse. Whole chroma columns (task #56): at a 4:2:x
    # width 2 mod 4, MCTD's pad-and-crop crops an odd chroma offset ("cropped
    # area needs to have mod 2 width offset", F1), and QTGMC with SrchClipPP 1
    # (Super / Ultra Fast) halves the frame to an odd chroma width for its
    # motion search ("image dimensions must be divisible by subsampling
    # factor", F2). QTGMC's other SrchClipPP values resample the whole frame
    # at a size that follows the width, so padding would move every column
    # (up to 5 levels inside the frame at 854x480): they keep the width.
    'havsfunc.MCTemporalDenoise': Contract(depths=ALL_DEPTHS, width_step=CHROMA, height_step=CHROMA),
    'havsfunc.QTGMC': Contract(depths=ALL_DEPTHS, height_step=CHROMA),
    'havsfunc.QTGMC[SrchClipPP=1]': Contract(depths=ALL_DEPTHS, width_step=CHROMA, height_step=CHROMA),
}

# Calls whose measured limits are met another way, so they need no
# run_within(): the reason is the evidence a reviewer checks.
HANDLED = {
    'vivtc.VFM': '8-bit only. The match decisions are made on an 8-bit copy and '
                 'the pixels come from clip2, the source (IVTC block)',
    'descratch.DeScratch': 'beyond its 8-bit contract, the plugin alone refuses '
                           'field-flagged 4:2:0 at most heights (its internal blur '
                           'resizes per field); the pass never hands it one: 4:2:0 '
                           'luma runs on a 4:2:2 carrier (#29), measured as pass.DeScratch',
    'pass.DeScratch': 'the DeScratch pass as the template runs it at 8-bit: '
                      'field-flagged 4:2:0 luma runs on a 4:2:2 carrier (#29)',
}

# Refusals the probe measured that no pass handles yet, each with the task
# that will. A user can hit these; the job fails with the plugin's own error.
# Remove an entry with its fix and re-run the probe on that call.
_H486 = ('4:2:0 at 720x486, field-flagged (243 chroma rows: a field has no '
         'whole chroma height), task #57')
KNOWN = {
    'dctf.DCTFilter': _H486,
    'deblock.Deblock': _H486,
    'havsfunc.Deblock_QED': _H486,
    'havsfunc.FixChromaBleedingMod': _H486,
    'havsfunc.LSFmod': _H486,
    'sangnom.SangNom': _H486,
    'srestore.unblend': 'every subsampling at 720x486 field-flagged, task #57',
    'stabilize.weave': _H486,
    'temporaldegrain2.TemporalDegrain2': _H486,
}

# MVTools' Compensate, Degrain and BlockFPS pick each block row's overlap
# window with ((by + nBlkY - 3) / (nBlkY - 2)) * 3: an integer division by zero
# when the analysed picture is exactly two block rows tall,
# (H - overlap) // (blksize - overlap) == 2. On x86 that is SIGFPE (vspipe dies
# with no Python error); on arm64 the division returns 0 and the bottom block
# row is blended with the top row's window, up to 106 levels off with no error.
# One block row (or one block column) is wrong on every CPU: the only block
# gets the bottom (right) edge's window, up to 127 levels off (task #56 F9,
# docs/reports/task-56-format-sweep-findings). Two rows means
# 2b - o <= H < 3b - 2o and one column W < 2b - o; with blocks up to 32 (the
# most any pass offers) and overlap at least 2, a picture of at least 94 rows
# and 62 columns is safe. Every MVTools caller with an overlap runs through
# mvtools_blocks() (test_256), which pads a smaller picture to these sizes and
# crops back. A real source is never that small, so no real job gets a node
# from it.
MVTOOLS_MIN_ROWS = 96
MVTOOLS_MIN_COLS = 64

_SS = {'420': (1, 1), '422': (1, 0), '444': (0, 0)}

_akarin_expr = getattr(getattr(core, 'akarin', None), 'Expr', None)


def _expr(clips, expr, **kwargs):
    """The template's _expr(): akarin's JIT where bundled (test_93)."""
    if _akarin_expr is not None:
        return _akarin_expr(clips, expr, **kwargs)
    return core.std.Expr(clips, expr, **kwargs)


def _subsampling_name(fmt):
    for name, wh in _SS.items():
        if (fmt.subsampling_w, fmt.subsampling_h) == wh:
            return name
    return '%d%d' % (fmt.subsampling_w, fmt.subsampling_h)


def work_format(fmt, contract):
    """The format run_within() runs the plugin at, for a clip in [fmt]:
    [fmt] itself when the contract accepts it; otherwise the smallest accepted
    depth at or above the clip's (else the largest below), and the accepted
    subsampling closest to the clip's that loses no chroma."""
    bits = fmt.bits_per_sample
    if bits not in contract.depths:
        above = [d for d in contract.depths if d >= bits]
        bits = min(above) if above else max(contract.depths)
    sw, sh = fmt.subsampling_w, fmt.subsampling_h
    if fmt.color_family == vs.YUV and _subsampling_name(fmt) not in contract.subsampling:
        fits = [_SS[s] for s in contract.subsampling if _SS[s][0] <= sw and _SS[s][1] <= sh]
        if not fits:
            raise vs.Error('no accepted subsampling holds %s' % fmt.name)
        sw, sh = max(fits, key=lambda wh: wh[0] + wh[1])
    return fmt.replace(bits_per_sample=bits, sample_type=vs.INTEGER,
                       subsampling_w=sw, subsampling_h=sh)


def _step(step, sub):
    """A step in luma samples: CHROMA is 2 << the axis's subsampling."""
    if step == CHROMA:
        return 2 << sub
    return int(step)


def _pad_rows(plane, rows):
    """[plane] with [rows] more rows, repeating with period 2: new row h is
    row h-2, h+1 is h-1, and so on. On a field-flagged clip that is each
    field's own last row; on a progressive one, a near-edge repeat. So the
    padding needs no _FieldBased, which is not known while the script is
    built (reading frame 0 would pull it through pipe_source)."""
    if rows <= 0:
        return plane
    if plane.height < 2:
        tail = [plane] * rows
    else:
        last2 = core.std.Crop(plane, top=plane.height - 2)
        tail = [last2] * (rows // 2)
        if rows % 2:
            tail.append(core.std.Crop(plane, top=plane.height - 2, bottom=1))
    return core.std.StackVertical([plane] + tail)


def _pad_cols(plane, cols):
    """[plane] with [cols] more columns, each a copy of the last."""
    if cols <= 0:
        return plane
    last = core.std.Crop(plane, left=plane.width - 1)
    return core.std.StackHorizontal([plane] + [last] * cols)


def pad_around(clip, fn, *, width_step=1, height_step=1, min_rows=0, min_cols=0, label=None):
    """fn(clip) on a copy padded right and bottom to whole [width_step] x
    [height_step] (luma samples, or CHROMA), cropped back by the same amount.

    - When the clip already fits, this is fn(clip): no node is added, so every
      size that works today keeps its script output byte for byte.
    - The pad is built per plane as GRAY clips (std.Crop / Stack*), never a
      resize: a resize of the odd chroma geometry is what refuses (task #57).
    - Columns repeat the last column; rows repeat with period 2 (_pad_rows),
      right for a field-flagged clip and a progressive one alike.
    - min_rows / min_cols: also pad until the frame has at least this many
      rows / columns (mvtools_blocks()), keeping whole steps.
    - fn may retime (QTGMC doubles the frame count) but must keep the frame
      size; anything else raises, naming [label]."""
    fmt = clip.format
    sw = fmt.subsampling_w if fmt.color_family == vs.YUV else 0
    sh = fmt.subsampling_h if fmt.color_family == vs.YUV else 0
    ws, hs = _step(width_step, sw), _step(height_step, sh)
    pw = -clip.width % ws
    ph = -clip.height % hs
    if clip.height + ph < min_rows:
        short = min_rows - (clip.height + ph)
        ph += -(-short // hs) * hs
    if clip.width + pw < min_cols:
        short = min_cols - (clip.width + pw)
        pw += -(-short // ws) * ws
    if pw == 0 and ph == 0:
        return fn(clip)
    if pw % (1 << sw) or ph % (1 << sh):
        raise vs.Error('%s: pad_around can only pad whole chroma samples (%dx%d %s by %dx%d)'
                       % (label or 'pad_around', clip.width, clip.height, fmt.name, pw, ph))
    planes = []
    for i in range(fmt.num_planes):
        plane = core.std.ShufflePlanes(clip, i, vs.GRAY)
        xs, ys = (sw, sh) if i else (0, 0)
        planes.append(_pad_rows(_pad_cols(plane, pw >> xs), ph >> ys))
    if fmt.num_planes == 1:
        padded = planes[0]
    else:
        padded = core.std.ShufflePlanes(planes, [0, 0, 0], fmt.color_family)
    padded = core.std.CopyFrameProps(padded, clip)
    out = fn(padded)
    if (out.width, out.height) != (padded.width, padded.height):
        raise vs.Error('%s: pad_around needs fn to keep the frame size (%dx%d in, %dx%d out)'
                       % (label or 'pad_around', padded.width, padded.height, out.width, out.height))
    return core.std.Crop(out, right=pw, bottom=ph)


def run_within(clip, plugin, fn, *, delta_only=True, label=None):
    """fn(work), where work is [clip] in a format and size [plugin] accepts
    (CONTRACTS[plugin]), brought back to [clip]'s format and size.

    - The frame is first padded to the contract's width_step / height_step
      (pad_around), and, when it must be converted, to whole field chroma
      rows: the conversion is a zimg resize, which refuses a field-flagged
      4:2:0 clip whose height is 2 mod 4. Padding is outside the conversion,
      and a clip that already fits gets no padding node.
    - A clip the plugin already accepts is handed to fn unchanged and fn's
      result returned as it is: no node is added.
    - Otherwise the work copy is converted with zimg, keeping _FieldBased, so
      a field-flagged clip's chroma is resampled per field: Bilinear down and
      Point back for a depth change alone, Bicubic both ways when the
      subsampling changes too.
    - delta_only (the default): the result is clip + back(fn(work)) -
      back(work), so every sample fn left alone is the source's, bit for
      bit, and a changed one keeps the source's low bits. fn must keep the
      frame count, size and format.
    - delta_only=False: back(fn(work)), for an fn that retimes.
    - A frame smaller than the contract's minimum raises, naming the pass
      ([label]), the plugin and both sizes, rather than failing inside the
      plugin."""
    contract = CONTRACTS.get(plugin)
    if contract is None:
        raise vs.Error('run_within: %s has no contract in plugin_formats.CONTRACTS' % plugin)
    name = label or plugin
    if clip.width < contract.min_width or clip.height < contract.min_height:
        raise vs.Error('%s: %s needs a frame at least %dx%d; this one is %dx%d'
                       % (name, plugin, contract.min_width, contract.min_height,
                          clip.width, clip.height))
    width_step, height_step = contract.width_step, contract.height_step
    fmt = clip.format
    if fmt.color_family == vs.YUV and work_format(fmt, contract).id != fmt.id:
        # The conversion to the work format is a zimg resize, per field on a
        # field-flagged clip, so it needs whole field chroma rows as well.
        hs = _step(height_step, fmt.subsampling_h)
        cs = _step(CHROMA, fmt.subsampling_h)
        height_step = hs * cs // math.gcd(hs, cs)
    return pad_around(clip, lambda c: _run_converted(c, contract, plugin, fn, delta_only, name),
                      width_step=width_step, height_step=height_step, label=name)


def _run_converted(clip, contract, plugin, fn, delta_only, name):
    """run_within()'s format half, on a clip already of a size it accepts."""
    return _change(clip, work_format(clip.format, contract), fn, delta_only,
                   name, 'run_within(delta_only=True) needs %s' % plugin)


def change_at(clip, fmt, fn, *, label=None):
    """fn(work), where work is [clip] converted to [fmt], with only fn's change
    added back at [clip]'s format: clip + back(fn(work)) - back(work), the
    conversions and delta of run_within(). Every sample fn leaves alone stays
    the source's, bit for bit, and a changed one keeps the source's low bits.

    For a filter that accepts the clip's format but should *decide* at
    another one (task #56 F7: Local Contrast's CLAHE equalises an 8-bit
    histogram, so a deep source gets the 8-bit picture's change, not one from
    a sparse 16-bit histogram). fn must keep the frame count, size and format."""
    return _change(clip, fmt, fn, True, label or 'change_at', 'change_at needs fn')


def _change(clip, target, fn, delta_only, name, needs):
    """fn on [clip] converted to [target] with zimg (keeping _FieldBased:
    Bilinear down / Point back for a depth change alone, Bicubic both ways
    when the subsampling changes too), brought back: whole (delta_only=False)
    or as clip + back(out) - back(work)."""
    fmt = clip.format
    if target.id == fmt.id:
        return fn(clip)
    if (target.subsampling_w, target.subsampling_h) == (fmt.subsampling_w, fmt.subsampling_h):
        work = core.resize.Bilinear(clip, format=target.id)

        def back(c):
            return core.resize.Point(c, format=fmt.id)
    else:
        work = core.resize.Bicubic(clip, format=target.id)

        def back(c):
            return core.resize.Bicubic(c, format=fmt.id)
    out = fn(work)
    if not delta_only:
        return back(out)
    if (out.num_frames, out.width, out.height, out.format.id) != \
            (work.num_frames, work.width, work.height, work.format.id):
        raise vs.Error('%s: %s to keep the frame count, size and format '
                       '(%d frames %dx%d %s in, %d frames %dx%d %s out)'
                       % (name, needs, work.num_frames, work.width, work.height, work.format.name,
                          out.num_frames, out.width, out.height, out.format.name))
    return _expr([clip, back(out), back(work)], 'x y + z -')


def mvtools_blocks(clip, fn, *, label=None):
    """fn(clip), where fn runs MVTools Compensate / Degrain / BlockFPS with an
    overlap (directly or inside havsfunc), on a copy padded right and bottom to
    at least MVTOOLS_MIN_COLS x MVTOOLS_MIN_ROWS when it is smaller, cropped
    back after (task #56 F9: a picture one or two block rows tall, or one
    block column wide, is blended with the wrong overlap windows, and two rows
    divide by zero). The rows repeat with period 2, so a field-flagged clip
    keeps its fields; a clip at least that big gets no node. fn may retime
    but must keep the frame size."""
    return pad_around(clip, fn, min_rows=MVTOOLS_MIN_ROWS, min_cols=MVTOOLS_MIN_COLS,
                      label=label or 'mvtools_blocks')
