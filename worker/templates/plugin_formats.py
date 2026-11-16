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
from collections import namedtuple

import vapoursynth as vs

core = vs.core

# depths / subsampling: what the plugin accepts, within the reachable set.
# min_width / min_height: the smallest frame it accepts (0: no limit found).
Contract = namedtuple('Contract', 'depths subsampling min_width min_height')
Contract.__new__.__defaults__ = (('420', '422', '444'), 0, 0)

CONTRACTS = {
    'bifrost.Bifrost': Contract(depths=(8,)),
    'dedot.Dedot': Contract(depths=(8,)),
    'descratch.DeScratch': Contract(depths=(8,)),
    'havsfunc.LUTDeCrawl': Contract(depths=(8, 10)),
    'havsfunc.LUTDeRainbow': Contract(depths=(8, 10)),
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
    'bifrost.Bifrost': '4:2:0 at 720x486, progressive too (SeparateFields), task #57',
    'dctf.DCTFilter': _H486,
    'deblock.Deblock': _H486,
    'havsfunc.Deblock_QED': _H486,
    'havsfunc.FixChromaBleedingMod': _H486,
    'havsfunc.LSFmod': _H486,
    'havsfunc.MCTemporalDenoise': 'width 2 mod 4 on 4:2:0/4:2:2 (task #56 F1); 4:2:0 at '
                                  '720x486, progressive too (task #57)',
    'havsfunc.QTGMC': '4:2:0 at 720x486, progressive too (SeparateFields), task #57',
    'sangnom.SangNom': _H486,
    'srestore.unblend': 'every subsampling at 720x486 field-flagged, task #57',
    'stabilize.weave': _H486,
    'temporaldegrain2.TemporalDegrain2': _H486,
}

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


def run_within(clip, plugin, fn, *, delta_only=True, label=None):
    """fn(work), where work is [clip] in a format [plugin] accepts
    (CONTRACTS[plugin]), brought back to [clip]'s format.

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
    fmt = clip.format
    target = work_format(fmt, contract)
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
        raise vs.Error('%s: run_within(delta_only=True) needs %s to keep the frame count, '
                       'size and format (%d frames %dx%d %s in, %d frames %dx%d %s out)'
                       % (name, plugin, work.num_frames, work.width, work.height, work.format.name,
                          out.num_frames, out.width, out.height, out.format.name))
    return _expr([clip, back(out), back(work)], 'x y + z -')
