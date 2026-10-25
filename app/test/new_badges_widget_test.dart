// The NEW badges as drawn by the generated panel, on the real Crop & Resize
// schema after an upgrade from 1.4.0: "Enable Upscale" badges because it
// reveals the new upscalers, "Upscale Method" because it holds them, and in the
// list exactly the three new options are badged. The labels only know about
// what they lead to through the panel's ParameterBadgeScope, so this is what
// catches that wiring breaking (each label would quietly fall back to its own
// stamp).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vapourbox/models/dynamic_parameters.dart';
import 'package:vapourbox/models/filter_schema.dart';
import 'package:vapourbox/services/advanced_mode_service.dart';
import 'package:vapourbox/services/whats_new_service.dart';
import 'package:vapourbox/views/settings/dynamic_filter_panel.dart';
import 'package:vapourbox/widgets/new_badge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'lastRunAppVersion': '1.4.0',
      'lastSeenAppVersion': '1.4.0',
    });
    PackageInfo.setMockInitialValues(
        appName: 'VapourBox', packageName: 'app.vapourbox.vapourbox',
        version: '1.5.0', buildNumber: '1', buildSignature: '');
    WhatsNewService.instance.resetForTesting();
    await WhatsNewService.instance.initialize();
    AdvancedModeService.instance.resetForTesting();
    await AdvancedModeService.instance.initialize();
  });

  /// Whether the row holding [label] carries a NEW badge.
  bool badged(WidgetTester tester, String label) {
    expect(find.text(label), findsWidgets, reason: '"$label" is not on screen');
    final rows = find.ancestor(of: find.text(label), matching: find.byType(Row));
    return rows.evaluate().any((row) => find
        .descendant(of: find.byElementPredicate((e) => e == row), matching: find.byType(NewBadge))
        .evaluate()
        .isNotEmpty);
  }

  testWidgets('Crop & Resize badges the way to the new upscalers', (tester) async {
    final schema = FilterSchema.fromJson(jsonDecode(
            File('assets/filters/core/crop_resize.json').readAsStringSync())
        as Map<String, dynamic>);
    await tester.binding.setSurfaceSize(const Size(900, 4000));
    await tester.pumpWidget(ChangeNotifierProvider<AdvancedModeService>.value(
      value: AdvancedModeService.instance,
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: DynamicFilterPanelCompact(
              schema: schema,
              params: DynamicParameters(
                filterId: 'crop_resize',
                enabled: true,
                values: const {'useIntegerUpscale': true, 'upscaleMethod': 'nnedi3Rpow2'},
                enabledOptionalParams: const {'upscaleMethod', 'upscaleFactor'},
              ),
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(badged(tester, 'Enable Upscale'), isTrue, reason: 'it reveals the new upscalers');
    expect(badged(tester, 'Upscale Method'), isTrue, reason: 'it holds them');

    await tester.tap(find.text('NNEDI3').last);
    await tester.pumpAndSettle();
    for (final o in ['Real-ESRGAN', 'Real-CUGAN', 'AnimeJaNai (download, non-commercial)']) {
      expect(badged(tester, o), isTrue, reason: o);
    }
    expect(badged(tester, 'EEDI3'), isFalse, reason: 'shipped in 1.4.0');
  });
}
