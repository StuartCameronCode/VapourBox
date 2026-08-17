// Tests for the app-wide advanced-mode setting: its default, that it persists,
// and that it notifies listeners so the filter panels rebuild.
//
// The default matters more than it looks — it is what a first-time user sees,
// and every advanced-only section and method in every schema hides behind it.
//
// Run with: flutter test test/advanced_mode_service_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vapourbox/services/advanced_mode_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = AdvancedModeService.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // The singleton carries state between tests.
    service.resetForTesting();
  });

  group('AdvancedModeService', () {
    test('defaults to off', () async {
      await service.initialize();
      expect(service.enabled, false);
    });

    test('loads a saved value', () async {
      SharedPreferences.setMockInitialValues({'showAdvancedOptions': true});
      await service.initialize();
      expect(service.enabled, true);
    });

    test('persists a change', () async {
      await service.initialize();
      await service.setEnabled(true);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('showAdvancedOptions'), true);

      // A fresh load sees it — this is the whole point of the setting being
      // global rather than per-panel widget state.
      service.resetForTesting();
      await service.initialize();
      expect(service.enabled, true);
    });

    test('turning it back off persists too', () async {
      SharedPreferences.setMockInitialValues({'showAdvancedOptions': true});
      await service.initialize();
      await service.setEnabled(false);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('showAdvancedOptions'), false);
    });

    test('notifies listeners on change', () async {
      await service.initialize();

      var notifications = 0;
      void listener() => notifications++;
      service.addListener(listener);
      addTearDown(() => service.removeListener(listener));

      await service.setEnabled(true);
      expect(notifications, 1);

      // Setting the same value again is a no-op, so panels don't rebuild for
      // nothing.
      await service.setEnabled(true);
      expect(notifications, 1);

      await service.setEnabled(false);
      expect(notifications, 2);
    });

    test('initialize is idempotent and does not clobber a live change',
        () async {
      await service.initialize();
      await service.setEnabled(true);
      await service.initialize();
      expect(service.enabled, true);
    });
  });
}
