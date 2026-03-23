// Integration test: schema-driven parameter validation for non-deinterlace filters.
// Run with: dart test integration_test/filter_parameters_test.dart --chain-stack-traces
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import '../lib/models/chroma_fix_parameters.dart';
import '../lib/models/color_correction_parameters.dart';
import '../lib/models/deband_parameters.dart';
import '../lib/models/deblock_parameters.dart';
import '../lib/models/dehalo_parameters.dart';
import '../lib/models/dynamic_parameters.dart';
import '../lib/models/encoding_settings.dart';
import '../lib/models/filter_schema.dart';
import '../lib/models/noise_reduction_parameters.dart';
import '../lib/models/parameter_converter.dart';
import '../lib/models/processing_pipeline.dart';
import '../lib/models/qtgmc_parameters.dart';
import '../lib/models/sharpen_parameters.dart';
import '../lib/models/video_job.dart';

// =============================================================================
// TEST CONFIGURATION
// =============================================================================
class TestConfig {
  static final String projectRoot = _findProjectRoot();
  static String get inputFile => '$projectRoot/Tests/TestResources/interlaced_test.avi';
  static String get outputDir => '$projectRoot/Tests/TestOutput/filter_params';
  static String get workerPath => '$projectRoot/worker/target/release/vapourbox-worker.exe';
  static String get depsDir => '$projectRoot/deps/windows-x64';

  static String _findProjectRoot() {
    var dir = Directory.current;
    while (!File('${dir.path}/CLAUDE.md').existsSync()) {
      final parent = dir.parent;
      if (parent.path == dir.path) throw StateError('Could not find project root');
      dir = parent;
    }
    return dir.path.replaceAll('\\', '/');
  }
}

// =============================================================================
// WORKER SCRIPT GENERATION (same as qtgmc_parameters_test.dart)
// =============================================================================
Future<String> generateScriptViaWorker(VideoJob job) async {
  final configFile = File('${Directory.systemTemp.path}/vapourbox_job_${job.id}.json');
  await configFile.writeAsString(jsonEncode(job.toJson()));

  final env = Map<String, String>.from(Platform.environment);
  final d = TestConfig.depsDir;
  env['PYTHONHOME'] = '$d/vapoursynth';
  env['PYTHONPATH'] = '$d/vapoursynth/Lib/site-packages';
  env['PATH'] = '$d/vapoursynth;$d/ffmpeg;${env['PATH']}';
  env['VAPOURSYNTH_PLUGIN_PATH'] = '$d/vapoursynth/vs-plugins';

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
  NoiseReductionParameters? noiseReduction,
  DehaloParameters? dehalo,
  DeblockParameters? deblock,
  DebandParameters? deband,
  SharpenParameters? sharpen,
  ChromaFixParameters? chromaFixes,
  ColorCorrectionParameters? colorCorrection,
}) => VideoJob(
  id: const Uuid().v4(),
  inputPath: TestConfig.inputFile,
  outputPath: '${TestConfig.outputDir}/$testName.mkv',
  processingPipeline: ProcessingPipeline(
    deinterlace: const QTGMCParameters(enabled: false),
    noiseReduction: noiseReduction ?? const NoiseReductionParameters(),
    dehalo: dehalo ?? const DehaloParameters(),
    deblock: deblock ?? const DeblockParameters(),
    deband: deband ?? const DebandParameters(),
    sharpen: sharpen ?? const SharpenParameters(),
    chromaFixes: chromaFixes ?? const ChromaFixParameters(),
    colorCorrection: colorCorrection ?? const ColorCorrectionParameters(),
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
    for (final e in {'Worker': TestConfig.workerPath, 'Input': TestConfig.inputFile}.entries) {
      if (!await File(e.value).exists()) throw StateError('${e.key} not found at ${e.value}');
    }
    if (!await Directory(TestConfig.depsDir).exists()) {
      throw StateError('Deps not found at ${TestConfig.depsDir}');
    }
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
  });
}
