// The second colour help dialog: not "which format do I pick" (that is
// settings_chroma_help_test.dart) but "what does VapourBox actually do to my
// colour". Added for people who want to reason about the output rather than
// just choose from a list.
//
// The same two failures the first dialog already hit are pinned here, because
// nothing about them was specific to that one: prose in a const drifts away
// from the code it describes, and a multi-paragraph explanation that cannot
// scroll runs off the bottom of a small window with no way to read the rest.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vapourbox/views/settings/settings_dialog.dart';

String get _helpText =>
    colourPipelineHelpSections.map((s) => '${s.$1}\n${s.$2}').join('\n\n');

Widget _harness(Brightness brightness) => MaterialApp(
      theme: ThemeData(
        colorScheme:
            ColorScheme.fromSeed(seedColor: Colors.blue, brightness: brightness),
        useMaterial3: true,
      ),
      home: const Scaffold(body: Center(child: ColourPipelineHelpIcon())),
    );

void main() {
  group('the pipeline explanation', () {
    test('covers every stage a frame passes through', () {
      // Each of these is a real, separately-observable stage. Dropping one
      // leaves a gap exactly where someone would be trying to reason.
      expect(_helpText.toLowerCase(), contains('ffmpeg'));
      expect(_helpText.toLowerCase(), contains('pipe'));
      expect(_helpText.toLowerCase(), contains('dither'));
      expect(_helpText.toLowerCase(), contains('encoder'));
    });

    test('explains the two things that surprise people', () {
      // The Y4M pipe silently dropping aspect and colour tags is why the output
      // has to be re-stamped, and is invisible from outside.
      expect(_helpText, contains('BT.601'));
      expect(_helpText.toLowerCase(), contains('untagged'));
      // And a hardware encoder advertising a mode its card lacks is issue #74.
      expect(_helpText, contains('4:2:2'));
      expect(_helpText, contains('NVENC'));
    });

    test('says values are rescaled rather than taken literally', () {
      // The 8-bit-vocabulary rule is the single most useful thing here for
      // anyone tuning a filter on a 10-bit source.
      expect(_helpText, contains('0–255'));
      expect(_helpText.toLowerCase(), contains('rescal'));
    });

    test('every section has a heading and a real body', () {
      expect(colourPipelineHelpSections, isNotEmpty);
      for (final (heading, body) in colourPipelineHelpSections) {
        expect(heading.trim(), isNotEmpty);
        expect(body.trim().length, greaterThan(80),
            reason: '"$heading" has no real explanation under it');
      }
    });
  });

  group('the icon', () {
    testWidgets('opens the dialog on click', (tester) async {
      await tester.pumpWidget(_harness(Brightness.dark));
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();

      expect(find.text('How VapourBox handles colour'), findsOneWidget);
      for (final (heading, _) in colourPipelineHelpSections) {
        expect(find.text(heading), findsOneWidget);
      }
    });

    testWidgets('is distinguishable from the format help beside it', (
      tester,
    ) async {
      // Two adjacent buttons drawn the same way read as one control repeated.
      await tester.pumpWidget(_harness(Brightness.light));
      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.icon, isNot(Icons.info_outline),
          reason: 'ChromaFormatHelpIcon already uses info_outline');
      expect(icon.semanticLabel, isNotNull,
          reason: 'a screen reader must be able to tell them apart too');
    });
  });

  group('the dialog', () {
    testWidgets('scrolls, and fits a small window', (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_harness(Brightness.dark));
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final scrollable = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(Scrollable),
      );
      expect(scrollable, findsWidgets);

      final last = colourPipelineHelpSections.last.$1;
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
}
