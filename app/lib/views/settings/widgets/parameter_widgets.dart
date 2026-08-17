import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/filter_schema.dart';
import '../../../viewmodels/main_viewmodel.dart';

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
      case WidgetType.filepicker:
        return _FilePickerParameterWidget(
          paramId: paramId,
          param: param,
          value: value,
          onChanged: onChanged,
        );
    }
  }

  /// Build a widget, wrapping in OptionalParameterWidget if param is optional.
  /// Optional parameters show a checkbox to enable/disable them.
  /// When disabled (value is null), the parameter is not passed to VapourSynth.
  /// [lastValue] is the user's last chosen value, restored when re-enabling.
  static Widget buildOptional({
    required String paramId,
    required ParameterDefinition param,
    required dynamic value,
    required ValueChanged<dynamic> onChanged,
    dynamic lastValue,
  }) {
    if (param.optional == true) {
      return _OptionalParameterWidget(
        paramId: paramId,
        param: param,
        value: value,
        lastValue: lastValue,
        onChanged: onChanged,
      );
    }
    return build(
      paramId: paramId,
      param: param,
      value: value,
      onChanged: onChanged,
    );
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

/// Wrapper widget for optional parameters with enable/disable checkbox.
/// When the checkbox is unchecked, the parameter value is null and
/// will not be passed to VapourSynth.
class _OptionalParameterWidget extends StatelessWidget {
  final String paramId;
  final ParameterDefinition param;
  final dynamic value; // null = disabled
  final dynamic lastValue; // last user-chosen value (for re-enabling)
  final ValueChanged<dynamic> onChanged;

  const _OptionalParameterWidget({
    required this.paramId,
    required this.param,
    required this.value,
    this.lastValue,
    required this.onChanged,
  });

  bool get isEnabled => value != null;

  /// Get a non-null default value for enabling this parameter.
  /// Falls back to a type-appropriate value if defaultValue is null.
  dynamic get _enableValue {
    if (param.defaultValue != null) return param.defaultValue;
    switch (param.type) {
      case ParameterType.boolean:
        return false;
      case ParameterType.integer:
        return param.min?.toInt() ?? 0;
      case ParameterType.number:
        return param.min ?? 0.0;
      case ParameterType.string:
        return '';
      case ParameterType.enumType:
        return param.options?.first ?? '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = param.ui?.label ?? _formatParamName(paramId);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Enable checkbox - use SizedBox to control size but allow tap target
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: SizedBox(
            width: 24,
            height: 24,
            child: Checkbox(
              value: isEnabled,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              onChanged: (checked) {
                if (checked == true) {
                  // Re-enable: restore last user value, or fall back to default
                  onChanged(lastValue ?? _enableValue);
                } else {
                  // Disable (null) — last value preserved by DynamicParameters
                  onChanged(null);
                }
              },
            ),
          ),
        ),
        const SizedBox(width: 8),
        // Parameter widget (dimmed when disabled)
        Expanded(
          child: IgnorePointer(
            ignoring: !isEnabled,
            child: Opacity(
              opacity: isEnabled ? 1.0 : 0.5,
              child: _buildInnerWidget(context, label),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildInnerWidget(BuildContext context, String label) {
    // Use the actual value if enabled, otherwise use fallback for display
    final displayValue = value ?? _enableValue;

    return ParameterWidgetFactory.build(
      paramId: paramId,
      param: param,
      value: displayValue,
      onChanged: onChanged,
    );
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
    final min = param.min ?? 0.0;
    final max = param.max ?? 100.0;
    final doubleValue = (value is num)
        ? value.toDouble()
        : (param.defaultValue is num)
            ? (param.defaultValue as num).toDouble()
            : min;
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
    // Case-insensitive match: find the canonical option that matches the value
    final matchedOption = options.cast<String?>().firstWhere(
      (o) => o?.toLowerCase() == stringValue.toLowerCase(),
      orElse: () => null,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          value: matchedOption ?? options.firstOrNull,
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

    // Check if we have custom labels for true/false - render as dropdown
    final booleanLabels = param.ui?.booleanLabels;
    if (booleanLabels != null) {
      final trueLabel = booleanLabels['true'] ?? 'True';
      final falseLabel = booleanLabels['false'] ?? 'False';

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          DropdownButtonFormField<bool>(
            value: boolValue,
            isExpanded: true,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            items: [
              DropdownMenuItem(value: true, child: Text(trueLabel)),
              DropdownMenuItem(value: false, child: Text(falseLabel)),
            ],
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

    // Default: render as switch
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

/// A path, with a Browse button beside the field.
///
/// Stateful with a controller rather than `TextFormField(initialValue:)` like
/// the plain text field above: `initialValue` is read once, so a path written
/// back by the picker would not appear in the field.
class _FilePickerParameterWidget extends StatefulWidget {
  final String paramId;
  final ParameterDefinition param;
  final dynamic value;
  final ValueChanged<dynamic> onChanged;

  const _FilePickerParameterWidget({
    required this.paramId,
    required this.param,
    required this.value,
    required this.onChanged,
  });

  @override
  State<_FilePickerParameterWidget> createState() =>
      _FilePickerParameterWidgetState();
}

class _FilePickerParameterWidgetState
    extends State<_FilePickerParameterWidget> {
  late final TextEditingController _controller;

  String get _current =>
      widget.value?.toString() ?? widget.param.defaultValue?.toString() ?? '';

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _current);
  }

  @override
  void didUpdateWidget(_FilePickerParameterWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only when it actually differs — assigning unconditionally would move the
    // caret to the end on every keystroke the user types.
    if (_current != _controller.text) {
      _controller.text = _current;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _browse() async {
    final extensions = widget.param.ui?.fileExtensions;
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: widget.param.ui?.label ?? 'Select File',
      type: extensions == null || extensions.isEmpty
          ? FileType.any
          : FileType.custom,
      allowedExtensions:
          extensions == null || extensions.isEmpty ? null : extensions,
    );

    // A cancelled picker returns null; leave whatever is already there.
    final path =
        (result == null || result.files.isEmpty) ? null : result.files.first.path;
    if (path != null) {
      _controller.text = path;
      widget.onChanged(path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.param.ui?.label ?? _formatParamName(widget.paramId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              // Typing or pasting a path still works — the button is an
              // addition, not a replacement.
              child: TextField(
                controller: _controller,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  isDense: true,
                  hintText: widget.param.ui?.description,
                ),
                onChanged: widget.onChanged,
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _browse,
              icon: const Icon(Icons.folder_open, size: 18),
              label: const Text('Browse…'),
            ),
          ],
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

/// Widget for a parameter preset selector.
/// Displays a dropdown that sets one or more parameters when changed.
class PresetSelectorWidget extends StatelessWidget {
  final String presetId;
  final ParameterPreset preset;
  final Map<String, dynamic> currentValues;
  final ValueChanged<Map<String, dynamic>> onChanged;

  const PresetSelectorWidget({
    super.key,
    required this.presetId,
    required this.preset,
    required this.currentValues,
    required this.onChanged,
  });

  /// Find which option matches the current parameter values.
  String? _findCurrentOption() {
    for (final entry in preset.options.entries) {
      final optionName = entry.key;
      final optionValues = entry.value;

      // Check if all values in this option match current values
      bool matches = true;
      for (final paramEntry in optionValues.entries) {
        if (currentValues[paramEntry.key] != paramEntry.value) {
          matches = false;
          break;
        }
      }
      if (matches) return optionName;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final currentOption = _findCurrentOption() ?? preset.defaultOption ?? preset.options.keys.first;
    final options = preset.options.keys.toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(preset.label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          value: options.contains(currentOption) ? currentOption : options.first,
          isExpanded: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
          items: options.map((option) {
            return DropdownMenuItem(
              value: option,
              child: Text(option),
            );
          }).toList(),
          onChanged: (newOption) {
            if (newOption != null) {
              final newValues = preset.options[newOption];
              if (newValues != null) {
                onChanged(newValues);
              }
            }
          },
        ),
        ...[
          const SizedBox(height: 4),
          Text(
            _getDescription(context, currentOption),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                ),
          ),
        ],
      ],
    );
  }

  String _getDescription(BuildContext context, String currentOption) {
    // For outputRate preset, show actual frame rates from the video
    if (presetId == 'outputRate') {
      final viewModel = Provider.of<MainViewModel>(context, listen: false);
      final frameRate = viewModel.selectedItem?.videoInfo?.frameRate;
      if (frameRate != null && frameRate > 0) {
        final fpsDivisor = preset.options[currentOption]?['fpsDivisor'] as num? ?? 1;
        final inputFmt = _formatRate(frameRate);
        final outputFmt = _formatRate(fpsDivisor == 1 ? frameRate * 2 : frameRate);
        return '${inputFmt}i \u2192 ${outputFmt}p';
      }
    }
    return preset.description ?? '';
  }

  String _formatRate(double rate) {
    if (rate == rate.roundToDouble()) return rate.toStringAsFixed(0);
    return rate.toStringAsFixed(2);
  }
}
