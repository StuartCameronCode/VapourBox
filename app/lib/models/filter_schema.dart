import 'package:json_annotation/json_annotation.dart';

part 'filter_schema.g.dart';

/// Type of parameter value.
enum ParameterType {
  @JsonValue('boolean')
  boolean,
  @JsonValue('integer')
  integer,
  @JsonValue('number')
  number,
  @JsonValue('string')
  string,
  @JsonValue('enum')
  enumType,
}

/// Type of UI widget to render for a parameter.
enum WidgetType {
  @JsonValue('slider')
  slider,
  @JsonValue('dropdown')
  dropdown,
  @JsonValue('checkbox')
  checkbox,
  @JsonValue('textfield')
  textfield,
  @JsonValue('number')
  number,

  /// A path, with a Browse button beside the field. Never inferred — a string
  /// parameter still defaults to [textfield], so a schema opts in explicitly.
  @JsonValue('filepicker')
  filepicker,
}

/// VapourSynth-specific parameter configuration.
@JsonSerializable()
class VapourSynthConfig {
  /// The parameter name in VapourSynth (may differ from schema name).
  final String name;

  const VapourSynthConfig({required this.name});

  factory VapourSynthConfig.fromJson(Map<String, dynamic> json) =>
      _$VapourSynthConfigFromJson(json);
  Map<String, dynamic> toJson() => _$VapourSynthConfigToJson(this);
}

/// UI configuration for a parameter.
@JsonSerializable()
class ParameterUiConfig {
  /// Display label for the parameter.
  final String? label;

  /// Description/tooltip for the parameter.
  final String? description;

  /// Type of widget to render.
  final WidgetType? widget;

  /// Decimal precision for number display.
  final int? precision;

  /// Whether this parameter is hidden from the UI.
  final bool? hidden;

  /// Condition for when this parameter is visible.
  /// Keys are parameter names, values are the required values (or list of values).
  final Map<String, dynamic>? visibleWhen;

  /// Custom labels for boolean values (renders as dropdown instead of toggle).
  /// Example: {"true": "Top Field First", "false": "Bottom Field First"}
  final Map<String, String>? booleanLabels;

  /// Extensions the file picker offers, without dots — `["srt", "ass"]`.
  /// Only meaningful for [WidgetType.filepicker]; null means any file.
  final List<String>? fileExtensions;

  const ParameterUiConfig({
    this.label,
    this.description,
    this.widget,
    this.precision,
    this.hidden,
    this.visibleWhen,
    this.booleanLabels,
    this.fileExtensions,
  });

  factory ParameterUiConfig.fromJson(Map<String, dynamic> json) =>
      _$ParameterUiConfigFromJson(json);
  Map<String, dynamic> toJson() => _$ParameterUiConfigToJson(this);
}

/// Definition of a single parameter.
@JsonSerializable()
class ParameterDefinition {
  /// Type of this parameter.
  final ParameterType type;

  /// Default value (type depends on [type]).
  @JsonKey(name: 'default')
  final dynamic defaultValue;

  /// Minimum value (for number/integer types).
  final double? min;

  /// Maximum value (for number/integer types).
  final double? max;

  /// Step size for sliders (for number/integer types).
  final double? step;

  /// Available options (for enum type).
  final List<String>? options;

  /// VapourSynth-specific configuration.
  final VapourSynthConfig? vapoursynth;

  /// UI configuration.
  final ParameterUiConfig? ui;

  /// Whether this parameter can be enabled/disabled with a checkbox.
  /// When disabled (null value), the parameter is not passed to VapourSynth.
  final bool? optional;

  const ParameterDefinition({
    required this.type,
    required this.defaultValue,
    this.min,
    this.max,
    this.step,
    this.options,
    this.vapoursynth,
    this.ui,
    this.optional,
  });

  /// Get the VapourSynth parameter name (falls back to schema name if not specified).
  String getVsName(String schemaName) => vapoursynth?.name ?? schemaName;

  /// Check if value is within valid range.
  bool isValidValue(dynamic value) {
    if (value == null) return true;

    switch (type) {
      case ParameterType.boolean:
        return value is bool;
      case ParameterType.integer:
        if (value is! int) return false;
        if (min != null && value < min!) return false;
        if (max != null && value > max!) return false;
        return true;
      case ParameterType.number:
        if (value is! num) return false;
        if (min != null && value < min!) return false;
        if (max != null && value > max!) return false;
        return true;
      case ParameterType.string:
        return value is String;
      case ParameterType.enumType:
        return value is String && (options?.contains(value) ?? true);
    }
  }

  factory ParameterDefinition.fromJson(Map<String, dynamic> json) =>
      _$ParameterDefinitionFromJson(json);
  Map<String, dynamic> toJson() => _$ParameterDefinitionToJson(this);
}

/// Definition of a filter method (e.g., DeHalo_alpha, YAHR).
@JsonSerializable()
class MethodDefinition {
  /// Unique identifier for this method.
  final String id;

  /// Display name.
  final String name;

  /// Description of what this method does.
  final String? description;

  /// VapourSynth function to call (e.g., "haf.DeHalo_alpha").
  final String function;

  /// List of parameter IDs that this method uses.
  final List<String> parameters;

  /// Whether this method only appears in advanced mode.
  ///
  /// Lets one filter offer a short, curated method list to everyone and the
  /// full set to someone who has asked for it — the mechanism that keeps a
  /// "Noise Reduction" row from becoming a dropdown of sixteen names. A method
  /// the user has actually selected is always shown regardless, so a preset or
  /// saved job never silently loses its method; see
  /// [FilterSchema.visibleMethods].
  final bool advancedOnly;

  const MethodDefinition({
    required this.id,
    required this.name,
    this.description,
    required this.function,
    required this.parameters,
    this.advancedOnly = false,
  });

  factory MethodDefinition.fromJson(Map<String, dynamic> json) =>
      _$MethodDefinitionFromJson(json);
  Map<String, dynamic> toJson() => _$MethodDefinitionToJson(this);
}

/// One VapourSynth call a filter makes, for the "what is this actually doing"
/// readout in advanced mode.
///
/// Most filters need none of this: a method already names its own [function],
/// and the readout uses that. This exists for the passes that are not a single
/// call — Colour Correction alone can invoke six different things depending on
/// which of its switches are on — where naming one function would be a lie and
/// naming none is what prompted the request.
///
/// [activeWhen] is evaluated against the filter's current parameter values with
/// exactly the same matcher as `visibleWhen`, so the readout can distinguish
/// what is running now from what the pass is merely capable of. An entry with
/// no condition is always active.
@JsonSerializable()
class ImplementationEntry {
  /// The call as it appears in the generated script, e.g. `core.retinex.MSRCP`.
  final String function;

  /// What this call contributes, in the user's vocabulary rather than the
  /// plugin's — "shadow detail", not "multi-scale retinex".
  final String? role;

  /// Condition under which this call is actually made. Null means always.
  final Map<String, dynamic>? activeWhen;

  const ImplementationEntry({
    required this.function,
    this.role,
    this.activeWhen,
  });

  factory ImplementationEntry.fromJson(Map<String, dynamic> json) =>
      _$ImplementationEntryFromJson(json);
  Map<String, dynamic> toJson() => _$ImplementationEntryToJson(this);
}

/// UI section grouping parameters together.
@JsonSerializable()
class UiSection {
  /// Section title.
  final String title;

  /// Parameter IDs in this section.
  final List<String> parameters;

  /// Whether the section is expanded by default.
  final bool expanded;

  /// Whether this section only appears in advanced mode.
  final bool advancedOnly;

  const UiSection({
    required this.title,
    required this.parameters,
    this.expanded = true,
    this.advancedOnly = false,
  });

  factory UiSection.fromJson(Map<String, dynamic> json) =>
      _$UiSectionFromJson(json);
  Map<String, dynamic> toJson() => _$UiSectionToJson(this);
}

/// UI layout configuration.
@JsonSerializable()
class UiLayout {
  /// Sections to organize parameters.
  final List<UiSection>? sections;

  const UiLayout({this.sections});

  factory UiLayout.fromJson(Map<String, dynamic> json) =>
      _$UiLayoutFromJson(json);
  Map<String, dynamic> toJson() => _$UiLayoutToJson(this);
}

/// Dependencies required by a filter.
@JsonSerializable()
class FilterDependencies {
  /// Python packages required (e.g., ["havsfunc", "mvsfunc"]).
  final List<String>? plugins;

  /// VapourSynth plugins required (e.g., ["libmvtools.dll"]).
  @JsonKey(name: 'vs_plugins')
  final List<String>? vsPlugins;

  /// Optional plugins that enable additional features.
  final List<String>? optional;

  const FilterDependencies({
    this.plugins,
    this.vsPlugins,
    this.optional,
  });

  factory FilterDependencies.fromJson(Map<String, dynamic> json) =>
      _$FilterDependenciesFromJson(json);
  Map<String, dynamic> toJson() => _$FilterDependenciesToJson(this);
}

/// A parameter preset group - a dropdown that sets one or more parameters.
@JsonSerializable()
class ParameterPreset {
  /// Display label for the preset selector.
  final String label;

  /// Optional description.
  final String? description;

  /// Default option key.
  @JsonKey(name: 'default')
  final String? defaultOption;

  /// Map of option display name to parameter values to apply.
  final Map<String, Map<String, dynamic>> options;

  /// Condition for when this preset is visible.
  final Map<String, dynamic>? visibleWhen;

  const ParameterPreset({
    required this.label,
    this.description,
    this.defaultOption,
    required this.options,
    this.visibleWhen,
  });

  factory ParameterPreset.fromJson(Map<String, dynamic> json) =>
      _$ParameterPresetFromJson(json);
  Map<String, dynamic> toJson() => _$ParameterPresetToJson(this);
}

/// Code generation configuration.
@JsonSerializable()
class CodeTemplate {
  /// Import statements needed.
  final List<String>? imports;

  /// How to generate code: "method" (use method.function) or custom template.
  final String? generate;

  /// Custom code body template (if generate != "method").
  final String? body;

  const CodeTemplate({
    this.imports,
    this.generate,
    this.body,
  });

  factory CodeTemplate.fromJson(Map<String, dynamic> json) =>
      _$CodeTemplateFromJson(json);
  Map<String, dynamic> toJson() => _$CodeTemplateToJson(this);
}

/// Preset configuration for filters with predefined parameter sets.
@JsonSerializable()
class PresetDefinition {
  /// Preset name.
  final String name;

  /// Parameter values for this preset.
  final Map<String, dynamic> values;

  const PresetDefinition({
    required this.name,
    required this.values,
  });

  factory PresetDefinition.fromJson(Map<String, dynamic> json) =>
      _$PresetDefinitionFromJson(json);
  Map<String, dynamic> toJson() => _$PresetDefinitionToJson(this);
}

/// Complete filter schema definition.
@JsonSerializable()
class FilterSchema {
  /// JSON Schema reference (optional).
  @JsonKey(name: r'$schema')
  final String? schema;

  /// Unique identifier for this filter.
  final String id;

  /// Schema version.
  final String version;

  /// Display name.
  final String name;

  /// Short one-line description of what this filter does.
  final String? description;

  /// Longer prose shown above the filter's options: what the filter does and
  /// when you'd reach for it. Paragraphs are separated by a blank line.
  /// Falls back to [description] in the UI when absent.
  final String? longDescription;

  /// Category for grouping (e.g., "cleanup", "enhancement").
  final String? category;

  /// Icon name (Material icon).
  final String? icon;

  /// Sort order in filter list.
  final int order;

  /// Highest per-component bit depth this filter processes natively. When set
  /// and the source exceeds it, the worker down-converts to this depth for the
  /// pass (a lossy round-trip), so the UI warns of reduced precision. Null (the
  /// default) means the filter handles the source's bit depth without loss.
  final int? maxBitDepth;

  /// Dependencies required by this filter.
  final FilterDependencies? dependencies;

  /// Available methods for this filter.
  final List<MethodDefinition> methods;

  /// Parameter definitions.
  final Map<String, ParameterDefinition> parameters;

  /// Parameter preset selectors - dropdowns that set one or more parameters.
  final Map<String, ParameterPreset>? parameterPresets;

  /// Preset configurations (for QTGMC-style quality presets).
  final Map<String, Map<String, dynamic>>? presets;

  /// UI layout configuration.
  final UiLayout? ui;

  /// Code generation configuration.
  final CodeTemplate? codeTemplate;

  /// The VapourSynth calls this filter makes, when it is not simply the
  /// selected method's own `function`. Declared only by the composite passes —
  /// see [ImplementationEntry].
  final List<ImplementationEntry>? implementation;

  /// Source of this schema: "builtin", "user", "community".
  @JsonKey(includeFromJson: false, includeToJson: false)
  String source;

  FilterSchema({
    this.schema,
    required this.id,
    required this.version,
    required this.name,
    this.description,
    this.longDescription,
    this.category,
    this.icon,
    this.order = 0,
    this.maxBitDepth,
    this.dependencies,
    required this.methods,
    required this.parameters,
    this.parameterPresets,
    this.presets,
    this.ui,
    this.codeTemplate,
    this.implementation,
    this.source = 'builtin',
  });

  /// Get the default method.
  MethodDefinition get defaultMethod => methods.first;

  /// Get a method by ID.
  MethodDefinition? getMethod(String id) {
    try {
      return methods.firstWhere((m) => m.id == id);
    } catch (_) {
      return null;
    }
  }

  /// The methods to offer in the UI.
  ///
  /// In simple mode ([showAdvanced] false) advanced-only methods are dropped —
  /// except [selectedId], which is always kept. Hiding a value the user has
  /// already chosen would both lie about what the pipeline is doing and, in a
  /// dropdown, crash on a value that isn't among its items.
  ///
  /// Order is preserved, so the schema decides what a regular user sees first.
  List<MethodDefinition> visibleMethods({
    required bool showAdvanced,
    String? selectedId,
  }) {
    if (showAdvanced) return methods;
    return methods
        .where((m) => !m.advancedOnly || m.id == selectedId)
        .toList();
  }

  /// Whether any method is advanced-only, so the UI knows there is more to
  /// reveal even when every parameter is basic.
  bool get hasAdvancedMethods => methods.any((m) => m.advancedOnly);

  /// Get default values for all parameters.
  /// Optional parameters are excluded (they start as null/disabled).
  Map<String, dynamic> getDefaults() {
    final defaults = <String, dynamic>{};
    for (final entry in parameters.entries) {
      // Skip optional parameters - they start as disabled (null)
      if (entry.value.optional == true) continue;
      defaults[entry.key] = entry.value.defaultValue;
    }
    return defaults;
  }

  /// Validate parameter values against schema.
  List<String> validate(Map<String, dynamic> values) {
    final errors = <String>[];
    for (final entry in values.entries) {
      final param = parameters[entry.key];
      if (param == null) {
        errors.add('Unknown parameter: ${entry.key}');
        continue;
      }
      if (!param.isValidValue(entry.value)) {
        errors.add('Invalid value for ${entry.key}: ${entry.value}');
      }
    }
    return errors;
  }

  factory FilterSchema.fromJson(Map<String, dynamic> json) =>
      _$FilterSchemaFromJson(json);
  Map<String, dynamic> toJson() => _$FilterSchemaToJson(this);
}
