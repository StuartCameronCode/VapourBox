// The nightly's add-on prefetch (task #117): .github/scripts/prefetch-addons.py
// fills a mirror before the tests, and the app's installer takes each file
// from it by the last segment of its URL (VAPOURBOX_ADDON_MIRROR). These
// check that the script lists exactly the files the app's manifests name,
// under the names the installer looks for; that it fetches, resumes, keeps,
// prunes and refuses as documented (against a local server, no network);
// and that every nightly job is wired to it.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vapourbox/services/manifest_addon.dart';

import 'support/worker_harness.dart';

void main() {
  final root = WorkerHarness.repoRoot;
  final script = p.join(root, '.github', 'scripts', 'prefetch-addons.py');
  // The system Python, as the workflow runs it; the script is stdlib only.
  final python = Platform.isWindows ? 'python' : 'python3';

  Future<ProcessResult> run(List<String> args) =>
      Process.run(python, ['-I', script, ...args], environment: {'GITHUB_ACTIONS': ''});

  List<String> lines(ProcessResult r) =>
      (r.stdout as String).replaceAll('\r\n', '\n').trim().split('\n').where((l) => l.isNotEmpty).toList();

  test('the script lists every manifest file, under the name the installer looks up', () async {
    final r = await run(['--list']);
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
    final listed = lines(r).toSet();
    final manifests =
        AddonManifest.loadDirectory(Directory(p.join(root, 'app', 'assets', 'addons')));
    final expected = {
      for (final m in manifests)
        for (final f in m.files)
          [Uri.parse(f.url).pathSegments.last, f.url, '${f.size}', f.sha256.toLowerCase()].join('\t'),
    };
    expect(listed, expected);
    final names = listed.map((l) => l.split('\t').first).toList();
    expect(names.toSet(), hasLength(names.length), reason: 'two files share a mirror name');
  });

  group('fetching (local server)', () {
    late HttpServer server;
    late Directory dir;
    final bodies = {'a.bin': 'first add-on file' * 1000, 'b.onnx': 'second add-on file'};
    final requests = <String>[];
    final ranges = <String?>[];

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('addon_prefetch_test');
      requests.clear();
      ranges.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final name = req.uri.pathSegments.last;
        requests.add(name);
        final range = req.headers.value(HttpHeaders.rangeHeader);
        ranges.add(range);
        final body = utf8.encode(bodies[name] ?? '');
        if (!bodies.containsKey(name)) {
          req.response.statusCode = 404;
        } else if (range != null && range.startsWith('bytes=')) {
          final start = int.parse(range.substring(6).split('-').first);
          req.response.statusCode = 206;
          req.response.headers
              .set(HttpHeaders.contentRangeHeader, 'bytes $start-${body.length - 1}/${body.length}');
          req.response.add(body.sublist(start));
        } else {
          req.response.add(body);
        }
        await req.response.close();
      });
    });
    tearDown(() async {
      await server.close(force: true);
      await dir.delete(recursive: true);
    });

    Map<String, Object> file(String name, {String? sha}) => {
          'name': name,
          'url': 'http://127.0.0.1:${server.port}/dl/$name',
          'size': utf8.encode(bodies[name] ?? 'x').length,
          'sha256': sha ?? sha256.convert(utf8.encode(bodies[name] ?? 'x')).toString(),
        };

    Future<String> manifests(List<Map<String, Object>> files) async {
      final m = Directory(p.join(dir.path, 'manifests'))..createSync();
      File(p.join(m.path, 'test.json')).writeAsStringSync(jsonEncode({'id': 'test', 'files': files}));
      return m.path;
    }

    test('downloads, keeps what matches, resumes a partial file and prunes the rest', () async {
      final m = await manifests([file('a.bin'), file('b.onnx')]);
      final out = p.join(dir.path, 'mirror');
      var r = await run(['--manifests', m, '--out', out, '--jobs', '1']);
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
      expect(File(p.join(out, 'a.bin')).readAsStringSync(), bodies['a.bin']);
      expect(File(p.join(out, 'b.onnx')).readAsStringSync(), bodies['b.onnx']);

      // A partial download of a.bin, a stray file: a.bin resumes from where
      // it stopped, b.onnx is kept, the stray file goes.
      File(p.join(out, 'a.bin')).deleteSync();
      File(p.join(out, 'a.bin.partial')).writeAsStringSync(bodies['a.bin']!.substring(0, 4000));
      File(p.join(out, 'old-model.onnx')).writeAsStringSync('from an older manifest');
      requests.clear();
      ranges.clear();
      r = await run(['--manifests', m, '--out', out]);
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
      expect(requests, ['a.bin']);
      expect(ranges, ['bytes=4000-']);
      expect(File(p.join(out, 'a.bin')).readAsStringSync(), bodies['a.bin']);
      expect(File(p.join(out, 'old-model.onnx')).existsSync(), isFalse);
      expect(File(p.join(out, 'a.bin.partial')).existsSync(), isFalse);
    });

    test('a hash mismatch and a 404 are errors (exit 1), and nothing is kept for them', () async {
      final m = await manifests([file('a.bin', sha: '0' * 64), file('missing.onnx')]);
      final out = p.join(dir.path, 'mirror');
      final ghOutput = File(p.join(dir.path, 'github_output'));
      final r = await Process.run(python, ['-I', script, '--manifests', m, '--out', out],
          environment: {'GITHUB_ACTIONS': 'true', 'GITHUB_OUTPUT': ghOutput.path});
      expect(r.exitCode, 1, reason: '${r.stdout}\n${r.stderr}');
      final log = (r.stdout as String);
      expect(log, contains('::error::add-on file a.bin'));
      expect(log, contains('does not match its pin'));
      expect(log, contains('::error::add-on file missing.onnx'));
      expect(log, contains('HTTP 404'));
      expect(Directory(out).listSync(), isEmpty);
      expect(ghOutput.readAsStringSync(), contains('complete=false'));
      // One request each: neither is retried.
      expect(requests..sort(), ['a.bin', 'missing.onnx']);
    });

    test('a network failure is a warning only (exit 2): the tests download that file', () async {
      final m = await manifests([
        {'name': 'c.bin', 'url': 'http://nonexistent.invalid/c.bin', 'size': 1, 'sha256': '0' * 64},
      ]);
      final r = await run(
          ['--manifests', m, '--out', p.join(dir.path, 'mirror'), '--attempts', '2', '--base-delay', '0']);
      expect(r.exitCode, 2, reason: '${r.stdout}\n${r.stderr}');
      expect(r.stdout as String, contains('retrying c.bin'));
      expect(r.stdout as String, contains('WARNING: add-on file c.bin'));
    });

    test('--check-links: a dead link fails, a live one with the pinned size passes', () async {
      var r = await run(['--manifests', await manifests([file('a.bin'), file('b.onnx')]), '--check-links']);
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
      expect(ranges, everyElement('bytes=0-0'));
      File(p.join(dir.path, 'manifests', 'test.json')).deleteSync();
      r = await run([
        '--manifests',
        await manifests([file('missing.onnx'), {...file('a.bin'), 'size': 7}]),
        '--check-links'
      ]);
      expect(r.exitCode, 1, reason: '${r.stdout}\n${r.stderr}');
      expect(r.stdout as String, contains('HTTP 404'));
      expect(r.stdout as String, contains('the manifest pins 7'));
    });
  });

  test('every nightly job prefetches, caches the mirror and runs the tests with it', () {
    final yaml = File(p.join(root, '.github', 'workflows', 'nightly.yml'))
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    for (final needle in [
      'name: Restore add-on mirror',
      'prefetch-addons.py --out .addon-mirror',
      'name: Save add-on mirror',
      "github.ref == 'refs/heads/main'",
      'enableCrossOsArchive: true',
      'VAPOURBOX_ADDON_MIRROR: \${{ github.workspace }}/.addon-mirror',
      'prefetch-addons.py --check-links',
    ]) {
      // macOS, Windows and Linux: one each (enableCrossOsArchive twice a job).
      final want = needle == 'enableCrossOsArchive: true' ? 6 : 3;
      expect(needle.allMatches(yaml).length, want, reason: needle);
    }
    // The mirror is keyed on the manifests, so a changed pin is a new entry.
    expect(yaml, contains("key: addon-mirror-v1-\${{ hashFiles('app/assets/addons/*.json') }}"));
  });
}
