// Tests for the app theme setting (issue #102): its default, persistence, and
// that every theme builds in the brightness it claims.
//
// Run with: flutter test test/theme_service_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vapourbox/services/theme_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = ThemeService.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    service.resetForTesting();
  });

  group('ThemeService', () {
    test('defaults to Auto, which follows the system', () async {
      await service.initialize();
      expect(service.theme, AppTheme.auto);
      expect(service.theme.themeMode, ThemeMode.system);
    });

    test('loads a saved theme', () async {
      SharedPreferences.setMockInitialValues({'appTheme': 'monokai'});
      await service.initialize();
      expect(service.theme, AppTheme.monokai);
    });

    test('an unknown saved name falls back to Auto', () async {
      SharedPreferences.setMockInitialValues({'appTheme': 'solarized'});
      await service.initialize();
      expect(service.theme, AppTheme.auto);
    });

    test('persists a change and notifies', () async {
      await service.initialize();
      var notified = 0;
      void listener() => notified++;
      service.addListener(listener);
      addTearDown(() => service.removeListener(listener));

      await service.setTheme(AppTheme.pride);

      expect(notified, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('appTheme'), 'pride');
    });
  });

  group('AppTheme', () {
    test('every theme has a label and description', () {
      for (final theme in AppTheme.values) {
        expect(theme.label, isNotEmpty);
        expect(theme.description, isNotEmpty);
      }
    });

    test('each theme builds with the brightness it will be shown in', () {
      for (final theme in AppTheme.values) {
        expect(theme.lightTheme.colorScheme.brightness,
            theme == AppTheme.monokai ? Brightness.dark : Brightness.light,
            reason: '$theme light');
        expect(theme.darkTheme.colorScheme.brightness, Brightness.dark,
            reason: '$theme dark');
      }
    });

    test('fixed themes ignore the system setting', () {
      expect(AppTheme.light.themeMode, ThemeMode.light);
      expect(AppTheme.dark.themeMode, ThemeMode.dark);
      expect(AppTheme.monokai.themeMode, ThemeMode.dark);
      expect(AppTheme.pride.themeMode, ThemeMode.system);
    });

    test('Monokai is pastel accents on neutral grey, not one colour', () {
      final scheme = AppTheme.monokai.darkTheme.colorScheme;
      expect(scheme.surface, const Color(0xFF2D2A2E));
      expect(scheme.onSurface, const Color(0xFFFCFCFA));
      expect(scheme.primary, const Color(0xFFAB9DF2));
      // Each accent role gets a different palette colour.
      final accents = {
        scheme.primary,
        scheme.secondary,
        scheme.tertiary,
        scheme.error,
      };
      expect(accents, hasLength(4));
      // The background is grey: no channel more than a few levels off the
      // others.
      final s = scheme.surface;
      final channels = [s.r, s.g, s.b].map((c) => (c * 255).round());
      expect(
        channels.reduce((a, b) => a > b ? a : b) -
            channels.reduce((a, b) => a < b ? a : b),
        lessThanOrEqualTo(6),
      );
    });

    test('only Pride draws the rainbow stripe, in both brightnesses', () {
      for (final theme in AppTheme.values) {
        for (final data in [theme.lightTheme, theme.darkTheme]) {
          final stripe = data.extension<AppDecorations>()?.accentStripe;
          if (theme == AppTheme.pride) {
            expect(stripe, AppThemes.prideStripe);
          } else {
            expect(stripe, isNull, reason: '$theme');
          }
        }
      }
    });
  });
}
