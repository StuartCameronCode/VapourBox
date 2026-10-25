// The 1.5.0 NEW badges on the shipped schemas, as a user upgrading from 1.4.0
// sees them: every new filter, method, option and setting is badged, and so is
// every control on the way to it. A wrongly placed stamp (on the parameter
// rather than its new option, or on a hidden parameter) passes the format
// lints but badges the wrong thing or nothing, so the result is checked here.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vapourbox/models/filter_schema.dart';
import 'package:vapourbox/services/whats_new_service.dart';

FilterSchema _load(String file) => FilterSchema.fromJson(
    jsonDecode(File('assets/filters/core/$file').readAsStringSync()) as Map<String, dynamic>);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final service = WhatsNewService.instance;

  setUp(() async {
    // Upgraded from 1.4.0 to 1.5.0.
    SharedPreferences.setMockInitialValues({
      'lastRunAppVersion': '1.4.0',
      'lastSeenAppVersion': '1.4.0',
    });
    PackageInfo.setMockInitialValues(
        appName: 'VapourBox', packageName: 'app.vapourbox.vapourbox',
        version: '1.5.0', buildNumber: '1', buildSignature: '');
    service.resetForTesting();
    await service.initialize();
  });

  test('Crop & Resize: the AI upscalers, their method list and the switch that shows it', () {
    final s = _load('crop_resize.json');
    final method = s.parameters['upscaleMethod']!;
    for (final o in ['realEsrgan', 'realCugan', 'animeJanai']) {
      expect(service.isOptionNew(method, o), isTrue, reason: o);
    }
    for (final o in ['nnedi3Rpow2', 'eedi3Rpow2', 'spline36']) {
      expect(service.isOptionNew(method, o), isFalse, reason: '$o shipped in 1.4.0');
    }
    expect(service.isParameterNew(s, 'upscaleMethod'), isTrue);
    expect(service.isParameterNew(s, 'useIntegerUpscale'), isTrue,
        reason: 'Enable Upscale reveals the new upscalers');
    for (final p in ['cuganNoise', 'animejanaiModel', 'animejanaiSharp']) {
      expect(service.isParameterNew(s, p), isTrue, reason: p);
    }
    final section = s.ui!.sections!.firstWhere((x) => x.parameters.contains('upscaleMethod'));
    expect(service.isSectionNew(s, section), isTrue);
    expect(service.isSchemaNew(s), isTrue);
    expect(service.isParameterNew(s, 'cropLeft'), isFalse, reason: 'unchanged since 1.4.0');
  });

  test('Noise Reduction: BM3D and KNLMeans in the method list', () {
    final s = _load('noise_reduction.json');
    expect(s.methods.where(service.isMethodNew).map((m) => m.id).toSet(), {'bm3d', 'knlmeans'});
    expect(service.isMethodChoiceNew(s), isTrue);
    expect(service.isSchemaNew(s), isTrue);
  });

  test('Frame Rate: RIFE in the method list', () {
    final s = _load('frame_rate.json');
    expect(s.methods.where(service.isMethodNew).map((m) => m.id).toSet(), {'rife'});
    expect(service.isMethodChoiceNew(s), isTrue);
  });

  test('Descale is a new filter', () {
    expect(service.isSchemaNew(_load('descale.json')), isTrue);
  });

  test('a filter with nothing new in 1.5.0 is not badged', () {
    expect(service.isSchemaNew(_load('deband.json')), isFalse);
  });
}
