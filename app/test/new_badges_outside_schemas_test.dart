// The NEW badges on things that are not schema elements (task #133): the
// codecs offered in Settings → Output (VideoCodec.sinceAppVersion), and the
// preview's Original / Split / Processed control
// (ComparisonViewMode.sinceAppVersion). Each badge leads to what is new: a
// codec badges its radio, the Video Codec heading, the Output tab and the
// toolbar's Settings button (SettingsDialog.hasNew).
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vapourbox/models/video_job.dart';
import 'package:vapourbox/services/advanced_mode_service.dart';
import 'package:vapourbox/services/theme_service.dart';
import 'package:vapourbox/services/whats_new_service.dart';
import 'package:vapourbox/viewmodels/main_viewmodel.dart';
import 'package:vapourbox/views/settings/addons_settings_tab.dart';
import 'package:vapourbox/views/settings/settings_dialog.dart';
import 'package:vapourbox/widgets/before_after_comparison.dart';
import 'package:vapourbox/widgets/comparison_view_mode.dart';
import 'package:vapourbox/widgets/new_badge.dart';

/// Launch [current] after last running [lastRun] (null: a fresh install).
Future<void> _launch(String current, {String? lastRun}) async {
  SharedPreferences.setMockInitialValues({
    if (lastRun != null) 'lastRunAppVersion': lastRun,
    if (lastRun != null) 'lastSeenAppVersion': lastRun,
  });
  PackageInfo.setMockInitialValues(
      appName: 'VapourBox', packageName: 'app.vapourbox.vapourbox',
      version: current, buildNumber: '1', buildSignature: '');
  WhatsNewService.instance.resetForTesting();
  await WhatsNewService.instance.initialize();
}

int _compare(String a, String b) {
  final pa = a.split('.').map(int.parse).toList();
  final pb = b.split('.').map(int.parse).toList();
  for (var i = 0; i < 3; i++) {
    if (pa[i] != pb[i]) return pa[i].compareTo(pb[i]);
  }
  return 0;
}

Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..color = const Color(0xFF808080));
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final service = WhatsNewService.instance;
  tearDown(service.resetForTesting);

  group('stamps', () {
    test('AV1 and v210 are the codecs stamped 1.8.0, and no other codec is stamped', () {
      final stamped = {
        for (final c in VideoCodec.values)
          if (c.sinceAppVersion != null) c: c.sinceAppVersion,
      };
      // Pinned: a shipped stamp must never change.
      expect(stamped, {VideoCodec.av1: '1.8.0', VideoCodec.v210: '1.8.0'});
      expect(ComparisonViewMode.sinceAppVersion, '1.8.0');
    });

    test('no stamp is ahead of the app version', () {
      final version = RegExp(r'^version:\s*(\d+\.\d+\.\d+)', multiLine: true)
          .firstMatch(File('pubspec.yaml').readAsStringSync())!
          .group(1)!;
      for (final since in [
        ...VideoCodec.values.map((c) => c.sinceAppVersion).whereType<String>(),
        ComparisonViewMode.sinceAppVersion,
      ]) {
        expect(_compare(since, version), lessThanOrEqualTo(0), reason: since);
      }
    });
  });

  group('which badges show', () {
    test('upgrading from 1.7.0 to 1.8.0 badges AV1, v210, the Output tab and Settings', () async {
      await _launch('1.8.0', lastRun: '1.7.0');
      expect(VideoCodec.values.where((c) => service.isNew(c.sinceAppVersion)).toSet(),
          {VideoCodec.av1, VideoCodec.v210});
      expect(service.isNew(ComparisonViewMode.sinceAppVersion), isTrue);
      expect(SettingsDialog.isOutputTabNew, isTrue);
      expect(SettingsDialog.hasNew, isTrue);
    });

    test('a fresh install badges nothing', () async {
      await _launch('1.8.0');
      expect(VideoCodec.values.where((c) => service.isNew(c.sinceAppVersion)), isEmpty);
      expect(service.isNew(ComparisonViewMode.sinceAppVersion), isFalse);
      expect(SettingsDialog.isOutputTabNew, isFalse);
      expect(SettingsDialog.hasNew, isFalse);
    });

    test('the next feature release clears them', () async {
      await _launch('1.9.0', lastRun: '1.8.0');
      expect(SettingsDialog.isOutputTabNew, isFalse);
      expect(service.isNew(ComparisonViewMode.sinceAppVersion), isFalse);
      expect(SettingsDialog.hasNew,
          service.isNew(AddonsSettingsTab.sinceAppVersion));
      expect(SettingsDialog.hasNew, isFalse);
    });
  });

  // The tabs share the dialog's width equally; the badge is overlaid so it
  // takes none. Flutter reports a RenderFlex overflow as a test failure.
  testWidgets('the Output tab label fits its tab with the NEW badge on', (tester) async {
    await _launch('1.8.0', lastRun: '1.7.0');
    for (final width in [600.0, 480.0]) {
      await tester.binding.setSurfaceSize(Size(width, 200));
      await tester.pumpWidget(const MaterialApp(
        home: DefaultTabController(
          length: 5,
          child: Scaffold(
            appBar: _TabsBar(),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'overflow at $width px');
      expect(find.text('NEW'), findsOneWidget);
      expect(find.byType(NewBadge), findsNothing, reason: 'overlaid, not set beside');
    }
    await tester.binding.setSurfaceSize(null);
  });

  group('the Output tab', () {
    Future<void> pumpOutputTab(WidgetTester tester, MainViewModel vm) async {
      await tester.binding.setSurfaceSize(const Size(900, 4000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<MainViewModel>.value(value: vm),
          ChangeNotifierProvider<ThemeService>.value(value: ThemeService.instance),
          ChangeNotifierProvider<AdvancedModeService>.value(
              value: AdvancedModeService.instance),
        ],
        child: const MaterialApp(home: Scaffold(body: SettingsDialog())),
      ));
      await tester.pump();
      await tester.tap(find.text('Output'));
      await tester.pumpAndSettle();
    }

    // The dialog is at most 700 px tall and the tab a lazy ListView: scroll
    // each row into view before looking at it.
    Future<void> reveal(WidgetTester tester, Finder finder) => tester.scrollUntilVisible(
        finder, 200,
        scrollable: find
            .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
            .first);

    Finder radioRow(String name) => find.ancestor(
        of: find.text(name), matching: find.byType(RadioListTile<VideoCodec>));

    testWidgets('badges AV1, v210 and the Video Codec heading on the upgrade', (tester) async {
      await _launch('1.8.0', lastRun: '1.7.0');
      final vm = MainViewModel();
      vm.updateEncodingSettings(
          vm.encodingSettings.copyWith(container: ContainerFormat.mov));
      await pumpOutputTab(tester, vm);

      await reveal(tester, find.text('Video Codec'));
      final heading = find.ancestor(of: find.text('Video Codec'), matching: find.byType(Row));
      expect(find.descendant(of: heading, matching: find.byType(NewBadge)), findsOneWidget);
      for (final codec in [VideoCodec.av1, VideoCodec.v210]) {
        await reveal(tester, find.text(codec.displayName));
        expect(
            find.descendant(of: radioRow(codec.displayName), matching: find.byType(NewBadge)),
            findsOneWidget,
            reason: '${codec.displayName}, listed in MOV (AV1 disabled with its reason)');
      }
      await reveal(tester, find.text(VideoCodec.h264.displayName));
      expect(
          find.descendant(
              of: radioRow(VideoCodec.h264.displayName), matching: find.byType(NewBadge)),
          findsNothing);
    });

    testWidgets('badges nothing on a fresh install', (tester) async {
      await _launch('1.8.0');
      await pumpOutputTab(tester, MainViewModel());
      await reveal(tester, find.text(VideoCodec.av1.displayName));
      expect(find.text('Video Codec'), findsOneWidget);
      expect(find.byType(NewBadge), findsNothing);
      expect(find.text('NEW'), findsNothing);
    });
  });

  group('the preview view-mode control', () {
    Future<void> pump(WidgetTester tester, {ValueChanged<ComparisonViewMode>? onChanged}) async {
      final image = (await tester.runAsync(() => _png(64, 48)))!;
      await tester.pumpWidget(MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            height: 300,
            child: BeforeAfterComparisonWidget(
              beforeImage: image,
              afterImage: image,
              beforeAspectRatio: 4 / 3,
              afterAspectRatio: 4 / 3,
              onViewModeChanged: onChanged,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('is badged on the upgrade, inside the preview', (tester) async {
      await _launch('1.8.0', lastRun: '1.7.0');
      await pump(tester, onChanged: (_) {});
      final badge = find.text('NEW');
      expect(badge, findsOneWidget);
      final rect = tester.getRect(badge);
      expect(const Rect.fromLTWH(0, 0, 400, 300).contains(rect.topLeft), isTrue,
          reason: 'drawn within the preview: $rect');
      expect(find.byKey(const Key('comparison-view-mode')), findsOneWidget);
    });

    testWidgets('is not badged on a fresh install', (tester) async {
      await _launch('1.8.0');
      await pump(tester, onChanged: (_) {});
      expect(find.text('NEW'), findsNothing);
    });

    testWidgets('has no badge when the control is not shown', (tester) async {
      await _launch('1.8.0', lastRun: '1.7.0');
      await pump(tester);
      expect(find.text('NEW'), findsNothing);
    });
  });
}

class _TabsBar extends StatelessWidget implements PreferredSizeWidget {
  const _TabsBar();

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight + kTextTabBarHeight);

  @override
  Widget build(BuildContext context) => AppBar(
        bottom: const TabBar(tabs: [
          Tab(text: 'General'),
          Tab(child: OutputTabLabel()),
          Tab(text: 'Input'),
          Tab(text: 'Add-ons'),
          Tab(text: 'Changes'),
        ]),
      );
}
