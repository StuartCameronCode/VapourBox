import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/views/histogram_scope.dart';

/// Encodes a solid-colour PNG so the scope can be pumped against real bytes
/// rather than a mock.
///
/// Must be called inside [WidgetTester.runAsync]: image codecs are real async
/// work, which the fake-async test zone never completes.
Future<Uint8List> solidPng(int r, int g, int b, {int size = 8}) async {
  final rgba = Uint8List(size * size * 4);
  for (var i = 0; i < size * size; i++) {
    rgba[i * 4] = r;
    rgba[i * 4 + 1] = g;
    rgba[i * 4 + 2] = b;
    rgba[i * 4 + 3] = 255;
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: size,
    height: size,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final codec = await descriptor.instantiateCodec();
  final frame = await codec.getNextFrame();
  final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
  frame.image.dispose();
  codec.dispose();
  descriptor.dispose();
  return png!.buffer.asUint8List();
}

Widget host(Widget child, {Brightness brightness = Brightness.light}) {
  return MaterialApp(
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.blue,
        brightness: brightness,
      ),
    ),
    home: Scaffold(body: Center(child: child)),
  );
}

/// Pumps [widget] and gives the scope's decode a real moment to finish.
Future<void> pumpScope(WidgetTester tester, Widget widget) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(widget);
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  await tester.pump();
}

void main() {
  const timeout = Timeout(Duration(seconds: 30));

  testWidgets('renders the empty state with no preview', (tester) async {
    await pumpScope(tester, host(const HistogramScope(imageBytes: null)));

    expect(find.text('No preview yet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, timeout: timeout);

  testWidgets('an empty buffer does not throw', (tester) async {
    await pumpScope(tester, host(HistogramScope(imageBytes: Uint8List(0))));

    expect(find.text('No preview yet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, timeout: timeout);

  testWidgets('unreadable bytes fall back to the empty state', (tester) async {
    await pumpScope(
      tester,
      host(HistogramScope(imageBytes: Uint8List.fromList([1, 2, 3, 4, 5]))),
    );

    expect(find.text('No preview yet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, timeout: timeout);

  testWidgets('bins a real preview and reports clipping', (tester) async {
    late Uint8List png;
    await tester.runAsync(() async => png = await solidPng(0, 0, 0));

    await pumpScope(tester, host(HistogramScope(imageBytes: png)));

    // An all-black frame is 100% shadow-clipped, 0% highlight-clipped.
    expect(find.text('clip 100% / 0%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, timeout: timeout);

  testWidgets('re-bins when the preview changes', (tester) async {
    late Uint8List black;
    late Uint8List white;
    await tester.runAsync(() async {
      black = await solidPng(0, 0, 0);
      white = await solidPng(255, 255, 255);
    });

    await pumpScope(tester, host(HistogramScope(imageBytes: black)));
    expect(find.text('clip 100% / 0%'), findsOneWidget);

    await pumpScope(tester, host(HistogramScope(imageBytes: white)));
    expect(find.text('clip 0% / 100%'), findsOneWidget);
  }, timeout: timeout);

  testWidgets('switches between Luma and RGB, and closes', (tester) async {
    late Uint8List png;
    await tester.runAsync(() async => png = await solidPng(90, 140, 200));
    var closed = false;

    await pumpScope(
      tester,
      host(
        HistogramScope(imageBytes: png, onClose: () => closed = true),
        brightness: Brightness.dark,
      ),
    );

    await tester.tap(find.text('RGB'));
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Luma'));
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(closed, isTrue);
  }, timeout: timeout);
}
