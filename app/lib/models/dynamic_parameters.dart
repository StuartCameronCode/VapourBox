import 'package:json_annotation/json_annotation.dart';

import 'filter_schema.dart';

part 'dynamic_parameters.g.dart';

/// Dynamic parameter container for schema-based filters.
///
/// Holds parameter values at runtime with validation against the schema.
@JsonSerializable()
class DynamicParameters {
  /// The filter ID this belongs to.
  final String filterId;

  /// Whether this filter pass is enabled.
  final bool enabled;

  /// Parameter values (key is parameter ID, value is the parameter value).
  final Map<String, dynamic> values;

  const DynamicParameters({
    required this.filterId,
    this.enabled = false,
    this.values = const {},
  });

  /// Create with default values from a schema.
  factory DynamicParameters.fromSchema(FilterSchema schema, {bool enabled = false}) {
    return DynamicParameters(
      filterId: schema.id,
      enabled: enabled,
      values: schema.getDefaults(),
    );
  }

  /// Get a parameter value with type casting.
  T? get<T>(String key) {
    final value = values[key];
    if (value == null) return null;
    if (value is T) return value;

    // Handle type coercion
    if (T == int && value is num) return value.toInt() as T;
    if (T == double && value is num) return value.toDouble() as T;
    if (T == bool && value is bool) return value as T;
    if (T == String && value is String) return value as T;

    return null;
  }

  /// Get a boolean parameter.
  bool getBool(String key, {bool defaultValue = false}) {
    return get<bool>(key) ?? defaultValue;
  }

  /// Get an integer parameter.
  int getInt(String key, {int defaultValue = 0}) {
    final value = values[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    return defaultValue;
  }

  /// Get a double parameter.
  double getDouble(String key, {double defaultValue = 0.0}) {
    final value = values[key];
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return defaultValue;
  }

  /// Get a string parameter.
  String getString(String key, {String defaultValue = ''}) {
    return get<String>(key) ?? defaultValue;
  }

  /// Get the currently selected method ID.
  String get method => getString('method');

  /// Create a copy with updated enabled state.
  DynamicParameters withEnabled(bool enabled) {
    return DynamicParameters(
      filterId: filterId,
      enabled: enabled,
      values: values,
    );
  }

  /// Create a copy with a single parameter updated.
  DynamicParameters withValue(String key, dynamic value) {
    return DynamicParameters(
      filterId: filterId,
      enabled: enabled,
      values: {...values, key: value},
    );
  }

  /// Create a copy with multiple parameters updated.
  DynamicParameters withValues(Map<String, dynamic> newValues) {
    return DynamicParameters(
      filterId: filterId,
      enabled: enabled,
      values: {...values, ...newValues},
    );
  }

  /// Validate values against a schema.
  List<String> validate(FilterSchema schema) {
    return schema.validate(values);
  }

  /// Get a summary string for display.
  String getSummary(FilterSchema schema) {
    if (!enabled) return 'Off';

    final methodDef = schema.getMethod(method);
    if (methodDef != null) {
      return methodDef.name;
    }
    return schema.name;
  }

  factory DynamicParameters.fromJson(Map<String, dynamic> json) =>
      _$DynamicParametersFromJson(json);
  Map<String, dynamic> toJson() => _$DynamicParametersToJson(this);
}

/// Container for all dynamic filter parameters in a pipeline.
@JsonSerializable(explicitToJson: true)
class DynamicPipeline {
  /// Map of filter ID to parameters.
  final Map<String, DynamicParameters> filters;

  const DynamicPipeline({this.filters = const {}});

  /// Get parameters for a specific filter.
  DynamicParameters? get(String filterId) => filters[filterId];

  /// Check if a filter is enabled.
  bool isEnabled(String filterId) => filters[filterId]?.enabled ?? false;

  /// Get list of enabled filter IDs in order.
  List<String> get enabledFilterIds =>
      filters.entries
          .where((e) => e.value.enabled)
          .map((e) => e.key)
          .toList();

  /// Create a copy with updated parameters for a filter.
  DynamicPipeline withFilter(String filterId, DynamicParameters params) {
    return DynamicPipeline(
      filters: {...filters, filterId: params},
    );
  }

  /// Create a copy with a filter's enabled state toggled.
  DynamicPipeline withFilterEnabled(String filterId, bool enabled) {
    final existing = filters[filterId];
    if (existing == null) return this;

    return DynamicPipeline(
      filters: {...filters, filterId: existing.withEnabled(enabled)},
    );
  }

  factory DynamicPipeline.fromJson(Map<String, dynamic> json) =>
      _$DynamicPipelineFromJson(json);
  Map<String, dynamic> toJson() => _$DynamicPipelineToJson(this);
}
