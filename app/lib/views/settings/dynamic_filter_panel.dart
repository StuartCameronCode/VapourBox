import 'package:flutter/material.dart';

import '../../models/dynamic_parameters.dart';
import '../../models/filter_schema.dart';
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

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ParameterWidgetFactory.build(
        paramId: paramId,
        param: param,
        value: params.values[paramId] ?? param.defaultValue,
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
    // Build method dropdown first if the filter has methods
    final hasMultipleMethods = schema.methods.length > 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Method selection (if multiple methods available)
        if (hasMultipleMethods) ...[
          Text('Method', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: params.method.isNotEmpty ? params.method : schema.methods.first.id,
            isExpanded: true,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            items: schema.methods.map((method) {
              return DropdownMenuItem(
                value: method.id,
                child: Text(method.name),
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

        // Get parameters for the current method
        ..._buildMethodParameters(context),
      ],
    );
  }

  List<Widget> _buildMethodParameters(BuildContext context) {
    final methodId = params.method.isNotEmpty ? params.method : schema.methods.first.id;
    final method = schema.getMethod(methodId) ?? schema.methods.first;

    final widgets = <Widget>[];

    for (final paramId in method.parameters) {
      final param = schema.parameters[paramId];
      if (param == null) continue;

      // Skip hidden parameters
      if (param.ui?.hidden == true) continue;

      // Check visibility conditions
      if (!_isVisible(paramId)) continue;

      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: ParameterWidgetFactory.build(
            paramId: paramId,
            param: param,
            value: params.values[paramId] ?? param.defaultValue,
            onChanged: (newValue) {
              onChanged(params.withValue(paramId, newValue));
            },
          ),
        ),
      );
    }

    return widgets;
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
