// AddonService: what the Settings → Add-ons page and every feature's download
// prompt go through. Checked here without the network: requirements install
// first and are removed with what needs them; AnimeJaNai's installer keeps
// only the hashed models and leaves nothing half-installed when a hash is
// wrong; and both shipped manifests describe what the code expects.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vapourbox/services/addon_manager.dart';
import 'package:vapourbox/services/addon_service.dart';
import 'package:vapourbox/services/whisper_addon_manager.dart';

/// An add-on that is a single marker file.
class _Fake implements AddonInstaller {
  @override
  final AddonInfo info;
  final List<String> log;
  _Fake(String id, this.log, {List<String> requires = const [], String? unavailable})
      : info = AddonInfo(
          id: id,
          name: 'Fake $id',
          feature: 'Test',
          description: '',
          licence: 'MIT',
          credit: 'tests',
          noticeName: 'Test',
          sourceUrl: 'https://example.invalid',
          downloadBytes: 10,
          requires: requires,
          unavailableReason: unavailable,
        );

  File _f(Directory d) => File(p.join(d.path, info.id));
  @override
  bool isInstalled(Directory d) => _f(d).existsSync();
  @override
  Future<void> install(Directory d, AddonManager _) async {
    log.add('install ${info.id}');
    await _f(d).writeAsString('x');
  }

  @override
  Future<void> remove(Directory d) async {
    log.add('remove ${info.id}');
    await _f(d).delete();
  }
}

/// Serves one fixed body for every download, after checking its hash the way
/// AddonManager does.
class _ServeBytes extends AddonManager {
  final List<int> body;
  _ServeBytes(this.body);
  @override
  Future<void> downloadFile(String url, File destination,
      {int? expectedSize, String? expectedSha256, Map<String, String>? extraHeaders}) async {
    if (expectedSha256 != null && sha256.convert(body).toString() != expectedSha256) {
      throw StateError('SHA256 mismatch');
    }
    await destination.writeAsBytes(body);
  }
}

String _repoFile(String rel) => File(p.join(
        Directory.current.path.endsWith('app') ? Directory.current.parent.path : Directory.current.path,
        rel))
    .readAsStringSync();

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('vb_addons_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('requirements', () {
    late List<String> log;
    late AddonService service;
    setUp(() async {
      log = [];
      service = AddonService.forTest(addonsDir: tmp, installers: [
        _Fake('engine', log),
        _Fake('model-a', log, requires: ['engine']),
        _Fake('model-b', log, requires: ['engine']),
        _Fake('elsewhere', log, unavailable: 'Not on this platform.'),
      ]);
      await service.load();
    });

    test('installing something installs what it requires first', () async {
      expect(service.missing(['model-a']), ['engine', 'model-a']);
      expect(service.downloadBytes(service.missing(['model-a'])), 20);
      expect(await service.install('model-a'), isTrue);
      expect(log, ['install engine', 'install model-a']);
      expect(service.isInstalled('engine'), isTrue);
      expect(service.missing(['model-b']), ['model-b'], reason: 'engine is already in');
    });

    test('removing something removes what requires it', () async {
      await service.install('model-a');
      await service.install('model-b');
      log.clear();
      expect(service.dependants('engine').toSet(), {'model-a', 'model-b'});
      await service.remove('engine');
      expect(log.last, 'remove engine');
      expect(log.toSet(), {'remove model-a', 'remove model-b', 'remove engine'});
      expect(service.catalog.where((i) => service.isInstalled(i.id)), isEmpty);
    });

    test('an add-on unavailable here is refused, not attempted', () async {
      await expectLater(service.install('elsewhere'), throwsStateError);
      expect(log, isEmpty);
      expect(service.installingId, isNull, reason: 'a failed install must not stay busy');
    });

    test('refresh notices files removed behind its back', () async {
      await service.install('engine');
      File(p.join(tmp.path, 'engine')).deleteSync();
      await service.refresh();
      expect(service.isInstalled('engine'), isFalse);
    });
  });

  group('AnimeJaNai installer', () {
    final models = {'a.onnx': utf8.encode('model a'), 'b.onnx': utf8.encode('model b')};
    List<int> zipOf(Map<String, List<int>> files) {
      final archive = Archive();
      for (final MapEntry(key: name, value: bytes) in files.entries) {
        archive.addFile(ArchiveFile('2x_ModelsOnly/$name', bytes.length, bytes));
      }
      return ZipEncoder().encode(archive)!;
    }

    Map<String, dynamic> manifest(List<int> zip, Map<String, List<int>> hashed) => {
          'version': 'test',
          'licence': 'CC BY-NC-SA 4.0',
          'homepage': 'https://example.invalid',
          'archive': {
            'url': 'https://example.invalid/m.zip',
            'size': zip.length,
            'sha256': sha256.convert(zip).toString(),
          },
          'models': {
            for (final MapEntry(key: n, value: b) in hashed.entries) n: sha256.convert(b).toString()
          },
        };

    test('keeps only the listed models, each hash-checked, then reports installed', () async {
      final zip = zipOf({...models, 'a.pth': utf8.encode('checkpoint')});
      final installer = AnimeJanaiInstaller(manifest(zip, models), 'macos-arm64');
      final service = AddonService.forTest(
          addonsDir: tmp, installers: [installer], downloader: _ServeBytes(zip));
      await service.load();
      expect(service.isInstalled(animeJanaiAddonId), isFalse);
      expect(await service.install(animeJanaiAddonId), isTrue);
      final dir = Directory(p.join(tmp.path, AnimeJanaiInstaller.dirName));
      expect(dir.listSync().map((f) => p.basename(f.path)).toSet(), {'a.onnx', 'b.onnx'});
      expect(service.isInstalled(animeJanaiAddonId), isTrue);
      expect(tmp.listSync().map((f) => p.basename(f.path)), [AnimeJanaiInstaller.dirName],
          reason: 'the download and staging directory are cleaned up');
      await service.remove(animeJanaiAddonId);
      expect(dir.existsSync(), isFalse);
    });

    test('a model with the wrong hash fails the install and leaves nothing behind', () async {
      final zip = zipOf({'a.onnx': models['a.onnx']!, 'b.onnx': utf8.encode('tampered')});
      final installer = AnimeJanaiInstaller(manifest(zip, models), 'macos-arm64');
      final service = AddonService.forTest(
          addonsDir: tmp, installers: [installer], downloader: _ServeBytes(zip));
      await service.load();
      await expectLater(service.install(animeJanaiAddonId), throwsStateError);
      expect(Directory(p.join(tmp.path, AnimeJanaiInstaller.dirName)).existsSync(), isFalse);
      expect(Directory(p.join(tmp.path, '${AnimeJanaiInstaller.dirName}.new')).existsSync(), isFalse);
      expect(service.isInstalled(animeJanaiAddonId), isFalse);
    });

    test('a missing model fails the install', () async {
      final zip = zipOf({'a.onnx': models['a.onnx']!});
      final installer = AnimeJanaiInstaller(manifest(zip, models), 'macos-arm64');
      final service = AddonService.forTest(
          addonsDir: tmp, installers: [installer], downloader: _ServeBytes(zip));
      await service.load();
      await expectLater(service.install(animeJanaiAddonId),
          throwsA(predicate((e) => '$e'.contains('b.onnx is missing'))));
    });

    test('is unavailable where the AI upscaler does not ship', () {
      final zip = zipOf(models);
      for (final platform in ['macos-x64', 'linux-arm64']) {
        expect(AnimeJanaiInstaller(manifest(zip, models), platform).info.unavailableReason,
            isNotNull, reason: platform);
      }
      for (final platform in AnimeJanaiInstaller.platforms) {
        expect(AnimeJanaiInstaller(manifest(zip, models), platform).info.unavailableReason,
            isNull, reason: platform);
      }
    });
  });

  group('shipped manifests', () {
    test('AnimeJaNai: a pinned upstream release asset, hashed, non-commercial, as the worker expects', () {
      final m = jsonDecode(_repoFile('app/assets/animejanai-addon.json')) as Map<String, dynamic>;
      final archive = m['archive'] as Map<String, dynamic>;
      expect(archive['url'], startsWith(
          'https://github.com/the-database/mpv-upscale-2x_animejanai/releases/download/'));
      expect(archive['sha256'], matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(archive['size'], greaterThan(1000000));
      expect(m['licence'], 'CC BY-NC-SA 4.0');
      final info = AnimeJanaiInstaller(m, 'macos-arm64').info;
      expect(info.usageNote, contains('non-commercial'));
      final models = (m['models'] as Map<String, dynamic>);
      for (final hash in models.values) {
        expect(hash, matches(RegExp(r'^[0-9a-f]{64}$')));
      }
      // The worker's list (worker/src/animejanai.rs MODELS), so the app never
      // reports installed a set the worker would call incomplete.
      final rust = _repoFile('worker/src/animejanai.rs');
      final listed = RegExp(r'^pub const MODELS: &\[&str\] = &\[(.*?)\];', multiLine: true, dotAll: true)
          .firstMatch(rust)!
          .group(1)!;
      final workerModels =
          RegExp(r'"([^"]+\.onnx)"').allMatches(listed).map((x) => x.group(1)).toSet();
      expect(models.keys.toSet(), workerModels);
    });

    test('Whisper: every platform has an engine, every model needs it', () {
      final m = jsonDecode(_repoFile('app/assets/whisper-addon.json')) as Map<String, dynamic>;
      for (final platform in ['macos-arm64', 'macos-x64', 'windows-x64', 'linux-x64', 'linux-arm64']) {
        final installers = WhisperAddonManager(m, platform).installers();
        final engine = installers.first.info;
        expect(engine.id, WhisperAddonManager.engineAddonId);
        expect(engine.downloadBytes, greaterThan(0), reason: platform);
        final models = installers.skip(1).map((i) => i.info).toList();
        expect(models.map((i) => i.id), containsAll([
          WhisperAddonManager.modelAddonId('small'),
          WhisperAddonManager.modelAddonId('medium'),
          WhisperAddonManager.modelAddonId('large-v3-turbo'),
        ]));
        for (final model in models) {
          expect(model.requires, [WhisperAddonManager.engineAddonId]);
          expect(model.downloadBytes, greaterThan(100000000));
        }
      }
    });
  });

  // The Settings → Add-ons page states each add-on's licence and credit from
  // its AddonInfo; the same facts are in NOTICES, the About dialog and the
  // README. All four must agree, and a non-commercial licence must carry its
  // usage note.
  group('credits agree everywhere', () {
    final notices = _repoFile('licenses/NOTICES.txt');
    final about = _repoFile('app/lib/views/about_dialog.dart');
    final readme = _repoFile('README.md');
    final infos = [
      for (final platform in ['macos-arm64', 'windows-x64', 'linux-x64'])
        ...WhisperAddonManager(
                jsonDecode(_repoFile('app/assets/whisper-addon.json')) as Map<String, dynamic>,
                platform)
            .installers()
            .map((i) => i.info),
      AnimeJanaiInstaller(
              jsonDecode(_repoFile('app/assets/animejanai-addon.json')) as Map<String, dynamic>,
              'macos-arm64')
          .info,
    ];
    final byNotice = {for (final i in infos) '${i.noticeName}|${i.licence}|${i.credit}': i}.values;

    for (final info in byNotice) {
      test(info.noticeName, () {
        final heading = RegExp('^${RegExp.escape(info.noticeName)} — (.*)\$', multiLine: true)
            .firstMatch(notices);
        expect(heading, isNotNull, reason: 'NOTICES.txt has no "${info.noticeName} — " entry');
        expect(heading!.group(1), startsWith(info.licence),
            reason: 'NOTICES and Settings → Add-ons state different licences');
        final body = notices.substring(heading.end).split(RegExp(r'\n\s*\n')).first;
        expect(body, contains(info.credit), reason: 'NOTICES credits someone else');
        expect(body, contains('add-on'), reason: 'NOTICES must say it is not bundled');

        final tile = RegExp("name: '${RegExp.escape(info.noticeName)}[^']*',\\s*license: '([^']+)',"
                "\\s*copyright: '([^']+)'")
            .firstMatch(about);
        expect(tile, isNotNull, reason: 'the About dialog has no "${info.noticeName}" tile');
        expect(tile!.group(1), startsWith(info.licence));

        final who = info.credit.split(' (').first.toLowerCase();
        final acks = readme.substring(readme.indexOf('## Acknowledgments'));
        expect(acks.toLowerCase(), contains(who), reason: 'README Acknowledgments omit $who');

        expect(info.usageNote != null, info.licence.contains('NC'),
            reason: 'a non-commercial licence must be shown as a usage note, and only that');
      });
    }
  });
}
