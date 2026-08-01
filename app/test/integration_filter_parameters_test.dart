// Integration test: schema-driven parameter validation for non-deinterlace filters.
// Run headless via CI: flutter test test/integration_filter_parameters_test.dart
// Script-only (no encode) — runs in the per-push CI gate.
library;

// ignore_for_file: avoid_print — these tests print diagnostics to the test log.

import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/chroma_denoise_parameters.dart';
import 'package:vapourbox/models/chroma_fix_parameters.dart';
import 'package:vapourbox/models/color_correction_parameters.dart';
import 'package:vapourbox/models/crop_resize_parameters.dart';
import 'package:vapourbox/models/deband_parameters.dart';
import 'package:vapourbox/models/deblock_parameters.dart';
import 'package:vapourbox/models/dehalo_parameters.dart';
import 'package:vapourbox/models/descratch_parameters.dart';
import 'package:vapourbox/models/dynamic_parameters.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/filter_schema.dart';
import 'package:vapourbox/models/noise_reduction_parameters.dart';
import 'package:vapourbox/models/parameter_converter.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/sharpen_parameters.dart';
import 'package:vapourbox/models/spotless_parameters.dart';
import 'package:vapourbox/models/video_job.dart';

import 'support/worker_harness.dart';

// =============================================================================
// TEST CONFIGURATION
// =============================================================================
/// Thin shim over [WorkerHarness] so the test bodies keep their `TestConfig.*`
/// call sites while paths/env resolve cross-platform.
class TestConfig {
  static String get projectRoot => WorkerHarness.repoRoot;
  static String get inputFile => WorkerHarness.inputFile;
  static String get outputDir => '${WorkerHarness.outputDir}/filter_params';
  static String get workerPath => WorkerHarness.workerPath;
  static String get depsDir => WorkerHarness.depsDir;
}

// =============================================================================
// WORKER SCRIPT GENERATION (same as qtgmc_parameters_test.dart)
// =============================================================================
Future<String> generateScriptViaWorker(VideoJob job) async {
  final configFile = File('${Directory.systemTemp.path}/vapourbox_job_${job.id}.json');
  await configFile.writeAsString(jsonEncode(job.toJson()));

  final env = WorkerHarness.workerEnv;

  final process = await Process.start(TestConfig.workerPath, ['--config', configFile.path],
      environment: env, workingDirectory: File(TestConfig.workerPath).parent.path);
  final scriptPath = '${Directory.systemTemp.path}/${job.id}.vpy';
  final logLines = <String>[];
  process.stdout.transform(utf8.decoder).listen((data) {
    for (final line in data.split('\n').where((l) => l.trim().isNotEmpty)) logLines.add(line);
  });
  process.stderr.transform(utf8.decoder).listen((_) {});

  String? scriptContent;
  for (var i = 0; i < 60; i++) {
    await Future.delayed(const Duration(milliseconds: 500));
    final f = File(scriptPath);
    if (await f.exists()) { scriptContent = await f.readAsString(); break; }
  }
  process.kill();
  await process.exitCode.timeout(const Duration(seconds: 5),
      onTimeout: () { Process.killPid(process.pid, ProcessSignal.sigkill); return -1; });
  await configFile.delete().catchError((_) => configFile);
  final sf = File(scriptPath);
  if (await sf.exists()) await sf.delete().catchError((_) => sf);
  if (scriptContent == null) {
    throw StateError('Script not generated at $scriptPath\nWorker output:\n${logLines.join('\n')}');
  }
  return scriptContent;
}

// =============================================================================
// SCRIPT VALUE PARSER
// =============================================================================
/// Parse `ParamName=Value` from a function call in a .vpy script.
Map<String, String> parseFilterParams(String script, String functionCall) {
  final start = script.indexOf(functionCall);
  if (start == -1) return {};
  var depth = 0, end = start;
  for (var i = start; i < script.length; i++) {
    if (script[i] == '(') depth++;
    if (script[i] == ')') { depth--; if (depth == 0) { end = i; break; } }
  }
  final call = script.substring(start, end + 1);
  final params = <String, String>{};
  final re = RegExp(r'(\w+)\s*=\s*(.+?)\s*,?\s*$', multiLine: true);
  for (final m in re.allMatches(call)) {
    var value = m.group(2)!;
    if (value.endsWith(',')) value = value.substring(0, value.length - 1).trim();
    params[m.group(1)!] = value;
  }
  return params;
}

String toPythonValue(dynamic value, ParameterType type) {
  switch (type) {
    case ParameterType.boolean: return value == true ? 'True' : 'False';
    case ParameterType.integer: return (value as num).toInt().toString();
    case ParameterType.number:
      final d = (value as num).toDouble();
      return (d == d.roundToDouble() && !d.isInfinite) ? d.toStringAsFixed(1) : d.toString();
    case ParameterType.string:
    case ParameterType.enumType: return '"$value"';
  }
}

// =============================================================================
// HELPERS
// =============================================================================
FilterSchema loadSchema(String id) => FilterSchema.fromJson(jsonDecode(
    File('${TestConfig.projectRoot}/app/assets/filters/core/$id.json').readAsStringSync())
    as Map<String, dynamic>);

/// Validate script params against a schema method's optional params.
void validateParams({
  required Map<String, String> actual,
  required FilterSchema schema,
  required MethodDefinition method,
  required Map<String, dynamic> setValues,
  Map<String, String> dynParamKeys = const {},
  Set<String> conditionallyOmitted = const {},
  Map<String, String> vsNameOverrides = const {},
}) {
  final missing = <String>[], wrongValue = <String>[];
  for (final paramId in method.parameters) {
    final paramDef = schema.parameters[paramId];
    if (paramDef == null || paramDef.optional != true) continue;
    if (conditionallyOmitted.contains(paramId)) continue;
    final vsName = vsNameOverrides[paramId] ?? paramDef.getVsName(paramId);
    final dynKey = dynParamKeys[paramId] ?? paramId;
    final value = setValues[dynKey];
    if (value == null) continue;
    if (!actual.containsKey(vsName)) { missing.add('$vsName ($paramId)'); continue; }
    final expected = toPythonValue(value, paramDef.type);
    if (actual[vsName] != expected) wrongValue.add('$vsName: expected $expected, got ${actual[vsName]}');
  }
  if (missing.isNotEmpty) { print('  MISSING: $missing'); }
  if (wrongValue.isNotEmpty) { print('  WRONG: $wrongValue'); }
  expect(missing, isEmpty, reason: 'Missing params: ${missing.join(', ')}');
  expect(wrongValue, isEmpty, reason: 'Wrong values: ${wrongValue.join('; ')}');
}

VideoJob buildJob({
  required String testName,
  QTGMCParameters? deinterlace,
  NoiseReductionParameters? noiseReduction,
  DehaloParameters? dehalo,
  DeblockParameters? deblock,
  DebandParameters? deband,
  SharpenParameters? sharpen,
  ChromaFixParameters? chromaFixes,
  ColorCorrectionParameters? colorCorrection,
  DeScratchParameters? descratch,
  SpotLessParameters? spotless,
  CropResizeParameters? cropResize,
  ChromaDenoiseParameters? chromaDenoise,
}) => VideoJob(
  id: const Uuid().v4(),
  inputPath: TestConfig.inputFile,
  outputPath: '${TestConfig.outputDir}/$testName.mkv',
  processingPipeline: ProcessingPipeline(
    deinterlace: deinterlace ?? const QTGMCParameters(enabled: false),
    descratch: descratch ?? const DeScratchParameters(),
    spotless: spotless ?? const SpotLessParameters(),
    noiseReduction: noiseReduction ?? const NoiseReductionParameters(),
    dehalo: dehalo ?? const DehaloParameters(),
    deblock: deblock ?? const DeblockParameters(),
    deband: deband ?? const DebandParameters(),
    sharpen: sharpen ?? const SharpenParameters(),
    chromaFixes: chromaFixes ?? const ChromaFixParameters(),
    colorCorrection: colorCorrection ?? const ColorCorrectionParameters(),
    cropResize: cropResize ?? const CropResizeParameters(),
    chromaDenoise: chromaDenoise ?? const ChromaDenoiseParameters(),
  ),
  encodingSettings: const EncodingSettings(
    codec: VideoCodec.h264, container: ContainerFormat.mkv, audioMode: AudioMode.none,
  ),
  startFrame: 10, endFrame: 30,
);

/// Map NR schema param IDs to converter keys (differ in casing for ThSAD/ThSADC).
String _nrKey(String id) => switch (id) {
  'smDegrainThSad' => 'smDegrainThSAD',
  'smDegrainThSadc' => 'smDegrainThSADC',
  _ => id,
};

// =============================================================================
// TESTS
// =============================================================================
void main() {
  setUpAll(() async {
    await WorkerHarness.ensureReady();
    await Directory(TestConfig.outputDir).create(recursive: true);
    print('Project root: ${TestConfig.projectRoot}');
  });

  group('Filter Parameters End-to-End', () {
    // --- NOISE REDUCTION (SMDegrain) ---
    test('noise_reduction: SMDegrain params', () async {
      final schema = loadSchema('noise_reduction');
      final method = schema.methods.firstWhere((m) => m.id == 'smdegrain');
      DynamicParameters dyn = ParameterConverter.fromNoiseReduction(
        const NoiseReductionParameters(enabled: true));
      for (final pid in method.parameters) {
        final p = schema.parameters[pid];
        if (p == null || p.optional != true) continue;
        dyn = dyn.withValue(_nrKey(pid), p.defaultValue);
      }
      final typed = ParameterConverter.toNoiseReduction(dyn);
      final job = buildJob(testName: 'nr_smdegrain', noiseReduction: typed);
      print('  Generating SMDegrain script...');
      final script = await generateScriptViaWorker(job);
      expect(script, contains('haf.SMDegrain('));
      final actual = parseFilterParams(script, 'haf.SMDegrain(');
      print('  Parsed ${actual.length} params');
      validateParams(
        actual: actual, schema: schema, method: method,
        dynParamKeys: { for (final pid in method.parameters) pid: _nrKey(pid) },
        setValues: ParameterConverter.fromNoiseReduction(typed).values,
        // thSADC omitted when == thSAD; prefilter omitted when == 2
        conditionallyOmitted: {'smDegrainThSadc', 'smDegrainPrefilter'},
      );
      print('  PASS');
    }, timeout: const Timeout(Duration(minutes: 2)));

    // --- DEHALO (DeHalo_alpha) ---
    test('dehalo: DeHalo_alpha params', () async {
      final schema = loadSchema('dehalo');
      final method = schema.methods.firstWhere((m) => m.id == 'dehalo_alpha');
      DynamicParameters dyn = ParameterConverter.fromDehalo(
        const DehaloParameters(enabled: true, method: DehaloMethod.dehaloAlpha));
      for (final pid in method.parameters) {
        final p = schema.parameters[pid];
        if (p == null || p.optional != true) continue;
        dyn = dyn.withValue(pid, p.defaultValue);
      }
      final typed = ParameterConverter.toDehalo(dyn);
      final job = buildJob(testName: 'dehalo_alpha', dehalo: typed);
      print('  Generating DeHalo_alpha script...');
      final script = await generateScriptViaWorker(job);
      expect(script, contains('haf.DeHalo_alpha('));
      final actual = parseFilterParams(script, 'haf.DeHalo_alpha(');
      print('  Parsed ${actual.length} params');
      validateParams(actual: actual, schema: schema, method: method,
        setValues: ParameterConverter.fromDehalo(typed).values);
      print('  PASS');
    }, timeout: const Timeout(Duration(minutes: 2)));

    // Issue #50: FineDehalo's masking limits, contra-sharpening and edge
    // processing were never exposed. Explicit non-default values, so a
    // parameter that silently fails to reach the script is visible.
    test('dehalo: FineDehalo advanced params', () async {
      loadSchema('dehalo'); // confirm schema parses
      final typed = const DehaloParameters(
        enabled: true,
        method: DehaloMethod.fineDehalo,
        limitLow: 60,
        limitHigh: 120,
        contra: 1.2,
        excludeCloseEdges: false,
        edgeProc: 0.5,
      );
      final job = buildJob(testName: 'dehalo_fine', dehalo: typed);
      print('  Generating FineDehalo script...');
      final script = await generateScriptViaWorker(job);
      expect(script, contains('haf.FineDehalo('));
      final actual = parseFilterParams(script, 'haf.FineDehalo(');
      print('  Parsed ${actual.length} params');
      expect(actual['thlimi'], '60');
      expect(actual['thlima'], '120');
      expect(actual['contra'], '1.2');
      expect(actual['excl'], 'False');
      expect(actual['edgeproc'], '0.5');
      print('  PASS');
    }, timeout: const Timeout(Duration(minutes: 2)));

    // The "ghost" half of issue #50: Vinverse removes the comb residue a
    // deinterlacer leaves behind.
    test('dehalo: Vinverse params', () async {
      loadSchema('dehalo');
      final typed = const DehaloParameters(
        enabled: true,
        method: DehaloMethod.vinverse,
        vinverseStrength: 3.5,
        vinverseAmount: 200,
        vinverseChroma: false,
      );
      final job = buildJob(testName: 'dehalo_vinverse', dehalo: typed);
      print('  Generating Vinverse script...');
      final script = await generateScriptViaWorker(job);
      expect(script, contains('haf.Vinverse('));
      final actual = parseFilterParams(script, 'haf.Vinverse(');
      print('  Parsed ${actual.length} params');
      expect(actual['sstr'], '3.5');
      expect(actual['amnt'], '200');
      expect(actual['chroma'], 'False');
      print('  PASS');
    }, timeout: const Timeout(Duration(minutes: 2)));

    // EdgeCleaner's repair/small-particle modes are numeric enums, so they
    // arrive from the UI as strings — the converter must coerce them to ints or
    // the script gets a quoted value VapourSynth rejects.
    test('dehalo: EdgeCleaner params (numeric enums from the UI)', () async {
      final schema = loadSchema('dehalo');
      var dyn = ParameterConverter.fromDehalo(const DehaloParameters(
          enabled: true, method: DehaloMethod.edgeCleaner));
      // Exactly what the dropdown widget stores: the raw option string.
      dyn = dyn.withValue('edgeStrength', 15);
      dyn = dyn.withValue('edgeRepairMode', schema.parameters['edgeRepairMode']!.options!.first);
      dyn = dyn.withValue('edgeSmallMode', '1');
      dyn = dyn.withValue('edgeHotPixels', true);
      final typed = ParameterConverter.toDehalo(dyn);

      final job = buildJob(testName: 'dehalo_edgecleaner', dehalo: typed);
      print('  Generating EdgeCleaner script...');
      final script = await generateScriptViaWorker(job);
      expect(script, contains('haf.EdgeCleaner('));
      final actual = parseFilterParams(script, 'haf.EdgeCleaner(');
      print('  Parsed ${actual.length} params');
      expect(actual['strength'], '15');
      expect(actual['rmode'], '1', reason: 'string option must be coerced to an int');
      expect(actual['smode'], '1');
      expect(actual['hot'], 'True');
      print('  PASS');
    }, timeout: const Timeout(Duration(minutes: 2)));


    // Issue #50: picking the EEDI3 upscale used to emit a Spline36 resize --
    // the template block was a placeholder. Assert the real call reaches the
    // script, in the push gate rather than only in the nightly encode.
    test('crop_resize: EEDI3 upscale emits eedi3m with its own parameters', () async {
      loadSchema('crop_resize'); // confirm schema parses
      final typed = const CropResizeParameters(
        enabled: true,
        useIntegerUpscale: true,
        upscaleMethod: UpscaleMethod.eedi3Rpow2,
        upscaleFactor: 2,
        upscaleNsize: 4,
        upscaleNeurons: 3,
        upscaleAlpha: 0.4,
        upscaleMdis: 30,
      );
      final job = buildJob(testName: 'upscale_eedi3', cropResize: typed);
      print('  Generating EEDI3 upscale script...');
      final script = await generateScriptViaWorker(job);
      expect(script, contains('core.eedi3m.EEDI3('));
      final actual = parseFilterParams(script, 'core.eedi3m.EEDI3(');
      print('  Parsed ${actual.length} params');
      expect(actual['alpha'], '0.4');
      expect(actual['mdis'], '30');
      // The nnedi3 sclip that guides it carries the nnedi3 controls.
      final sclip = parseFilterParams(script, 'core.znedi3.nnedi3(');
      expect(sclip['nsize'], '4');
      expect(sclip['nns'], '3');
      // And the half-pixel dh shift is corrected per plane.
      expect(script, contains('_upscale_fix_shift'));
      print('  PASS');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('crop_resize: kernel tuning only reaches the kernel that reads it', () async {
      loadSchema('crop_resize');
      final job = buildJob(
        testName: 'resize_lanczos_taps',
        cropResize: const CropResizeParameters(
          enabled: true,
          resizeEnabled: true,
          targetWidth: 640,
          targetHeight: 480,
          maintainAspect: false,
          kernel: ResizeKernel.lanczos,
          lanczosTaps: 4,
          bicubicB: 0.33,
          bicubicC: 0.33,
        ),
      );
      print('  Generating Lanczos resize script...');
      final script = await generateScriptViaWorker(job);
      expect(script, contains('core.resize.Lanczos('));
      final actual = parseFilterParams(script, 'core.resize.Lanczos(');
      // filter_param_a is a float in zimg, so an integer tap count is emitted
      // as 4.0 — zimg rounds it back to an int.
      expect(actual['filter_param_a'], '4.0', reason: 'taps go in filter_param_a');
      expect(actual.containsKey('filter_param_b'), isFalse,
          reason: "Bicubic's c must not leak into a Lanczos call");
      print('  PASS');
    }, timeout: const Timeout(Duration(minutes: 2)));


    // Issue #50: temperature/tint white balance. U carries blue-yellow and V
    // carries red-cyan, so warm is -U/+V; a sign error here is invisible until
    // you look at the picture.
    test('color_correction: white balance offsets reach the script', () async {
      loadSchema('color_correction'); // confirm schema parses
      final job = buildJob(
        testName: 'white_balance',
        colorCorrection: const ColorCorrectionParameters(
          enabled: true,
          temperature: 40,
          tint: -20,
        ),
      );
      print('  Generating white balance script...');
      final script = await generateScriptViaWorker(job);
      // temperature 40 -> ±10 levels, tint -20 -> -5 on both planes.
      expect(script, contains('_wb_u = -15.0 * _wb_scale'));
      expect(script, contains('_wb_v = 5.0 * _wb_scale'));
      // Luma is copied by the empty expression rather than rewritten.
      expect(script, contains("['', 'x ' + repr(_wb_u) + ' +'"));
      print('  PASS');
    }, timeout: const Timeout(Duration(minutes: 2)));


    // Issue #50: CCD chroma denoise, the pass that pulls in the zsmooth plugin.
    test('chroma_denoise: CCD params + derived scale', () async {
      loadSchema('chroma_denoise'); // confirm schema parses
      final job = buildJob(
        testName: 'chroma_denoise',
        chromaDenoise: const ChromaDenoiseParameters(
          enabled: true,
          threshold: 8.5,
          temporalRadius: 2,
          pointsHigh: true,
        ),
      );
      print('  Generating CCD script...');
      final script = await generateScriptViaWorker(job);
      expect(script, contains('core.zsmooth.CCD('));
      final actual = parseFilterParams(script, 'core.zsmooth.CCD(');
      print('  Parsed ${actual.length} params');
      expect(actual['threshold'], '8.5');
      expect(actual['temporal_radius'], '2');
      expect(actual['points'], '[True, True, True]');
      // CCD rejects a scale below 1.0, and its own automatic value is below 1.0
      // for anything shorter than 480 lines — so we derive it with a floor.
      expect(script, contains('max(1.0, clip.height / 480.0)'));
      print('  PASS');
    }, timeout: const Timeout(Duration(minutes: 2)));

    // --- DEBLOCK (Deblock_QED) ---
    test('deblock: Deblock_QED params', () async {
      final schema = loadSchema('deblock');
      final method = schema.methods.firstWhere((m) => m.id == 'deblock_qed');
      DynamicParameters dyn = ParameterConverter.fromDeblock(
        const DeblockParameters(enabled: true, method: DeblockMethod.deblockQed));
      for (final pid in method.parameters) {
        final p = schema.parameters[pid];
        if (p == null || p.optional != true) continue;
        dyn = dyn.withValue(pid, p.defaultValue);
      }
      final typed = ParameterConverter.toDeblock(dyn);
      final job = buildJob(testName: 'deblock_qed', deblock: typed);
      print('  Generating Deblock_QED script...');
      final script = await generateScriptViaWorker(job);
      expect(script, contains('haf.Deblock_QED('));
      final actual = parseFilterParams(script, 'haf.Deblock_QED(');
      print('  Parsed ${actual.length} params');
      // Template uses aOff1/aOff2 but schema VS names are aOffset1/aOffset2
      validateParams(actual: actual, schema: schema, method: method,
        setValues: ParameterConverter.fromDeblock(typed).values,
        vsNameOverrides: {'aOffset1': 'aOff1', 'aOffset2': 'aOff2'});
      print('  PASS');
    }, timeout: const Timeout(Duration(minutes: 2)));

    // --- DEBAND (f3kdb) ---
    test('deband: f3kdb params', () async {
      final schema = loadSchema('deband');
      final method = schema.methods.firstWhere((m) => m.id == 'f3kdb');
      DynamicParameters dyn = ParameterConverter.fromDeband(
        const DebandParameters(enabled: true));
      for (final pid in method.parameters) {
        final p = schema.parameters[pid];
        if (p == null || p.optional != true) continue;
        dyn = dyn.withValue(pid, p.defaultValue);
      }
      final typed = ParameterConverter.toDeband(dyn);
      final job = buildJob(testName: 'deband_f3kdb', deband: typed);
      print('  Generating f3kdb script...');
      final script = await generateScriptViaWorker(job);
      expect(script, contains('core.neo_f3kdb.Deband('));
      final actual = parseFilterParams(script, 'core.neo_f3kdb.Deband(');
      print('  Parsed ${actual.length} params');
      validateParams(actual: actual, schema: schema, method: method,
        setValues: ParameterConverter.fromDeband(typed).values);
      print('  PASS');
    }, timeout: const Timeout(Duration(minutes: 2)));

    // --- SHARPEN (LSFmod) ---
    test('sharpen: LSFmod params', () async {
      final schema = loadSchema('sharpen');
      final method = schema.methods.firstWhere((m) => m.id == 'lsfmod');
      DynamicParameters dyn = ParameterConverter.fromSharpen(
        const SharpenParameters(enabled: true, method: SharpenMethod.lsfmod));
      for (final pid in method.parameters) {
        final p = schema.parameters[pid];
        if (p == null || p.optional != true) continue;
        dyn = dyn.withValue(pid, p.defaultValue);
      }
      final typed = ParameterConverter.toSharpen(dyn);
      final job = buildJob(testName: 'sharpen_lsfmod', sharpen: typed);
      print('  Generating LSFmod script...');
      final script = await generateScriptViaWorker(job);
      expect(script, contains('haf.LSFmod('));
      final actual = parseFilterParams(script, 'haf.LSFmod(');
      print('  Parsed ${actual.length} params');
      // Template uses lowercase overshoot/undershoot; schema VS names are capitalized
      validateParams(actual: actual, schema: schema, method: method,
        setValues: ParameterConverter.fromSharpen(typed).values,
        vsNameOverrides: {'overshoot': 'overshoot', 'undershoot': 'undershoot'});
      print('  PASS');
    }, timeout: const Timeout(Duration(minutes: 2)));

    // --- CHROMA FIXES (3 sub-filters) ---
    test('chroma_fixes: FixChromaBleedingMod + LUTDeCrawl + Vinverse', () async {
      loadSchema('chroma_fixes'); // confirm schema parses
      final typed = const ChromaFixParameters(
        enabled: true,
        applyChromaBleedingFix: true, chromaBleedCx: 4, chromaBleedCy: 4,
        chromaBleedCBlur: 0.7, chromaBleedStrength: 0.8,
        applyDeCrawl: true, deCrawlYThresh: 10, deCrawlCThresh: 10, deCrawlMaxDiff: 50,
        applyVinverse: true, vinverseSstr: 2.7, vinverseAmnt: 255,
      );
      final job = buildJob(testName: 'chroma_fixes', chromaFixes: typed);
      print('  Generating chroma_fixes script...');
      final script = await generateScriptViaWorker(job);

      // FixChromaBleedingMod (template maps cblur -> thr)
      expect(script, contains('haf.FixChromaBleedingMod('));
      final bleed = parseFilterParams(script, 'haf.FixChromaBleedingMod(');
      print('  FixChromaBleedingMod: ${bleed.length} params');
      expect(bleed['cx'], '4'); expect(bleed['cy'], '4');
      expect(bleed['thr'], '0.7'); expect(bleed['strength'], '0.8');

      // LUTDeCrawl
      expect(script, contains('haf.LUTDeCrawl('));
      final crawl = parseFilterParams(script, 'haf.LUTDeCrawl(');
      print('  LUTDeCrawl: ${crawl.length} params');
      expect(crawl['ythresh'], '10'); expect(crawl['cthresh'], '10');
      expect(crawl['maxdiff'], '50');

      // Vinverse
      expect(script, contains('haf.Vinverse('));
      final vinv = parseFilterParams(script, 'haf.Vinverse(');
      print('  Vinverse: ${vinv.length} params');
      expect(vinv['sstr'], '2.7'); expect(vinv['amnt'], '255');

      print('  PASS');
    }, timeout: const Timeout(Duration(minutes: 2)));

    // --- COLOR CORRECTION (Tweak + Levels) ---
    test('color_correction: Tweak and Levels params', () async {
      loadSchema('color_correction'); // confirm schema parses
      // Non-default values required: Rust worker omits params at defaults.
      final typed = const ColorCorrectionParameters(
        enabled: true, brightness: 5.0, contrast: 1.2, hue: 10.0, saturation: 1.3,
        applyLevels: true, inputLow: 10, inputHigh: 240,
        outputLow: 5, outputHigh: 250, gamma: 0.9,
      );
      final job = buildJob(testName: 'color_correction', colorCorrection: typed);
      print('  Generating color_correction script...');
      final script = await generateScriptViaWorker(job);

      // Tweak
      expect(script, contains('adjust.Tweak('));
      final tweak = parseFilterParams(script, 'adjust.Tweak(');
      print('  Tweak: ${tweak.length} params');
      expect(tweak['bright'], '5.0'); expect(tweak['cont'], '1.2');
      expect(tweak['sat'], '1.3'); expect(tweak['hue'], '10.0');

      // Levels
      expect(script, contains('core.std.Levels('));
      final levels = parseFilterParams(script, 'core.std.Levels(');
      print('  Levels: ${levels.length} params');
      expect(levels['min_in'], '10'); expect(levels['max_in'], '240');
      expect(levels['min_out'], '5'); expect(levels['max_out'], '250');
      expect(levels['gamma'], '0.9');

      print('  PASS');
    }, timeout: const Timeout(Duration(minutes: 2)));

    // --- DESCRATCH (core.descratch.DeScratch) ---
    test('descratch: DeScratch params', () async {
      loadSchema('descratch'); // confirm schema parses
      // Explicit non-default values so each one is distinguishable in the script.
      final typed = const DeScratchParameters(
        enabled: true, mindif: 6, asym: 8, maxgap: 4, maxwidth: 5,
        blurlen: 12, modeY: 1, modeU: 1,
      );
      final job = buildJob(testName: 'descratch', descratch: typed);
      print('  Generating DeScratch script...');
      final script = await generateScriptViaWorker(job);
      expect(script, contains('core.descratch.DeScratch('));
      final actual = parseFilterParams(script, 'core.descratch.DeScratch(');
      print('  Parsed ${actual.length} params');
      expect(actual['mindif'], '6');
      expect(actual['asym'], '8');
      expect(actual['maxgap'], '4');
      expect(actual['maxwidth'], '5');
      expect(actual['blurlen'], '12');
      expect(actual['modey'], '1');
      expect(actual['modeu'], '1');
      print('  PASS');
    }, timeout: const Timeout(Duration(minutes: 2)));

    // --- SPOTLESS (_SpotLess) ---
    test('spotless: SpotLess params', () async {
      loadSchema('spotless'); // confirm schema parses
      // chroma/blksize/overlap/pel set to non-defaults; rec toggled on.
      final typed = const SpotLessParameters(
        enabled: true, chroma: false, rec: true, blksize: 8, overlap: 4, pel: 1,
      );
      final job = buildJob(testName: 'spotless', spotless: typed);
      print('  Generating SpotLess script...');
      final script = await generateScriptViaWorker(job);
      expect(script, contains('_SpotLess('));
      final actual = parseFilterParams(script, '_SpotLess(');
      print('  Parsed ${actual.length} params');
      expect(actual['chroma'], 'False');
      expect(actual['rec'], 'True');
      expect(actual['blksize'], '8');
      expect(actual['overlap'], '4');
      expect(actual['pel'], '1');
      print('  PASS');
    }, timeout: const Timeout(Duration(minutes: 2)));

    // --- IVTC (core.vivtc.VFM + VDecimate) high-bit-depth guard ---
    // VFM only accepts 8-bit YUV/GRAY, so IVTC on a 10-bit source (e.g. ProRes
    // 422, yuv422p10le) must run field matching on an 8-bit metrics copy while
    // emitting full-depth pixels via clip2. Assert that wiring is in the script.
    test('ivtc: VFM/VDecimate 8-bit guard + clip2', () async {
      final job = buildJob(
        testName: 'ivtc_guard',
        deinterlace: const QTGMCParameters(
          enabled: true, method: DeinterlaceMethod.ivtc, tff: true,
        ),
      );
      print('  Generating IVTC script...');
      final script = await generateScriptViaWorker(job);
      expect(script, contains('bits_per_sample == 8'));
      expect(script, contains('core.vivtc.VFM(_ivtc_metrics'));
      expect(script, contains('clip2=_ivtc_src'));
      expect(script, contains('core.vivtc.VDecimate(clip'));
      print('  PASS');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
