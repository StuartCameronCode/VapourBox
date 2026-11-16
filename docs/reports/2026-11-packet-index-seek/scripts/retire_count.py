"""D. What a packet index would retire, counted from the source.

Each item is found by its declaration and measured with its doc comment
(brace or bracket matching), then classed by what the sweep found
(data/sweep.json), not by intent:

  retired     goes with the index (its job is done by K's byte position)
  simplified  stays, smaller
  unchanged   the index cannot do its job (the reason is given)

Unit tests are counted apart: the `#[test]` functions in source_decode.rs
that name an item (a test naming a retired and a kept item counts as kept).
Dart twins are listed separately, since task #50 (R3b) deletes them whatever
this decides. Writes data/retire.json.
"""
import json
import os
import re

import pktlib as L

R = os.path.join(L.REPO, 'worker', 'src')
D = os.path.join(L.REPO, 'app', 'lib', 'services', 'field_order_detector.dart')

C1 = 'C1 SeekPlan preroll'
C2 = 'C2 AVI decoder delay'
C3 = 'C3 microsecond round-up'
C4 = 'C4 COUNT_SEEK_BELOW'
C5 = 'C5 grid lookback'
C6 = 'C6 frame-0 -copyts exception'
C7 = 'C7 joined copy'

WHY_C1 = 'M2 (byte start at K) exact on every TS/PS start; replaces the GOP-sized preroll and its probe'
WHY_C2 = 'needs display order; MPEG-2 in AVI stores its I/P packets without PTS and open GOPs drop leading Bs: count from K was 13/90'
WHY_C3 = 'still formats seconds: delayed AVI seeks, the no-grid PS trim, and M1 itself (rounded down instead)'
WHY_C4 = 'tied to C2: a delayed AVI still seeks by time'
WHY_C5 = 'M1 exact on every grid source, but only with an index of MP4/MOV/MKV/AVI too, a full read they do not pay today'
WHY_C6 = '-copyts stops at a reset whatever starts the decode (byte or time)'
WHY_C7 = 'byte start reaches a later segment only within it; a decode across a reset still stops'

RUST = [
    ('source_decode.rs', 'pub const SEEK_PROBE_SECONDS', C1, 'retired', WHY_C1),
    ('source_decode.rs', 'pub const SEEK_PROBE_ARGS', C1, 'retired', WHY_C1),
    ('source_decode.rs', 'pub const SEEK_PREROLL_MARGIN', C1, 'retired', WHY_C1),
    ('source_decode.rs', 'pub const SEEK_PREROLL_MIN', C1, 'retired', WHY_C1),
    ('source_decode.rs', 'pub fn seek_plan_from_probe', C1, 'retired', WHY_C1),
    ('source_decode.rs', 'pub fn probe_seek_plan', C1, 'retired', WHY_C1),
    ('source_decode.rs', 'pub struct SeekPlan', C1, 'simplified',
     'keeps container_start (the no-grid PS trim) and becomes "this source starts by byte"'),
    ('source_decode.rs', 'impl SeekPlan', C1, 'unchanged', 'validity check'),
    ('source_decode.rs', 'pub fn decoder_seek', C1, 'simplified', 'the preroll arithmetic becomes a byte offset'),
    ('source_decode.rs', 'pub const TIMESTAMP_SEARCH_FORMATS', C1, 'unchanged', 'still decides who starts by byte'),
    ('source_decode.rs', 'pub fn trim_filter', C3, 'unchanged', WHY_C3),
    ('source_decode.rs', 'pub fn seek_arg', C3, 'unchanged', WHY_C3),
    ('source_decode.rs', 'pub fn seek_time', C3, 'unchanged', 'every time-seeked source'),
    ('source_decode.rs', 'pub fn stores_decode_order', C2, 'unchanged', WHY_C2),
    ('source_decode.rs', 'pub const DECODER_DELAY_PROBE_ARGS', C2, 'unchanged', WHY_C2),
    ('source_decode.rs', 'pub const MAX_DECODER_DELAY', C2, 'unchanged', WHY_C2),
    ('source_decode.rs', 'pub fn decoder_delay_from_probe', C2, 'unchanged', WHY_C2),
    ('source_decode.rs', 'pub fn probe_video_timing', C2, 'unchanged', WHY_C2),
    ('source_decode.rs', 'pub struct DecoderSeek', C2, 'unchanged', WHY_C2),
    ('source_decode.rs', 'impl DecoderSeek', C2, 'unchanged', WHY_C2),
    ('source_decode.rs', 'pub const COUNT_SEEK_BELOW', C4, 'unchanged', WHY_C4),
    ('source_decode.rs', 'pub fn trim_frames_filter', C4, 'unchanged', WHY_C4),
    ('source_decode.rs', 'pub fn source_seek', C4, 'unchanged', WHY_C4),
    ('source_decode.rs', 'pub fn sound_seek_fails', C4, 'unchanged', 'the sound, not the picture (rule 9)'),
    ('source_decode.rs', 'pub enum SoundSeek', C4, 'unchanged', 'the sound, not the picture (rule 9)'),
    ('source_decode.rs', 'pub fn sound_seek', C4, 'unchanged', 'the sound, not the picture (rule 9)'),
    ('source_decode.rs', 'pub const GRID_LOOKBACK_SLOTS', C5, 'unchanged', WHY_C5),
    ('source_decode.rs', 'pub fn filters_from_first_picture', C6, 'unchanged', WHY_C6),
    ('source_decode.rs', 'pub fn decode_start', C1, 'simplified', 'the plan branch becomes a byte start'),
    ('source_continuity.rs', 'pub const PACKETS_PROBE_ARGS', C7, 'simplified',
     'widened (pts, flags, pos) to carry the index: grows, not shrinks'),
    ('source_continuity.rs', 'pub fn scan', C7, 'unchanged', WHY_C7),
    ('main.rs', 'fn fill_seek_plan', C1, 'retired', 'replaced by filling the index (new code below)'),
]

# Dart twins (FieldOrderDetector, SeekPlan, SourceGrid): R3b (#50) removes
# them with the worker's --probe-source; listed so the credit is not double.
DART = [
    ('static const seekProbeSeconds', C1), ('static const seekPrerollMargin', C1),
    ('static const seekPrerollMin', C1), ('static const seekProbeArgs', C1),
    ('static SeekPlan? seekPlanFromProbe', C1), ('static Future<SeekPlan?> probeSeekPlan', C1),
    ('static ({List<String> input, String? trim}) seekArgs', C1),
    ('static String formatSeek', C3), ('static const countSeekBelow', C4),
    ('static ({List<String> input, String? trim})? frameSeekArgs', C4),
    ('static const lookbackSlots', C5),
    ('static const decoderDelayProbeArgs', C2), ('static int decoderDelayFromProbe', C2),
    ('static Future<int> probeDecoderDelay', C2),
]

VECTORS = [
    ('seek_probe_dvbt.json', C1, 'retired'),
    ('seek_arg_cases.json', C3, 'unchanged'),
    ('source_grid_vectors.json', C5, 'unchanged'),
    ('decoder_delay_probe_avi.json', C2, 'unchanged'),
]

# New code, estimated from this report's Python (pktlib.packet_index,
# fps_slot, key_for_slot, m2_grid, the no-grid PS key): Rust is counted at
# twice the Python's lines, as the existing Rust/Python ports here run.
NEW = [
    ('index parse + store (I-key: key PTS + byte position)', 'packet_index', 2),
    ('K for a grid slot', 'key_for_slot', 2),
    ('fps-filter slot of a PTS', 'fps_slot', 2),
    ('byte start', 'm2_grid', 2),
]


def span(lines, start):
    """Lines of the item declared at `start`, with its doc comment and
    attributes above."""
    a = start
    while a > 0 and re.match(r'\s*(///|//!|#\[)', lines[a - 1]):
        a -= 1
    depth, opened, b = 0, False, start
    for b in range(start, len(lines)):
        for ch in lines[b]:
            if ch in '{[(':
                depth += 1
                opened = True
            elif ch in '}])':
                depth -= 1
        if (opened and depth <= 0) or (not opened and lines[b].rstrip().endswith(';')):
            break
    return a, b


def find(lines, decl):
    for i, l in enumerate(lines):
        tail = r'(?![A-Za-z0-9_])' if re.match(r'.*\w$', decl) else ''
        if re.match(re.escape(decl) + tail, l.strip()):
            return i
    raise KeyError(decl)


def ident(decl):
    return re.findall(r'[A-Za-z_][A-Za-z0-9_]*', decl.split('(')[0])[-1]


def rust_tests(path, idents, kept):
    """#[test] fns in `path` naming any of `idents` and none of `kept`."""
    src = open(path).read().splitlines()
    tstart = next(i for i, l in enumerate(src) if l.strip() == '#[cfg(test)]')
    total = 0
    names = []
    i = tstart
    while i < len(src):
        if src[i].strip() == '#[test]':
            a, b = span(src, i + 1)
            body = '\n'.join(src[i:b + 1])
            if any(re.search(rf'\b{x}\b', body) for x in idents) and not any(
                    re.search(rf'\b{x}\b', body) for x in kept):
                total += b - i + 1
                names.append(re.search(r'fn (\w+)', src[i + 1]).group(1))
            i = b + 1
        else:
            i += 1
    return total, names


def main():
    out = dict(rust=[], dart=[], vectors=[], new=[], claude_md=None, tests=None)
    files = {}
    for f, decl, c, verdict, why in RUST:
        path = os.path.join(R, f)
        lines = files.setdefault(path, open(path).read().splitlines())
        i = find(lines, decl)
        a, b = span(lines, i)
        out['rust'].append(dict(file=f, item=decl, correction=c, verdict=verdict, why=why, lines=b - a + 1,
                                at=i + 1))
    retired = [ident(r['item']) for r in out['rust'] if r['verdict'] == 'retired']
    kept = [ident(r['item']) for r in out['rust'] if r['verdict'] != 'retired' and r['file'] == 'source_decode.rs']
    kept = [k for k in kept if k not in ('SeekPlan', 'DecoderSeek', 'decode_start', 'decoder_seek')]
    t, names = rust_tests(os.path.join(R, 'source_decode.rs'), retired, kept)
    out['tests'] = dict(lines=t, names=names)
    dl = open(D).read().splitlines()
    for decl, c in DART:
        i = find(dl, decl)
        a, b = span(dl, i)
        out['dart'].append(dict(item=decl, correction=c, lines=b - a + 1, at=i + 1))
    for name, c, verdict in VECTORS:
        p = L.resource(name)
        out['vectors'].append(dict(file=name, correction=c, verdict=verdict,
                                   lines=len(open(p).read().splitlines())))
    py = open(os.path.join(L.HERE, 'pktlib.py')).read().splitlines()
    for what, fn, factor in NEW:
        i = find(py, f'def {fn}(')
        b = i + 1
        while b < len(py) and (py[b].startswith(' ') or not py[b].strip()):
            b += 1
        while not py[b - 1].strip():
            b -= 1
        out['new'].append(dict(what=what, python_lines=b - i, rust_estimate=(b - i) * factor))
    # Plumbing has no Python counterpart here: the index has to reach every
    # decoder like the plan does today (a fill in main.rs, a job field, the
    # widened scan's parse). Estimated as the size of what it replaces.
    plan_fill = next(r['lines'] for r in out['rust'] if r['item'] == 'fn fill_seek_plan')
    out['new'].append(dict(what='fill + carry the index (as fill_seek_plan + SeekPlan do today)',
                           python_lines=None, rust_estimate=plan_fill + 13))
    md = open(os.path.join(L.REPO, 'CLAUDE.md')).read().splitlines()
    i = find(md, '- **MPEG-TS/PS seek a GOP early and trim to the frame (issue #169).**')
    j = find(md, '- **An AVI lands on frame N too (issue #173).**')
    out['claude_md'] = dict(rule='MPEG-TS/PS seek a GOP early (issue #169)', lines=j - i, verdict='rewritten')
    s = lambda v: sum(r['lines'] for r in out['rust'] if r['verdict'] == v)
    out['summary'] = dict(rust_retired=s('retired'), rust_simplified=s('simplified'),
                          rust_unchanged=s('unchanged'), rust_tests_retired=t,
                          dart_twins=sum(r['lines'] for r in out['dart']),
                          dart_twins_c1=sum(r['lines'] for r in out['dart'] if r['correction'] == C1),
                          new_rust_estimate=sum(r['rust_estimate'] for r in out['new']))
    json.dump(out, open(os.path.join(L.DATA, 'retire.json'), 'w'), indent=1)
    print(json.dumps(out['summary'], indent=1))
    for r in out['rust']:
        print(f"{r['verdict']:10s} {r['lines']:4d}  {r['file']}:{r['at']} {r['item']}")


if __name__ == '__main__':
    main()
