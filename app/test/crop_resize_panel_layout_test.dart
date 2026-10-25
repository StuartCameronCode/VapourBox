// Crop & Resize's panel in simple mode, in reading order: each preset under
// the heading of the section it sets (Crop Preset under Crop, Resize Preset
// under Resize, Canvas Preset under Borders), and Upscale before Aspect Ratio.
// Before, all three presets were drawn in a block at the top, so "Resize
// Preset" and "Canvas Preset" read as part of Crop.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vapourbox/models/dynamic_parameters.dart';
import 'package:vapourbox/models/filter_schema.dart';
import 'package:vapourbox/services/advanced_mode_service.dart';
import 'package:vapourbox/views/settings/dynamic_filter_panel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('each preset sits under its own section, Upscale before Aspect Ratio',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    AdvancedModeService.instance.resetForTesting();
    await AdvancedModeService.instance.initialize();
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
              params: const DynamicParameters(filterId: 'crop_resize', enabled: true, values: {}),
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    double y(String text) => tester.getTopLeft(find.text(text).first).dy;
    final order = ['Crop', 'Crop Preset', 'Resize', 'Resize Preset', 'Upscale',
        'Aspect Ratio', 'Borders', 'Canvas Preset'];
    for (var i = 1; i < order.length; i++) {
      expect(y(order[i - 1]), lessThan(y(order[i])),
          reason: '"${order[i - 1]}" should come before "${order[i]}"');
    }
    await tester.binding.setSurfaceSize(null);
  });
}
