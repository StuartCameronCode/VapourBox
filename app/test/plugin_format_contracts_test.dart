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

  test('the bundle still refuses exactly what the table says (quick probe)', () async {
    final sw = Stopwatch()..start();
    final r = await _python([_probe, '--quick', '--check', _tablePath, '--ffmpeg', WorkerHarness.ffmpegPath]);
    // ignore: avoid_print
    print('  quick probe: ${sw.elapsed.inSeconds} s');
    expect(r.exitCode, 0,
        reason: 'the bundle disagrees with ${p.basename(_tablePath)}. If a deps update changed a '
            'plugin\'s limits, re-run Scripts/probe-plugin-formats.py --out on every platform, '
            'then update plugin_formats.CONTRACTS and the report:\n${r.stdout}\n${r.stderr}');
    // 30 min: with task #56's padded cells it took 550 s -> ~800 s on the
    // push gate's runners and passed 15 min on macOS x64 (Intel).
  }, timeout: const Timeout(Duration(minutes: 30)));

  test('run_within keeps every sample the plugin leaves alone, and refuses clearly', () async {
    final problems = await _pythonJson(_runWithinCheck) as List;
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
