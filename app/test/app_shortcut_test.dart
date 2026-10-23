// Tests for the main window's keyboard shortcuts (issue #102).
//
// The requirement that shaped them: a shortcut must never interfere with
// typing. Bare-key shortcuts (I, O, arrows, Home/End) are suppressed while a
// text field has focus, and the key reaches the field instead.
//
// Run with: flutter test test/app_shortcut_test.dart

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/app_shortcut.dart';
import 'package:vapourbox/widgets/app_shortcut_scope.dart';

void main() {
  group('AppShortcut', () {
    test('no two shortcuts share a key combination', () {
      for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
        debugDefaultTargetPlatformOverride = platform;
        final seen = <String, AppShortcut>{};
        for (final shortcut in AppShortcut.values) {
          for (final a in shortcut.activators) {
            final id = '${a.trigger.keyId}/${a.shift}/${a.alt}/'
                '${a.control}/${a.meta}';
            expect(seen[id], isNull,
                reason: '$shortcut and ${seen[id]} share $id on $platform');
            seen[id] = shortcut;
          }
        }
      }
      debugDefaultTargetPlatformOverride = null;
    });

    test('only primary-modifier shortcuts may fire while typing', () {
      for (final shortcut in AppShortcut.values) {
        expect(shortcut.allowedInTextInput, shortcut.primary,
            reason: '$shortcut');
      }
    });

    test('labels use the platform conventions', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(AppShortcut.openSettings.keyLabel, '⌘,');
      expect(AppShortcut.back10Frames.keyLabel, '⇧←');
      expect(AppShortcut.clearInOut.keyLabel, '⌥X');
      expect(AppShortcut.startProcessing.keyLabel, '⌘↩');

      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(AppShortcut.openSettings.keyLabel, 'Ctrl+,');
      expect(AppShortcut.back10Frames.keyLabel, 'Shift+←');
      expect(AppShortcut.clearInOut.keyLabel, 'Alt+X');
      expect(AppShortcut.startProcessing.keyLabel, 'Ctrl+Enter');

      expect(AppShortcut.showShortcuts.keyLabel, '?');
      expect(AppShortcut.nextFrame.tooltip, 'Next frame (→)');
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('AppShortcutScope', () {
    Future<({TextEditingController controller, FocusNode fieldFocus})> pump(
      WidgetTester tester,
      Map<AppShortcut, VoidCallback?> bindings,
    ) async {
      final controller = TextEditingController();
      final fieldFocus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(fieldFocus.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AppShortcutScope(
            bindings: bindings,
            child: Column(
              children: [
                TextField(controller: controller, focusNode: fieldFocus),
                const SizedBox(height: 200, width: 200),
              ],
            ),
          ),
        ),
      ));
      await tester.pump();
      return (controller: controller, fieldFocus: fieldFocus);
    }

    testWidgets('fires bare-key shortcuts when nothing is being typed in',
        (tester) async {
      final fired = <AppShortcut>[];
      await pump(tester, {
        AppShortcut.setInPoint: () => fired.add(AppShortcut.setInPoint),
        AppShortcut.previousFrame: () => fired.add(AppShortcut.previousFrame),
      });

      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);

      expect(fired, [AppShortcut.setInPoint, AppShortcut.previousFrame]);
    });

    testWidgets('leaves keys to a focused text field', (tester) async {
      final fired = <AppShortcut>[];
      final field = await pump(tester, {
        AppShortcut.setInPoint: () => fired.add(AppShortcut.setInPoint),
        AppShortcut.previousFrame: () => fired.add(AppShortcut.previousFrame),
        AppShortcut.goToStart: () => fired.add(AppShortcut.goToStart),
      });

      field.fieldFocus.requestFocus();
      await tester.pump();
      field.controller.value = const TextEditingValue(
        text: 'abc',
        selection: TextSelection.collapsed(offset: 3),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();

      expect(fired, isEmpty);
      // The arrow reached the field and moved the caret.
      expect(field.controller.selection.baseOffset, 2);
    });

    testWidgets('primary-modifier shortcuts still fire while typing',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final fired = <AppShortcut>[];
      final field = await pump(tester, {
        AppShortcut.openSettings: () => fired.add(AppShortcut.openSettings),
      });

      field.fieldFocus.requestFocus();
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.comma);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      expect(fired, [AppShortcut.openSettings]);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a null binding lets the key through', (tester) async {
      await pump(tester, {AppShortcut.setInPoint: null});
      // Nothing to assert beyond not throwing: there is no handler to call.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    });
  });
}
