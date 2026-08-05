// The colour format help has to describe the formats that actually exist, be
// readable in both themes, and fit on screen.
//
// All three have already gone wrong once. The help is prose in a const, so
// nothing links it to the enum — add a fifth output format and it silently keeps
// explaining four. Styling its tooltip text white read fine in light mode and was
// invisible in dark, where Material inverts the tooltip surface. And the whole
// explanation started life *inside* the tooltip, which cannot scroll and ran off
// the screen edge with no way to read the rest.

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/views/settings/settings_dialog.dart';

/// The help text as one string, for content assertions.
String get _helpText => chromaFormatHelpSections
    .map((s) => '${s.$1}\n${s.$2}')
    .join('\n\n');

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

  group('the hover tooltip', () {
    test('stays short enough to sit on screen', () {
      // A Tooltip cannot scroll and is placed against its child, so a long one
      // runs off the edge. Detail belongs in the dialog.
      final lines = chromaFormatTooltip.split('\n');
      expect(lines.length, lessThanOrEqualTo(3),
          reason: 'the hover text is ${lines.length} lines — move detail into '
              'showChromaFormatHelp, which scrolls');
      for (final line in lines) {
        expect(line.length, lessThanOrEqualTo(72), reason: 'wrap: "$line"');
      }
    });

    test('points at the detail', () {
      expect(chromaFormatTooltip.toLowerCase(), contains('click'));
    });
  });

  /// WCAG relative-contrast ratio between two opaque colours (1 = identical,
  /// 21 = black on white). 4.5 is the AA threshold for body text.
  double contrastRatio(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final hi = la > lb ? la : lb;
    final lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  Widget harness(Brightness brightness) => MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.blue, brightness: brightness),
          useMaterial3: true,
        ),
        home: const Scaffold(body: Center(child: ChromaFormatHelpIcon())),
      );

  /// Hover the help icon and return the tooltip's text and surface colours as
  /// actually rendered.
  Future<({Color text, Color surface})> hoverTooltip(
      WidgetTester tester, Brightness brightness) async {
    await tester.pumpWidget(harness(brightness));

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byType(Icon)));
    await tester.pump(const Duration(seconds: 1));

    final textFinder = find.text(chromaFormatTooltip);
    expect(textFinder, findsOneWidget,
        reason: 'the tooltip should be showing after a hover');
    final textColor = tester.widget<Text>(textFinder).style?.color;
    expect(textColor, isNotNull, reason: 'tooltip text must set a colour');

    // The surface is the nearest ancestor DecoratedBox carrying a fill.
    final boxes = tester
        .widgetList<DecoratedBox>(
            find.ancestor(of: textFinder, matching: find.byType(DecoratedBox)))
        .map((b) => b.decoration)
        .whereType<BoxDecoration>()
        .where((d) => d.color != null)
        .toList();
    expect(boxes, isNotEmpty, reason: 'tooltip must paint a background');

    return (text: textColor!, surface: boxes.first.color!);
  }

  group('the tooltip is readable', () {
    for (final brightness in Brightness.values) {
      testWidgets('in ${brightness.name} mode', (tester) async {
        final colors = await hoverTooltip(tester, brightness);
        final ratio = contrastRatio(colors.text, colors.surface);
        expect(ratio, greaterThanOrEqualTo(4.5),
            reason: 'tooltip text ${colors.text} on ${colors.surface} has a '
                'contrast ratio of ${ratio.toStringAsFixed(2)}:1 in '
                '${brightness.name} mode — unreadable. The text colour must come '
                'from the same pair as the tooltip surface '
                '(onInverseSurface/inverseSurface), not from the page text.');
      });
    }
  });

  group('the help dialog', () {
    testWidgets('opens from the icon and shows every section', (tester) async {
      await tester.pumpWidget(harness(Brightness.dark));
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

    testWidgets('scrolls, and fits a small window', (tester) async {
      // The failure being pinned: content taller than the window with no way to
      // reach the rest of it. 800x600 is smaller than the app's default.
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness(Brightness.dark));
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
      await tester.pumpWidget(harness(Brightness.light));
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
