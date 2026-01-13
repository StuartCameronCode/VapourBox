import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/chroma_fix_parameters.dart';
import '../../viewmodels/main_viewmodel.dart';

/// Settings panel for the chroma fix pass.
class ChromaFixSettingsPanel extends StatelessWidget {
  const ChromaFixSettingsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<MainViewModel>(
      builder: (context, viewModel, child) {
        final params = viewModel.restorationPipeline.chromaFixes;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Text(
              'Chroma Fix Settings',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              'Fix chroma bleeding and crawl artifacts',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
            ),
            const SizedBox(height: 16),

            // Preset
            Text('Preset', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            DropdownButtonFormField<ChromaFixPreset>(
              value: params.preset,
              isExpanded: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              items: ChromaFixPreset.values.map((preset) {
                return DropdownMenuItem(
                  value: preset,
                  child: Text(_getPresetDisplayName(preset)),
                );
              }).toList(),
              onChanged: (value) {
                if (value != null) {
                  final newParams = ChromaFixParameters.fromPreset(value);
                  _updateParams(viewModel, newParams);
                }
              },
            ),
            const SizedBox(height: 4),
            Text(
              _getPresetDescription(params.preset),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
            ),

            if (params.enabled) ...[
              const SizedBox(height: 16),

              // Chroma Bleeding Fix
              ExpansionTile(
                title: const Text('Chroma Bleeding Fix'),
                tilePadding: EdgeInsets.zero,
                initiallyExpanded: params.applyChromaBleedingFix,
                children: [
                  SwitchListTile(
                    title: const Text('Enable'),
                    subtitle: const Text('Fix color bleeding at edges'),
                    contentPadding: EdgeInsets.zero,
                    value: params.applyChromaBleedingFix,
                    onChanged: (value) {
                      _updateParams(viewModel, params.copyWith(
                        applyChromaBleedingFix: value,
                        preset: ChromaFixPreset.custom,
                      ));
                    },
                  ),

                  if (params.applyChromaBleedingFix) ...[
                    Text('Blur Strength: ${params.chromaBleedCBlur.toStringAsFixed(1)}',
                        style: Theme.of(context).textTheme.labelLarge),
                    Slider(
                      value: params.chromaBleedCBlur,
                      min: 0.0,
                      max: 1.5,
                      divisions: 15,
                      onChanged: (value) {
                        _updateParams(viewModel, params.copyWith(
                          chromaBleedCBlur: value,
                          preset: ChromaFixPreset.custom,
                        ));
                      },
                    ),

                    Text('Fix Strength: ${params.chromaBleedStrength.toStringAsFixed(1)}',
                        style: Theme.of(context).textTheme.labelLarge),
                    Slider(
                      value: params.chromaBleedStrength,
                      min: 0.0,
                      max: 1.0,
                      divisions: 10,
                      onChanged: (value) {
                        _updateParams(viewModel, params.copyWith(
                          chromaBleedStrength: value,
                          preset: ChromaFixPreset.custom,
                        ));
                      },
                    ),
                  ],
                ],
              ),

              // De-Crawl
              ExpansionTile(
                title: const Text('De-Crawl'),
                tilePadding: EdgeInsets.zero,
                initiallyExpanded: params.applyDeCrawl,
                children: [
                  SwitchListTile(
                    title: const Text('Enable'),
                    subtitle: const Text('Fix dot crawl and chroma crawl'),
                    contentPadding: EdgeInsets.zero,
                    value: params.applyDeCrawl,
                    onChanged: (value) {
                      _updateParams(viewModel, params.copyWith(
                        applyDeCrawl: value,
                        preset: ChromaFixPreset.custom,
                      ));
                    },
                  ),

                  if (params.applyDeCrawl) ...[
                    Text('Luma Threshold: ${params.deCrawlYThresh}',
                        style: Theme.of(context).textTheme.labelLarge),
                    Slider(
                      value: params.deCrawlYThresh.toDouble(),
                      min: 0,
                      max: 50,
                      divisions: 50,
                      onChanged: (value) {
                        _updateParams(viewModel, params.copyWith(
                          deCrawlYThresh: value.round(),
                          preset: ChromaFixPreset.custom,
                        ));
                      },
                    ),

                    Text('Chroma Threshold: ${params.deCrawlCThresh}',
                        style: Theme.of(context).textTheme.labelLarge),
                    Slider(
                      value: params.deCrawlCThresh.toDouble(),
                      min: 0,
                      max: 50,
                      divisions: 50,
                      onChanged: (value) {
                        _updateParams(viewModel, params.copyWith(
                          deCrawlCThresh: value.round(),
                          preset: ChromaFixPreset.custom,
                        ));
                      },
                    ),
                  ],
                ],
              ),

              // Vinverse
              ExpansionTile(
                title: const Text('Vinverse'),
                tilePadding: EdgeInsets.zero,
                initiallyExpanded: params.applyVinverse,
                children: [
                  SwitchListTile(
                    title: const Text('Enable'),
                    subtitle: const Text('Remove residual combing'),
                    contentPadding: EdgeInsets.zero,
                    value: params.applyVinverse,
                    onChanged: (value) {
                      _updateParams(viewModel, params.copyWith(
                        applyVinverse: value,
                        preset: ChromaFixPreset.custom,
                      ));
                    },
                  ),

                  if (params.applyVinverse) ...[
                    Text('Strength: ${params.vinverseSstr.toStringAsFixed(1)}',
                        style: Theme.of(context).textTheme.labelLarge),
                    Slider(
                      value: params.vinverseSstr,
                      min: 1.0,
                      max: 5.0,
                      divisions: 40,
                      onChanged: (value) {
                        _updateParams(viewModel, params.copyWith(
                          vinverseSstr: value,
                          preset: ChromaFixPreset.custom,
                        ));
                      },
                    ),
                  ],
                ],
              ),
            ],
          ],
        );
      },
    );
  }

  String _getPresetDisplayName(ChromaFixPreset preset) {
    switch (preset) {
      case ChromaFixPreset.off:
        return 'Off';
      case ChromaFixPreset.vhsCleanup:
        return 'VHS Cleanup';
      case ChromaFixPreset.broadcastFix:
        return 'Broadcast Fix';
      case ChromaFixPreset.analogRepair:
        return 'Analog Repair';
      case ChromaFixPreset.custom:
        return 'Custom';
    }
  }

  String _getPresetDescription(ChromaFixPreset preset) {
    switch (preset) {
      case ChromaFixPreset.off:
        return 'No chroma fixes applied';
      case ChromaFixPreset.vhsCleanup:
        return 'Fix common VHS chroma issues';
      case ChromaFixPreset.broadcastFix:
        return 'Fix dot crawl from composite sources';
      case ChromaFixPreset.analogRepair:
        return 'Aggressive analog artifact repair';
      case ChromaFixPreset.custom:
        return 'Custom chroma fix settings';
    }
  }

  void _updateParams(MainViewModel viewModel, ChromaFixParameters params) {
    viewModel.updateRestorationPipeline(
      viewModel.restorationPipeline.copyWith(chromaFixes: params),
    );
  }
}
