// Tests for the "NEW" badge version tracking: badges must persist across
// every launch of the same app version, and only advance the next time the
// app itself updates — not clear after a single run.
//
// Run with: flutter test test/whats_new_service_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vapourbox/services/whats_new_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = WhatsNewService.instance;

  void setCurrentVersion(String version) {
    PackageInfo.setMockInitialValues(
      appName: 'VapourBox',
      packageName: 'app.vapourbox.vapourbox',
      version: version,
      buildNumber: '1',
      buildSignature: '',
    );
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // The singleton carries state between tests.
    service.resetForTesting();
  });

  group('WhatsNewService', () {
    test('fresh install flags nothing as new', () async {
      setCurrentVersion('1.2.0');
      await service.initialize();

      expect(service.isNew('0.1.0'), false);
      expect(service.isNew('1.2.0'), false);
    });

    test('an upgrade from a build that predates this tracking is treated like '
        'a fresh install', () async {
      // Old single-key data with no lastRunAppVersion at all — as if this
      // service shipped after the stored lastSeenAppVersion was written by
      // something else, or simply never existed before.
      SharedPreferences.setMockInitialValues({'lastSeenAppVersion': '1.1.0'});
      setCurrentVersion('1.2.0');
      await service.initialize();

      expect(service.isNew('1.2.0'), false,
          reason: 'no lastRunAppVersion means there is nothing reliable to '
              'diff against yet, so this launch just seeds the baseline');
    });

    test('the first launch after an update flags anything shipped since the '
        'version being left behind', () async {
      SharedPreferences.setMockInitialValues({
        'lastRunAppVersion': '1.1.0',
        'lastSeenAppVersion': '1.1.0',
      });
      setCurrentVersion('1.2.0');
      await service.initialize();

      expect(service.isNew('1.2.0'), true, reason: 'added in the update just installed');
      expect(service.isNew('1.1.0'), false, reason: 'already present before this update');
      expect(service.isNew('1.0.0'), false, reason: 'shipped well before the update');
    });

    test('badges persist across many launches of the same version', () async {
      SharedPreferences.setMockInitialValues({
        'lastRunAppVersion': '1.1.0',
        'lastSeenAppVersion': '1.1.0',
      });
      setCurrentVersion('1.2.0');
      await service.initialize();
      expect(service.isNew('1.2.0'), true);

      // Close and reopen the app several times, still on 1.2.0 — nothing
      // about the installed version has changed, so the badge should keep
      // showing every time, not just the first.
      for (var i = 0; i < 3; i++) {
        service.resetForTesting();
        await service.initialize();
        expect(service.isNew('1.2.0'), true, reason: 'launch #${i + 2} at the same version');
      }
    });

    test('the next real update advances the baseline and clears the old badge',
        () async {
      // Already updated once (1.1.0 -> 1.2.0) and relaunched a few times.
      SharedPreferences.setMockInitialValues({
        'lastRunAppVersion': '1.2.0',
        'lastSeenAppVersion': '1.1.0',
      });

      // Now a second update lands: 1.2.0 -> 1.3.0.
      setCurrentVersion('1.3.0');
      await service.initialize();

      expect(service.isNew('1.2.0'), false,
          reason: 'no longer new now that a further update has shipped');
      expect(service.isNew('1.3.0'), true, reason: 'added in the update just installed');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('lastSeenAppVersion'), '1.2.0');
      expect(prefs.getString('lastRunAppVersion'), '1.3.0');
    });

    test('untagged (null) is never new', () async {
      SharedPreferences.setMockInitialValues({
        'lastRunAppVersion': '1.1.0',
        'lastSeenAppVersion': '1.1.0',
      });
      setCurrentVersion('1.2.0');
      await service.initialize();

      expect(service.isNew(null), false);
    });

    test('handles a version bump across a multi-digit component', () async {
      // Plain string comparison would put "1.10.0" before "1.9.0".
      SharedPreferences.setMockInitialValues({
        'lastRunAppVersion': '1.9.0',
        'lastSeenAppVersion': '1.9.0',
      });
      setCurrentVersion('1.10.0');
      await service.initialize();

      expect(service.isNew('1.10.0'), true);
    });
  });
}
