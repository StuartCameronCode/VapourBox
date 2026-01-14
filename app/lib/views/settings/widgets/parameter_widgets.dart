import 'package:flutter/material.dart';

import '../../../models/filter_schema.dart';

/// Factory for creating parameter widgets based on schema definition.
class ParameterWidgetFactory {
  /// Build a widget for the given parameter definition.
  static Widget build({
    required String paramId,
    required ParameterDefinition param,
    required dynamic value,
    required ValueChanged<dynamic> onChanged,
  }) {
    final widgetType = param.ui?.widget ?? _inferWidgetType(param);

    switch (widgetType) {
      case WidgetType.slider:
        return _SliderParameterWidget(
          paramId: paramId,
          param: param,
          value: value,
          onChanged: onChanged,
        );
      case WidgetType.dropdown:
        return _DropdownParameterWidget(
          paramId: paramId,
          param: param,
          value: value,
          onChanged: onChanged,
        );
      case WidgetType.checkbox:
        return _CheckboxParameterWidget(
          paramId: paramId,
          param: param,
          value: value,
          onChanged: onChanged,
        );
      case WidgetType.textfield:
        return _TextFieldParameterWidget(
          paramId: paramId,
          param: param,
          value: value,
          onChanged: onChanged,
        );
      case WidgetType.number:
        return _NumberParameterWidget(
          paramId: paramId,
          param: param,
          value: value,
          onChanged: onChanged,
        );
    }
  }

  /// Infer widget type from parameter type if not specified.
  static WidgetType _inferWidgetType(ParameterDefinition param) {
    switch (param.type) {
      case ParameterType.boolean:
        return WidgetType.checkbox;
      case ParameterType.enumType:
        return WidgetType.dropdown;
      case ParameterType.integer:
      case ParameterType.number:
        if (param.min != null && param.max != null) {
          return WidgetType.slider;
        }
        return WidgetType.number;
      case ParameterType.string:
        return WidgetType.textfield;
    }
  }
}

/// Slider widget for numeric parameters with range.
class _SliderParameterWidget extends StatelessWidget {
  final String paramId;
  final ParameterDefinition param;
  final dynamic value;
  final ValueChanged<dynamic> onChanged;

  const _SliderParameterWidget({
    required this.paramId,
    required this.param,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final doubleValue = (value is num) ? value.toDouble() : (param.defaultValue as num).toDouble();
    final min = param.min ?? 0.0;
    final max = param.max ?? 100.0;
    final step = param.step ?? 1.0;
    final precision = param.ui?.precision ?? (param.type == ParameterType.integer ? 0 : 1);
    final divisions = ((max - min) / step).round();

    final label = param.ui?.label ?? _formatParamName(paramId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label: ${doubleValue.toStringAsFixed(precision)}',
          style: Theme.of(context).textTheme.labelLarge,
        ),
        Slider(
          value: doubleValue.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions > 0 ? divisions : null,
          onChanged: (newValue) {
            if (param.type == ParameterType.integer) {
              onChanged(newValue.round());
            } else {
              onChanged(newValue);
            }
          },
        ),
        if (param.ui?.description != null)
          Text(
            param.ui!.description!,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                ),
          ),
      ],
    );
  }
}

/// Dropdown widget for enum parameters.
class _DropdownParameterWidget extends StatelessWidget {
  final String paramId;
  final ParameterDefinition param;
  final dynamic value;
  final ValueChanged<dynamic> onChanged;

  const _DropdownParameterWidget({
    required this.paramId,
    required this.param,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final options = param.options ?? [];
    final stringValue = value?.toString() ?? param.defaultValue?.toString() ?? '';
    final label = param.ui?.label ?? _formatParamName(paramId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          value: options.contains(stringValue) ? stringValue : options.firstOrNull,
          isExpanded: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
          items: options.map((option) {
            return DropdownMenuItem(
              value: option,
              child: Text(_formatOptionName(option)),
            );
          }).toList(),
          onChanged: (newValue) {
            if (newValue != null) {
              onChanged(newValue);
            }
          },
        ),
        if (param.ui?.description != null) ...[
          const SizedBox(height: 4),
          Text(
            param.ui!.description!,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                ),
          ),
        ],
      ],
    );
  }
}

/// Checkbox/switch widget for boolean parameters.
class _CheckboxParameterWidget extends StatelessWidget {
  final String paramId;
  final ParameterDefinition param;
  final dynamic value;
  final ValueChanged<dynamic> onChanged;

  const _CheckboxParameterWidget({
    required this.paramId,
    required this.param,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final boolValue = value is bool ? value : (param.defaultValue as bool? ?? false);
    final label = param.ui?.label ?? _formatParamName(paramId);

    return SwitchListTile(
      title: Text(label),
      subtitle: param.ui?.description != null ? Text(param.ui!.description!) : null,
      value: boolValue,
      contentPadding: EdgeInsets.zero,
      onChanged: (newValue) => onChanged(newValue),
    );
  }
}

/// Text field widget for string parameters.
class _TextFieldParameterWidget extends StatelessWidget {
  final String paramId;
  final ParameterDefinition param;
  final dynamic value;
  final ValueChanged<dynamic> onChanged;

  const _TextFieldParameterWidget({
    required this.paramId,
    required this.param,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final stringValue = value?.toString() ?? param.defaultValue?.toString() ?? '';
    final label = param.ui?.label ?? _formatParamName(paramId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        TextFormField(
          initialValue: stringValue,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            hintText: param.ui?.description,
          ),
          onChanged: onChanged,
        ),
      ],
    );
  }
}

/// Number input widget for numeric parameters without range.
class _NumberParameterWidget extends StatelessWidget {
  final String paramId;
  final ParameterDefinition param;
  final dynamic value;
  final ValueChanged<dynamic> onChanged;

  const _NumberParameterWidget({
    required this.paramId,
    required this.param,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final numValue = value is num ? value : (param.defaultValue as num? ?? 0);
    final label = param.ui?.label ?? _formatParamName(paramId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        TextFormField(
          initialValue: numValue.toString(),
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            hintText: param.ui?.description,
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (text) {
            if (param.type == ParameterType.integer) {
              final parsed = int.tryParse(text);
              if (parsed != null) {
                onChanged(parsed);
              }
            } else {
              final parsed = double.tryParse(text);
              if (parsed != null) {
                onChanged(parsed);
              }
            }
          },
        ),
      ],
    );
  }
}

/// Format a parameter ID to a human-readable name.
String _formatParamName(String paramId) {
  // Convert camelCase or snake_case to Title Case
  return paramId
      .replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .replaceAll('_', ' ')
      .split(' ')
      .map((word) => word.isNotEmpty ? '${word[0].toUpperCase()}${word.substring(1)}' : '')
      .join(' ');
}

/// Format an option value to a human-readable name.
String _formatOptionName(String option) {
  // Convert snake_case to Title Case
  return option
      .replaceAll('_', ' ')
      .split(' ')
      .map((word) => word.isNotEmpty ? '${word[0].toUpperCase()}${word.substring(1).toLowerCase()}' : '')
      .join(' ');
}
