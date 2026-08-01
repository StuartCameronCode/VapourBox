// Tests for the configurable scratch-file directory: the system default, a
// user override, resetting back, and the fallbacks that keep a job runnable
// when the chosen directory has gone away.
//
// Run with: flutter test test/temp_directory_service_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vapourbox/services/temp_directory_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = TempDirectoryService.instance;
  late Directory sandbox;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    sandbox = await Directory.systemTemp.createTemp('vb_temp_service_test_');
    // The singleton carries state between tests; start each one at the default.
    await service.setOverride(null);
  });

  tearDown(() async {
    await service.setOverride(null);
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
  });

  test('defaults to the system temp directory', () async {
    expect(service.override, isNull);
    expect(service.effectivePath, Directory.systemTemp.path);
    expect((await service.resolve()).path, Directory.systemTemp.path);
  });

  test('an override redirects resolve() and file paths', () async {
    await service.setOverride(sandbox.path);

    expect(service.override, sandbox.path);
    expect(service.effectivePath, sandbox.path);
    expect((await service.resolve()).path, sandbox.path);

    final filePath = await service.filePath('job.json');
    expect(filePath, startsWith(sandbox.path));
    expect(filePath, endsWith('job.json'));

    final scratch = await service.createTemp('unit_');
    expect(scratch.parent.path, sandbox.path);
    await scratch.delete(recursive: true);
  });

  test('setOverride(null) resets to the system default', () async {
    await service.setOverride(sandbox.path);
    await service.setOverride(null);

    expect(service.override, isNull);
    expect(service.effectivePath, Directory.systemTemp.path);
  });

  test('an empty or whitespace path is treated as a reset', () async {
    await service.setOverride(sandbox.path);
    await service.setOverride('   ');

    expect(service.override, isNull);
  });

  test('a missing override directory is created', () async {
    final nested = '${sandbox.path}${Platform.pathSeparator}made/by/the/service';
    await service.setOverride(nested);

    expect(await Directory(nested).exists(), isTrue);
    // The writability probe must not leave anything behind.
    expect(await Directory(nested).list().isEmpty, isTrue);
  });

  test('an unusable directory is rejected and the old value kept', () async {
    await service.setOverride(sandbox.path);

    // A path whose parent is a file can't be created.
    final blocker = File('${sandbox.path}${Platform.pathSeparator}not_a_dir');
    await blocker.writeAsString('x');

    await expectLater(
      service.setOverride('${blocker.path}${Platform.pathSeparator}child'),
      throwsA(isA<FileSystemException>()),
    );
    expect(service.override, sandbox.path);
  });

  test('resolve() falls back to system temp if the override disappears',
      () async {
    final removable =
        await Directory.systemTemp.createTemp('vb_temp_service_gone_');
    await service.setOverride(removable.path);
    await removable.delete(recursive: true);

    // It is recreated when it can be...
    expect((await service.resolve()).path, removable.path);
    expect(await removable.exists(), isTrue);
    await removable.delete(recursive: true);

    // ...and when it can't (parent replaced by a file), the job still gets a
    // working directory rather than an exception.
    final parentAsFile = File(removable.path);
    await parentAsFile.writeAsString('x');
    expect((await service.resolve()).path, Directory.systemTemp.path);
    await parentAsFile.delete();
  });

  test('the override survives a reload from preferences', () async {
    await service.setOverride(sandbox.path);

    // initialize() is a no-op once loaded; prove the value was persisted by
    // reading the same key back out of preferences.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('tempDirectoryOverride'), sandbox.path);

    await service.setOverride(null);
    expect(prefs.getString('tempDirectoryOverride'), isNull);
  });
}
