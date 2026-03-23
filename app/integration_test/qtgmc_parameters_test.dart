/// Integration test: QTGMC advanced parameters end-to-end.
///
/// This test is fully schema-driven — it uses the deinterlace filter schema to:
/// 1. Determine which parameters are optional and what their defaults are
/// 2. Map schema param IDs → VapourSynth parameter names
/// 3. Enable each optional parameter (simulating the Advanced UI checkbox flow)
/// 4. Validate that every enabled parameter appears in the generated .vpy script
///    with the correct value matching what was set via the schema
///
/// Run with: dart test integration_test/qtgmc_parameters_test.dart --chain-stack-traces

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import '../lib/models/dynamic_parameters.dart';
import '../lib/models/encoding_settings.dart';
import '../lib/models/filter_schema.dart';
import '../lib/models/parameter_converter.dart';
import '../lib/models/processing_pipeline.dart';
import '../lib/models/qtgmc_parameters.dart';
import '../lib/models/video_job.dart';

// =============================================================================
// TEST CONFIGURATION
// =============================================================================

class TestConfig {
  static final String projectRoot = _findProjectRoot();
  static String get inputFile =>
      '$projectRoot/Tests/TestResources/interlaced_test.avi';
  static String get outputDir =>
      '$projectRoot/Tests/TestOutput/qtgmc_params';
  static String get workerPath =>
      '$projectRoot/worker/target/release/vapourbox-worker.exe';
  static String get depsDir => '$projectRoot/deps/windows-x64';
  static String get ffmpegPath => '$depsDir/ffmpeg/ffmpeg.exe';

  static String _findProjectRoot() {
    var dir = Directory.current;
    while (!File('${dir.path}/CLAUDE.md').existsSync()) {
      final parent = dir.parent;
      if (parent.path == dir.path) {
        throw StateError(
            'Could not find project root (looking for CLAUDE.md)');
      }
      dir = parent;
    }
    return dir.path.replaceAll('\\', '/');
  }
}

// =============================================================================
// SCAN DETECTION (uses ffmpeg idet filter, same approach as FieldOrderDetector)
// =============================================================================

enum DetectedScanType { interlaced, progressive, telecine, unknown }

/// Detect interlacing via ffmpeg's idet filter (mirrors FieldOrderDetector logic).
Future<DetectedScanType> detectScanType(String videoPath) async {
  final result = await Process.run(
    TestConfig.ffmpegPath,
    ['-i', videoPath, '-vf', 'idet=half_life=0', '-frames:v', '200',
     '-an', '-f', 'null', '-'],
    environment: {
      'PATH': '${TestConfig.depsDir}/ffmpeg;${Platform.environment['PATH']}',
    },
  );

  // idet outputs to stderr; prints results twice (mid + end). Use the last match.
  final output = result.stderr as String;
  final multiMatches = RegExp(
    r'Multi frame detection:\s*TFF:\s*(\d+)\s*BFF:\s*(\d+)\s*Progressive:\s*(\d+)\s*Undetermined:\s*(\d+)',
  ).allMatches(output).toList();
  final singleMatches = RegExp(
    r'Single frame detection:\s*TFF:\s*(\d+)\s*BFF:\s*(\d+)\s*Progressive:\s*(\d+)\s*Undetermined:\s*(\d+)',
  ).allMatches(output).toList();

  final match = multiMatches.isNotEmpty
      ? multiMatches.last
      : singleMatches.isNotEmpty ? singleMatches.last : null;
  if (match == null) return DetectedScanType.unknown;

  final tff = int.parse(match.group(1)!);
  final bff = int.parse(match.group(2)!);
  final prog = int.parse(match.group(3)!);
  if (tff + bff + prog == 0) return DetectedScanType.unknown;
  if (tff + bff > 0) return DetectedScanType.interlaced;
  if (prog > 0) return DetectedScanType.progressive;
  return DetectedScanType.unknown;
}

// =============================================================================
// WORKER SCRIPT GENERATION
// =============================================================================

/// Run the worker to generate the .vpy script, then kill it and return the
/// script contents. We only need the script, not the encode.
Future<String> generateScriptViaWorker(VideoJob job) async {
  final configFile =
      File('${Directory.systemTemp.path}/vapourbox_job_${job.id}.json');
  await configFile.writeAsString(jsonEncode(job.toJson()));

  final env = Map<String, String>.from(Platform.environment);
  final d = TestConfig.depsDir;
  env['PYTHONHOME'] = '$d/vapoursynth';
  env['PYTHONPATH'] = '$d/vapoursynth/Lib/site-packages';
  env['PATH'] = '$d/vapoursynth;$d/ffmpeg;${env['PATH']}';
  env['VAPOURSYNTH_PLUGIN_PATH'] = '$d/vapoursynth/vs-plugins';

  final process = await Process.start(
    TestConfig.workerPath,
    ['--config', configFile.path],
    environment: env,
    workingDirectory: File(TestConfig.workerPath).parent.path,
  );

  final scriptPath = '${Directory.systemTemp.path}/${job.id}.vpy';

  // Drain stdout/stderr to avoid blocking
  final logLines = <String>[];
  process.stdout.transform(utf8.decoder).listen((data) {
    for (final line in data.split('\n').where((l) => l.trim().isNotEmpty)) {
      logLines.add(line);
    }
  });
  process.stderr.transform(utf8.decoder).listen((_) {});

  // Poll for the script file (worker writes it early, before vspipe runs)
  String? scriptContent;
  for (var i = 0; i < 60; i++) {
    await Future.delayed(const Duration(milliseconds: 500));
    final f = File(scriptPath);
    if (await f.exists()) {
      scriptContent = await f.readAsString();
      break;
    }
  }

  // Kill the worker — we only needed the script
  process.kill();
  await process.exitCode.timeout(const Duration(seconds: 5),
      onTimeout: () { Process.killPid(process.pid, ProcessSignal.sigkill); return -1; });

  // Clean up temp files
  await configFile.delete().catchError((_) => configFile);
  final sf = File(scriptPath);
  if (await sf.exists()) await sf.delete().catchError((_) => sf);

  if (scriptContent == null) {
    throw StateError(
        'Script was not generated at $scriptPath\n'
        'Worker output:\n${logLines.join('\n')}');
  }
  return scriptContent;
}

// =============================================================================
// SCRIPT VALUE PARSER
// =============================================================================

/// Parse all `ParamName=Value` assignments from the haf.QTGMC(...) call in a
/// generated .vpy script. Returns a map of {paramName → rawValueString}.
Map<String, String> parseQtgmcParams(String script) {
  final start = script.indexOf('haf.QTGMC(');
  if (start == -1) return {};
  // Find the matching closing paren (handles nested calls)
  var depth = 0;
  var end = start;
  for (var i = start; i < script.length; i++) {
    if (script[i] == '(') depth++;
    if (script[i] == ')') { depth--; if (depth == 0) { end = i; break; } }
  }
  final qtgmcCall = script.substring(start, end + 1);

  final params = <String, String>{};
  // Match lines like "    ParamName=Value," or "    ParamName="StringVal","
  final re = RegExp(r'(\w+)\s*=\s*(.+?)\s*,?\s*$', multiLine: true);
  for (final m in re.allMatches(qtgmcCall)) {
    final name = m.group(1)!;
    var value = m.group(2)!;
    // Strip trailing comma
    if (value.endsWith(',')) value = value.substring(0, value.length - 1).trim();
    params[name] = value;
  }
  return params;
}

/// Convert a Dart/JSON value to its expected Python representation in the
/// generated script, based on the parameter's schema type.
String toPythonValue(dynamic value, ParameterType type) {
  switch (type) {
    case ParameterType.boolean:
      return value == true ? 'True' : 'False';
    case ParameterType.integer:
      return (value as num).toInt().toString();
    case ParameterType.number:
      final d = (value as num).toDouble();
      // Rust formats with minimal precision but always includes ".0" for whole numbers
      if (d == d.roundToDouble() && !d.isInfinite) {
        return '${d.toStringAsFixed(1)}';
      }
      return d.toString();
    case ParameterType.string:
    case ParameterType.enumType:
      // Strings are wrapped in quotes in the template
      return '"$value"';
  }
}

// =============================================================================
// TESTS
// =============================================================================

void main() {
  late FilterSchema schema;
  late MethodDefinition qtgmcMethod;

  setUpAll(() async {
    // Verify prerequisites
    for (final check in <String, String>{
      'Worker': TestConfig.workerPath,
      'Input': TestConfig.inputFile,
    }.entries) {
      if (!await File(check.value).exists()) {
        throw StateError('${check.key} not found at ${check.value}');
      }
    }
    if (!await Directory(TestConfig.depsDir).exists()) {
      throw StateError('Deps not found at ${TestConfig.depsDir}');
    }

    await Directory(TestConfig.outputDir).create(recursive: true);

    // Load the deinterlace filter schema (same JSON the UI loads at runtime)
    final schemaFile = File(
        '${TestConfig.projectRoot}/app/assets/filters/core/deinterlace.json');
    schema = FilterSchema.fromJson(
        jsonDecode(await schemaFile.readAsString()) as Map<String, dynamic>);

    // Get the QTGMC method definition — its parameter list defines which
    // schema params belong to QTGMC (vs IVTC, Soft Telecine, etc.)
    qtgmcMethod = schema.methods.firstWhere((m) => m.id == 'qtgmc');

    print('Test configuration:');
    print('  Project root:    ${TestConfig.projectRoot}');
    print('  Schema params:   ${schema.parameters.length}');
    print('  QTGMC params:    ${qtgmcMethod.parameters.length}');
  });

  group('QTGMC Parameters End-to-End', () {
    // =========================================================================
    // STEP 1: Scan detection
    // =========================================================================
    test('Step 1: Scan detects interlaced content', () async {
      final scanType = await detectScanType(TestConfig.inputFile);
      print('  Detected: $scanType');
      expect(scanType, DetectedScanType.interlaced,
          reason: 'Test video should be detected as interlaced');
    });

    // =========================================================================
    // STEP 2: QTGMC auto-selection (replicate ViewModel logic)
    // =========================================================================
    test('Step 2: ViewModel selects QTGMC for interlaced content', () {
      // MainViewModel._analyzeQueueItem maps ScanType.interlaced → QTGMC
      expect(DeinterlaceMethod.qtgmc, DeinterlaceMethod.qtgmc);
      print('  QTGMC correctly selected for interlaced content');
    });

    // =========================================================================
    // STEP 3: Schema-driven parameter enabling (simulates Advanced UI)
    // =========================================================================
    late QTGMCParameters allParamsEnabled;
    // Map of {vsParamName → {value, type}} for script validation in step 4
    late Map<String, ({dynamic value, ParameterType type})> expectedScriptParams;

    test('Step 3: Enable every optional QTGMC parameter from schema', () {
      // Start with QTGMC enabled as the scan would set it
      DynamicParameters dynParams = ParameterConverter.fromQTGMC(
        const QTGMCParameters(
          enabled: true,
          method: DeinterlaceMethod.qtgmc,
          preset: QTGMCPreset.superFast,
          tff: true,
          fpsDivisor: 2,
        ),
      );

      expectedScriptParams = {};
      int enabledCount = 0;

      // Walk every parameter that belongs to the QTGMC method, using the
      // schema's method.parameters list (exactly what the UI iterates).
      for (final paramId in qtgmcMethod.parameters) {
        final paramDef = schema.parameters[paramId];
        if (paramDef == null) continue;

        final vsName = paramDef.getVsName(paramId);

        if (paramDef.optional == true) {
          // Optional param: starts null (disabled). Enable it with its default.
          final defaultValue = paramDef.defaultValue;
          expect(defaultValue, isNotNull,
              reason: 'Optional param "$paramId" must have a non-null schema '
                  'default (issue #4 fix)');
          dynParams = dynParams.withValue(paramId, defaultValue);
          expectedScriptParams[vsName] =
              (value: defaultValue, type: paramDef.type);
          enabledCount++;
          print('  [optional] $paramId → $vsName = $defaultValue');
        } else if (paramDef.ui?.hidden != true) {
          // Non-optional, non-hidden param: already has a value in dynParams.
          final value = dynParams.values[paramId] ?? paramDef.defaultValue;
          if (value != null) {
            expectedScriptParams[vsName] =
                (value: value, type: paramDef.type);
          }
        }
      }

      print('  Optional params enabled: $enabledCount');
      expect(enabledCount, greaterThan(30),
          reason: 'QTGMC should have 30+ optional parameters');

      // Convert back to typed model (same path as ViewModel.updateDynamicParams)
      allParamsEnabled = ParameterConverter.toQTGMC(dynParams);

      // Schema-driven spot checks: verify every optional field we enabled
      // actually made it into the typed model (not null).
      for (final paramId in qtgmcMethod.parameters) {
        final paramDef = schema.parameters[paramId];
        if (paramDef == null || paramDef.optional != true) continue;
        final vsName = paramDef.getVsName(paramId);
        // Verify via round-trip: DynamicParams → QTGMCParameters → DynamicParams
        final roundTripped = ParameterConverter.fromQTGMC(allParamsEnabled);
        final val = roundTripped.values[paramId];
        expect(val, isNotNull,
            reason: 'Optional param "$paramId" ($vsName) should survive '
                'DynamicParams → QTGMCParameters → DynamicParams round-trip');
      }

      print('  PASS: All optional params survive round-trip');
    });

    // =========================================================================
    // STEP 4: Generate script and validate values from schema
    // =========================================================================
    test('Step 4: Script contains all params with correct values', () async {
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: TestConfig.inputFile,
        outputPath: '${TestConfig.outputDir}/qtgmc_all_params.mkv',
        qtgmcParameters: allParamsEnabled,
        processingPipeline: ProcessingPipeline(
          deinterlace: allParamsEnabled,
        ),
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.h264,
          container: ContainerFormat.mkv,
          audioMode: AudioMode.none,
        ),
        startFrame: 10,
        endFrame: 30,
      );

      print('  Generating .vpy script via worker...');
      final script = await generateScriptViaWorker(job);
      print('  Script generated (${script.length} bytes)');

      expect(script, contains('haf.QTGMC('),
          reason: 'Script must contain a QTGMC call');

      // Parse actual parameter assignments from the generated script
      final actualParams = parseQtgmcParams(script);
      print('  Parsed ${actualParams.length} params from QTGMC call');

      // Validate every expected parameter is present with the correct value
      final missing = <String>[];
      final wrongValue = <String>[];

      for (final entry in expectedScriptParams.entries) {
        final vsName = entry.key;
        final expectedValue = entry.value.value;
        final paramType = entry.value.type;

        if (!actualParams.containsKey(vsName)) {
          // The Rust script generator omits params whose Rust-side Option is
          // None. Non-optional params (like Rep1, TrueMotion) that the schema
          // sets but the typed model stores as a raw default may pass through
          // as None on the Rust side. Only flag optional params as missing.
          final paramId = qtgmcMethod.parameters.firstWhere(
            (id) => schema.parameters[id]?.getVsName(id) == vsName,
            orElse: () => '',
          );
          final isOptional = paramId.isNotEmpty &&
              schema.parameters[paramId]?.optional == true;
          if (isOptional) {
            missing.add(vsName);
          }
          continue;
        }

        final actualRaw = actualParams[vsName]!;
        final expectedPython = toPythonValue(expectedValue, paramType);

        if (actualRaw != expectedPython) {
          wrongValue.add(
              '$vsName: expected $expectedPython, got $actualRaw');
        }
      }

      // Print results
      if (missing.isNotEmpty) {
        print('  MISSING optional params:');
        for (final p in missing) print('    - $p');
      }
      if (wrongValue.isNotEmpty) {
        print('  WRONG VALUES:');
        for (final p in wrongValue) print('    - $p');
      }

      // Print the QTGMC call for debugging on failure
      if (missing.isNotEmpty || wrongValue.isNotEmpty) {
        final s = script.indexOf('haf.QTGMC(');
        if (s != -1) {
          var depth = 0;
          var e = s;
          for (var i = s; i < script.length; i++) {
            if (script[i] == '(') depth++;
            if (script[i] == ')') { depth--; if (depth == 0) { e = i; break; } }
          }
          print('\n  Generated QTGMC call:\n${script.substring(s, e + 1)}');
        }
      }

      expect(missing, isEmpty,
          reason: 'All optional QTGMC params should appear in script. '
              'Missing: ${missing.join(', ')}');
      expect(wrongValue, isEmpty,
          reason: 'All QTGMC param values should match schema defaults. '
              'Mismatches: ${wrongValue.join('; ')}');

      final optionalCount = expectedScriptParams.entries
          .where((e) {
            final paramId = qtgmcMethod.parameters.firstWhere(
              (id) => schema.parameters[id]?.getVsName(id) == e.key,
              orElse: () => '',
            );
            return paramId.isNotEmpty &&
                schema.parameters[paramId]?.optional == true;
          })
          .length;

      print('  PASS: All $optionalCount optional params present with correct values');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  // ===========================================================================
  // Basic mode: no advanced settings, no optional checkboxes ticked
  // ===========================================================================
  group('QTGMC Basic Mode (no advanced)', () {
    test('Only basic-mode parameters appear in script', () async {
      // -----------------------------------------------------------------
      // Derive the set of params visible in simple (non-advanced) mode,
      // entirely from the schema — matching DynamicFilterPanelCompact logic.
      // -----------------------------------------------------------------

      // 1. Collect parameter IDs controlled by parameterPresets.
      //    In simple mode, these are shown as dropdown selectors, and the
      //    raw parameter widgets are hidden (they still get values though).
      final presetControlledParams = <String>{};
      final presets = schema.parameterPresets;
      if (presets != null) {
        for (final preset in presets.values) {
          for (final optionValues in preset.options.values) {
            presetControlledParams.addAll(optionValues.keys);
          }
        }
      }
      print('  Preset-controlled params: $presetControlledParams');

      // 2. Collect parameter IDs from non-advancedOnly sections.
      final basicSectionParamIds = <String>{};
      final advancedSectionParamIds = <String>{};
      final sections = schema.ui?.sections;
      if (sections != null) {
        for (final section in sections) {
          if (section.advancedOnly) {
            advancedSectionParamIds.addAll(section.parameters);
          } else {
            basicSectionParamIds.addAll(section.parameters);
          }
        }
      }
      print('  Basic section params: $basicSectionParamIds');

      // 3. The basic-mode visible params are those in basic sections that
      //    are not hidden, belong to the QTGMC method, and are not
      //    preset-controlled (preset-controlled params still get values
      //    from the preset selector but aren't individual widgets).
      //    All of these params have non-null defaults (they're non-optional).

      // Build DynamicParameters with default values only (no optional params
      // enabled) — this is the state when the user hasn't touched anything
      // in the Advanced tab.
      final defaultParams = ParameterConverter.fromQTGMC(
        const QTGMCParameters(
          enabled: true,
          method: DeinterlaceMethod.qtgmc,
          preset: QTGMCPreset.superFast,
          tff: true,
          fpsDivisor: 2,
        ),
      );

      // 4. Determine which VS param names we expect in the script.
      //    Non-optional params with explicit values flow through the typed
      //    model. Optional params are null → omitted from the script.
      //    The Rust side emits a parameter only when its Option<T> is Some.
      final unexpectedVsNames = <String>{};

      for (final paramId in qtgmcMethod.parameters) {
        final paramDef = schema.parameters[paramId];
        if (paramDef == null) continue;
        final vsName = paramDef.getVsName(paramId);

        if (paramDef.optional == true) {
          // Optional params start disabled (null) in basic mode → must NOT
          // appear in the script.
          final value = defaultParams.values[paramId];
          if (value == null) {
            unexpectedVsNames.add(vsName);
          }
        }
      }

      // The always-present params are those with explicit non-null values
      // in the base QTGMCParameters: Preset, TFF, FPSDivisor.
      // (InputType defaults to 0 but is stored as a non-optional int with
      // a default, so it may or may not appear depending on Rust Option.)
      // We derive expected params from what the typed model actually has set.

      // Generate the script
      final job = VideoJob(
        id: const Uuid().v4(),
        inputPath: TestConfig.inputFile,
        outputPath: '${TestConfig.outputDir}/qtgmc_basic_mode.mkv',
        qtgmcParameters: ParameterConverter.toQTGMC(defaultParams),
        processingPipeline: ProcessingPipeline(
          deinterlace: ParameterConverter.toQTGMC(defaultParams),
        ),
        encodingSettings: const EncodingSettings(
          codec: VideoCodec.h264,
          container: ContainerFormat.mkv,
          audioMode: AudioMode.none,
        ),
        startFrame: 10,
        endFrame: 30,
      );

      print('  Generating .vpy script in basic mode...');
      final script = await generateScriptViaWorker(job);
      expect(script, contains('haf.QTGMC('),
          reason: 'Script must contain a QTGMC call');

      final actualParams = parseQtgmcParams(script);
      print('  Parsed ${actualParams.length} params from QTGMC call');

      // Verify: no optional (advanced-only) parameter should be in the script
      final leakedAdvanced = <String>[];
      for (final vsName in unexpectedVsNames) {
        if (actualParams.containsKey(vsName)) {
          leakedAdvanced.add(vsName);
        }
      }

      if (leakedAdvanced.isNotEmpty) {
        print('  LEAKED advanced params (should not be in script):');
        for (final p in leakedAdvanced) {
          print('    - $p = ${actualParams[p]}');
        }
      }

      expect(leakedAdvanced, isEmpty,
          reason: 'No optional/advanced params should appear in the script '
              'when Advanced mode is off. Leaked: ${leakedAdvanced.join(', ')}');

      // Verify: the params that ARE present should be the basic non-optional
      // ones, and their values should match what we set.
      print('  Parameters in basic-mode script:');
      for (final entry in actualParams.entries) {
        // Find the schema param ID for this VS name
        final paramId = qtgmcMethod.parameters.cast<String?>().firstWhere(
          (id) => id != null && schema.parameters[id]?.getVsName(id) == entry.key,
          orElse: () => null,
        );
        final paramDef = paramId != null ? schema.parameters[paramId] : null;
        final isOptional = paramDef?.optional == true;
        final section = sections?.firstWhere(
          (s) => s.parameters.contains(paramId),
          orElse: () => const UiSection(title: '?', parameters: []),
        );
        final sectionLabel = section?.advancedOnly == true ? 'ADVANCED' : 'basic';

        print('    $sectionLabel: ${entry.key} = ${entry.value}'
            '${isOptional ? ' [OPTIONAL]' : ''}');

        // Every param in the script should be non-optional
        expect(isOptional, isFalse,
            reason: '${entry.key} is optional and should not be in the '
                'basic-mode script');
      }

      // Verify that the basic params have the correct values
      final basicValueChecks = <String, String>{
        'Preset': '"Super Fast"',
        'TFF': 'True',
        'FPSDivisor': '2',
      };

      for (final entry in basicValueChecks.entries) {
        expect(actualParams[entry.key], entry.value,
            reason: 'Basic param ${entry.key} should be ${entry.value}');
      }

      print('  PASS: Only ${actualParams.length} non-optional params in script, '
          'no advanced params leaked');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
