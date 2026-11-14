// Tests for the preview comparison's Fit / 1:1 zoom (issue #8).
//
// 1:1 means one stored frame pixel per PHYSICAL screen pixel, so the scale
// depends on the device pixel ratio and the panel size, and the frame has to
// sit on the pixel grid or nearest-neighbour sampling repeats rows.
//
// Run with: flutter test test/before_after_comparison_test.dart

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/services/image_dimensions.dart';
import 'package:vapourbox/widgets/before_after_comparison.dart';
import 'package:vapourbox/widgets/comparison_view_mode.dart';
import 'package:vapourbox/widgets/comparison_zoom_controller.dart';

Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFF808080),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

/// A minimal JPEG header: SOI, an APP0 segment, then SOF0.
Uint8List _jpegHeader(int width, int height) => Uint8List.fromList([
      0xFF, 0xD8, // SOI
      0xFF, 0xE0, 0x00, 0x06, 0x4A, 0x46, 0x49, 0x46, // APP0, length 6
      0xFF, 0xC0, 0x00, 0x11, 0x08, // SOF0, length 17, 8-bit
      height >> 8, height & 0xFF,
      width >> 8, width & 0xFF,
      0x03,
    ]);

void main() {
  group('encodedImageSize', () {
    test('reads a PNG header', () async {
      final png = await _png(321, 123);
      expect(encodedImageSize(png), const Size(321, 123));
    });

    test('reads a JPEG start-of-frame after other segments', () {
      expect(encodedImageSize(_jpegHeader(720, 576)), const Size(720, 576));
    });

    test('returns null for anything else or a truncated header', () {
      expect(encodedImageSize(Uint8List.fromList([1, 2, 3, 4])), isNull);
      expect(encodedImageSize(Uint8List.fromList([0xFF, 0xD8, 0xFF])), isNull);
    });
  });

  group('Fit / 1:1', () {
    late ComparisonZoomController controller;

    setUp(() => controller = ComparisonZoomController());

    Future<void> pump(
      WidgetTester tester,
      Uint8List image, {
      double width = 400,
      double height = 300,
      double devicePixelRatio = 1,
      double? displayAspectRatio,
      Uint8List? beforeImage,
      double? beforeAspectRatio,
    }) async {
      tester.view.devicePixelRatio = devicePixelRatio;
      tester.view.physicalSize =
          const Size(1000, 1000) * devicePixelRatio;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            height: height,
            child: BeforeAfterComparisonWidget(
              beforeImage: beforeImage ?? image,
              afterImage: image,
              beforeAspectRatio: beforeImage != null
                  ? beforeAspectRatio
                  : displayAspectRatio,
              afterAspectRatio: displayAspectRatio,
              zoomController: controller,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    Matrix4 frameTransform(WidgetTester tester) => tester
        .widget<Transform>(find
            .descendant(
              of: find.byType(BeforeAfterComparisonWidget),
              matching: find.byType(Transform),
            )
            .first)
        .transform;

    double scaleOf(WidgetTester tester) =>
        frameTransform(tester).getMaxScaleOnAxis();

    testWidgets('the 1:1 button scales one frame pixel to one screen pixel',
        (tester) async {
      final image = await tester.runAsync(() => _png(200, 100));
      // The 400x300 panel (less its 1px border) fits the 2:1 frame at
      // 398 wide, so 1:1 is 200/398 of fit.
      await pump(tester, image!);
      expect(find.text('${(398 / 200 * 100).round()}%'), findsOneWidget);

      await tester.tap(find.text('1:1'));
      await tester.pumpAndSettle();

      expect(scaleOf(tester), closeTo(200 / 398, 1e-9));
      expect(find.text('100%'), findsOneWidget);
    });

    testWidgets('1:1 counts physical pixels, not logical ones',
        (tester) async {
      final image = await tester.runAsync(() => _png(200, 100));
      await pump(tester, image!, devicePixelRatio: 2);

      controller.showActualSize();
      await tester.pumpAndSettle();

      expect(scaleOf(tester), closeTo(100 / 398, 1e-9));
    });

    testWidgets('1:1 holds when the panel is resized', (tester) async {
      final image = await tester.runAsync(() => _png(200, 100));
      await pump(tester, image!);
      controller.showActualSize();
      await tester.pumpAndSettle();

      // Now height-limited: 298 tall fits the 2:1 frame 596 wide.
      await pump(tester, image, width: 600);
      expect(scaleOf(tester), closeTo(200 / 596, 1e-9));
      expect(find.text('100%'), findsOneWidget);
    });

    testWidgets('an anamorphic frame keeps its rows exact', (tester) async {
      // 720x480 shown at 16:9: the fitted height decides the scale.
      final image = await tester.runAsync(() => _png(720, 480));
      await pump(tester, image!, displayAspectRatio: 16 / 9);
      controller.showActualSize();
      await tester.pumpAndSettle();

      final fittedHeight = 398 / (16 / 9);
      expect(scaleOf(tester), closeTo(480 / fittedHeight, 1e-9));
    });

    // Issue #149: a 720x576 PAL 4:3 source upscaled and padded to a
    // 1920x1080 canvas was drawn squashed into the source's 4:3 shape.
    testWidgets('each side is drawn at its own display aspect',
        (tester) async {
      final source = await tester.runAsync(() => _png(720, 576));
      final processed = await tester.runAsync(() => _png(1920, 1080));
      await pump(
        tester,
        processed!,
        displayAspectRatio: 16 / 9,
        beforeImage: source!,
        beforeAspectRatio: 4 / 3,
      );

      // Stack order: the processed layer, then the source layer.
      final images = find.descendant(
        of: find.byType(BeforeAfterComparisonWidget),
        matching: find.byType(Image),
      );
      expect(images, findsNWidgets(2));
      final after = tester.getRect(images.at(0));
      final before = tester.getRect(images.at(1));
      expect(after.width / after.height, closeTo(16 / 9, 1e-6));
      expect(before.width / before.height, closeTo(4 / 3, 1e-6));
      // Both fit the 398x298 panel: the processed one by width, the source
      // by height.
      expect(after.width, closeTo(398, 1e-6));
      expect(before.height, closeTo(298, 1e-6));
    });

    testWidgets('1:1 is measured against the processed frame\'s aspect',
        (tester) async {
      final source = await tester.runAsync(() => _png(720, 576));
      final processed = await tester.runAsync(() => _png(1920, 1080));
      await pump(
        tester,
        processed!,
        displayAspectRatio: 16 / 9,
        beforeImage: source!,
        beforeAspectRatio: 4 / 3,
      );
      controller.showActualSize();
      await tester.pumpAndSettle();

      // Fitted 398 wide at 16:9; 1:1 puts its 1080 rows on 1080 pixels.
      final fittedHeight = 398 / (16 / 9);
      expect(scaleOf(tester), closeTo(1080 / fittedHeight, 1e-9));
    });

    testWidgets('the frame is drawn on the pixel grid at 1:1', (tester) async {
      // An odd-sized frame centred in an even panel would straddle pixels.
      final image = await tester.runAsync(() => _png(201, 101));
      await pump(tester, image!);
      controller.showActualSize();
      await tester.pumpAndSettle();

      final box = tester.renderObject<RenderBox>(find
          .descendant(
            of: find.byType(BeforeAfterComparisonWidget),
            matching: find.byType(Listener),
          )
          .first);
      final origin = box.localToGlobal(Offset.zero);
      final m = frameTransform(tester);
      // With Transform's centre alignment the frame's top-left lands at
      // centre + translation - displayed size / 2.
      final scale = m.getMaxScaleOnAxis();
      final fitted = Size(box.size.width, box.size.width / (201 / 101));
      final left = origin.dx +
          box.size.width / 2 +
          m.getTranslation().x -
          fitted.width * scale / 2;
      final top = origin.dy +
          box.size.height / 2 +
          m.getTranslation().y -
          fitted.height * scale / 2;
      expect(left, closeTo(left.roundToDouble(), 1e-6));
      expect(top, closeTo(top.roundToDouble(), 1e-6));
    });

    testWidgets('Fit returns to the fitted frame, from the button or the controller',
        (tester) async {
      final image = await tester.runAsync(() => _png(200, 100));
      await pump(tester, image!);
      controller.showActualSize();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Fit'));
      await tester.pumpAndSettle();
      expect(scaleOf(tester), 1.0);

      controller.showActualSize();
      await tester.pumpAndSettle();
      controller.fit();
      await tester.pumpAndSettle();
      expect(scaleOf(tester), 1.0);
    });

    testWidgets('a detached controller does nothing', (tester) async {
      final image = await tester.runAsync(() => _png(200, 100));
      await pump(tester, image!);
      await tester.pumpWidget(const SizedBox());
      controller.showActualSize();
      controller.fit();
    });
  });

  // Forum feedback (videohelp 419911): the divider stopped 5% short of each
  // edge, hiding a typical left crop; and there was no way to see either frame
  // whole.
  group('divider and view modes', () {
    const panel = Size(400, 300);

    Future<void> pump(
      WidgetTester tester, {
      required Uint8List before,
      required Uint8List after,
      double? beforeAspectRatio,
      double? afterAspectRatio,
      ComparisonViewMode viewMode = ComparisonViewMode.split,
      ValueChanged<ComparisonViewMode>? onViewModeChanged,
      ComparisonZoomController? zoomController,
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 1000);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: panel.width,
            height: panel.height,
            child: BeforeAfterComparisonWidget(
              beforeImage: before,
              afterImage: after,
              beforeAspectRatio: beforeAspectRatio,
              afterAspectRatio: afterAspectRatio,
              viewMode: viewMode,
              onViewModeChanged: onViewModeChanged,
              zoomController: zoomController,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    Rect panelRect(WidgetTester tester) =>
        tester.getRect(find.byType(BeforeAfterComparisonWidget));

    /// The width of the screen-space clip that shows the original.
    double originalClipWidth(WidgetTester tester) {
      final clip = tester.renderObject<RenderClipRect>(find
          .descendant(
            of: find.byType(BeforeAfterComparisonWidget),
            matching: find.byType(ClipRect),
          )
          .first);
      return clip.clipper!.getClip(clip.size).width;
    }

    Finder images() => find.descendant(
          of: find.byType(BeforeAfterComparisonWidget),
          matching: find.byType(Image),
        );

    testWidgets('a drag past either edge takes the divider to 0 and 1',
        (tester) async {
      final image = await tester.runAsync(() => _png(200, 100));
      await pump(tester, before: image!, after: image);
      final bounds = panelRect(tester);
      final centre = bounds.center;

      await tester.dragFrom(centre, const Offset(-1000, 0));
      await tester.pumpAndSettle();
      expect(originalClipWidth(tester), 0);
      final lineAtLeft =
          tester.getRect(find.byKey(const Key('comparison-divider')));
      final handleAtLeft =
          tester.getRect(find.byKey(const Key('comparison-divider-handle')));
      // The 1 px border insets the content; the line touches its left edge.
      expect(lineAtLeft.left, closeTo(bounds.left + 1, 1e-6));
      expect(handleAtLeft.left, greaterThanOrEqualTo(bounds.left));

      await tester.dragFrom(centre, const Offset(2000, 0));
      await tester.pumpAndSettle();
      final contentWidth = bounds.width - 2;
      expect(originalClipWidth(tester), closeTo(contentWidth, 1e-6));
      final lineAtRight =
          tester.getRect(find.byKey(const Key('comparison-divider')));
      final handleAtRight =
          tester.getRect(find.byKey(const Key('comparison-divider-handle')));
      expect(lineAtRight.right, closeTo(bounds.right - 1, 1e-6));
      expect(handleAtRight.right, lessThanOrEqualTo(bounds.right));
    });

    testWidgets('a tap at the edge puts the divider there, not 5% in',
        (tester) async {
      final image = await tester.runAsync(() => _png(200, 100));
      await pump(tester, before: image!, after: image);
      final bounds = panelRect(tester);

      await tester.tapAt(Offset(bounds.left + 1.5, bounds.center.dy));
      await tester.pump(const Duration(milliseconds: 500));
      expect(originalClipWidth(tester), lessThan(1));
    });

    group('each mode shows only its own side', () {
      late Uint8List source;
      late Uint8List processed;

      Future<void> load(WidgetTester tester) async {
        source = (await tester.runAsync(() => _png(720, 576)))!;
        processed = (await tester.runAsync(() => _png(1920, 1080)))!;
      }

      Future<void> pumpMode(WidgetTester tester, ComparisonViewMode mode) =>
          pump(
            tester,
            before: source,
            after: processed,
            beforeAspectRatio: 4 / 3,
            afterAspectRatio: 16 / 9,
            viewMode: mode,
          );

      testWidgets('Original', (tester) async {
        await load(tester);
        await pumpMode(tester, ComparisonViewMode.original);
        expect(images(), findsOneWidget);
        final rect = tester.getRect(images());
        expect(rect.width / rect.height, closeTo(4 / 3, 1e-6));
        expect(find.text('Original'), findsOneWidget);
        expect(find.text('Processed'), findsNothing);
        expect(find.byKey(const Key('comparison-divider')), findsNothing);
        expect(
            find.byKey(const Key('comparison-divider-handle')), findsNothing);
      });

      testWidgets('Processed', (tester) async {
        await load(tester);
        await pumpMode(tester, ComparisonViewMode.processed);
        expect(images(), findsOneWidget);
        final rect = tester.getRect(images());
        expect(rect.width / rect.height, closeTo(16 / 9, 1e-6));
        expect(find.text('Processed'), findsOneWidget);
        expect(find.text('Original'), findsNothing);
        expect(find.byKey(const Key('comparison-divider')), findsNothing);
      });

      testWidgets('Split', (tester) async {
        await load(tester);
        await pumpMode(tester, ComparisonViewMode.split);
        expect(images(), findsNWidgets(2));
        expect(find.text('Original'), findsOneWidget);
        expect(find.text('Processed'), findsOneWidget);
        expect(find.byKey(const Key('comparison-divider')), findsOneWidget);
      });

      testWidgets('dragging does nothing outside Split', (tester) async {
        await load(tester);
        await pumpMode(tester, ComparisonViewMode.original);
        await tester.dragFrom(
            panelRect(tester).center, const Offset(-1000, 0));
        await tester.pumpAndSettle();
        // Back in Split, the divider is still in the middle.
        await pumpMode(tester, ComparisonViewMode.split);
        expect(originalClipWidth(tester),
            closeTo((panel.width - 2) / 2, 1e-6));
      });
    });

    testWidgets('1:1 is measured against the frame on screen',
        (tester) async {
      final controller = ComparisonZoomController();
      final source = await tester.runAsync(() => _png(720, 576));
      final processed = await tester.runAsync(() => _png(1920, 1080));
      Future<void> pumpMode(ComparisonViewMode mode) => pump(
            tester,
            before: source!,
            after: processed!,
            beforeAspectRatio: 4 / 3,
            afterAspectRatio: 16 / 9,
            viewMode: mode,
            zoomController: controller,
          );

      await pumpMode(ComparisonViewMode.processed);
      controller.showActualSize();
      await tester.pumpAndSettle();
      double scale() => tester
          .widget<Transform>(find
              .descendant(
                of: find.byType(BeforeAfterComparisonWidget),
                matching: find.byType(Transform),
              )
              .first)
          .transform
          .getMaxScaleOnAxis();
      // 398 wide at 16:9; 1080 rows on 1080 pixels.
      expect(scale(), closeTo(1080 / (398 / (16 / 9)), 1e-9));
      expect(find.text('100%'), findsOneWidget);

      // The 4:3 source fits by height (298); 576 rows on 576 pixels.
      await pumpMode(ComparisonViewMode.original);
      expect(scale(), closeTo(576 / 298, 1e-9));
      expect(find.text('100%'), findsOneWidget);
    });

    testWidgets('the mode and the divider survive a new processed frame',
        (tester) async {
      final source = await tester.runAsync(() => _png(720, 576));
      final first = await tester.runAsync(() => _png(1920, 1080));
      final second = await tester.runAsync(() => _png(1280, 720));

      // Move the divider in Split first.
      await pump(tester, before: source!, after: first!);
      await tester.dragFrom(panelRect(tester).center, const Offset(-100, 0));
      await tester.pumpAndSettle();
      final moved = originalClipWidth(tester);
      expect(moved, lessThan((panel.width - 2) / 2));

      await pump(tester,
          before: source,
          after: first,
          viewMode: ComparisonViewMode.processed);
      await pump(tester,
          before: source,
          after: second!,
          viewMode: ComparisonViewMode.processed);
      expect(images(), findsOneWidget);
      final shown = tester.widget<Image>(images()).image as MemoryImage;
      expect(identical(shown.bytes, second), isTrue);

      // Back to Split: the divider is where the user left it.
      await pump(tester, before: source, after: second);
      expect(originalClipWidth(tester), closeTo(moved, 1e-6));
    });

    testWidgets('the view-mode control reports a tap, with shortcut tooltips',
        (tester) async {
      final image = await tester.runAsync(() => _png(200, 100));
      final picked = <ComparisonViewMode>[];
      await pump(tester,
          before: image!, after: image, onViewModeChanged: picked.add);

      final control = find.byKey(const Key('comparison-view-mode'));
      expect(control, findsOneWidget);
      await tester.tap(
          find.descendant(of: control, matching: find.text('Processed')));
      await tester.tap(
          find.descendant(of: control, matching: find.text('Original')));
      expect(picked,
          [ComparisonViewMode.processed, ComparisonViewMode.original]);

      for (final mode in ComparisonViewMode.values) {
        expect(find.byTooltip(mode.shortcut.tooltipFor(mode.description)),
            findsOneWidget);
      }
    });

    testWidgets('no control without a callback', (tester) async {
      final image = await tester.runAsync(() => _png(200, 100));
      await pump(tester, before: image!, after: image);
      expect(find.byKey(const Key('comparison-view-mode')), findsNothing);
    });
  });
}
