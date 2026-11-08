// Manifest add-ons (assets/addons/*.json, ManifestAddonInstaller): checked
// without the network, through the mirror (VAPOURBOX_ADDON_MIRROR's code
// path) and a fake downloader. Every file is hash-checked before anything is
// unpacked, an install is all or nothing, a manifest version bump reinstalls,
// and the app and the worker see the same set of manifests.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vapourbox/services/addon_manager.dart';
import 'package:vapourbox/services/addon_service.dart';
import 'package:vapourbox/services/manifest_addon.dart';

String get _root =>
    Directory.current.path.endsWith('app') ? Directory.current.parent.path : Directory.current.path;

/// Serves files from a map of url → bytes, checking the hash as AddonManager does.
class _Serve extends AddonManager {
  final Map<String, List<int>> bodies;
  final List<String> fetched = [];
  _Serve(this.bodies);
  @override
  Future<void> downloadFile(String url, File destination,
      {int? expectedSize, String? expectedSha256, Map<String, String>? extraHeaders}) async {
    fetched.add(url);
    final body = bodies[url]!;
    if (expectedSha256 != null && sha256.convert(body).toString() != expectedSha256) {
      throw StateError('SHA256 mismatch');
    }
    await destination.writeAsBytes(body);
  }
}

List<int> _zip(Map<String, List<int>> files) {
  final archive = Archive();
  for (final MapEntry(key: name, value: bytes) in files.entries) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }
  return ZipEncoder().encode(archive)!;
}

String _sha(List<int> b) => sha256.convert(b).toString();

Map<String, dynamic> _entry(String name, List<int> bytes, {List<String>? platforms, Object? extract}) => {
      'name': name,
      'url': 'https://example.invalid/dl/$name',
      'size': bytes.length,
      'sha256': _sha(bytes),
      if (platforms != null) 'platforms': platforms,
      if (extract != null) 'extract': extract,
    };

Map<String, dynamic> _manifest({
  String id = 'test-addon',
  String version = '1.0.0',
  String kind = 'files',
  Object platforms = 'all',
  required List<Map<String, dynamic>> files,
  List<String> requires = const [],
}) =>
    {
      'id': id,
      'version': version,
      'name': 'Test add-on',
      'feature': 'Testing',
      'description': 'A test.',
      'licence': 'MIT',
      'credit': 'Tests',
      'noticeName': 'Test',
      'homepage': 'https://example.invalid',
      'requires': requires,
      'kind': kind,
      'platforms': platforms,
      'files': files,
    };

void main() {
  late Directory tmp;
  late Directory addons;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vb_manifest_addon_');
    addons = Directory(p.join(tmp.path, 'addons'))..createSync();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  final model = utf8.encode('model weights');
  final other = utf8.encode('other model');

  group('files add-on', () {
    test('installs each file, hash-checked, behind a marker; removes cleanly', () async {
      final m = AddonManifest.fromJson(_manifest(files: [_entry('a.onnx', model)]));
      final server = _Serve({'https://example.invalid/dl/a.onnx': model});
      final service = AddonService.forTest(
          addonsDir: addons,
          installers: [ManifestAddonInstaller(m, 'linux-x64')],
          downloader: server);
      await service.load();
      expect(service.isInstalled('test-addon'), isFalse);
      expect(service.info('test-addon')!.downloadBytes, model.length);
      expect(await service.install('test-addon'), isTrue);
      final dir = Directory(p.join(addons.path, 'test-addon'));
      expect(File(p.join(dir.path, 'a.onnx')).readAsBytesSync(), model);
      final marker = jsonDecode(
          File(p.join(dir.path, ManifestAddonInstaller.markerName)).readAsStringSync());
      expect(marker, {'id': 'test-addon', 'version': '1.0.0', 'platform': 'linux-x64'});
      expect(service.isInstalled('test-addon'), isTrue);
      expect(addons.listSync().map((e) => p.basename(e.path)).toSet(), {'test-addon', '.downloads'});
      expect(Directory(p.join(addons.path, '.downloads')).listSync(), isEmpty,
          reason: 'downloads are deleted once installed');
      await service.remove('test-addon');
      expect(dir.existsSync(), isFalse);
    });

    test('only this platform\'s files are fetched', () async {
      final m = AddonManifest.fromJson(_manifest(
          platforms: {'linux-x64': {}, 'windows-x64': {}},
          files: [
            _entry('linux.onnx', model, platforms: ['linux-x64']),
            _entry('windows.onnx', other, platforms: ['windows-x64']),
          ]));
      final server = _Serve({
        'https://example.invalid/dl/linux.onnx': model,
        'https://example.invalid/dl/windows.onnx': other,
      });
      final installer = ManifestAddonInstaller(m, 'windows-x64');
      expect(installer.info.downloadBytes, other.length);
      await installer.install(addons, server);
      expect(server.fetched, ['https://example.invalid/dl/windows.onnx']);
      expect(installer.isInstalled(addons), isTrue);
      expect(ManifestAddonInstaller(m, 'linux-x64').isInstalled(addons), isFalse,
          reason: 'another platform\'s install is not this one\'s');
    });

    test('an archive keeps only its listed members, each hash-checked', () async {
      final zip = _zip({'pack/a.onnx': model, 'pack/b.pth': utf8.encode('checkpoint')});
      final m = AddonManifest.fromJson(_manifest(files: [
        _entry('pack.zip', zip, extract: [
          {'path': 'pack/a.onnx', 'sha256': _sha(model)},
        ]),
      ]));
      final installer = ManifestAddonInstaller(m, 'macos-arm64', osVersion: '15.0');
      await installer.install(addons, _Serve({'https://example.invalid/dl/pack.zip': zip}));
      final dir = Directory(p.join(addons.path, 'test-addon'));
      expect(dir.listSync().map((e) => p.basename(e.path)).toSet(),
          {'a.onnx', ManifestAddonInstaller.markerName});
      expect(installer.isInstalled(addons), isTrue);
    });

    test('a wrong member hash installs nothing', () async {
      final zip = _zip({'pack/a.onnx': utf8.encode('tampered')});
      final m = AddonManifest.fromJson(_manifest(files: [
        _entry('pack.zip', zip, extract: [
          {'path': 'pack/a.onnx', 'sha256': _sha(model)},
        ]),
      ]));
      final installer = ManifestAddonInstaller(m, 'linux-x64');
      await expectLater(installer.install(addons, _Serve({'https://example.invalid/dl/pack.zip': zip})),
          throwsA(predicate((e) => '$e'.contains('does not match its expected hash'))));
      expect(Directory(p.join(addons.path, 'test-addon')).existsSync(), isFalse);
      expect(Directory(p.join(addons.path, 'test-addon.new')).existsSync(), isFalse);
      expect(installer.isInstalled(addons), isFalse);
    });

    test('a version bump counts as missing, and reinstalling replaces the old install', () async {
      final v1 = AddonManifest.fromJson(_manifest(files: [_entry('a.onnx', model)]));
      final v2 = AddonManifest.fromJson(_manifest(version: '2.0.0', files: [_entry('b.onnx', other)]));
      final server = _Serve({
        'https://example.invalid/dl/a.onnx': model,
        'https://example.invalid/dl/b.onnx': other,
      });
      await ManifestAddonInstaller(v1, 'linux-x64').install(addons, server);
      final upgraded = ManifestAddonInstaller(v2, 'linux-x64');
      expect(upgraded.isInstalled(addons), isFalse);
      await upgraded.install(addons, server);
      expect(upgraded.isInstalled(addons), isTrue);
      final dir = Directory(p.join(addons.path, 'test-addon'));
      expect(File(p.join(dir.path, 'a.onnx')).existsSync(), isFalse, reason: 'replaced, not merged');
      expect(Directory(p.join(addons.path, 'test-addon.old')).existsSync(), isFalse);
    });

    test('the mirror replaces the download, and is still verified', () async {
      final mirror = Directory(p.join(tmp.path, 'mirror'))..createSync();
      File(p.join(mirror.path, 'a.onnx')).writeAsBytesSync(model);
      final m = AddonManifest.fromJson(_manifest(files: [_entry('a.onnx', model)]));
      final server = _Serve({});
      final installer = ManifestAddonInstaller(m, 'linux-x64', mirror: mirror.path);
      await installer.install(addons, server);
      expect(server.fetched, isEmpty);
      expect(installer.isInstalled(addons), isTrue);

      await installer.remove(addons);
      File(p.join(mirror.path, 'a.onnx')).writeAsBytesSync(other);
      await expectLater(installer.install(addons, server),
          throwsA(predicate((e) => '$e'.contains('does not match the pinned size and hash'))));
      expect(installer.isInstalled(addons), isFalse);

      File(p.join(mirror.path, 'a.onnx')).deleteSync();
      await expectLater(installer.install(addons, server),
          throwsA(predicate((e) => '$e'.contains(addonMirrorEnv))));
    });
  });

  group('python add-on', () {
    test('unpacks each wheel into site-packages, as pip lays it out', () async {
      final wheel = _zip({
        'pkg/__init__.py': utf8.encode('x = 1'),
        'pkg-1.0.dist-info/METADATA': utf8.encode('Name: pkg'),
        'pkg-1.0.data/platlib/pkg_native.so': utf8.encode('elf'),
        'pkg-1.0.data/scripts/tool': utf8.encode('#!'),
      });
      final m = AddonManifest.fromJson(
          _manifest(kind: 'python', files: [_entry('pkg-1.0-cp312-cp312-any.whl', wheel)]));
      final installer = ManifestAddonInstaller(m, 'linux-arm64');
      await installer.install(
          addons, _Serve({'https://example.invalid/dl/pkg-1.0-cp312-cp312-any.whl': wheel}));
      final site = Directory(p.join(addons.path, 'test-addon', 'site-packages'));
      expect(File(p.join(site.path, 'pkg', '__init__.py')).readAsStringSync(), 'x = 1');
      expect(File(p.join(site.path, 'pkg_native.so')).existsSync(), isTrue);
      expect(File(p.join(site.path, 'tool')).existsSync(), isFalse);
      expect(installer.isInstalled(addons), isTrue);
    });

    test('a wheel entry escaping its directory is refused', () async {
      final wheel = _zip({'../evil.py': utf8.encode('boom')});
      final m = AddonManifest.fromJson(_manifest(kind: 'python', files: [_entry('evil.whl', wheel)]));
      await expectLater(
          ManifestAddonInstaller(m, 'linux-x64')
              .install(addons, _Serve({'https://example.invalid/dl/evil.whl': wheel})),
          throwsStateError);
      expect(File(p.join(addons.path, 'evil.py')).existsSync(), isFalse);
      expect(Directory(p.join(addons.path, 'test-addon')).existsSync(), isFalse);
    });
  });

  group('availability', () {
    final m = AddonManifest.fromJson(_manifest(
        platforms: {'macos-x64': {'minOs': '13.0'}, 'linux-x64': {}},
        files: [_entry('a.onnx', model)]));

    test('a platform outside the table is unavailable, and refused', () async {
      final installer = ManifestAddonInstaller(m, 'windows-x64');
      expect(installer.unavailableReason, contains('isn\'t available for Windows'));
      final service = AddonService.forTest(addonsDir: addons, installers: [installer]);
      await service.load();
      await expectLater(service.install('test-addon'), throwsStateError);
    });

    test('minOs is checked against the running macOS', () {
      expect(ManifestAddonInstaller(m, 'macos-x64', osVersion: '12.7.6').unavailableReason,
          contains('needs macOS 13.0 or later'));
      expect(ManifestAddonInstaller(m, 'macos-x64', osVersion: '13.0').unavailableReason, isNull);
      expect(ManifestAddonInstaller(m, 'macos-x64', osVersion: '15.1').unavailableReason, isNull);
      expect(ManifestAddonInstaller.compareOsVersions('13.10', '13.9'), greaterThan(0));
    });
  });

  group('validation', () {
    Map<String, dynamic> good() => _manifest(files: [_entry('a.onnx', model)]);
    void bad(void Function(Map<String, dynamic>) edit, String why) {
      final json = good();
      edit(json);
      expect(() => AddonManifest.fromJson(json), throwsFormatException, reason: why);
    }

    test('malformed manifests are refused', () {
      expect(AddonManifest.fromJson(good()).id, 'test-addon');
      bad((j) => j['kind'] = 'binary', 'unknown kind');
      bad((j) => j['id'] = 'Test Addon', 'id format');
      bad((j) => (j['files'] as List).first['sha256'] = 'abc', 'short hash');
      bad((j) => (j['files'] as List).first['url'] = 'http://example.invalid/a', 'plain http');
      bad((j) => (j['files'] as List).first['name'] = '../a.onnx', 'path in a name');
      bad((j) => j['platforms'] = {'windows-arm64': {}}, 'unknown platform');
      bad((j) {
        j['platforms'] = {'linux-x64': {}, 'macos-arm64': {}};
        (j['files'] as List).first['platforms'] = ['linux-x64'];
      }, 'a platform with no files');
      bad((j) => j['kind'] = 'python', 'a python add-on lists wheels only');
    });
  });

  group('shipped manifests', () {
    final dir = Directory(p.join(_root, 'app', 'assets', 'addons'));
    final manifests = AddonManifest.loadDirectory(dir);

    test('all parse, one per id, named after it, requirements known', () {
      expect(manifests, isNotEmpty);
      final ids = manifests.map((m) => m.id).toSet();
      expect(ids.length, manifests.length);
      for (final m in manifests) {
        expect(File(p.join(dir.path, '${m.id}.json')).existsSync(), isTrue, reason: m.id);
        for (final r in m.requires) {
          expect(ids, contains(r), reason: '${m.id} requires unknown $r');
        }
        // Not the ids the hand-written installers use.
        expect({'whisper', 'animejanai'}, isNot(contains(m.id)));
        expect(m.id.startsWith('whisper-model-'), isFalse);
      }
    });

    test('pubspec ships the directory, so AddonService finds every one', () {
      final pubspec = File(p.join(_root, 'app', 'pubspec.yaml')).readAsStringSync();
      expect(pubspec, contains('- assets/addons/'));
    });

    test('the worker compiled in the same manifests, at the same versions', () async {
      final ext = Platform.isWindows ? '.exe' : '';
      final worker = [
        p.join(_root, 'worker', 'target', 'debug', 'vapourbox-worker$ext'),
        p.join(_root, 'worker', 'target', 'release', 'vapourbox-worker$ext'),
      ].firstWhere((w) => File(w).existsSync(),
          orElse: () => fail('Build the worker first: (cd worker && cargo build)'));
      final result = await Process.run(worker, ['--list-addons']);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final listed = jsonDecode((result.stdout as String).trim()) as Map<String, dynamic>;
      expect(listed, {for (final m in manifests) m.id: m.version},
          reason: 'a stale worker binary? rebuild it (cd worker && cargo build)');
    });
  });
}
