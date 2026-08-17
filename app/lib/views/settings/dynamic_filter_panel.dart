import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/dynamic_parameters.dart';
import '../../models/filter_schema.dart';
import '../../services/advanced_mode_service.dart';
import 'widgets/parameter_widgets.dart';

/// A dynamically-generated settings panel based on a filter schema.
///
/// This widget reads a [FilterSchema] definition and generates appropriate
/// UI controls for each parameter, respecting visibility conditions and
/// UI layout preferences.
class DynamicFilterPanel extends StatelessWidget {
  /// The filter schema defining the parameters.
  final FilterSchema schema;

  /// Current parameter values.
  final DynamicParameters params;

  /// Callback when any parameter value changes.
  final ValueChanged<DynamicParameters> onChanged;

  /// Whether to show advanced-only sections.
  final bool showAdvanced;

  const DynamicFilterPanel({
    super.key,
    required this.schema,
    required this.params,
    required this.onChanged,
    this.showAdvanced = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Text(
          '${schema.name} Settings',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        if (schema.description != null) ...[
          const SizedBox(height: 4),
          Text(
            schema.description!,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                ),
          ),
        ],
        const SizedBox(height: 16),

        // Build sections if defined, otherwise build flat list
        if (schema.ui?.sections != null && schema.ui!.sections!.isNotEmpty)
          ..._buildSections(context)
        else
          ..._buildFlatParameters(context),
      ],
    );
  }

  /// Build UI sections from schema.
  List<Widget> _buildSections(BuildContext context) {
    final sections = schema.ui!.sections!;
    final widgets = <Widget>[];

    for (final section in sections) {
      // Skip advanced-only sections if not showing advanced
      if (section.advancedOnly && !showAdvanced) continue;

      // Get visible parameters in this section
      final visibleParams = section.parameters
          .where((paramId) => _isParameterVisible(paramId))
          .toList();

      if (visibleParams.isEmpty) continue;

      widgets.add(_buildSection(context, section, visibleParams));
      widgets.add(const SizedBox(height: 16));
    }

    return widgets;
  }

  /// Build a single section.
  Widget _buildSection(BuildContext context, UiSection section, List<String> visibleParams) {
    return Card(
      margin: EdgeInsets.zero,
      child: ExpansionTile(
        title: Text(
          section.title,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        initiallyExpanded: section.expanded,
        childrenPadding: const EdgeInsets.all(16),
        children: visibleParams.map((paramId) => _buildParameter(context, paramId)).toList(),
      ),
    );
  }

  /// Build flat list of parameters (no sections).
  List<Widget> _buildFlatParameters(BuildContext context) {
    final widgets = <Widget>[];

    // Build parameters in order, respecting visibility
    for (final entry in schema.parameters.entries) {
      final paramId = entry.key;
      final param = entry.value;

      // Skip hidden parameters
      if (param.ui?.hidden == true) continue;

      // Skip invisible parameters
      if (!_isParameterVisible(paramId)) continue;

      widgets.add(_buildParameter(context, paramId));
      widgets.add(const SizedBox(height: 12));
    }

    return widgets;
  }

  /// Build a single parameter widget.
  Widget _buildParameter(BuildContext context, String paramId) {
    final param = schema.parameters[paramId];
    if (param == null) return const SizedBox.shrink();

    // For optional parameters, pass the actual value (may be null = disabled)
    // For non-optional parameters, fall back to default value
    final value = param.optional == true
        ? params.values[paramId]
        : (params.values[paramId] ?? param.defaultValue);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ParameterWidgetFactory.buildOptional(
        paramId: paramId,
        param: param,
        value: value,
        lastValue: param.optional == true ? params.lastOptionalValues[paramId] : null,
        onChanged: (newValue) {
          onChanged(params.withValue(paramId, newValue));
        },
      ),
    );
  }

  /// Check if a parameter should be visible based on visibleWhen conditions.
  bool _isParameterVisible(String paramId) {
    final param = schema.parameters[paramId];
    if (param == null) return false;

    // Check if hidden
    if (param.ui?.hidden == true) return false;

    // Check visibleWhen conditions
    final visibleWhen = param.ui?.visibleWhen;
    if (visibleWhen == null) return true;

    // All conditions must be satisfied (AND logic)
    for (final entry in visibleWhen.entries) {
      final conditionParam = entry.key;
      final expectedValues = entry.value;
      final currentValue = params.values[conditionParam];

      // Handle list of values (OR logic within condition)
      if (expectedValues is List) {
        if (!expectedValues.contains(currentValue)) {
          return false;
        }
      } else {
        // Single value comparison
        if (currentValue != expectedValues) {
          return false;
        }
      }
    }

    return true;
  }
}

/// A variant of DynamicFilterPanel that can be used inside a pass container.
///
/// Advanced mode is read from [AdvancedModeService], not held here: it is one
/// app-wide, persisted choice, so flipping it in any panel affects them all and
/// it survives collapsing the pass. It gates advanced-only sections,
/// preset-controlled parameters and advanced-only *methods*.
class DynamicFilterPanelCompact extends StatelessWidget {
  final FilterSchema schema;
  final DynamicParameters params;
  final ValueChanged<DynamicParameters> onChanged;

  const DynamicFilterPanelCompact({
    super.key,
    required this.schema,
    required this.params,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final advancedMode = context.watch<AdvancedModeService>().enabled;

    // The method the pipeline is actually using, which is always offered even
    // when it's advanced-only.
    final selectedMethod = params.method.isNotEmpty
        ? params.method
        : schema.methods.first.id;
    final visibleMethods = schema.visibleMethods(
      showAdvanced: advancedMode,
      selectedId: selectedMethod,
    );

    final hasMultipleMethods = visibleMethods.length > 1;
    final hasAdvancedContent = _hasAdvancedContent();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Advanced mode toggle (only show if there's advanced content)
        if (hasAdvancedContent) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Tooltip(
                message: 'Show advanced options for every filter',
                child: Text(
                  'Advanced',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 24,
                child: Switch(
                  value: advancedMode,
                  onChanged: (value) =>
                      AdvancedModeService.instance.setEnabled(value),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],

        // Method selection (if multiple methods available)
        if (hasMultipleMethods) ...[
          Text('Method', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: selectedMethod,
            isExpanded: true,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            items: visibleMethods.map((method) {
              return DropdownMenuItem(
                value: method.id,
                child: Text(
                  method.advancedOnly ? '${method.name} (advanced)' : method.name,
                ),
              );
            }).toList(),
            onChanged: (value) {
              if (value != null) {
                onChanged(params.withValue('method', value));
              }
            },
          ),
          // Show method description
          _buildMethodDescription(context),
          const SizedBox(height: 16),
        ],

        // Sits outside the dropdown block on purpose: when simple mode filters
        // a filter down to a single method there is no dropdown to hang this
        // off, and that is precisely when the user most needs telling that more
        // exist.
        if (!advancedMode && schema.hasAdvancedMethods) ...[
          Text(
            'More methods are available in advanced mode.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.5),
                ),
          ),
          const SizedBox(height: 16),
        ],

        // Get parameters for the current method
        ..._buildMethodParameters(context, advancedMode),
      ],
    );
  }

  /// Check if there's any advanced content to show.
  bool _hasAdvancedContent() {
    // Has parameter presets (which would be hidden in advanced mode)
    if (schema.parameterPresets != null && schema.parameterPresets!.isNotEmpty) {
      return true;
    }
    // Has methods that only appear in advanced mode
    if (schema.hasAdvancedMethods) return true;
    // Has advanced-only sections
    final sections = schema.ui?.sections;
    if (sections != null) {
      return sections.any((s) => s.advancedOnly);
    }
    return false;
  }

  /// Get set of parameter IDs that are controlled by presets.
  Set<String> _getPresetControlledParams() {
    final controlled = <String>{};
    final presets = schema.parameterPresets;
    if (presets != null) {
      for (final preset in presets.values) {
        for (final optionValues in preset.options.values) {
          controlled.addAll(optionValues.keys);
        }
      }
    }
    return controlled;
  }

  List<Widget> _buildMethodParameters(BuildContext context, bool advancedMode) {
    final widgets = <Widget>[];
    final presetControlledParams = _getPresetControlledParams();

    // In simple mode, show parameter preset selectors
    // In advanced mode, hide them and show the raw parameters
    if (!advancedMode) {
      final presets = schema.parameterPresets;
      if (presets != null) {
        for (final entry in presets.entries) {
          // Check visibleWhen on preset
          if (!_isPresetVisible(entry.value)) continue;

          widgets.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: PresetSelectorWidget(
                presetId: entry.key,
                preset: entry.value,
                currentValues: params.values,
                onChanged: (newValues) {
                  onChanged(params.withValues(newValues));
                },
              ),
            ),
          );
        }
      }
    }

    // Use UI sections if available, otherwise show all non-hidden parameters
    final sections = schema.ui?.sections;
    if (sections != null && sections.isNotEmpty) {
      for (final section in sections) {
        // In simple mode, skip advanced-only sections
        if (!advancedMode && section.advancedOnly) continue;

        // Collect visible parameter widgets for this section first
        final sectionWidgets = <Widget>[];
        for (final paramId in section.parameters) {
          // In simple mode, skip parameters controlled by presets
          if (!advancedMode && presetControlledParams.contains(paramId)) continue;

          final widget = _buildParameterWidget(context, paramId, showHidden: advancedMode);
          if (widget != null) {
            sectionWidgets.add(widget);
          }
        }

        // Skip sections with no visible parameters
        if (sectionWidgets.isEmpty) continue;

        // In advanced mode with sections, show section headers
        if (advancedMode && section.advancedOnly) {
          widgets.add(
            Padding(
              padding: const EdgeInsets.only(top: 16, bottom: 8),
              child: Text(
                section.title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          );
        }

        widgets.addAll(sectionWidgets);
      }
    } else {
      // No sections defined, show all parameters from method
      final methodId = params.method.isNotEmpty ? params.method : schema.methods.first.id;
      final method = schema.getMethod(methodId) ?? schema.methods.first;

      for (final paramId in method.parameters) {
        // In simple mode, skip parameters controlled by presets
        if (!advancedMode && presetControlledParams.contains(paramId)) continue;

        final widget = _buildParameterWidget(context, paramId, showHidden: advancedMode);
        if (widget != null) {
          widgets.add(widget);
        }
      }
    }

    return widgets;
  }

  Widget? _buildParameterWidget(BuildContext context, String paramId, {bool showHidden = false}) {
    final param = schema.parameters[paramId];
    if (param == null) return null;

    // Always skip structural parameters — these are managed by the panel itself
    if (paramId == 'enabled' || paramId == 'method') return null;

    // Skip hidden parameters (unless showHidden is true)
    if (!showHidden && param.ui?.hidden == true) return null;

    // Check visibility conditions
    if (!_isVisible(paramId)) return null;

    // For optional parameters, pass the actual value (may be null = disabled)
    // For non-optional parameters, fall back to default value
    final value = param.optional == true
        ? params.values[paramId]
        : (params.values[paramId] ?? param.defaultValue);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ParameterWidgetFactory.buildOptional(
        paramId: paramId,
        param: param,
        value: value,
        onChanged: (newValue) {
          onChanged(params.withValue(paramId, newValue));
        },
      ),
    );
  }

  Widget _buildMethodDescription(BuildContext context) {
    if (params.method.isEmpty) return const SizedBox.shrink();

    final selectedMethod = schema.getMethod(params.method);
    if (selectedMethod?.description == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        selectedMethod!.description!,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
            ),
      ),
    );
  }

  bool _isVisible(String paramId) {
    final param = schema.parameters[paramId];
    if (param?.ui?.visibleWhen == null) return true;

    final visibleWhen = param!.ui!.visibleWhen!;
    return _checkVisibleWhen(visibleWhen);
  }

  bool _isPresetVisible(ParameterPreset preset) {
    if (preset.visibleWhen == null) return true;
    return _checkVisibleWhen(preset.visibleWhen!);
  }

  bool _checkVisibleWhen(Map<String, dynamic> visibleWhen) {
    for (final entry in visibleWhen.entries) {
      final expected = entry.value;
      final current = params.values[entry.key];

      if (expected is List) {
        if (!expected.contains(current)) return false;
      } else if (current != expected) {
        return false;
      }
    }

    return true;
  }
}
