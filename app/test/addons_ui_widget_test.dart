// Settings → Add-ons and the AnimeJaNai notice, over a test AddonService: each
// add-on shows its size, licence and any usage restriction; Install and Remove
// do what they say (Remove naming what goes with it); and the Crop & Resize
// notice keeps the non-commercial terms on screen, offering the download only
// while the models are missing.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:vapourbox/services/addon_manager.dart';
import 'package:vapourbox/services/addon_service.dart';
import 'package:vapourbox/views/pass_settings/pass_settings_inline.dart';
import 'package:vapourbox/views/settings/addons_settings_tab.dart';

class _Marker implements AddonInstaller {
  @override
  final AddonInfo info;
  _Marker(this.info);
  File _f(Directory d) => File(p.join(d.path, info.id));
  @override
  bool isInstalled(Directory d) => _f(d).existsSync();
  @override
  Future<void> install(Directory d, AddonManager _) => _f(d).writeAsString('x');
  @override
  Future<void> remove(Directory d) => _f(d).delete();
}

AddonInfo _info(String id, String feature,
        {String? usageNote, List<String> requires = const [], int bytes = 25000000}) =>
    AddonInfo(
      id: id,
      name: 'Name of $id',
      feature: feature,
      description: 'Description of $id',
      licence: id == animeJanaiAddonId ? 'CC BY-NC-SA 4.0' : 'MIT',
      usageNote: usageNote,
      credit: 'Credit',
      noticeName: 'Test',
      sourceUrl: 'https://example.invalid/$id',
      downloadBytes: bytes,
      requires: requires,
    );

void main() {
  late Directory tmp;
  late AddonService service;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('vb_addons_ui_');
    service = AddonService.forTest(addonsDir: tmp, installers: [
      _Marker(_info('whisper', 'Subtitles', bytes: 3400000)),
      _Marker(_info('whisper-model-small', 'Subtitles', requires: ['whisper'], bytes: 466000000)),
      _Marker(_info(animeJanaiAddonId, 'AI upscaling',
          usageNote: 'Free for non-commercial use only.')),
    ]);
    await service.load();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
    await tester.pumpAndSettle();
  }

  testWidgets('lists every add-on by feature with size, licence and restriction', (tester) async {
    await pump(tester, AddonsSettingsTab(service: service));
    expect(find.text('Subtitles'), findsOneWidget);
    expect(find.text('AI upscaling'), findsOneWidget);
    expect(find.text('Name of whisper-model-small'), findsOneWidget);
    expect(find.text('466 MB'), findsOneWidget);
    expect(find.text('CC BY-NC-SA 4.0'), findsOneWidget);
    expect(find.text('Free for non-commercial use only.'), findsOneWidget);
    expect(find.text('Install'), findsNWidgets(3));
  });

  testWidgets('Install installs, then offers Remove; Remove names what goes with it',
      (tester) async {
    await pump(tester, AddonsSettingsTab(service: service));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('install-whisper-model-small')));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(service.isInstalled('whisper'), isTrue, reason: 'its requirement came first');
    expect(service.isInstalled('whisper-model-small'), isTrue);
    expect(find.byKey(const ValueKey('remove-whisper')), findsOneWidget);
    expect(find.text('Installed'), findsNWidgets(2));

    await tester.tap(find.byKey(const ValueKey('remove-whisper')));
    await tester.pumpAndSettle();
    expect(find.textContaining('This also removes: Name of whisper-model-small'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    // The removal itself is real file I/O, one step per file, after the
    // dialog closes: let each step's I/O complete and its continuation run.
    for (var i = 0; i < 10 && service.isInstalled('whisper'); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(service.isInstalled('whisper'), isFalse);
    expect(service.isInstalled('whisper-model-small'), isFalse);
  });

  testWidgets('the AnimeJaNai notice shows its terms, and Download only while missing',
      (tester) async {
    await pump(tester, AnimeJanaiNotice(service: service));
    expect(find.text('Free for non-commercial use only.'), findsOneWidget);
    expect(find.textContaining('not installed'), findsOneWidget);
    expect(find.textContaining('Download (25 MB)'), findsOneWidget);

    await tester.runAsync(() => service.install(animeJanaiAddonId));
    await tester.pumpAndSettle();
    expect(find.text('Free for non-commercial use only.'), findsOneWidget,
        reason: 'the restriction applies to every job, not just the download');
    expect(find.textContaining('Download'), findsNothing);
    expect(find.text('AnimeJaNai models installed.'), findsOneWidget);
  });
}
