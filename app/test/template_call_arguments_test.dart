// Every keyword argument the scripts pass to a function must be one that
// function takes, in the deps bundle actually shipped:
//
//   * havsfunc: read from havsfunc.py's `def` lines;
//   * native plugins: read from the loaded core's own signatures, through
//     vspipe, for every namespace this platform's bundle autoloads.
//
// Task #42 found two such arguments the scripts had passed for months:
// QTGMC was offered Str, Amp, FastMA, ESearchP and RefineMotion (SMDegrain's
// and AviSynth QTGMC's names), and Blocksize instead of BlockSize. havsfunc's
// QTGMC has no **kwargs, so setting any of them in Deinterlace's advanced
// settings failed every encode with "unexpected keyword argument". Nothing
// caught it: the Rust tests only inspect the generated script, defaults leave
// those arguments out, and the preview template had (by drift) never passed
// the five. This checks names, whatever value they would take.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/python_calls.dart';
import 'support/worker_harness.dart';

/// havsfunc's top-level functions: name -> (parameter names, takes **kwargs).
Map<String, ({Set<String> params, bool kwargs})> _havsfuncSignatures(String src) {
  final out = <String, ({Set<String> params, bool kwargs})>{};
  for (final m in RegExp(r'^def (\w+)\(', multiLine: true).allMatches(src)) {
    final names = <String>{};
    var kwargs = false;
    for (final a in topLevelArgs(balancedArgs(src, m.end - 1))) {
      if (a.startsWith('**')) {
        kwargs = true;
      } else if (!a.startsWith('*')) {
        names.add(a.split('=').first.split(':').first.trim());
      }
    }
    out[m.group(1)!] = (params: names, kwargs: kwargs);
  }
  return out;
}

String get _templatesDir => p.join(WorkerHarness.repoRoot, 'worker', 'templates');

/// The script template and every Python module beside it, by file name.
Map<String, String> _sources() => {
      for (final f in Directory(_templatesDir).listSync().whereType<File>())
        if (f.path.endsWith('.vpy') || f.path.endsWith('.py'))
          p.basename(f.path): f.readAsStringSync().replaceAll('\r\n', '\n'),
    };

void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
  });

  group('havsfunc', () {
    late Map<String, ({Set<String> params, bool kwargs})> havsfunc;

    setUpAll(() {
      final found = Directory(WorkerHarness.depsDir)
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((f) => p.basename(f.path) == 'havsfunc.py')
          .toList();
      expect(found, isNotEmpty, reason: 'no havsfunc.py under ${WorkerHarness.depsDir}');
      havsfunc = _havsfuncSignatures(found.first.readAsStringSync());
    });

    test('the signature parser reads a known function', () {
      final qtgmc = havsfunc['QTGMC'];
      expect(qtgmc, isNotNull);
      expect(qtgmc!.params, containsAll(['Input', 'Preset', 'TFF', 'FPSDivisor', 'BlockSize', 'opencl']));
      expect(qtgmc.params, isNot(contains('Str')));
      expect(qtgmc.kwargs, isFalse);
    });

    test('every havsfunc call in the templates uses only that function\'s parameters', () {
      final problems = <String>[];
      var count = 0;
      for (final MapEntry(key: file, value: src) in _sources().entries) {
        for (final call in pythonCalls(src, RegExp(r'\bhaf\.(\w+)\('))) {
          count++;
          final sig = havsfunc[call.name];
          if (sig == null) {
            problems.add('$file:${call.line}: haf.${call.name} is not in the bundled havsfunc');
          } else if (!sig.kwargs) {
            for (final k in call.keywords.where((k) => !sig.params.contains(k))) {
              problems.add('$file:${call.line}: haf.${call.name} does not take $k=');
            }
          }
        }
      }
      expect(count, greaterThan(15), reason: 'the scan found too few havsfunc calls');
      expect(problems, isEmpty, reason: problems.join('\n'));
    });
  });

  test('every native plugin call in the templates uses only that function\'s arguments', () async {
    // Ask the bundle's own core for every function's signature.
    final script = File(p.join(Directory.systemTemp.path, 'vb_signatures_${pid}.vpy'));
    await script.writeAsString('''
import sys
import vapoursynth as vs
core = vs.core
for _pl in core.plugins():
    for _fn in _pl.functions():
        sys.stderr.write("SIG\\t%s.%s\\t%s\\n" % (_pl.namespace, _fn.name, _fn.signature))
sys.stderr.flush()
core.std.BlankClip().set_output()
''');
    final vspipe = Platform.isWindows
        ? p.join(WorkerHarness.depsDir, 'vapoursynth', 'Lib', 'site-packages', 'vapoursynth', 'vspipe.exe')
        : p.join(WorkerHarness.depsDir, 'vapoursynth', 'vspipe');
    final ProcessResult r;
    try {
      r = await Process.run(vspipe, ['-i', script.path, '-'], environment: WorkerHarness.workerEnv);
    } finally {
      if (script.existsSync()) script.deleteSync();
    }
    expect(r.exitCode, 0, reason: '${r.stderr}');

    // "clip:vnode;width:int:opt;..." -> {clip, width}; "any" takes anything.
    final signatures = <String, Set<String>?>{};
    // Trim: on Windows each line ends in \r, which made the last argument of
    // `clip:vnode;any` read as "any\r" and SetFrameProps look strict.
    for (final line in (r.stderr as String).split('\n')) {
      final parts = line.trimRight().split('\t');
      if (parts.length != 3 || parts[0] != 'SIG') continue;
      final args = parts[2].split(';').where((a) => a.isNotEmpty).map((a) => a.split(':').first).toSet();
      signatures[parts[1]] = args.contains('any') ? null : args;
    }
    expect(signatures['std.BlankClip'], contains('length'), reason: 'signatures were not read');
    final namespaces = signatures.keys.map((k) => k.split('.').first).toSet();

    final problems = <String>[];
    final notLoaded = <String>{};
    var checked = 0;
    for (final MapEntry(key: file, value: src) in _sources().entries) {
      for (final call in pythonCalls(src, RegExp(r'\bcore\.(\w+\.\w+)\('))) {
        final ns = call.name.split('.').first;
        if (!namespaces.contains(ns)) {
          // Loaded explicitly (rife, ncnn), OpenCL-only, or not shipped on
          // this platform: whether it should be there is the required-plugin
          // list's question (vapoursynth_integration_test.dart).
          notLoaded.add(ns);
          continue;
        }
        if (!signatures.containsKey(call.name)) {
          problems.add('$file:${call.line}: core.${call.name} does not exist in the bundle');
          continue;
        }
        final sig = signatures[call.name];
        checked++;
        if (sig == null) continue;
        for (final k in call.keywords.where((k) => !sig.contains(k))) {
          problems.add('$file:${call.line}: core.${call.name} does not take $k=');
        }
      }
    }
    // ignore: avoid_print
    print('  checked $checked plugin calls; namespaces not loaded here: ${notLoaded.toList()..sort()}');
    expect(checked, greaterThan(100), reason: 'the scan found too few plugin calls');
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
