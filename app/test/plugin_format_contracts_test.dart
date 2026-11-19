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
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

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

// The probe evaluates havsfunc's pure Lut2 functions into one list per
// process (task #75: 7.7 s -> 1.1 s per 10-bit LUTDeCrawl cell on an M1). The list must
// give the same picture and format as the function, a function that reads
// anything but its arguments must pass through, and havsfunc's own calls must
// still take the memo (else the probe is slow again, silently).
const _lutMemoCheck = r'''
import importlib.util, json, sys
import vapoursynth as vs
core = vs.core
spec = importlib.util.spec_from_file_location('probe', sys.argv[1])
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
sys.path.insert(0, sys.argv[2])

problems = []
def check(cond, msg):
    if not cond:
        problems.append(msg)

def same(a, b):
    if a.format.id != b.format.id or (a.width, a.height, a.num_frames) != (b.width, b.height, b.num_frames):
        return False
    for p in range(a.format.num_planes):
        st = core.std.PlaneStats(a, b, plane=p)
        for n in range(a.num_frames):
            if st.get_frame(n).props['PlaneStatsDiff'] != 0:
                return False
    return True

def clip(fmt, seed):
    c = core.std.BlankClip(width=64, height=48, format=fmt, length=3)
    return core.grain.Add(c, var=800, uvar=800, constant=False, seed=seed)

memo = probe._LutMemoCore(core)
asym8 = lambda x, y: (x * 3 + (y >> 1)) & 255
asym10 = lambda x, y: (x * 3 + (y >> 1)) & 1023
# Mixed depths pin the index order both ways (x + (y << bits_a)) at a quarter
# of a 10x10 table's cost: the reference is built the slow way, which takes
# seconds per 10-bit table on the Intel runners.
for fa, fb, f in ((vs.GRAY8, vs.GRAY8, asym8), (vs.GRAY8, vs.GRAY10, asym8),
                  (vs.YUV420P10, vs.YUV420P8, asym10)):
    a, b = clip(fa, 1), clip(fb, 2)
    n = len(memo.std.tables)
    got = memo.std.Lut2(a, b, function=f)
    check(len(memo.std.tables) == n + 1, '%s x %s: the memo was not used' % (a.format.name, b.format.name))
    check(same(got, core.std.Lut2(a, b, function=f)),
          '%s x %s: the list differs from the function' % (a.format.name, b.format.name))
a, b = clip(vs.YUV420P8, 1), clip(vs.YUV420P8, 2)
check(same(memo.std.Lut2(clipa=a, clipb=b, function=asym8, planes=[0]), core.std.Lut2(a, b, function=asym8, planes=[0])),
      'keywords and planes: the list differs')

t = 5
n = len(memo.std.tables)
a = clip(vs.GRAY8, 3)
check(same(memo.std.Lut2(a, a, function=lambda x, y: (x + t) & 255),
           core.std.Lut2(a, a, function=lambda x, y: (x + t) & 255)), 'a closure changed the picture')
check(same(memo.std.Lut2(a, a, function=lambda x, y: max(x, y)), core.std.Lut2(a, a, function=lambda x, y: max(x, y))),
      'a function naming a global changed the picture')
check(len(memo.std.tables) == n, 'a function that reads more than its arguments was memoised')

import havsfunc as haf
src = clip(vs.YUV420P8, 4)
want = haf.LUTDeCrawl(src, ythresh=10, cthresh=10, maxdiff=50)
shim = probe.memo_havsfunc_luts()
got = haf.LUTDeCrawl(src, ythresh=10, cthresh=10, maxdiff=50)
check(len(shim.std.tables) > 0, 'havsfunc.LUTDeCrawl no longer goes through the memo: the probe is slow again')
check(same(got, want), 'havsfunc.LUTDeCrawl through the memo differs')
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

  // macOS x64 is the slowest: 442-857 s before task #75 evaluated havsfunc's
  // Lut2 tables once per process (LUTDeCrawl/LUTDeRainbow were 80% of it).
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
  }, timeout: const Timeout(quickTimeout));

  test('the probe\'s Lut2 memo gives exactly what havsfunc\'s functions give (task #75)', () async {
    final script = File(p.join(Directory.systemTemp.path, 'vb_lutmemo_$pid.py'));
    await script.writeAsString(_lutMemoCheck);
    try {
      final r = await _python([script.path, _probe, _templatesDir]);
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
      final problems = jsonDecode((r.stdout as String).trim().split('\n').last) as List;
      expect(problems, isEmpty, reason: problems.join('\n'));
    } finally {
      if (script.existsSync()) script.deleteSync();
    }
    // About 6 s on an M1; the reference tables are much slower on the Intel runners.
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('MVTools Flow calls avoid the AVX2 upsizer below 8 block columns (task #69)', () async {
    final problems = await _pythonJson(_flowGuardCheck) as List;
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('run_within keeps every sample the plugin leaves alone, and refuses clearly', () async {
    final problems = await _pythonJson(_runWithinCheck) as List;
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
