// The colour format help has to describe the formats that actually exist, and
// fit on screen.
//
// Both have already gone wrong. The help is prose in a const, so nothing links it
// to the enum — add a fifth output format and it silently keeps explaining four.
// And the explanation started life inside a hover tooltip, which cannot scroll
// and ran off the screen edge with no way to read the rest; it is a click-opened
// dialog now, and the hover was dropped entirely.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/views/settings/settings_dialog.dart';

/// The help text as one string, for content assertions.
String get _helpText =>
    chromaFormatHelpSections.map((s) => '${s.$1}\n${s.$2}').join('\n\n');

Widget _harness(Brightness brightness) => MaterialApp(
      theme: ThemeData(
        colorScheme:
            ColorScheme.fromSeed(seedColor: Colors.blue, brightness: brightness),
        useMaterial3: true,
      ),
      home: const Scaffold(body: Center(child: ChromaFormatHelpIcon())),
    );

void main() {
  group('the help text', () {
    test('describes every output colour format', () {
      for (final format in ChromaSubsampling.values) {
        expect(_helpText, contains(format.label),
            reason: 'the help does not mention "${format.label}" — a colour '
                'format was added without updating it');
      }
    });

    test('explains both ideas the control combines', () {
      // Subsampling: what it is and why video does it at all.
      expect(_helpText, contains('2x2'));
      expect(_helpText, contains('horizontal pair'));
      expect(_helpText.toLowerCase(), contains('brightness'));
      // Bit depth: what the numbers mean and what goes wrong without them.
      expect(_helpText, contains('256'));
      expect(_helpText, contains('1024'));
      expect(_helpText.toLowerCase(), contains('band'));
    });

    test('warns that matching the source can produce an unplayable file', () {
      // The whole reason the other options exist.
      expect(_helpText, contains('High 4:2:2'));
      expect(_helpText.toLowerCase(), contains('refuse'));
    });

    test('every section has a heading and a body', () {
      expect(chromaFormatHelpSections, isNotEmpty);
      for (final (heading, body) in chromaFormatHelpSections) {
        expect(heading.trim(), isNotEmpty);
        expect(body.trim().length, greaterThan(80),
            reason: '"$heading" has no real explanation under it');
      }
    });
  });

  group('the help icon', () {
    testWidgets('opens the dialog on click', (tester) async {
      await tester.pumpWidget(_harness(Brightness.dark));
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();

      expect(find.text('Output colour format'), findsOneWidget);
      for (final (heading, _) in chromaFormatHelpSections) {
        expect(find.text(heading), findsOneWidget);
      }
      for (final format in ChromaSubsampling.values) {
        expect(find.textContaining(format.label), findsWidgets,
            reason: '${format.label} should be explained in the dialog');
      }
    });

    testWidgets('has no hover tooltip', (tester) async {
      // A decision, not an omission: the explanation is dialog-sized, and a
      // hover summary on top of it was one more thing to read past. Pinned so it
      // does not quietly return — a long tooltip is what ran off screen before.
      await tester.pumpWidget(_harness(Brightness.dark));
      expect(find.byType(Tooltip), findsNothing);
      expect(tester.widget<IconButton>(find.byType(IconButton)).tooltip, isNull);
    });

    testWidgets('is still announced to a screen reader', (tester) async {
      // Dropping the tooltip must not drop the accessible name with it.
      await tester.pumpWidget(_harness(Brightness.light));
      expect(tester.widget<Icon>(find.byType(Icon)).semanticLabel, isNotNull);
    });
  });

  group('the help dialog', () {
    testWidgets('scrolls, and fits a small window', (tester) async {
      // The failure being pinned: content taller than the window with no way to
      // reach the rest of it. 800x600 is smaller than the app's default.
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_harness(Brightness.dark));
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();

      // No overflow while laying out in a short window.
      expect(tester.takeException(), isNull);

      final scrollable = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(Scrollable),
      );
      expect(scrollable, findsWidgets,
          reason: 'the dialog content must be scrollable');

      // And scrolling actually reveals the far end of the text.
      final last = chromaFormatHelpSections.last.$1;
      await tester.drag(scrollable.first, const Offset(0, -4000));
      await tester.pumpAndSettle();
      expect(find.text(last), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('closes again', (tester) async {
      await tester.pumpWidget(_harness(Brightness.light));
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  group('ChromaSubsampling labels', () {
    test('displayName is the label plus its hint', () {
      expect(ChromaSubsampling.original.displayName, 'Match source');
      expect(
          ChromaSubsampling.yuv420.displayName, '4:2:0 8-bit (most compatible)');
      expect(ChromaSubsampling.yuv422p10.displayName,
          '4:2:2 10-bit (keeps 10-bit precision)');
    });

    test('every label names its bit depth except "match source"', () {
      // The depth is what decides playability, so a label that omits it leaves
      // the user guessing at the one thing that matters.
      for (final format in ChromaSubsampling.values) {
        if (format.outputBitDepth == null) continue;
        expect(format.label, contains('${format.outputBitDepth}-bit'),
            reason: '${format.name} should say its depth in its label');
      }
    });
  });
}
