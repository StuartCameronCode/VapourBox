import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vapourbox/services/dependency_manager.dart';

/// From deps 1.13.0 the v2 CPU tier is not a second full bundle: it is the v3
/// bundle plus a small delta extracted over it, and a package may ship either
/// zip so the first launch needs no network (the Linux AppImage does). These
/// pin which zips make up an install, when a shipped zip is trusted, and that
/// extracting a delta over a bundle produces the v2 tree and nothing else.
void main() {
  List<int> zipOf(Map<String, String> files) {
    final archive = Archive();
    files.forEach((name, content) {
      final bytes = utf8.encode(content);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    });
    return ZipEncoder().encode(archive)!;
  }

  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('vb_delta_test_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('installAssetIds', () {
    test('a delta-format v2 install is the v3 bundle, then the delta', () {
      for (final id in ['macos-x64', 'windows-x64', 'linux-x64']) {
        expect(DependencyManager.installAssetIds(id, 'v2', delta: true),
            [id, '$id-v2-delta']);
      }
    });

    test('v3 and ARM installs are one bundle in either format', () {
      for (final delta in [true, false]) {
        expect(DependencyManager.installAssetIds('linux-x64', 'v3', delta: delta),
            ['linux-x64']);
        expect(
            DependencyManager.installAssetIds('linux-arm64', null, delta: delta),
            ['linux-arm64']);
      }
    });

    test('a release without tierFormat still ships v2 as a full bundle', () {
      // Deps 1.11.0-1.12.0. An app pinned to one of those must keep asking for
      // the asset that release actually has.
      expect(DependencyManager.installAssetIds('linux-x64', 'v2', delta: false),
          ['linux-x64-v2']);
    });

    test('the delta resolves to its own zip and sidecar', () {
      // Must agree with what Scripts/make-deps-delta.py writes.
      final info = DepsVersionInfo.fromJson({
        'version': '1.13.0',
        'releaseTag': 'deps-v1.13.0',
        'tierFormat': 'delta',
        'githubRepo': 'StuartCameronCode/VapourBox',
      });
      expect(info.tierIsDelta, isTrue);
      expect(info.filenameFor('linux-x64-v2-delta'),
          'VapourBox-deps-1.13.0-linux-x64-v2-delta.zip');
      expect(
          info.getManifestUrl('linux-x64-v2-delta'),
          'https://github.com/StuartCameronCode/VapourBox/releases/download/'
          'deps-v1.13.0/VapourBox-deps-1.13.0-linux-x64-v2-delta.zip.sha256.json');
    });

    test('tierFormat defaults to full bundles', () {
      final info = DepsVersionInfo.fromJson({'version': '1.12.0'});
      expect(info.tierIsDelta, isFalse);
    });
  });

  group('findBundledZip', () {
    const name = 'VapourBox-deps-9.9.9-linux-x64.zip';

    void writeZip(List<int> bytes, {String? sidecarSha}) {
      File(p.join(tmp.path, name)).writeAsBytesSync(bytes);
      if (sidecarSha != null) {
        File(p.join(tmp.path, '$name.sha256.json'))
            .writeAsStringSync(jsonEncode({'filename': name, 'sha256': sidecarSha}));
      }
    }

    test('a zip matching the sidecar shipped beside it is used', () async {
      final bytes = zipOf({'ffmpeg/ffmpeg': 'x'});
      writeZip(bytes, sidecarSha: sha256.convert(bytes).toString());
      final found = await DependencyManager.findBundledZip(tmp, name);
      expect(found?.path, p.join(tmp.path, name));
    });

    test('nothing shipped means download', () async {
      expect(await DependencyManager.findBundledZip(tmp, name), isNull);
      expect(
          await DependencyManager.findBundledZip(
              Directory(p.join(tmp.path, 'absent')), name),
          isNull);
    });

    test('a zip with no sidecar is not trusted', () async {
      // Offline there is nothing else to say the zip is whole.
      writeZip(zipOf({'ffmpeg/ffmpeg': 'x'}));
      expect(await DependencyManager.findBundledZip(tmp, name), isNull);
    });

    test('a zip that does not match its sidecar falls back to download',
        () async {
      writeZip(zipOf({'ffmpeg/ffmpeg': 'x'}), sidecarSha: '0' * 64);
      expect(await DependencyManager.findBundledZip(tmp, name), isNull);
    });

    test('an unreadable sidecar falls back to download', () async {
      writeZip(zipOf({'ffmpeg/ffmpeg': 'x'}));
      File(p.join(tmp.path, '$name.sha256.json')).writeAsStringSync('not json');
      expect(await DependencyManager.findBundledZip(tmp, name), isNull);
    });
  });

  group('deltaBaseSha256', () {
    Archive deltaWith(String versionJson) => ZipDecoder().decodeBytes(
        zipOf({'vapoursynth/plugins/libzsmooth.so': 'v2', 'version.json': versionJson}));

    test('reads the bundle the delta was cut against', () {
      expect(
          DependencyManager.deltaBaseSha256(
              deltaWith(jsonEncode({'tier': 'v2', 'baseSha256': 'abc123'}))),
          'abc123');
    });

    test('a delta that records no base matches nothing', () {
      // null never equals a real hash, so such a delta is always refused.
      expect(DependencyManager.deltaBaseSha256(deltaWith('{"tier":"v2"}')), isNull);
      expect(DependencyManager.deltaBaseSha256(deltaWith('garbage')), isNull);
      expect(
          DependencyManager.deltaBaseSha256(
              ZipDecoder().decodeBytes(zipOf({'a': 'b'}))),
          isNull);
    });
  });

  group('extractBundle', () {
    final manager = DependencyManager.instance;

    Future<File> zipFile(String name, Map<String, String> files) async {
      final f = File(p.join(tmp.path, name));
      await f.writeAsBytes(zipOf(files));
      return f;
    }

    String read(Directory d, String rel) =>
        File(p.joinAll([d.path, ...rel.split('/')])).readAsStringSync();

    test('a delta replaces only the files it carries', () async {
      final deps = Directory(p.join(tmp.path, 'deps'));
      final base = await zipFile('base.zip', {
        'ffmpeg/ffmpeg': 'ffmpeg',
        'vapoursynth/plugins/libzsmooth.so': 'haswell',
        'vapoursynth/plugins/libmvtools.so': 'mvtools',
        'version.json': '{"version":"9.9.9","tier":"v3"}',
      });
      final delta = await zipFile('delta.zip', {
        'vapoursynth/plugins/libzsmooth.so': 'x86_64_v2',
        'version.json': '{"version":"9.9.9","tier":"v2","baseSha256":"x"}',
      });

      await manager.extractBundle(base, deps, finalize: false);
      await manager.extractBundle(delta, deps, overlay: true, finalize: false);

      expect(read(deps, 'vapoursynth/plugins/libzsmooth.so'), 'x86_64_v2');
      expect(read(deps, 'vapoursynth/plugins/libmvtools.so'), 'mvtools');
      expect(read(deps, 'ffmpeg/ffmpeg'), 'ffmpeg');
    });

    test('a zip never writes version.json; that is the commit marker',
        () async {
      // The bundle's own copy says v3. Extracted, it would make an install
      // interrupted before the delta look like a complete v3 one on a v2 CPU.
      final deps = Directory(p.join(tmp.path, 'deps'));
      final base = await zipFile('base.zip', {
        'ffmpeg/ffmpeg': 'ffmpeg',
        'version.json': '{"version":"9.9.9","tier":"v3"}',
      });
      final delta = await zipFile('delta.zip', {
        'ffmpeg/ffmpeg': 'v2',
        'version.json': '{"version":"9.9.9","tier":"v2"}',
      });
      await manager.extractBundle(base, deps, finalize: false);
      expect(File(p.join(deps.path, 'version.json')).existsSync(), isFalse);
      await manager.extractBundle(delta, deps, overlay: true, finalize: false);
      expect(File(p.join(deps.path, 'version.json')).existsSync(), isFalse);
    });

    test('without overlay the previous tree is replaced, not merged', () async {
      final deps = Directory(p.join(tmp.path, 'deps'))..createSync();
      File(p.join(deps.path, 'stale.so')).writeAsStringSync('old');
      final base = await zipFile('base.zip', {'ffmpeg/ffmpeg': 'ffmpeg'});
      await manager.extractBundle(base, deps, finalize: false);
      expect(File(p.join(deps.path, 'stale.so')).existsSync(), isFalse);
    });
  });

  group('the shipped pointer and manifest', () {
    String repoFile(List<String> parts) {
      var dir = Directory.current;
      while (!Directory(p.join(dir.path, 'worker')).existsSync() ||
          !Directory(p.join(dir.path, 'app')).existsSync()) {
        dir = dir.parent;
      }
      return File(p.joinAll([dir.path, ...parts])).readAsStringSync();
    }

    test('every tier file is a plugin its platform is required to ship', () {
      final manifest = jsonDecode(repoFile(['Scripts', 'deps-expected-plugins.json']))
          as Map<String, dynamic>;
      final tierFiles = manifest['_tierFiles'] as Map<String, dynamic>;
      // A tiered platform with no tier files would publish an empty delta and
      // hand older CPUs the v3 plugins.
      expect(tierFiles.keys.toSet(), {'macos-x64', 'windows-x64', 'linux-x64'});
      for (final entry in tierFiles.entries) {
        final files = (entry.value as List).cast<String>();
        expect(files, isNotEmpty, reason: entry.key);
        final plugins = (manifest[entry.key] as List).cast<String>().toSet();
        final pluginDir = entry.key.startsWith('windows')
            ? 'vapoursynth/vs-plugins/'
            : 'vapoursynth/plugins/';
        for (final f in files) {
          expect(f, startsWith(pluginDir), reason: entry.key);
          expect(plugins, contains(f.substring(pluginDir.length)),
              reason: '${entry.key}: $f is not in the platform plugin list');
        }
      }
    });

    test('no deps workflow can publish a full v2 bundle', () {
      // The v2 build is an intermediate. A release holding both it and the
      // delta would leave two different answers to "what is the v2 tier".
      for (final os in ['macos', 'windows', 'linux']) {
        final workflow =
            repoFile(['.github', 'workflows', 'build-deps-$os.yml']);
        expect(workflow, contains(r'"dist/$STEM-v2-delta.zip"'), reason: os);
        expect(workflow, contains(r'"dist/$STEM-v2-delta.zip.sha256.json"'),
            reason: os);
        expect(workflow, isNot(contains('-x64*.zip')), reason: os);
        expect(workflow, isNot(contains(r'dist/${{ env.ASSET }}.zip" \')),
            reason: '$os uploads a matrix build straight to the release');
      }
    });
  });
}
