// The plugins' format limits, measured against the deps bundle, and the one
// helper the template runs a plugin outside them with (task #48).
//
//   * Scripts/probe-plugin-formats.py runs every plugin call the template
//     makes at every format a pass can be handed and writes
//     Tests/TestResources/plugin_format_table.json.
//   * worker/templates/plugin_formats.py holds a Contract for each plugin that
//     refuses part of that set, and run_within(), which runs the plugin on a
//     copy it accepts and adds back only its change.
//
// This checks the three agree, on the bundle actually installed: the quick
// probe against the table (a deps update that changes a limit fails here,
// naming the cell), the contracts against the table, every template call
// against the probe's list, and run_within() itself on a picture with real
// low bits. The full probe, with the frame-size axis, is the heavy test in
// plugin_format_probe_test.dart. worker/tests/filter_integration_test.rs
// (test_252) keeps contracted plugins inside run_within().
//
// The quick probe and the no-Lut2 check are tagged `heavy` (task
// #84): they check the deps bundle and the probe's own tooling, not code a
// pull request usually changes, so nightly runs them, and ci-test.yml runs
// them only when .github/scripts/deps-sensitive.sh says the run touches the
// bundle, the table or the probe. The other tests here run on every PR.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/deps_version.dart';
import 'support/plugin_probe_runner.dart';
import 'support/worker_harness.dart';

String get _templatesDir => p.join(WorkerHarness.repoRoot, 'worker', 'templates');
String get _probe => p.join(WorkerHarness.repoRoot, 'Scripts', 'probe-plugin-formats.py');
String get _tablePath =>
    p.join(WorkerHarness.repoRoot, 'Tests', 'TestResources', 'plugin_format_table.json');

Map<String, String> get _env => {
      ...WorkerHarness.workerEnv,
      'VAPOURBOX_FFMPEG': WorkerHarness.ffmpegPath,
      'VAPOURBOX_PLATFORM': WorkerHarness.platform,
    };

Future<ProcessResult> _python(List<String> args) =>
    Process.run(WorkerHarness.pythonPath, args, environment: _env);

/// Runs [source] under the bundle's Python with the templates importable and
/// returns what it printed on its last line, as JSON.
Future<dynamic> _pythonJson(String source) async {
  final script = File(p.join(Directory.systemTemp.path, 'vb_pf_${pid}_${source.hashCode}.py'));
  await script.writeAsString(source);
  try {
    final r = await _python([script.path, _templatesDir]);
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
    final lines = (r.stdout as String).trim().split('\n');
    return jsonDecode(lines.last);
  } finally {
    if (script.existsSync()) script.deleteSync();
  }
}

/// Every plugin function the template and its modules name, as
/// `ns.Fn` (core.ns.Fn) or `havsfunc.Fn` (haf.Fn), outside comment lines.
Map<String, String> _templateCalls() {
  final calls = <String, String>{};
  final core = RegExp(r'\bcore\.([a-z]\w*)\.([A-Za-z_]\w*)\b');
  final haf = RegExp(r'\bhaf\.(\w+)\(');
  for (final f in Directory(_templatesDir).listSync().whereType<File>()) {
    final name = p.basename(f.path);
    if (!(name.endsWith('.py') || name.endsWith('.vpy')) || name == 'plugin_formats.py') continue;
    final lines = f.readAsStringSync().replaceAll('\r\n', '\n').split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trimLeft().startsWith('#')) continue;
      for (final m in core.allMatches(lines[i])) {
        if (m.group(1) == 'std' || m.group(1) == 'resize') continue;
        calls.putIfAbsent('${m.group(1)}.${m.group(2)}', () => '$name:${i + 1}');
      }
      for (final m in haf.allMatches(lines[i])) {
        calls.putIfAbsent('havsfunc.${m.group(1)}', () => '$name:${i + 1}');
      }
    }
  }
  return calls;
}

/// Whether [contract]'s width_step / height_step pad the frame of [cell]
/// (`<ss>p<bits>/f<field>/<W>x<H>`): a size refusal its run_within() avoids.
/// A step is luma samples, or 'chroma' (2 << that axis's subsampling).
bool _padsCell(Map<String, dynamic> contract, String cell) {
  final m = RegExp(r'^(\d{3})p\d+/f\d/(\d+)x(\d+)$').firstMatch(cell);
  if (m == null) return false;
  final (sw, sh) = switch (m.group(1)) {
    '420' => (1, 1),
    '422' => (1, 0),
    _ => (0, 0),
  };
  int step(Object? v, int sub) => v == 'chroma' ? 2 << sub : (v as int? ?? 1);
  final w = int.parse(m.group(2)!), h = int.parse(m.group(3)!);
  return w % step(contract['width_step'], sw) != 0 || h % step(contract['height_step'], sh) != 0;
}

/// Whether [cell] is in the reachable set ({420,422,444} x {8,10,12,16}): not
/// a 4:1:1 or 9/14-bit documentation row.
bool _reachable(String cell) {
  final m = RegExp(r'^(\d{3})p(\d+)/').firstMatch(cell);
  return m != null &&
      const ['420', '422', '444'].contains(m.group(1)) &&
      const ['8', '10', '12', '16'].contains(m.group(2));
}

/// Whether a call's summary in the table refuses anything a pass can see.
bool _limited(Map<String, dynamic> s) =>
    s.containsKey('broken') ||
    (s['depths'] as List).length != 4 ||
    (s['subsampling'] as List).length != 3 ||
    s['field_based'] != true ||
    s.containsKey('irregular') ||
    ((s['sizes_refused'] as List?)?.isNotEmpty ?? false);

const _runWithinCheck = r'''
import json, sys
import vapoursynth as vs
core = vs.core
sys.path.insert(0, sys.argv[1])
import plugin_formats as pf
from plugin_formats import Contract, run_within

problems = []
def check(cond, msg):
    if not cond:
        problems.append(msg)

def same(a, b):
    for p in range(a.format.num_planes):
        st = core.std.PlaneStats(a, b, plane=p)
        for n in range(a.num_frames):
            if st.get_frame(n).props['PlaneStatsDiff'] != 0:
                return False
    return True

def low_bits(c):
    # True when the clip uses its depth's lowest two bits: a deep
    # fixture converted from a shallower master has none, and every delta
    # guard is exact on it whatever it does (task #37).
    shallow = c.format.replace(bits_per_sample=c.format.bits_per_sample - 2)
    return not same(c, core.resize.Point(core.resize.Point(c, format=shallow.id), format=c.format.id))

# Grain, then a Bicubic downscale at 16-bit (zimg interpolates in float),
# then each depth by rounding: real content below every depth's last bit.
base = core.std.BlankClip(width=240, height=180, format=vs.YUV444P16, length=4,
                          color=[30000, 32768, 32768])
base = core.grain.Add(base, var=200, uvar=200, constant=False, seed=1)
base = core.resize.Bicubic(base, 160, 120)

pf.CONTRACTS['probe.Min'] = Contract(depths=(8,), min_width=200, min_height=200)
pf.CONTRACTS['probe.Ss422'] = Contract(depths=(8, 10, 12, 16), subsampling=('422', '444'))

def invert_top(c):
    top = core.std.Invert(core.std.Crop(c, bottom=c.height - 16))
    return core.std.StackVertical([top, core.std.Crop(c, top=16)])

for bits in (10, 12, 16):
    for ss, (sw, sh) in (('420', (1, 1)), ('422', (1, 0))):
        for field in (0, 2):
            name = '%sp%d f%d' % (ss, bits, field)
            fmt = core.query_video_format(vs.YUV, vs.INTEGER, bits, sw, sh)
            src = core.std.SetFieldBased(core.resize.Point(base, format=fmt.id), field)
            check(low_bits(src), name + ': the fixture has no low bits')
            seen = {}
            def ident(c):
                seen['bits'] = c.format.bits_per_sample
                seen['field'] = c.get_frame(0).props.get('_FieldBased')
                return c
            out = run_within(src, 'dedot.Dedot', ident)
            check(seen.get('bits') == 8, name + ': Dedot ran at %s bits' % seen.get('bits'))
            check(seen.get('field') == field, name + ': _FieldBased not kept on the work copy')
            check(out.format.id == src.format.id, name + ': format not restored')
            check(same(out, src), name + ': a no-op fn did not give the source back bit for bit')
            check(out.get_frame(0).props.get('_FieldBased') == field, name + ': _FieldBased lost')

            out = run_within(src, 'havsfunc.LUTDeCrawl', ident)
            want = 10 if bits > 10 else bits
            check(seen.get('bits') == want, name + ': LUTDeCrawl ran at %s bits, not %d' % (seen.get('bits'), want))

            out = run_within(src, 'dedot.Dedot', invert_top)
            check(same(core.std.Crop(out, top=16), core.std.Crop(src, top=16)),
                  name + ': samples the fn left alone changed')
            check(not same(core.std.Crop(out, bottom=src.height - 16), core.std.Crop(src, bottom=src.height - 16)),
                  name + ': the fn\'s change was lost')

            if ss == '420':
                out = run_within(src, 'probe.Ss422', ident)
                check(same(out, src), name + ': a no-op fn across a subsampling change was not exact')

            try:
                run_within(src, 'dedot.Dedot', lambda c: c[:2]).get_frame(0)
                check(False, name + ': a fn that drops frames was not refused')
            except vs.Error as e:
                check('frame count' in str(e), name + ': unclear refusal: %s' % e)

            out = run_within(src, 'dedot.Dedot', lambda c: c[:2], delta_only=False)
            check(out.num_frames == 2 and out.format.id == src.format.id, name + ': delta_only=False')

            try:
                run_within(src, 'probe.Min', ident, label='Test Pass')
                check(False, name + ': a too-small frame was not refused')
            except vs.Error as e:
                msg = str(e)
                check('Test Pass' in msg and '200x200' in msg and '160x120' in msg,
                      name + ': unreadable size refusal: %s' % msg)

src8 = core.resize.Point(base, format=vs.YUV420P8)
check(run_within(src8, 'dedot.Dedot', lambda c: c) is src8, '8-bit: an accepted clip must pass through untouched')
try:
    run_within(src8, 'no.Such', lambda c: c)
    check(False, 'a plugin with no contract was accepted')
except vs.Error:
    pass

# run_within (task #87): a depth change alone converts without _FieldBased
# and pads nothing, so on a field-flagged 4:2:0 frame 2 mod 4 high the
# plugin sees the real rows, flag kept, and its change is the native 8-bit
# run's (shifted); a subsampling change still pads to whole field chroma rows.
short8 = core.resize.Bicubic(base, 160, 122, format=vs.YUV420P8)
for fb in (0, 2):
    c8 = core.std.SetFieldBased(short8, fb)
    c16 = core.std.CopyFrameProps(core.std.Expr(c8, 'x 256 *', format=vs.YUV420P16), c8)
    # Every graph run_within builds (pad_around builds both paths while the
    # flag is unknown), with the height and flag fn was handed.
    seen = []
    def look(x):
        seen.append((x.height, x.get_frame(0).props.get('_FieldBased')))
        return x
    out = run_within(c16, 'dedot.Dedot', look)
    name = '160x122 420p16 f%d' % fb
    check(seen == [(122, fb)], name + ': a depth change built %s, not only the real 122 rows' % seen)
    check(same(out, c16), name + ': a no-op fn did not give the source back')
    check(out.get_frame(0).props.get('_FieldBased') == fb, name + ': _FieldBased lost')
    native = core.std.Expr(run_within(c8, 'dedot.Dedot', invert_top), 'x 256 *', format=vs.YUV420P16)
    check(same(run_within(c16, 'dedot.Dedot', invert_top), native),
          name + ': the change differs from the native 8-bit run\'s')
    built = []
    run_within(c16, 'probe.Ss422', lambda x: built.append(x.height) or x).get_frame(0)
    check(124 in built, name + ': a subsampling change built no padded path (%s)' % built)

# pad_around (task #57): a 4:2:0 frame 2 mod 4 high, field-flagged and not.
def rows_equal(c, plane, a, b):
    g = core.std.ShufflePlanes(c, plane, vs.GRAY)
    ra = core.std.Crop(g, top=a, bottom=g.height - a - 1)
    rb = core.std.Crop(g, top=b, bottom=g.height - b - 1)
    return core.std.PlaneStats(ra, rb).get_frame(0).props['PlaneStatsDiff'] == 0

tall = core.resize.Bicubic(base, 160, 122, format=vs.YUV420P10)
for fb in (0, 2):
    c = core.std.SetFieldBased(tall, fb)
    seen = {}
    def grab(x):
        seen['x'] = x
        return x
    out = pf.pad_around(c, grab, height_step=pf.CHROMA)
    p = seen['x']
    check((p.width, p.height) == (160, 124), 'pad_around: padded to %dx%d' % (p.width, p.height))
    check(rows_equal(p, 0, 122, 120) and rows_equal(p, 0, 123, 121) and rows_equal(p, 1, 61, 59),
          'pad_around: the new rows must repeat each field\'s own last row')
    check(p.get_frame(0).props.get('_FieldBased', 0) == fb, 'pad_around: _FieldBased lost')
    check(same(out, c), 'pad_around: a no-op fn did not come back exact (f%d)' % fb)
    # field_based_only: a field-flagged frame takes the padded path, another
    # frame the old one; SeparateFields refuses the unpadded frame.
    split = lambda x: core.std.DoubleWeave(core.std.SeparateFields(x, tff=True), tff=True)[::2]
    out = pf.pad_around(c, split, height_step=pf.CHROMA, field_based_only=True)
    check(same(out, c), 'pad_around(field_based_only): a split and weave did not come back exact (f%d)' % fb)
    marked = {}
    def mark(x):
        marked[x.height] = True
        return x
    pf.pad_around(c, mark, height_step=pf.CHROMA, field_based_only=True)
    check(set(marked) == {122, 124}, 'pad_around(field_based_only): both paths must be built')
fits = core.resize.Bicubic(base, 160, 120, format=vs.YUV420P10)
check(pf.pad_around(fits, lambda x: x, height_step=pf.CHROMA) is fits, 'pad_around: a frame that fits got a node')
try:
    pf.pad_around(tall, lambda x: core.std.Crop(x, bottom=2), height_step=pf.CHROMA, label='Test Pass')
    check(False, 'pad_around: an fn that changes the size was not refused')
except vs.Error as e:
    check('Test Pass' in str(e), 'pad_around: unreadable refusal: %s' % e)
print(json.dumps(problems))
''';

// Task #69: MVTools' AVX2 vector upsizer writes before its buffer with fewer
// than 8 block columns. mvtools_flow_opt() against MVTools' own arithmetic
// (Analyse's nBlkX, grown by Flow* to nBlkXP), then FlowFPS and FlowInter
// through it at the sizes that corrupted the heap on x86: a crash kills this
// process (64x48 crashed 3 runs in 3 on Linux x64 without the guard).
const _flowGuardCheck = r'''
import json, sys
import vapoursynth as vs
core = vs.core
sys.path.insert(0, sys.argv[1])
import plugin_formats as pf

problems = []
table = {(64, 16, 8): False, (65, 16, 8): True, (176, 32, 8): False, (177, 32, 8): True,
         (224, 32, 0): False, (225, 32, 0): True, (128, 32, 16): False, (129, 32, 16): True,
         (96, 16, 8): True, (720, 16, 8): True}
for (w, b, o), want in table.items():
    if pf.mvtools_flow_opt(w, b, o) != want:
        problems.append('mvtools_flow_opt(%d, %d, %d) is %s, not %s' % (w, b, o, not want, want))
for b in (4, 8, 16, 32):
    for o in range(0, b // 2 + 1, 2):
        for w in range(max(16, 2 * b), 400, 2):
            step = b - o
            cols = max((w - o) // step, -(-(w - o) // step))
            if pf.mvtools_flow_opt(w, b, o) != (cols >= 8):
                problems.append('mvtools_flow_opt(%d, %d, %d) disagrees with nBlkXP = %d' % (w, b, o, cols))

base = core.std.BlankClip(width=240, height=180, format=vs.YUV444P16, length=12,
                          color=[30000, 32768, 32768])
base = core.grain.Add(base, var=400, uvar=400, constant=False, seed=1)
for (w, h, b, o) in ((64, 48, 16, 8), (176, 144, 32, 8)):
    for fmt in (vs.YUV420P8, vs.YUV420P16):
        c = core.resize.Bicubic(base, w, h, format=fmt)
        sup = core.mv.Super(c, pel=2)
        bw = core.mv.Analyse(sup, isb=True, blksize=b, overlap=o)
        fw = core.mv.Analyse(sup, isb=False, blksize=b, overlap=o)
        opt = pf.mvtools_flow_opt(c.width, b, o)
        for out in (core.mv.FlowFPS(c, sup, bw, fw, num=60000, den=1001, opt=opt),
                    core.mv.FlowInter(c, sup, bw, fw, time=50.0, opt=opt)):
            for n in range(out.num_frames):
                out.get_frame(n)
print(json.dumps(problems))
''';

// Task #79: havsfunc's QTGMC runs mv.Mask(kind=1) on InputType 2 and 3
// (ProgSADMask, Placebo..Medium) with no opt. Mask writes before its buffer on
// x86 under 4 block columns (AVX2 8-bit upsizer), and fills the rows under its
// block grid with one overlapping memcpy when a row is as wide as its stride,
// so those rows are wrong on every CPU. The template pads QTGMC's input to
// mvtools_mask_cols() through mvtools_blocks(min_cols=). Checked here: the
// helper against MVTools' arithmetic, the mask's bottom rows through the pad,
// and QTGMC through it at the sizes valgrind flagged (an unguarded call
// corrupts the heap on x86 without crashing reliably: valgrind is the
// evidence, docs/reports/task-79-qtgmc-mask-avx2).
const _maskGuardCheck = r'''
import json, sys
import vapoursynth as vs
core = vs.core
sys.path.insert(0, sys.argv[1])
import plugin_formats as pf
import havsfunc as haf

problems = []
def check(cond, msg):
    if not cond:
        problems.append(msg)

for b in (4, 8, 16, 32):
    for o in range(0, min(16, b // 2) + 1, 2):
        step = b - o
        for w in range(16, 400, 2):
            for h in (48, 66, 96, 100, 120, 486):
                got = pf.mvtools_mask_cols(w, h, b, o)
                pw = max(got, pf.MVTOOLS_MIN_COLS, w)   # what mvtools_blocks pads to
                ph = max(h, pf.MVTOOLS_MIN_ROWS)
                if (pw - o) // step < 4:
                    problems.append('mvtools_mask_cols(%d, %d, %d, %d) = %d: %d block columns'
                                    % (w, h, b, o, got, (pw - o) // step))
                if (ph - o) % step and pw % 32 == 0:
                    problems.append('mvtools_mask_cols(%d, %d, %d, %d) = %d: a row fills a 32-byte stride above a short grid'
                                    % (w, h, b, o, got))
                needs = (max(w, 64) - o) // step < 4 or ((ph - o) % step and max(w, 64) % 32 == 0)
                if not needs and got != w:
                    problems.append('mvtools_mask_cols(%d, %d, %d, %d) = %d: padded a picture that needs nothing'
                                    % (w, h, b, o, got))

base = core.std.BlankClip(width=320, height=240, format=vs.YUV444P16, length=8,
                          color=[30000, 32768, 32768])
base = core.grain.Add(base, var=400, uvar=400, constant=False, seed=1)

# The mask's rows under the block grid must repeat the grid's last row.
for (w, h, b, o) in ((128, 96, 32, 8), (256, 196, 32, 8), (64, 96, 32, 16), (120, 100, 32, 0)):
    src = core.resize.Bicubic(base, w, h, format=vs.YUV420P8)
    masks = []
    def mask(x, b=b, o=o):
        sup = core.mv.Super(x, pel=2)
        bv = core.mv.Analyse(sup, isb=True, blksize=b, overlap=o)
        masks.append(core.mv.Mask(x, bv, kind=1, ml=10, thscd1=16320))
        return x
    pf.mvtools_blocks(src, mask, min_cols=pf.mvtools_mask_cols(w, h, b, o))
    m = masks[0]
    hb = (m.height - o) // (b - o) * (b - o) + o
    for n in range(1, 6):
        y = bytes(m.get_frame(n)[0])
        row = lambda r: y[r * m.width:(r + 1) * m.width]
        bad = sum(1 for r in range(hb, m.height) if row(r) != row(hb - 1))
        check(bad == 0, '%dx%d at %d/%d (padded %d wide): %d mask rows under the grid wrong, frame %d'
              % (w, h, b, o, m.width, bad, n))

for fmt in (vs.YUV420P8, vs.YUV444P8):
    src = core.resize.Bicubic(base, 64, 96, format=fmt)
    for input_type in (2, 3):
        for o in (0, 8, 16):
            out = pf.mvtools_blocks(
                src,
                lambda x: haf.QTGMC(x, Preset='Slow', InputType=input_type, BlockSize=32, Overlap=o, TFF=True),
                min_cols=pf.mvtools_mask_cols(src.width, src.height, 32, o))
            check((out.width, out.height) == (64, 96), 'QTGMC through the pad: %dx%d' % (out.width, out.height))
            for n in range(out.num_frames):
                out.get_frame(n)
print(json.dumps(problems))
''';

// Task #89: MVTools' Mask refuses a clip above 8 bits, so havsfunc's QTGMC
// failed every 10-16-bit job at InputType 2/3, Placebo..Medium (ProgSADMask).
// plugin_formats.havsfunc_mask_any_depth runs that Mask on an 8-bit stand-in
// with ml x 2^(bits - 8). Checked here against the bundle: on a deep picture
// that is an 8-bit one shifted, the stand-in's mask is the 8-bit mask on the
// deep scale, sample for sample; QTGMC through the helper runs at every
// depth while the bare call still refuses (when MVTools accepts deep clips,
// this fails and the helper can go); an 8-bit job through the helper is the
// plain call's picture; havsfunc's core is restored after the call, an
// error included (docs/reports/task-89-qtgmc-mask-high-bit-depth).
const _maskAnyDepthCheck = r'''
import json, sys
import vapoursynth as vs
core = vs.core
sys.path.insert(0, sys.argv[1])
import plugin_formats as pf
import havsfunc as haf

problems = []
def check(cond, msg):
    if not cond:
        problems.append(msg)

def max_diff(a, b):
    # Largest |a - b| over every plane and frame.
    d = core.std.Expr([a, b], 'x y - abs')
    worst = 0
    for p in range(a.format.num_planes):
        s = core.std.PlaneStats(d, plane=p)
        for n in range(a.num_frames):
            worst = max(worst, s.get_frame(n).props['PlaneStatsMax'])
    return worst

# A textured picture panning 3 px right and 1 down a frame: real vectors and
# SADs, and no frame near MVTools' scene-change thresholds (grain on a flat
# picture put one there, which deep vectors decided differently even for an
# 8-bit clip: MVTools' own depth rounding, not the stand-in's).
tex = core.std.BlankClip(width=180, height=120, format=vs.YUV444P8, length=1, color=[128, 128, 128])
tex = core.std.BoxBlur(core.grain.Add(tex, var=2500, uvar=400, constant=True, seed=1), hradius=1, vradius=1)
src8 = core.std.Splice([core.std.CropAbs(tex, 128, 96, left=3 * n, top=n) for n in range(6)])
src8 = core.resize.Bicubic(src8, format=vs.YUV422P8)
base = core.resize.Point(src8, format=vs.YUV444P16)

# pel=1: each SAD of the shifted picture is then exactly 2^(bits - 8) times
# the 8-bit one. With pel=2 the half-pel planes round at each depth, so the
# deep SAD differs (up to 10 mask levels here) as it would for a native deep
# Mask too: that is MVTools' interpolation, not the stand-in.
def vectors(c):
    return core.mv.Analyse(core.mv.Super(c, pel=1), isb=True, blksize=16, overlap=8)

# The stand-in's mask on a picture that is an 8-bit one shifted (limited range,
# Point: an exact x 2^(bits - 8)) is the 8-bit mask put on the deep scale.
v8 = vectors(src8)
for kind in (0, 1, 3):
    m8 = core.mv.Mask(src8, v8, kind=kind, ml=10)
    check(pf.mvtools_mask_any_depth(src8, v8, kind=kind, ml=10).format.id == m8.format.id,
          'an 8-bit clip must reach Mask unchanged')
    for bits in (10, 16):
        deep = core.resize.Point(src8, format=src8.format.replace(bits_per_sample=bits).id)
        got = pf.mvtools_mask_any_depth(deep, vectors(deep), kind=kind, ml=10)
        want = core.std.Expr(m8, 'x %d * 255 /' % ((1 << bits) - 1), format=got.format.id)
        check(got.format.bits_per_sample == bits, 'kind %d at %d bits: mask came back %s'
              % (kind, bits, got.format.name))
        diff = max_diff(got, want)
        check(diff == 0, 'kind %d at %d bits: the stand-in mask is %d off the 8-bit mask'
              % (kind, bits, diff))
    if kind == 1:
        avg = sum(core.std.PlaneStats(m8).get_frame(n).props['PlaneStatsAverage'] for n in range(m8.num_frames)) / m8.num_frames
        check(0.02 < avg < 0.98, 'the SAD mask is flat (%.3f): the picture no longer tests it' % avg)

def qtgmc(c, it=2):
    return pf.mvtools_blocks(
        c, lambda x: haf.QTGMC(x, Preset='Medium', InputType=it, TFF=True),
        min_cols=pf.mvtools_mask_cols(c.width, c.height, 16, 8))

wrapped = pf.havsfunc_mask_any_depth(haf, qtgmc)
for fmt in (vs.YUV420P10, vs.YUV422P10, vs.YUV420P16):
    c = core.resize.Bicubic(base, format=fmt)
    try:
        out = wrapped(c)
        check(out.format.id == c.format.id, '%s: QTGMC through the helper came back %s'
              % (c.format.name, out.format.name))
        for n in range(out.num_frames):
            out.get_frame(n)
    except vs.Error as e:
        problems.append('%s: QTGMC InputType 2 through the helper failed: %s' % (c.format.name, e))
    try:
        bare = qtgmc(c)
        bare.get_frame(0)
        problems.append('%s: the bare QTGMC InputType 2 call now runs; MVTools may accept deep '
                        'clips, so havsfunc_mask_any_depth may be unneeded (task #89)' % c.format.name)
    except vs.Error as e:
        check('Mask' in str(e), '%s: the bare call failed, but not on Mask: %s' % (c.format.name, e))

saved = haf.core
check(max_diff(pf.havsfunc_mask_any_depth(haf, lambda c: qtgmc(c, 3))(src8), qtgmc(src8, 3)) == 0,
      '8-bit QTGMC InputType 3 through the helper differs from the plain call')
check(haf.core is saved, "havsfunc's core was not restored")
def fails(c):
    raise RuntimeError('boom')
try:
    pf.havsfunc_mask_any_depth(haf, fails)(src8)
except RuntimeError:
    pass
check(haf.core is saved, "havsfunc's core was not restored after an error")
print(json.dumps(problems))
''';

// LUTDeCrawl and LUTDeRainbow used to AND their masks through eight
// Lut2(function=lambda x, y: x & y) tables, a million Python calls each at 10
// bits: 80% of the quick probe, and the full probe never finished on macOS x64
// (task #75, which memoised them in the probe). Havsfunc patch 8 (deps
// 1.18.0-rc3, task #82) made them Expr 'x y min', leaving havsfunc no Lut2
// call, so the memo was retired (task #104). This checks the probe's own LUT
// calls, and the branches they don't take (linkUV=False, mask=True), make no
// Lut2 call at all: one coming back would make the probe slow again, silently.
// vapoursynth_integration_test's patch-8 test checks the picture.
const _noLut2Check = r'''
import importlib.util, json, sys
import vapoursynth as vs
core = vs.core
spec = importlib.util.spec_from_file_location('probe', sys.argv[1])
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
sys.path.insert(0, sys.argv[2])
import havsfunc as haf

problems = []
if not hasattr(haf, '_mask_and'):
    problems.append('havsfunc lacks patch 8 (no _mask_and) on a bundle from 1.18.0-rc3 on (task #82)')

calls = []

class _CountingStd:
    def __init__(self, std):
        self._std = std
    def __getattr__(self, name):
        fn = getattr(self._std, name)
        if name != 'Lut2':
            return fn
        def lut2(*args, **kw):
            calls.append(name)
            return fn(*args, **kw)
        return lut2

class _CountingCore:
    def __init__(self, c):
        self._core = c
        self.std = _CountingStd(c.std)
    def __getattr__(self, name):
        return getattr(self._core, name)

probe_calls = probe._calls()
runs = {key: probe_calls[key]['run'] for key in probe.LUT_CALLS}
runs['havsfunc.LUTDeCrawl mask'] = lambda c: haf.LUTDeCrawl(c, ythresh=10, cthresh=10, maxdiff=50, mask=True)
runs['havsfunc.LUTDeRainbow mask'] = lambda c: haf.LUTDeRainbow(c, cthresh=10, ythresh=10, y=True, linkUV=True, mask=True)
runs['havsfunc.LUTDeRainbow unlinked'] = lambda c: haf.LUTDeRainbow(c, cthresh=10, ythresh=10, y=True, linkUV=False)
runs['havsfunc.LUTDeRainbow unlinked mask'] = lambda c: haf.LUTDeRainbow(c, cthresh=10, ythresh=10, y=True, linkUV=False, mask=True)

original = haf.core
haf.core = _CountingCore(original)
try:
    for fmt in (vs.YUV420P8, vs.YUV420P10):
        c = core.std.BlankClip(width=64, height=48, format=fmt, length=3)
        c = core.grain.Add(c, var=800, uvar=800, constant=False, seed=1)
        for label, run in runs.items():
            del calls[:]
            run(c).get_frame(1)
            if calls:
                problems.append('%s at %s made %d Lut2 call(s): the probe builds Python tables again'
                                % (label, c.format.name, len(calls)))
finally:
    haf.core = original
print(json.dumps(problems))
''';

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
  });

  late Map<String, dynamic> table;
  setUpAll(() {
    table = jsonDecode(File(_tablePath).readAsStringSync()) as Map<String, dynamic>;
  });

  test('every plugin call in the template is probed or listed as not probed', () async {
    final r = await _python([_probe, '--list']);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    final list = jsonDecode(r.stdout as String) as Map<String, dynamic>;
    final covered = <String>{
      for (final covers in (list['calls'] as Map).values) ...(covers as List).cast<String>(),
    };
    final notProbed = (list['not_probed'] as Map).keys.cast<String>().toSet();
    final calls = _templateCalls();
    expect(calls.length, greaterThan(60), reason: 'the scan found too few calls');

    final missing = [
      for (final MapEntry(key: call, value: at) in calls.entries)
        if (!covered.contains(call) && !notProbed.contains(call)) '$call ($at)',
    ];
    expect(missing, isEmpty,
        reason: 'add these to CALLS in Scripts/probe-plugin-formats.py (with the template\'s '
            'arguments) and re-run it, or to NOT_PROBED with a reason:\n${missing.join('\n')}');
    final stale = [...covered, ...notProbed].where((c) => !calls.containsKey(c)).toList();
    expect(stale, isEmpty, reason: 'the probe lists calls the template no longer makes: $stale');
    // Every probe entry is in the committed table.
    expect((table['calls'] as Map).keys.toSet(), (list['calls'] as Map).keys.toSet(),
        reason: 're-run the probe with --out ${p.relative(_tablePath, from: WorkerHarness.repoRoot)}');
  });

  test('plugin_formats.CONTRACTS states what the table measured', () async {
    final code = await _pythonJson('''
import json, sys
sys.path.insert(0, sys.argv[1])
import plugin_formats as pf
print(json.dumps({'contracts': {k: dict(v._asdict()) for k, v in pf.CONTRACTS.items()},
                  'handled': pf.HANDLED, 'known': pf.KNOWN}))
''') as Map<String, dynamic>;
    final contracts = (code['contracts'] as Map).cast<String, dynamic>();
    final handled = (code['handled'] as Map).cast<String, dynamic>();
    final known = (code['known'] as Map).cast<String, dynamic>();
    final calls = (table['calls'] as Map).cast<String, dynamic>();
    final problems = <String>[];

    for (final MapEntry(key: key, value: c) in contracts.entries) {
      final s = (calls[key] as Map?)?['summary'] as Map<String, dynamic>?;
      if (s == null) {
        problems.add('$key: has a contract but no probe entry');
        continue;
      }
      final depths = (c['depths'] as List).cast<int>();
      if (depths.join(',') != (s['depths'] as List).join(',')) {
        problems.add('$key: contract depths $depths, the bundle accepts ${s['depths']}');
      }
      final subs = (c['subsampling'] as List).cast<String>()..sort();
      if (subs.join(',') != ((s['subsampling'] as List).cast<String>()..sort()).join(',')) {
        problems.add('$key: contract subsampling $subs, the bundle accepts ${s['subsampling']}');
      }
      // Task #57: every reachable cell runs through run_within(), which
      // converts and pads to the contract.
      final within = (s['within_refused'] as List?)?.cast<String>();
      if (within == null) {
        problems.add('$key: the table has no run_within() measurement; re-run the probe on it');
      } else if (within.isNotEmpty && !handled.containsKey(key)) {
        // A HANDLED key's refusals beyond its contract are met by the pass,
        // not by run_within() (DeScratch: field-flagged 4:2:0 runs on a
        // 4:2:2 carrier, measured as pass.DeScratch).
        problems.add('$key: refused through run_within() at ${within.join(', ')}');
      }
    }
    for (final MapEntry(key: key, value: entry) in calls.entries) {
      final s = (entry as Map)['summary'] as Map<String, dynamic>;
      if (!_limited(s)) continue;
      final depthOrSs = (s['depths'] as List?)?.length != 4 || (s['subsampling'] as List?)?.length != 3;
      final contract = contracts[key] as Map<String, dynamic>?;
      final unpadded = ((s['sizes_refused'] as List?) ?? const [])
          .cast<String>()
          .where((cell) => contract == null || !_padsCell(contract, cell));
      final other = s.containsKey('broken') ||
          s['field_based'] != true ||
          s.containsKey('irregular') ||
          unpadded.isNotEmpty;
      if (depthOrSs && !contracts.containsKey(key) && !handled.containsKey(key)) {
        problems.add('$key: refuses ${s['depths']} x ${s['subsampling']} but has no contract');
      }
      if (other && !handled.containsKey(key) && !known.containsKey(key)) {
        problems.add('$key: refuses part of the reachable set ($s) that no contract expresses; '
            'handle it in its pass and say how in plugin_formats.HANDLED, or file a task and '
            'list it in plugin_formats.KNOWN');
      }
    }
    // Task #81: the summaries are one platform's (the table is written on
    // macOS arm64). A refusal only another bundle shows is a `platforms`
    // override, and must be met the same way: padded by a contract (and fine
    // through run_within() where measured), or handled / known. znedi3's odd
    // plane on x86 was recorded nowhere a check read.
    final platforms = ((table['platforms'] as Map?) ?? const {}).cast<String, dynamic>();
    for (final MapEntry(key: plat, value: byCall) in platforms.entries) {
      for (final MapEntry(key: key, value: cells) in (byCall as Map).cast<String, dynamic>().entries) {
        for (final MapEntry(key: cell, value: res) in (cells as Map).cast<String, dynamic>().entries) {
          final r = (res as Map).cast<String, dynamic>();
          if (r['ok'] == true || !_reachable(cell)) continue;
          if (handled.containsKey(key) || known.containsKey(key)) continue;
          final contract = contracts[key] as Map<String, dynamic>?;
          if (contract == null || !_padsCell(contract, cell)) {
            problems.add('$key $cell: refused on $plat (${r['error']}) and no contract pads it; '
                'pad it with a contract, or handle it in its pass and list it in '
                'plugin_formats.HANDLED, or file a task and list it in KNOWN');
          } else if (r.containsKey('within') && r['within'] != 'ok') {
            problems.add('$key $cell: refused on $plat through run_within() too (${r['within']})');
          }
        }
      }
    }
    for (final key in handled.keys) {
      if (!calls.containsKey(key)) problems.add('$key: in HANDLED but not probed');
    }
    for (final key in known.keys) {
      final s = (calls[key] as Map?)?['summary'] as Map<String, dynamic>?;
      if (s == null) {
        problems.add('$key: in KNOWN but not probed');
      } else if (!_limited(s) ||
          (contracts.containsKey(key) &&
              s['field_based'] == true &&
              !s.containsKey('irregular') &&
              ((s['sizes_refused'] as List?) ?? const [])
                  .cast<String>()
                  .every((cell) => _padsCell(contracts[key] as Map<String, dynamic>, cell)))) {
        problems.add('$key: in KNOWN, but the bundle now accepts everything, or its contract '
            'pads every size it refuses; remove it (and close its task if this was the fix)');
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  // macOS x64 is the slowest: 442-857 s while havsfunc's LUTDeCrawl/LUTDeRainbow
  // built Python Lut2 tables in every cell (80% of it; task #75 memoised them,
  // patch 8 removed them from deps 1.18.0-rc3, task #82).
  // The probe stops itself 90 s before this (--budget) and says which calls
  // were still running.
  const quickTimeout = Duration(minutes: 15);
  test('the bundle still refuses exactly what the table says (quick probe)', () async {
    final r = await runPluginProbe(['--quick', '--check', _tablePath], timeout: quickTimeout);
    expect(r.exitCode, 0,
        reason: 'the bundle disagrees with ${p.basename(_tablePath)}. If a deps update changed a '
            'plugin\'s limits, re-run Scripts/probe-plugin-formats.py --out on every platform, '
            'then update plugin_formats.CONTRACTS and the report. Exit 3 is --budget: the probe '
            'ran out of time and says which calls were still running:\n${r.report}');
  }, tags: ['heavy'], timeout: const Timeout(quickTimeout));

  test('havsfunc makes no Lut2 call, so the probe\'s LUT cells build no Python tables '
      '(task #104; patch 8, task #82)', () async {
    if (depsVersionBefore(WorkerHarness.depsDir, '1.18.0-rc3')) {
      markTestSkipped('deps before 1.18.0-rc3 ship havsfunc without patch 8: its LUTDeCrawl/'
          'LUTDeRainbow still build Python Lut2 tables, which the probe no longer memoises');
      return;
    }
    final script = File(p.join(Directory.systemTemp.path, 'vb_nolut2_$pid.py'));
    await script.writeAsString(_noLut2Check);
    try {
      final r = await _python([script.path, _probe, _templatesDir]);
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
      final problems = jsonDecode((r.stdout as String).trim().split('\n').last) as List;
      expect(problems, isEmpty, reason: problems.join('\n'));
    } finally {
      if (script.existsSync()) script.deleteSync();
    }
  }, tags: ['heavy'], timeout: const Timeout(Duration(minutes: 1)));

  test('MVTools Flow calls avoid the AVX2 upsizer below 8 block columns (task #69)', () async {
    final problems = await _pythonJson(_flowGuardCheck) as List;
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('QTGMC InputType 2/3 pads past MVTools Mask\'s faults (task #79)', () async {
    final problems = await _pythonJson(_maskGuardCheck) as List;
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('QTGMC InputType 2/3 runs MVTools Mask at every depth on an 8-bit stand-in (task #89)', () async {
    final problems = await _pythonJson(_maskAnyDepthCheck) as List;
    expect(problems, isEmpty, reason: problems.join('\n'));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('run_within keeps every sample the plugin leaves alone, and refuses clearly', () async {
    final problems = await _pythonJson(_runWithinCheck) as List;
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
