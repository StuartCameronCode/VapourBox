// The GPU features' status as the app reads it from `--probe-rife` /
// `--probe-upscale`, and the panels' decision about what to say. Pure unit
// tests; the probes themselves run against the real worker in
// integration_gpu_plugins_test.dart.
import 'package:flutter_test/flutter_test.dart';

import 'package:vapourbox/models/crop_resize_parameters.dart';
import 'package:vapourbox/models/dynamic_parameters.dart';
import 'package:vapourbox/models/frame_rate_parameters.dart';
import 'package:vapourbox/models/gpu_plugin_status.dart';
import 'package:vapourbox/models/parameter_converter.dart';

void main() {
  group('GpuPluginStatus.fromJson', () {
    test('available', () {
      final s = GpuPluginStatus.fromJson(GpuPlugin.rife, {'available': true});
      expect(s.available, isTrue);
      expect(s.message, isNull);
    });

    test('unavailable carries the worker message verbatim', () {
      final s = GpuPluginStatus.fromJson(GpuPlugin.rife, {
        'available': false,
        'reason': 'missingLibrary',
        'detail': 'could not load vcomp140.dll',
        'message': 'RIFE needs the Microsoft Visual C++ Redistributable (x64)…',
      });
      expect(s.available, isFalse);
      expect(s.reason, 'missingLibrary');
      expect(s.message, startsWith('RIFE needs the Microsoft Visual C++'));
    });

    test('an unavailable answer without a message is never shown as blank', () {
      for (final plugin in GpuPlugin.values) {
        final s = GpuPluginStatus.fromJson(plugin, {'available': false, 'reason': 'noVulkan'});
        expect(s.available, isFalse);
        expect(s.message, contains(plugin.label));
      }
    });

    test('each plugin has its own probe flag', () {
      expect(GpuPlugin.rife.probeFlag, '--probe-rife');
      expect(GpuPlugin.upscale.probeFlag, '--probe-upscale');
    });
  });

  group('gpuPluginSelectedBy', () {
    test('Frame Rate selects RIFE only for the rife method', () {
      expect(gpuPluginSelectedBy('frame_rate', {'method': 'rife'}), GpuPlugin.rife);
      for (final m in ['flowFps', 'duplicate', null]) {
        expect(gpuPluginSelectedBy('frame_rate', {'method': m}), isNull);
      }
    });

    test('Crop & Resize selects AI upscaling only for an AI method with upscaling on', () {
      for (final m in ['realEsrgan', 'realCugan', 'animeJanai']) {
        expect(gpuPluginSelectedBy('crop_resize', {'useIntegerUpscale': true, 'upscaleMethod': m}),
            GpuPlugin.upscale);
        expect(gpuPluginSelectedBy('crop_resize', {'useIntegerUpscale': false, 'upscaleMethod': m}),
            isNull);
      }
      for (final m in ['nnedi3Rpow2', 'eedi3Rpow2', 'spline36']) {
        expect(gpuPluginSelectedBy('crop_resize', {'useIntegerUpscale': true, 'upscaleMethod': m}),
            isNull);
      }
      // Every AI method in the enum is recognised.
      for (final m in [...UpscaleMethod.values.where((m) => m.name.startsWith('real')),
          UpscaleMethod.animeJanai]) {
        expect(gpuPluginSelectedBy('crop_resize', {'useIntegerUpscale': true, 'upscaleMethod': m.name}),
            GpuPlugin.upscale, reason: m.name);
      }
    });

    test('other passes select nothing', () {
      expect(gpuPluginSelectedBy('noise_reduction', {'method': 'rife'}), isNull);
    });
  });

  group('gpuPluginNoticeFor', () {
    const ok = GpuPluginStatus(available: true);
    const no = GpuPluginStatus(available: false, reason: 'noVulkan', message: 'no GPU');

    test('says nothing unless the feature is selected', () {
      for (final status in [ok, no, null]) {
        expect(gpuPluginNoticeFor(selected: false, status: status, checking: false),
            GpuPluginNotice.none);
      }
    });

    test('selected: checking, then unavailable or silent', () {
      expect(gpuPluginNoticeFor(selected: true, status: null, checking: false),
          GpuPluginNotice.checking);
      expect(gpuPluginNoticeFor(selected: true, status: no, checking: true),
          GpuPluginNotice.checking);
      expect(gpuPluginNoticeFor(selected: true, status: no, checking: false),
          GpuPluginNotice.unavailable);
      expect(gpuPluginNoticeFor(selected: true, status: ok, checking: false),
          GpuPluginNotice.none);
    });
  });

  test('the converter round-trips every Frame Rate method', () {
    for (final method in FrameRateMethod.values) {
      final params = FrameRateParameters(enabled: true, method: method);
      final dynamic = ParameterConverter.fromFrameRate(params);
      expect(dynamic.values['method'], method.name);
      expect(ParameterConverter.toFrameRate(dynamic).method, method);
    }
    // An unknown id from an old or hand-edited preset falls back to FlowFPS.
    final unknown = const DynamicParameters(
        filterId: 'frame_rate', enabled: true, values: {'method': 'bogus'});
    expect(ParameterConverter.toFrameRate(unknown).method, FrameRateMethod.flowFps);
  });

  test('AnimeJaNai is recognised as needing its add-on only when chosen', () {
    expect(animeJanaiSelectedBy('crop_resize', {'useIntegerUpscale': true, 'upscaleMethod': 'animeJanai'}),
        isTrue);
    expect(animeJanaiSelectedBy('crop_resize', {'useIntegerUpscale': false, 'upscaleMethod': 'animeJanai'}),
        isFalse);
    expect(animeJanaiSelectedBy('crop_resize', {'useIntegerUpscale': true, 'upscaleMethod': 'realEsrgan'}),
        isFalse);
    expect(animeJanaiSelectedBy('frame_rate', {'useIntegerUpscale': true, 'upscaleMethod': 'animeJanai'}),
        isFalse);
  });

  test('the converter round-trips AnimeJaNai\'s model and Sharp settings', () {
    for (final model in ['compact', 'ultraCompact', 'superUltraCompact']) {
      for (final sharp in [false, true]) {
        final params = CropResizeParameters(
            enabled: true,
            useIntegerUpscale: true,
            upscaleMethod: UpscaleMethod.animeJanai,
            animejanaiModel: model,
            animejanaiSharp: sharp);
        final back = ParameterConverter.toCropResize(ParameterConverter.fromCropResize(params));
        expect((back.upscaleMethod, back.animejanaiModel, back.animejanaiSharp),
            (UpscaleMethod.animeJanai, model, sharp));
        expect(back.toJson()['upscaleMethod'], 'animeJanai',
            reason: 'the wire name the worker reads');
      }
    }
  });

  test('the converter round-trips every upscale method and CUGAN strength', () {
    for (final method in UpscaleMethod.values) {
      for (final noise in ['none', 'conservative', 'denoise3x']) {
        final params = CropResizeParameters(
            enabled: true, useIntegerUpscale: true, upscaleMethod: method, cuganNoise: noise);
        final back = ParameterConverter.toCropResize(ParameterConverter.fromCropResize(params));
        expect(back.upscaleMethod, method);
        expect(back.cuganNoise, noise);
      }
    }
  });
}
