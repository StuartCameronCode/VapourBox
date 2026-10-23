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
import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/services/image_dimensions.dart';
import 'package:vapourbox/widgets/before_after_comparison.dart';
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
              beforeImage: image,
              afterImage: image,
              displayAspectRatio: displayAspectRatio,
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
}
