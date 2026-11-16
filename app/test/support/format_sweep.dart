// The generated format sweep (task #47): every pass × method × depth ×
// subsampling × field flag × frame size, built from the enums and schemas
// rather than from hand-written lists.
//
// This file holds everything the sweep is made of, and nothing that runs the
// worker: the axes, the variant generator, the fixtures and the few
// declaration tables. `format_sweep_cases_test.dart` (push gate, no worker)
// checks the generator; `integration_format_sweep_test.dart` runs it.
//
// What joins by itself, with no edit here:
//  * a new `PassType` (after it is classified in [sweepClassOf], which has no
//    `default` and so won't compile until it is);
//  * a new method in a schema's `methods`, or a new `implementation` entry
//    with its own `activeWhen`;
//  * a new pixel format in the worker's `NATIVE_FORMATS`;
//  * a new GPU or add-on method (the app's own decisions say what it needs).
//
// The count assertions in the cases test fail when any of these appear or
// disappear, so a skipped row can't look like a passing one.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:vapourbox/models/colorize_parameters.dart';
import 'package:vapourbox/models/dynamic_parameters.dart';
import 'package:vapourbox/models/encoding_settings.dart';
import 'package:vapourbox/models/face_restore_parameters.dart';
import 'package:vapourbox/models/gpu_plugin_status.dart';
import 'package:vapourbox/models/parameter_converter.dart';
import 'package:vapourbox/models/processing_pipeline.dart';
import 'package:vapourbox/models/qtgmc_parameters.dart';
import 'package:vapourbox/models/video_job.dart';
import 'package:vapourbox/views/pass_settings/pass_settings_inline.dart';

import 'worker_harness.dart';

// =============================================================================
// PASSES
// =============================================================================

/// Whether a pass is swept, and if not, why.
class SweepClass {
  const SweepClass.swept() : excludedBecause = null;
  const SweepClass.excluded(String this.excludedBecause);

  final String? excludedBecause;
  bool get swept => excludedBecause == null;
}

/// Every [PassType], classified. No `default`: a new pass doesn't compile
/// until someone decides here whether the sweep covers it — the Dart form of
/// `ChromaSubsampling::ALL`'s catch-all-free match.
SweepClass sweepClassOf(PassType type) {
  switch (type) {
    case PassType.deinterlace:
    case PassType.unblend:
    case PassType.descratch:
    case PassType.spotless:
    case PassType.noiseReduction:
    case PassType.chromaDenoise:
    case PassType.dehalo:
    case PassType.deblock:
    case PassType.deband:
    case PassType.sharpen:
    case PassType.antiAlias:
    case PassType.stabilize:
    case PassType.geometry:
    case PassType.grain:
    case PassType.frameRate:
    case PassType.deflicker:
    case PassType.edgeRepair:
    case PassType.ghostRemoval:
    case PassType.descale:
    case PassType.colorCorrection:
    case PassType.chromaFixes:
    case PassType.cropResize:
    case PassType.faceRestore:
    case PassType.colorize:
      return const SweepClass.swept();
    case PassType.audioRestoration:
      return const SweepClass.excluded(
          'works on the soundtrack; never touches the script (test_185)');
    case PassType.subtitles:
      return const SweepClass.excluded(
          'transcribes and muxes after the encode; no VapourSynth code');
  }
}

/// The swept passes, in pipeline order.
List<PassType> get sweptPassTypes =>
    PassType.values.where((t) => sweepClassOf(t).swept).toList();

/// A filter schema as raw JSON (the cases test checks the parts the sweep
/// reads; the app's model drops keys it doesn't know).
Map<String, dynamic> loadSchemaJson(String filterId) => jsonDecode(
        File('assets/filters/core/$filterId.json').readAsStringSync())
    as Map<String, dynamic>;

/// The method ids a schema declares.
List<String> schemaMethodIds(Map<String, dynamic> schema) =>
    [for (final m in (schema['methods'] as List? ?? const [])) (m as Map)['id'] as String];

// =============================================================================
// THE HAND-WRITTEN PARTS: enum axes, actuation overrides, prerequisites
// =============================================================================

/// An enum parameter swept option by option, on top of the schema's methods:
/// options the schema alone doesn't reach, which pick different code paths.
class EnumAxis {
  const EnumAxis(this.filterId, this.param,
      {this.onlyMethod, this.exclude = const {}, required this.reason});

  final String filterId;
  final String param;

  /// Only for this method (null: every variant of the filter).
  final String? onlyMethod;

  /// Options not swept, each for the reason given.
  final Set<String> exclude;
  final String reason;
}

const enumAxes = <EnumAxis>[
  EnumAxis('deinterlace', 'preset',
      onlyMethod: 'qtgmc',
      reason: 'presets pick different EDI/Bob paths; 14-bit failed on every '
          'one (task #23)'),
  EnumAxis('geometry', 'rotation',
      exclude: {'none'},
      reason: 'the default rotation with no flip is inert; each turn is its own '
          'transpose path'),
  EnumAxis('stabilize', 'pitchMode',
      exclude: {'file'},
      reason: 'auto pitch is its own module (stabilize.py); file mode needs a '
          'factor file'),
];

/// A frame size's own numbers, for overrides that must scale with it.
typedef SizeValues = Map<String, dynamic> Function(int width, int height);

/// Values that make a pass act on the fixture, or that must follow the frame
/// size. Keyed by variant id (exact) or filter id (every variant of it), in
/// **schema parameter names**; the cases test fails on a key or parameter
/// that doesn't exist. Applied before the variant's own values, so a
/// variant's `activeWhen` wins.
final actuationOverrides = <String, ({String reason, SizeValues values})>{
  'crop_resize/cropEnabled=true': (
    reason: 'an even crop inside the frame, a multiple of 4 vertically so a '
        'still-interlaced 4:2:0 picture stays legal per field',
    values: (w, h) => {
          'cropLeft': (w ~/ 8) & ~1,
          'cropRight': (w ~/ 8) & ~1,
          'cropTop': (h ~/ 8) & ~3,
          'cropBottom': (h ~/ 8) & ~3,
        },
  ),
  'crop_resize/resizeEnabled=true': (
    reason: 'the default 1920x1080 box is 20x a tiny frame; twice the size '
        'resamples just as well',
    values: (w, h) => {'targetWidth': 2 * w, 'targetHeight': 2 * h},
  ),
  'crop_resize/padToAspect=true+resizeEnabled=true': (
    reason: 'a square box of the frame\'s width: no resample, real bars',
    values: (w, h) => {'targetWidth': w, 'targetHeight': w},
  ),
  'crop_resize/padEnabled=true': (
    reason: 'the default 720x576 canvas is smaller than SD NTSC\'s 720x480 '
        'in neither axis but refuses any wider frame, by design',
    values: (w, h) => {'padWidth': w + 32, 'padHeight': h + 32},
  ),
  'descale': (
    reason: 'the default 720-line native height is above every sweep frame; '
        'detail protection keeps nearly every pixel of a never-upscaled '
        'picture, which makes the pass inert',
    values: (w, h) => {'nativeHeight': (h * 3 ~/ 4) & ~1, 'protectDetail': false},
  ),
  'descratch': (
    reason: 'the default minimum scratch length (100 lines) is taller than a '
        'tiny frame',
    values: (w, h) => {'minlen': h ~/ 2},
  ),
  'edge_repair': (
    reason: 'every border defaults to 0 lines',
    values: (w, h) => {'left': 4, 'right': 4, 'top': 2, 'bottom': 2},
  ),
  'chroma_fixes/applyAutoChroma=false+applyChromaShift=true': (
    reason: 'the shift defaults to 0',
    values: (w, h) => {'chromaShiftH': 2.0, 'chromaShiftV': -1.0},
  ),
  'color_correction': (
    reason: 'brightness, contrast, saturation and hue default to identity',
    values: (w, h) => {'brightness': 10.0},
  ),
  'color_correction/applyLevels=true+smoothLevels=false': (
    reason: 'the default levels are the identity map',
    values: (w, h) => {'inputLow': 16, 'inputHigh': 235, 'gamma': 1.2},
  ),
  'color_correction/applyLevels=true+smoothLevels=true': (
    reason: 'the default levels are the identity map',
    values: (w, h) => {'inputLow': 16, 'inputHigh': 235, 'gamma': 1.2},
  ),
};

/// Other passes a variant needs on to act at all. Values in schema names.
const prerequisites = <String, Map<String, Map<String, dynamic>>>{
  // The schema: "only useful when deinterlacing is on" (QTGMC's own
  // EZDenoise); alone it changes nothing.
  'noise_reduction/qtgmc_builtin': {
    'deinterlace': {'enabled': true, 'method': 'qtgmc', 'preset': 'Fast'},
  },
};

// =============================================================================
// VARIANTS
// =============================================================================

/// One pass with one method or one sub-feature switched on, as the panel
/// would produce it.
class SweepVariant {
  SweepVariant({
    required this.id,
    required this.type,
    required this.filterId,
    required this.values,
    required this.index,
  });

  /// `filterId`, `filterId/method` (`filterId/method[param=v]` for an enum
  /// axis on a method), or `filterId/k=v+k2=v2` with the keys sorted.
  final String id;
  final PassType type;
  final String filterId;

  /// The values the variant sets on top of the defaults (before overrides).
  final Map<String, dynamic> values;

  /// Position in [sweepVariants], which rotates the covering rows.
  final int index;

  /// The pipeline at a frame size, built through the app's own converter.
  ProcessingPipeline pipelineFor(int width, int height) =>
      buildPipeline(filterId, id, values, width, height);

  /// The panel values the variant ends up with (for requirement checks).
  Map<String, dynamic> panelValues(int width, int height) =>
      ParameterConverter.fromPipeline(pipelineFor(width, height))
          .get(filterId)!
          .values;

  /// The GPU feature it needs, from the app's own decision.
  GpuPlugin? get gpu => gpuPluginSelectedBy(filterId, panelValues(96, 64));

  /// The add-ons it needs, from the app's own decisions.
  List<String> get addons {
    final v = panelValues(96, 64);
    return {
      if (modelAddonSelectedBy(filterId, v) case final id?) id,
      if (colorizeAddonSelectedBy(filterId, true, v) case final id?) id,
      ...?faceRestoreAddonsSelectedBy(filterId, true, v),
    }.toList();
  }

  /// KNLMeansCL needs an OpenCL device; the worker refuses the job without.
  bool get needsKnlmDevice =>
      filterId == 'noise_reduction' && values['method'] == 'knlmeans';

  /// A CPU variant that downloads nothing: runs in the push gate.
  bool get runsAnywhere => gpu == null && addons.isEmpty;

  @override
  String toString() => id;
}

/// The pipeline every variant starts from: everything off. The default
/// pipeline deinterlaces (QTGMCParameters.enabled defaults to true).
const ProcessingPipeline sweepBasePipeline =
    ProcessingPipeline(deinterlace: QTGMCParameters(enabled: false));

/// [filterId] switched on with [values] on top of its defaults, the
/// overrides for [variantId] at the frame size, and its prerequisites,
/// round-tripped through [ParameterConverter] as the panel does.
ProcessingPipeline buildPipeline(String filterId, String variantId,
    Map<String, dynamic> values, int width, int height) {
  final base = ParameterConverter.fromPipeline(sweepBasePipeline);
  final filters = Map<String, DynamicParameters>.of(base.filters);

  DynamicParameters apply(String id, Map<String, dynamic> extra) {
    final p = filters[id]!;
    return DynamicParameters(
      filterId: p.filterId,
      enabled: true,
      values: {...p.values, ...extra},
      enabledOptionalParams: p.enabledOptionalParams,
      lastOptionalValues: p.lastOptionalValues,
    );
  }

  final overrides = <String, dynamic>{
    ...?actuationOverrides[filterId]?.values(width, height),
    ...?actuationOverrides[variantId]?.values(width, height),
  };
  filters[filterId] = apply(filterId, {...overrides, ...values});
  for (final MapEntry(key: other, value: v)
      in (prerequisites[variantId] ?? const {}).entries) {
    filters[other] = apply(other, v);
  }
  return ParameterConverter.toPipeline(DynamicPipeline(filters: filters));
}

String _setId(Map<String, dynamic> set) =>
    (set.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))
        .map((e) => '${e.key}=${e.value}')
        .join('+');

/// The value sets a schema's own structure names, before enum axes:
/// one per method when there are several, else one per distinct
/// `implementation` `activeWhen` (no `activeWhen`: the base), else the base.
List<Map<String, dynamic>> schemaValueSets(Map<String, dynamic> schema) {
  final methods = schemaMethodIds(schema);
  if (methods.length > 1) {
    return [for (final m in methods) {'method': m}];
  }
  final impl = schema['implementation'] as List? ?? const [];
  if (impl.isEmpty) return [{}];
  final params = schema['parameters'] as Map<String, dynamic>;
  final sets = <String, Map<String, dynamic>>{};
  for (final entry in impl) {
    final when = (entry as Map)['activeWhen'] as Map<String, dynamic>?;
    final set = <String, dynamic>{};
    for (final MapEntry(:key, :value) in (when ?? const {}).entries) {
      if (value is List) {
        // A list matches any of its values: take the first that is not the
        // default (`convertToBt709: [auto, on]` -> on).
        final def = (params[key] as Map?)?['default'];
        set[key] = value.firstWhere((v) => v != def, orElse: () => value.first);
      } else {
        set[key] = value;
      }
    }
    sets[_setId(set)] = set;
  }
  return sets.values.toList();
}

/// Every variant, generated. Deduplicated by the pipeline it builds, so two
/// implementation entries with one `activeWhen` (or a base equal to a
/// default method) count once.
final List<SweepVariant> sweepVariants = _generateVariants();

List<SweepVariant> _generateVariants() {
  final out = <SweepVariant>[];
  final seen = <String>{};
  for (final type in sweptPassTypes) {
    final filterId = PassSettingsInline.filterIdFor(type);
    final schema = loadSchemaJson(filterId);
    final params = schema['parameters'] as Map<String, dynamic>;
    var sets = schemaValueSets(schema);
    for (final axis in enumAxes.where((a) => a.filterId == filterId)) {
      final options = ((params[axis.param] as Map)['options'] as List)
          .map((o) => o is Map ? o['value'] : o)
          .where((o) => !axis.exclude.contains(o));
      sets = [
        for (final set in sets)
          if (axis.onlyMethod == null || set['method'] == axis.onlyMethod)
            for (final o in options) {...set, axis.param: o}
          else
            set,
      ];
    }
    for (final set in sets) {
      final id = set.isEmpty ? filterId : '$filterId/${_variantKey(set)}';
      final pipeline = buildPipeline(filterId, id, set, 96, 64);
      if (!seen.add(jsonEncode(pipeline.toJson()))) continue;
      out.add(SweepVariant(
          id: id, type: type, filterId: filterId, values: set, index: out.length));
    }
  }
  return out;
}

/// `method=x` reads as `x`; an axis as `[param=v]`.
String _variantKey(Map<String, dynamic> set) {
  final method = set['method'];
  final rest = Map.of(set)..remove('method');
  if (method == null) return _setId(rest);
  final axes = enumAxes.map((a) => a.param).toSet();
  final axisPart = rest.keys.where(axes.contains).map((k) => '[$k=${rest[k]}]').join();
  rest.removeWhere((k, _) => axes.contains(k));
  return '$method$axisPart${rest.isEmpty ? '' : '+${_setId(rest)}'}';
}

// =============================================================================
// FORMATS, FIELDS, SIZES, ROWS
// =============================================================================

const sweepDepths = [8, 9, 10, 12, 14, 16];
const sweepSubsamplings = ['420', '422', '444'];

/// A source pixel format the sweep feeds the worker.
class SweepFormat {
  const SweepFormat(this.name, this.layout, this.depth);

  /// ffmpeg's name: `yuv420p`, `yuv422p10le`, `yuvj444p`, `yuv411p`.
  final String name;

  /// The 8-bit format with the same planes: `yuv422p`, `yuvj444p`, `yuv411p`.
  final String layout;
  final int depth;

  factory SweepFormat.parse(String name) {
    final m = RegExp(r'^(yuvj?4\d\dp)(\d+)?(le)?$').firstMatch(name);
    if (m == null) throw ArgumentError('not a planar YUV format: $name');
    return SweepFormat(name, m.group(1)!, int.parse(m.group(2) ?? '8'));
  }

  factory SweepFormat.of(String subsampling, int depth) => SweepFormat(
      depth == 8 ? 'yuv${subsampling}p' : 'yuv${subsampling}p${depth}le',
      'yuv${subsampling}p',
      depth);

  /// `420`, `422`, `444`, `411`.
  String get subsampling => RegExp(r'4\d\d').firstMatch(layout)!.group(0)!;

  /// Chroma divisors (horizontal, vertical).
  (int, int) get chromaShift => switch (subsampling) {
        '420' => (2, 2),
        '422' => (2, 1),
        '411' => (4, 1),
        _ => (1, 1),
      };

  /// In the depth × subsampling product (as opposed to an extra native one).
  bool get inProduct => !name.startsWith('yuvj') && subsampling != '411';

  /// The depth the worker's decoder pipes (9 -> 10, 14 -> 16; task #23/#31).
  int get pipedDepth => switch (depth) { 9 => 10, 14 => 16, _ => depth };

  /// The format the worker pipes and an FFV1 encode with Color Format
  /// "original" writes.
  String get pipedName => depth == pipedDepth
      ? name
      : SweepFormat.of(subsampling, pipedDepth).name;

  int get bytesPerSample => depth > 8 ? 2 : 1;

  @override
  bool operator ==(Object other) => other is SweepFormat && other.name == name;
  @override
  int get hashCode => name.hashCode;
  @override
  String toString() => name;
}

/// The worker's `NATIVE_FORMATS`, parsed from `worker/src/pixel_format.rs`.
List<String> workerNativeFormats() {
  final src = File(p.join(WorkerHarness.repoRoot, 'worker', 'src', 'pixel_format.rs'))
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final list = RegExp(r'pub const NATIVE_FORMATS: &\[&str\] = &\[([^\]]*)\]')
      .firstMatch(src)!
      .group(1)!;
  return RegExp(r'"([^"]+)"').allMatches(list).map((m) => m.group(1)!).toList();
}

/// depth × subsampling.
final List<SweepFormat> productFormats = [
  for (final d in sweepDepths)
    for (final s in sweepSubsamplings) SweepFormat.of(s, d),
];

/// Every native format outside the product (NTSC DV's 4:1:1, the full-range
/// `yuvj` formats). A format added to the worker joins here by itself.
final List<SweepFormat> extraFormats = [
  for (final name in workerNativeFormats())
    if (!productFormats.any((f) => f.name == name)) SweepFormat.parse(name),
];

enum SweepField {
  progressive('prog', FieldOrder.progressive),
  tff('tff', FieldOrder.topFieldFirst);

  const SweepField(this.setfield, this.fieldOrder);

  /// ffmpeg's `setfield` value for the fixture.
  final String setfield;

  /// The job's `detectedFieldOrder`.
  final FieldOrder fieldOrder;
}

enum SweepSize {
  /// Under DeScratch's 402-line limit (task #35); heights are multiples of 4
  /// so interlaced 4:2:0 is legal per field.
  short(96, 64),

  /// Width 2 mod 4: 4:2:x chroma is 49 wide, as on 854x480, 1366x768 and
  /// 426x240 sources.
  oddChroma(98, 64),

  /// The height-dependent branches (HD/SD thresholds, block sizes).
  sd(720, 480);

  const SweepSize(this.width, this.height);
  final int width;
  final int height;
}

const tinySizes = [SweepSize.short, SweepSize.oddChroma];

/// Tiny size [k] (mod 2), unless [format]'s chroma grid can't hold its
/// width: a 98-wide 4:1:1 picture doesn't exist (VapourSynth refuses it).
SweepSize tinySizeFor(SweepFormat format, int k) {
  final size = tinySizes[k % 2];
  return size.width % format.chromaShift.$1 == 0 ? size : SweepSize.short;
}

/// 30 frames at 29.97: IVTC and Soft Telecine decimate, Unblend's default
/// 23.976 is exact (4/5), and Frame Rate's default 25 retimes.
const sweepFrames = 30;
const sweepFpsNum = 30000;
const sweepFpsDen = 1001;
const sweepPreviewFrame = 15;

/// One source the sweep runs a variant on.
class SweepRow {
  const SweepRow(this.format, this.field, this.size);

  final SweepFormat format;
  final SweepField field;
  final SweepSize size;

  String get key => '${size.width}x${size.height}/${format.name}/${field.setfield}';

  /// The same picture at another format.
  SweepRow at(SweepFormat f) => SweepRow(f, field, size);

  @override
  bool operator ==(Object other) => other is SweepRow && other.key == key;
  @override
  int get hashCode => key.hashCode;
  @override
  String toString() => key;
}

/// The push gate's rows for variant [i]: four depths, each meeting a
/// different subsampling, field and tiny size, rotating between variants so
/// that every variant meets every subsampling, both fields, both sizes, and
/// every field × size pair; plus one extra native format, round-robin.
List<SweepRow> gateRows(int i) {
  const depths = [8, 10, 12, 16];
  return [
    for (var r = 0; r < 4; r++)
      SweepRow(
        SweepFormat.of(sweepSubsamplings[(r + i) % 3], depths[r]),
        SweepField.values[(r + i) % 2],
        tinySizes[(r + i + r ~/ 2) % 2],
      ),
    if (extraFormats.isNotEmpty)
      SweepRow(
          extraFormats[i % extraFormats.length],
          SweepField.values[i % 2],
          tinySizeFor(extraFormats[i % extraFormats.length], (i ~/ 2) % 2)),
  ];
}

/// The nightly rows for variant [i]:
///  * the full product at tiny sizes, for depths the worker pipes as they
///    are (8, 10, 12, 16) — 48 rows;
///  * 9- and 14-bit at two rotating rows: the decoder maps them losslessly to
///    10 and 16, so every pass sees the 10/16-bit script, and these rows only
///    prove the mapping end to end;
///  * every extra native format, both fields, one tiny size;
///  * three SD rows, one per subsampling, the depth and field rotating.
List<SweepRow> nightlyRows(int i) {
  return [
    for (final size in tinySizes)
      for (final field in SweepField.values)
        for (final f in productFormats)
          if (f.depth == f.pipedDepth) SweepRow(f, field, size),
    for (final (r, d) in [(0, 9), (1, 14)])
      SweepRow(SweepFormat.of(sweepSubsamplings[(r + i) % 3], d),
          SweepField.values[(r + i) % 2], tinySizes[(i ~/ 2 + r) % 2]),
    for (final f in extraFormats)
      for (final field in SweepField.values)
        SweepRow(f, field, tinySizeFor(f, i)),
    for (var s = 0; s < 3; s++)
      SweepRow(SweepFormat.of(sweepSubsamplings[s], const [8, 10, 16][(s + i) % 3]),
          SweepField.values[(s + i) % 2], SweepSize.sd),
  ];
}

// =============================================================================
// ASSERTION TABLES
// =============================================================================

/// The parity tolerance (mean abs RGB difference, 0-255, above the
/// passthrough's own) for variants that interpolate, by id prefix. The
/// default is [defaultParityTolerance].
const defaultParityTolerance = 2.0;
const parityTolerances = <String, ({double tolerance, String reason})>{
  'deinterlace/qtgmc': (
    tolerance: 4.0,
    reason: 'QTGMC interpolates: a half-level source difference shifts an '
        'edge decision; Very Fast and below measured up to 2.96 at 96x64',
  ),
  'crop_resize/upscaleMethod=nnedi3Rpow2': (
    tolerance: 3.0,
    reason: 'NNEDI3 is a neural predictor: half-level inputs move edges',
  ),
  'crop_resize/upscaleMethod=eedi3Rpow2': (
    tolerance: 3.0,
    reason: 'EEDI3 picks edge directions by cost; half-level inputs move them',
  ),
  'color_correction/applyLocalContrast=true': (
    tolerance: 4.0,
    reason: 'CLAHE\'s per-tile histograms quantise differently by depth; '
        'at 96x64 its tiles are 12x8 px (since task #56 F7 it decides on an '
        '8-bit copy at every depth)',
  ),
  'chroma_fixes/applyChromaBleedingFix=true': (
    tolerance: 4.0,
    reason: 'the bleed fix\'s chroma blur masks are thresholded per depth',
  ),
};

double parityToleranceFor(String variantId) {
  for (final MapEntry(:key, :value) in parityTolerances.entries) {
    if (variantId == key || variantId.startsWith(key)) return value.tolerance;
  }
  return defaultParityTolerance;
}

/// Variants that may legitimately leave the fixture unchanged, with the
/// reason (the "acts" check is waived, not inverted).
/// The aim is to degrade the master instead of growing this.
final inertOnFixture = <String, String>{
  for (final id in ['face_restore', 'face_restore/model=gfpgan', 'face_restore/model=codeFormer'])
    id: 'the fixture has no faces; that every sample outside a face is '
        'bit-exact is the deltaOnly check',
  'spotless/spotless': 'acts at SD (nightly rows); on a 96x64 frame '
      'MVTools calls every frame a scene change and Compensate returns the '
      'frame itself',
  'descale/protectDetail=true': 'on a never-upscaled picture detail '
      'protection keeps nearly every pixel, by design (CLAUDE.md, "Descale")',
  'frame_rate/duplicate': 'drops or repeats whole source frames: a preview of '
      'a source frame is that frame, unchanged',
  for (final id in ['deinterlace/ivtc', 'deinterlace/soft_telecine'])
    id: 'the fixture has no pulldown, so field matching keeps every frame '
        'and decimation drops whole frames; since task #46 the preview shows '
        'the encode\'s frame for its source frame, which is that frame, '
        'unchanged',
};

/// What a delta-only pass promises about the samples it leaves alone.
sealed class DeltaOnly {
  const DeltaOnly(this.reason);
  final String reason;
}

/// The plugin runs at [workDepth] and only its change is applied at full
/// depth (`plugin_formats.run_within`, task #48; formerly tasks #34/#37).
class WorkDepth extends DeltaOnly {
  const WorkDepth(this.workDepth, super.reason);
  final int workDepth;
}

/// [planes] (0 = Y, 1 = U, 2 = V) are bit-exact copies of the source's.
class UntouchedPlanes extends DeltaOnly {
  const UntouchedPlanes(this.planes, super.reason);
  final List<int> planes;
}

/// Every output sample is a source sample at a known place.
class ExactGeometry extends DeltaOnly {
  const ExactGeometry(this.kind, super.reason);
  final GeometryKind kind;
}

enum GeometryKind { rotation, crop, edgeRepairInterior, bordersInside }

const deltaOnly = <String, DeltaOnly>{
  'descratch': WorkDepth(8, 'DeScratch is 8-bit only; task #34'),
  'chroma_fixes/applyDedot=true': WorkDepth(8, 'dedot.Dedot is 8-bit only; task #37'),
  'chroma_fixes/applyBifrost=true': WorkDepth(8, 'bifrost is 8-bit only; task #37'),
  'chroma_fixes/applyDeCrawl=true': WorkDepth(10, 'LUTDeCrawl caps at 10-bit; task #37'),
  'chroma_fixes/applyDeRainbow=true':
      WorkDepth(10, 'LUTDeRainbow caps at 10-bit; task #37'),
  'colorize/ddcolor': UntouchedPlanes([0], 'Colourisation never touches luma'),
  'colorize/deoldify': UntouchedPlanes([0], 'Colourisation never touches luma'),
  'grain/grain_factory3':
      UntouchedPlanes([1, 2], 'GrainFactory3 is luma-only; chroma bit-identical'),
  'descale/kernel=bicubic': UntouchedPlanes([1, 2], 'Descale works on luma and keeps chroma'),
  'descale/protectDetail=true':
      UntouchedPlanes([1, 2], 'Descale works on luma and keeps chroma'),
  'face_restore': UntouchedPlanes(
      [0, 1, 2], 'bit-exact outside the faces; the fixture has none'),
  'face_restore/model=gfpgan': UntouchedPlanes(
      [0, 1, 2], 'bit-exact outside the faces; the fixture has none'),
  'face_restore/model=codeFormer': UntouchedPlanes(
      [0, 1, 2], 'bit-exact outside the faces; the fixture has none'),
  'geometry/rotation=cw90': ExactGeometry(GeometryKind.rotation, 'a transpose'),
  'geometry/rotation=rotate180': ExactGeometry(GeometryKind.rotation, 'two flips'),
  'geometry/rotation=ccw90': ExactGeometry(GeometryKind.rotation, 'a transpose'),
  'crop_resize/cropEnabled=true': ExactGeometry(GeometryKind.crop, 'a crop copies'),
  'edge_repair':
      ExactGeometry(GeometryKind.edgeRepairInterior, 'only the borders are filled'),
  'crop_resize/padEnabled=true': ExactGeometry(
      GeometryKind.bordersInside, 'the picture inside the bars is not rescaled'),
};

/// Which check a known failure is for.
enum SweepCheck { runs, depth, parity, bitExact }

/// A (variant, row) that fails today for a filed reason. The sweep requires
/// the failure to match [error] (so a crash can't hide behind it) and fails
/// when the row starts passing, so the entry is removed with the fix.
class KnownFailure {
  const KnownFailure({
    required this.variant,
    required this.check,
    required this.rows,
    required this.error,
    required this.task,
    required this.finding,
    this.flaky = false,
  });

  /// The failure is not reproducible run to run (uninitialised memory), so
  /// a passing row is not reported as fixed.
  final bool flaky;

  /// Variant id, or a prefix ending in `/`.
  final String variant;
  final SweepCheck check;
  final bool Function(SweepRow row) rows;

  /// What the failure's text must match.
  final String error;
  final int task;
  final String finding;

  bool covers(String variantId, SweepRow row, SweepCheck c) =>
      c == check &&
      (variantId == variant || (variant.endsWith('/') && variantId.startsWith(variant))) &&
      rows(row);
}

/// The one task the sweep's findings are filed as.
const knownFailuresTask = 56;

// Task #56 fixed every entry this list held (F1-F4, F6, F7, F9; see
// docs/reports/task-56-format-sweep-findings). A new finding goes here with
// its task, and comes out with its fix.
final knownFailures = <KnownFailure>[];

KnownFailure? knownFailureFor(String variantId, SweepRow row, SweepCheck check) {
  for (final k in knownFailures) {
    if (k.covers(variantId, row, check)) return k;
  }
  return null;
}

// =============================================================================
// FIXTURES
// =============================================================================

/// Bump when the fixtures change, so a cached set is rebuilt.
const _fixtureVersion = 5;

String get sweepOutDir => p.join(WorkerHarness.outputDir, 'format_sweep');
String get _fixtureDir => p.join(sweepOutDir, 'fixtures_v$_fixtureVersion');

final _fixtureFutures = <String, Future<String>>{};

/// The fixture for [row], made once per run (and cached on disk).
Future<String> sweepFixture(SweepRow row) =>
    _fixtureFutures[row.key] ??= _makeFixture(row);

Future<void> _ffmpeg(List<String> args, String what) async {
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    ['-hide_banner', '-loglevel', 'error', '-y', ...args],
    environment: WorkerHarness.ffmpegEnv,
  );
  if (r.exitCode != 0) throw StateError('$what failed: ${r.stderr}');
}

/// Run [write] on a temporary name beside [path], then rename it into place,
/// so a run killed mid-write never leaves a partial fixture that the
/// `existsSync` cache check would take for a finished one.
Future<String> _writeAtomically(String path, Future<void> Function(String tmp) write) async {
  final tmp = '$path.part${p.extension(path)}';
  await write(tmp);
  await File(tmp).rename(path);
  return path;
}

final _masterFutures = <SweepSize, Future<String>>{};

/// One degraded 8-bit 4:4:4 master per size, so most passes find work:
/// seeded grain under a starved interlaced MPEG-2 encode (blocking and
/// ringing for deblock/dehalo) and lighter grain over it (at tiny sizes the
/// encode skips so many blocks that temporal denoisers found nothing), dark
/// scratch columns (DeScratch), one-frame spots (SpotLess), +-2 px shake
/// (Stabilize, on the right half), and a still left half for the crawl and
/// rainbow filters.
/// Dot crawl and rainbow are added per layout, below.
Future<String> _master(SweepSize size) => _masterFutures[size] ??= () async {
      final w = size.width, h = size.height;
      final path = p.join(_fixtureDir, 'master_${w}x$h.mkv');
      if (File(path).existsSync()) return path;
      await Directory(_fixtureDir).create(recursive: true);
      final mpeg = p.join(_fixtureDir, 'master_${w}x${h}_mpeg2.mkv');
      await _ffmpeg([
        '-f', 'lavfi',
        '-i', 'testsrc2=size=${w}x$h:rate=$sweepFpsNum/$sweepFpsDen',
        '-frames:v', '$sweepFrames',
        '-vf', 'noise=alls=18:allf=t+u:all_seed=20261116,setfield=tff',
        '-c:v', 'mpeg2video', '-b:v', '${w * h * 7}', '-flags', '+ilme+ildct',
        '-g', '15', '-bf', '2',
        mpeg,
      ], 'master MPEG-2 ($w x $h)');
      final m = (w ~/ 16) & ~1; // shake margin, even
      final spot = (w ~/ 16).clamp(4, 24);
      final moving = 'noise=alls=4:allf=t+u:all_seed=20261117,'
          "crop=w=${w - 2 * m}:h=${h - 2 * m}"
          ":x='$m+2*(2*mod(n\\,2)-1)':y='$m+2*(2*mod(floor(n/2)\\,2)-1)',"
          'pad=$w:$h:$m:$m,'
          'fillborders=left=$m:right=$m:top=$m:bottom=$m:mode=smear,'
          'drawbox=x=${w * 2 ~/ 10}:y=0:w=2:h=ih:color=black@0.4:t=fill,'
          'drawbox=x=${w ~/ 2}:y=${h ~/ 16}:w=1:h=${h * 3 ~/ 4}:color=black@0.5:t=fill,'
          'drawbox=x=${w * 8 ~/ 10}:y=0:w=2:h=ih:color=black@0.35:t=fill,'
          "drawbox=x=${w * 6 ~/ 10}:y=${h * 3 ~/ 10}:w=$spot:h=$spot:color=white:t=fill"
          ":enable='eq(mod(n\\,5)\\,0)',"
          "drawbox=x=${w * 7 ~/ 10}:y=${h * 6 ~/ 10}:w=$spot:h=$spot:color=black:t=fill"
          ":enable='eq(mod(n\\,5)\\,2)'";
      await _writeAtomically(path, (out) => _ffmpeg([
        '-i', mpeg,
        '-filter_complex',
        '[0:v]$moving,split[a][b];'
            // The left half holds still (frame 0, repeated): the crawl and
            // rainbow filters only act where luma is static, and LUTDeCrawl
            // skips a frame whose mean luma moves by over 25/255, which the
            // whole shaken picture did on every frame.
            '[b]trim=end_frame=1,loop=loop=-1:size=1:start=0,setpts=N/FRAME_RATE/TB,'
            'crop=${(w ~/ 2) & ~3}:ih:0:0[still];'
            '[a][still]overlay=0:0:shortest=1,format=yuv444p[out]',
        '-map', '[out]', '-frames:v', '$sweepFrames',
        '-c:v', 'ffv1', '-pix_fmt', 'yuv444p',
        out,
      ], 'master ($w x $h)'));
      await File(mpeg).delete();
      return path;
    }();

/// The 8-bit fixture in [layout] (and field flag), with dot crawl and
/// rainbow in its top-left eighth (more flips every block MVTools
/// measures, and SpotLess's Compensate calls every frame a scene change): a luma checker of +-4 and a chroma pattern of
/// +-8 per column, flipping every frame, drawn in the layout's own chroma
/// columns so subsampling doesn't average it away (task #37).
Future<String> _eightBit(SweepSize size, String layout, SweepField field) {
  final key = '${size.name}/$layout/${field.name}';
  return _fixtureFutures[key] ??= () async {
    final path = p.join(_fixtureDir,
        '${size.width}x${size.height}_${layout}_${field.setfield}.mkv');
    if (File(path).existsSync()) return path;
    final crawl = "if(lt(X\\,W/4)*lt(Y\\,H/2)\\,clip(lum(X\\,Y)+4*(2*mod(X+Y+N\\,2)-1)\\,0\\,255)\\,lum(X\\,Y))";
    String chroma(String plane, int sign) =>
        "if(lt(X\\,W/4)*lt(Y\\,H/2)\\,clip($plane(X\\,Y)${sign > 0 ? '+' : '-'}8*(2*mod(X+N\\,2)-1)\\,0\\,255)\\,$plane(X\\,Y))";
    final master = await _master(size);
    return _writeAtomically(path, (out) => _ffmpeg([
      '-i', master,
      '-vf', "format=$layout,geq=lum='$crawl':cb='${chroma('cb', 1)}'"
          ":cr='${chroma('cr', -1)}',setfield=${field.setfield}",
      '-c:v', 'ffv1', '-pix_fmt', layout,
      out,
    ], '8-bit fixture $key'));
  }();
}

/// The low-part patterns of the chain, per step: q1 (8 -> 10) and q2
/// (10 -> 12) are 0 or 1, q3 (12 -> 16) is 0..7, each in its own pattern
/// per plane and frame.
int _q1(int x, int y, int n, int plane) => (x + y + n + plane) & 1;
int _q2(int x, int y, int n, int plane) => (x * (y + 1) + plane) & 1;
int _q3(int x, int y, int n, int plane) => (x * 3 + y * 5 + n + plane) & 7;

/// A sample of the chain at [depth] from the 8-bit sample [s]:
/// f10 = 4 f8 + q1, f12 = 4 f10 + q2, f16 = 16 f12 + q3, f9 = 2 f8 + q1,
/// f14 = f16 >> 2. The low part stays under half an 8-bit level (at most
/// 87/256 at 16-bit), so every fixture rounds back (by floor or to nearest)
/// to every shallower one in the chain exactly, and every deep fixture has
/// real sub-8-bit content (task #34's lesson: one converted from an 8-bit
/// master has none, and passes a precision test either way).
int chainSample(int s, int depth, int x, int y, int n, int plane) {
  final q1 = _q1(x, y, n, plane);
  final f10 = 4 * s + q1;
  final f12 = 4 * f10 + _q2(x, y, n, plane);
  final f16 = 16 * f12 + _q3(x, y, n, plane);
  return switch (depth) {
    8 => s,
    9 => 2 * s + q1,
    10 => f10,
    12 => f12,
    14 => f16 >> 2,
    16 => f16,
    _ => throw ArgumentError('no chain at $depth bits'),
  };
}

/// Plane sizes (luma, chroma) for [format] at [size].
({int lw, int lh, int cw, int ch}) planeDims(SweepFormat format, int w, int h) {
  final (sx, sy) = format.chromaShift;
  return (lw: w, lh: h, cw: (w + sx - 1) ~/ sx, ch: (h + sy - 1) ~/ sy);
}

Future<Uint8List> decodeRaw(String path, String pixFmt) async {
  final r = await Process.run(
    WorkerHarness.ffmpegPath,
    ['-hide_banner', '-loglevel', 'error', '-i', path,
     '-f', 'rawvideo', '-pix_fmt', pixFmt, '-'],
    environment: WorkerHarness.ffmpegEnv,
    stdoutEncoding: null,
  );
  if (r.exitCode != 0) throw StateError('raw decode of $path failed: ${r.stderr}');
  return Uint8List.fromList(r.stdout as List<int>);
}

/// [raw] (a planar format, 1 or 2 bytes a sample) as samples.
List<int> samplesOf(Uint8List raw, int bytesPerSample) => bytesPerSample == 1
    ? raw
    : raw.buffer.asUint16List(raw.offsetInBytes, raw.length ~/ 2);

/// Apply [f] to every sample of planar frames laid out as [format] at
/// [w] x [h]: `f(sample, x, y, frame, plane)`.
List<int> mapPlanes(List<int> samples, SweepFormat format, int w, int h,
    int Function(int s, int x, int y, int n, int plane) f) {
  final d = planeDims(format, w, h);
  final out = List<int>.filled(samples.length, 0);
  var i = 0;
  for (var n = 0; i < samples.length; n++) {
    for (var plane = 0; plane < 3; plane++) {
      final pw = plane == 0 ? d.lw : d.cw, ph = plane == 0 ? d.lh : d.ch;
      for (var y = 0; y < ph; y++) {
        for (var x = 0; x < pw; x++, i++) {
          out[i] = f(samples[i], x, y, n, plane);
        }
      }
    }
  }
  return out;
}

Future<String> _makeFixture(SweepRow row) async {
  final f = row.format, size = row.size;
  final eight = await _eightBit(size, f.layout, row.field);
  if (f.depth == 8) return eight;
  final path = p.join(_fixtureDir,
      '${size.width}x${size.height}_${f.name}_${row.field.setfield}.mkv');
  if (File(path).existsSync()) return path;
  final src = samplesOf(await decodeRaw(eight, f.layout), 1);
  final deep = mapPlanes(src, f, size.width, size.height,
      (s, x, y, n, plane) => chainSample(s, f.depth, x, y, n, plane));
  final raw = File('$path.raw');
  await raw.writeAsBytes(Uint16List.fromList(deep).buffer.asUint8List());
  await _writeAtomically(path, (out) => _ffmpeg([
    '-f', 'rawvideo', '-pix_fmt', f.name, '-s', '${size.width}x${size.height}',
    '-r', '$sweepFpsNum/$sweepFpsDen', '-i', raw.path,
    '-vf', 'setfield=${row.field.setfield}',
    '-c:v', 'ffv1', '-pix_fmt', f.name,
    out,
  ], 'fixture ${row.key}'));
  await raw.delete();
  return path;
}

// =============================================================================
// JOBS
// =============================================================================

/// The job for [variant] on [row]: an FFV1 encode with Color Format
/// "original" (so the preview, and any encode, keeps the source's format),
/// and VapourSynth's cache capped — every concurrent vspipe otherwise sizes
/// its cache from the machine's memory, which took a 1.4 s SD preview to
/// 26.5 s at 7 in parallel.
VideoJob sweepJob(ProcessingPipeline pipeline, SweepRow row, String fixture,
    {String? outputPath}) {
  // The app stamps the detected field order on Deinterlace when it builds a
  // job (PreviewGenerator, MainViewModel); QTGMC refuses a job without it.
  pipeline = pipeline.copyWith(
      deinterlace: pipeline.deinterlace
          .copyWith(tff: row.field.fieldOrder == FieldOrder.topFieldFirst));
  return VideoJob(
    id: const Uuid().v4(),
    inputPath: fixture,
    outputPath: outputPath ?? p.join(sweepOutDir, 'unused.mkv'),
    qtgmcParameters: pipeline.deinterlace,
    processingPipeline: pipeline,
    encodingSettings: const EncodingSettings(
      codec: VideoCodec.ffv1,
      container: ContainerFormat.mkv,
      audioMode: AudioMode.none,
      chromaSubsampling: ChromaSubsampling.original,
      maxCacheSizeMb: 512,
    ),
    detectedFieldOrder: row.field.fieldOrder,
    totalFrames: sweepFrames,
    inputFrameRate: sweepFpsNum / sweepFpsDen,
    inputWidth: row.size.width,
    inputHeight: row.size.height,
    inputPixelFormat: row.format.name,
  );
}

/// How many rows run at once: half the cores (VAPOURBOX_SWEEP_JOBS
/// overrides it). Every vspipe is itself multithreaded.
int get sweepJobs =>
    int.tryParse(Platform.environment['VAPOURBOX_SWEEP_JOBS'] ?? '') ??
    (Platform.numberOfProcessors ~/ 2).clamp(1, 64);
