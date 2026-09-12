// Disk behaviour of PresetService: saving, deleting, and the import/export
// added for issue #81's fourth ask.
//
// There were no tests over this service at all, which is how three bugs
// survived in it — see the groups below. `directoryOverride` exists so these
// can run against a temp directory instead of the real ~/.vapourbox/presets.
//
// Run with: flutter test test/preset_service_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/processing_preset.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/services/preset_service.dart';

void main() {
  late Directory tempDir;
  late PresetService service;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('vapourbox-presets-test');
    service = PresetService.instance;
    service.directoryOverride = tempDir;
    await service.reload();
  });

  tearDown(() async {
    service.directoryOverride = null;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  ProcessingPreset makePreset(
    String name, {
    String? id,
    String customVapoursynth = '',
    String customFfmpegArgs = '',
  }) =>
      ProcessingPreset(
        id: id,
        name: name,
        pipeline: const ProcessingPipeline(
          deinterlace: QTGMCParameters(enabled: false),
        ),
        encodingSettings: EncodingSettings(
          customVapoursynth: customVapoursynth,
          customFfmpegArgs: customFfmpegArgs,
        ),
      );

  Future<List<String>> presetFiles() async => tempDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .map((f) => f.uri.pathSegments.last)
      .toList()
    ..sort();

  group('saving', () {
    test('round-trips through disk', () async {
      await service.savePreset(makePreset('My Preset'));
      await service.reload();

      final loaded = service.findByName('My Preset');
      expect(loaded, isNotNull);
      expect(loaded!.isBuiltIn, isFalse);
    });

    test('names the file after the id, not the name', () async {
      final preset = makePreset('My Preset');
      await service.savePreset(preset);
      expect(await presetFiles(), ['${preset.id}.json']);
    });

    test('renaming does not leave the old file behind', () async {
      // The filename used to come from the name, so a rename wrote a second
      // file and the original stayed — the preset appeared twice after reload.
      final preset = makePreset('Before');
      await service.savePreset(preset);
      await service.savePreset(preset.copyWith(name: 'After'));

      expect(await presetFiles(), hasLength(1));
      await service.reload();
      expect(service.userPresets.map((p) => p.name), ['After']);
    });

    test('two names that sanitize alike do not overwrite each other', () async {
      // Verified against the old sanitizer: "VHS Cleanup", "vhs cleanup",
      // "VHS/Cleanup" and "VHS  Cleanup" all produced vhs_cleanup.json, so
      // saving one destroyed the other. Import makes this easy to hit, because
      // the imported preset is very likely to be named like an existing one.
      await service.savePreset(makePreset('VHS Cleanup'));
      await service.savePreset(makePreset('vhs cleanup'));
      await service.savePreset(makePreset('VHS/Cleanup'));

      expect(await presetFiles(), hasLength(3));
      await service.reload();
      expect(service.userPresets, hasLength(3));
    });

    test('refuses to save a built-in', () async {
      final builtIn = ProcessingPreset.builtInPresets().first;
      expect(() => service.savePreset(builtIn), throwsArgumentError);
    });
  });

  group('deleting', () {
    test('removes only the named preset', () async {
      // The old implementation deleted `<sanitized-name>.json` first and only
      // then looked by id, so deleting "vhs cleanup" took "VHS Cleanup"'s file.
      final keep = makePreset('VHS Cleanup');
      final drop = makePreset('vhs cleanup');
      await service.savePreset(keep);
      await service.savePreset(drop);

      await service.deletePreset(drop);
      await service.reload();

      expect(service.userPresets.map((p) => p.name), ['VHS Cleanup']);
    });
  });

  group('load failures are reported, not swallowed', () {
    test('malformed JSON is named with a readable reason', () async {
      await File('${tempDir.path}/broken.json').writeAsString('{not json');
      await service.reload();

      expect(service.loadFailures, hasLength(1));
      expect(service.loadFailures.single.filename, 'broken.json');
      expect(service.loadFailures.single.reason, contains('not valid JSON'));
    });

    test('valid JSON that is not a preset is distinguished', () async {
      await File('${tempDir.path}/other.json').writeAsString('{"hello":"world"}');
      await service.reload();

      expect(service.loadFailures, hasLength(1));
      expect(service.loadFailures.single.reason, contains('not a VapourBox preset'));
    });

    test('one bad file does not stop the others loading', () async {
      await service.savePreset(makePreset('Good'));
      await File('${tempDir.path}/broken.json').writeAsString('nonsense');
      await service.reload();

      expect(service.findByName('Good'), isNotNull);
      expect(service.loadFailures, hasLength(1));
    });

    test('a clean folder reports nothing', () async {
      await service.savePreset(makePreset('Good'));
      await service.reload();
      expect(service.loadFailures, isEmpty);
    });
  });

  group('export', () {
    test('writes JSON that imports back unchanged', () async {
      final preset = makePreset('Shared');
      final dest = '${tempDir.path}/exported-elsewhere.json';
      await service.exportPreset(preset, dest);

      final preview = await service.inspectPresetFile(dest);
      expect(preview.ok, isTrue, reason: preview.error);
      expect(preview.preset!.name, 'Shared');
      expect(preview.preset!.id, preset.id);
    });

    test('is pretty-printed, because people read and send these', () async {
      final dest = '${tempDir.path}/exported.json';
      await service.exportPreset(makePreset('Shared'), dest);
      expect(await File(dest).readAsString(), contains('\n  '));
    });

    test('suggests a filename from the name', () {
      expect(PresetService.suggestedExportFilename(makePreset('My VHS Preset')),
          'my_vhs_preset.json');
      // A name made entirely of separators must still produce something.
      expect(PresetService.suggestedExportFilename(makePreset('///')),
          isNot(startsWith('.')));
    });
  });

  group('import', () {
    Future<String> writeFile(String name, Object json) async {
      final f = File('${tempDir.path}/$name');
      await f.writeAsString(jsonEncode(json));
      return f.path;
    }

    test('reports a readable error rather than throwing', () async {
      final p = await writeFile('bad.json', {'nope': true});
      final preview = await service.inspectPresetFile(p);

      expect(preview.ok, isFalse);
      expect(preview.error, contains('not a VapourBox preset'));
    });

    test('reports a missing file', () async {
      final preview =
          await service.inspectPresetFile('${tempDir.path}/nothing.json');
      expect(preview.ok, isFalse);
      expect(preview.error, contains('no longer exists'));
    });

    test('rejects a preset with no name', () async {
      final p = await writeFile('noname.json', makePreset('  ').toJson());
      final preview = await service.inspectPresetFile(p);
      expect(preview.ok, isFalse);
      expect(preview.error, contains('no name'));
    });

    test('never trusts isBuiltIn from the file', () async {
      // Verified: the flag survives fromJson. A preset claiming to be built-in
      // could not then be deleted or overwritten, so it would be stuck in the
      // menu permanently.
      final json = makePreset('Sneaky').toJson()..['isBuiltIn'] = true;
      final p = await writeFile('sneaky.json', json);

      final preview = await service.inspectPresetFile(p);
      expect(preview.preset!.isBuiltIn, isFalse);

      final imported = await service.commitImport(preview);
      expect(imported.isBuiltIn, isFalse);
      await service.reload();
      expect(service.findByName('Sneaky')!.isBuiltIn, isFalse);
    });

    test('flags custom code, which is the whole reason import confirms', () async {
      final p = await writeFile(
        'custom.json',
        makePreset('Loaded',
                customVapoursynth: 'import os',
                customFfmpegArgs: '-metadata x=1')
            .toJson(),
      );

      final preview = await service.inspectPresetFile(p);
      expect(preview.carriesCustomCode, isTrue);
      expect(preview.customVapoursynth, 'import os');
      expect(preview.customFfmpegArgs, '-metadata x=1');
    });

    test('an ordinary preset carries no custom code', () async {
      final p = await writeFile('plain.json', makePreset('Plain').toJson());
      expect((await service.inspectPresetFile(p)).carriesCustomCode, isFalse);
    });

    test('whitespace-only custom code does not count', () async {
      final p = await writeFile('ws.json',
          makePreset('WS', customVapoursynth: '   \n ').toJson());
      expect((await service.inspectPresetFile(p)).carriesCustomCode, isFalse);
    });

    test('can strip the custom code and keep the settings', () async {
      final p = await writeFile(
        'custom.json',
        makePreset('Loaded',
                customVapoursynth: 'import os', customFfmpegArgs: '-x 1')
            .toJson(),
      );
      final preview = await service.inspectPresetFile(p);

      final imported = await service.commitImport(preview, stripCustomCode: true);
      expect(imported.encodingSettings.customVapoursynth, isEmpty);
      expect(imported.encodingSettings.customFfmpegArgs, isEmpty);

      await service.reload();
      final onDisk = service.findByName('Loaded')!;
      expect(onDisk.encodingSettings.customVapoursynth, isEmpty);
    });

    test('keeps the custom code when not asked to strip it', () async {
      final p = await writeFile(
          'custom.json', makePreset('Kept', customVapoursynth: 'x = 1').toJson());
      final preview = await service.inspectPresetFile(p);

      final imported = await service.commitImport(preview);
      expect(imported.encodingSettings.customVapoursynth, 'x = 1');
    });

    test('spots an update to a preset already installed', () async {
      final original = makePreset('Mine');
      await service.savePreset(original);

      final p = await writeFile('again.json',
          original.copyWith(name: 'Mine, revised').toJson());
      final preview = await service.inspectPresetFile(p);

      expect(preview.existingWithSameId, isNotNull);
      expect(preview.existingWithSameName, isNull);

      // Importing it updates in place rather than adding a second copy.
      await service.commitImport(preview);
      await service.reload();
      expect(service.userPresets, hasLength(1));
      expect(service.userPresets.single.name, 'Mine, revised');
    });

    test('spots a different preset sharing a name', () async {
      await service.savePreset(makePreset('VHS Cleanup'));
      final p = await writeFile('theirs.json', makePreset('VHS Cleanup').toJson());

      final preview = await service.inspectPresetFile(p);
      expect(preview.existingWithSameId, isNull);
      expect(preview.existingWithSameName, isNotNull);

      // Both survive — the ids differ, so they are genuinely two presets.
      await service.commitImport(preview);
      await service.reload();
      expect(service.userPresets, hasLength(2));
    });

    test('commitImport refuses a preview that failed', () async {
      const bad = PresetImportPreview(error: 'nope');
      expect(() => service.commitImport(bad), throwsStateError);
    });
  });
}
