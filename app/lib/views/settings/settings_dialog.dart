import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/encoding_settings.dart';
import '../../models/video_job.dart';
import '../../services/dependency_manager.dart';
import '../../services/hardware_encoder_detector.dart';
import '../../services/update_checker.dart';
import '../../viewmodels/main_viewmodel.dart';

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key});

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: 600,
          maxHeight: 700,
        ),
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color:
                        Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
                  ),
                ),
              ),
              child: Row(
                children: [
                  Text(
                    'Settings',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            // Tab bar
            TabBar(
              controller: _tabController,
              tabs: const [
                Tab(text: 'Input'),
                Tab(text: 'Output'),
                Tab(text: 'General'),
              ],
            ),

            // Tab content
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: const [
                  _InputSettingsTab(),
                  _OutputSettingsTab(),
                  _GeneralSettingsTab(),
                ],
              ),
            ),

            // Footer
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color:
                        Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
                  ),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InputSettingsTab extends StatelessWidget {
  const _InputSettingsTab();

  @override
  Widget build(BuildContext context) {
    return Consumer<MainViewModel>(
      builder: (context, viewModel, child) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Field Order
            _buildSection(
              context,
              title: 'Field Order',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    title: const Text('Auto-detect field order'),
                    subtitle: const Text('Use detected field order from video'),
                    value: viewModel.autoFieldOrder,
                    onChanged: (value) {
                      viewModel.setAutoFieldOrder(value);
                    },
                  ),
                  if (!viewModel.autoFieldOrder) ...[
                    const SizedBox(height: 8),
                    SegmentedButton<FieldOrder>(
                      segments: const [
                        ButtonSegment(
                          value: FieldOrder.topFieldFirst,
                          label: Text('TFF (Top Field First)'),
                        ),
                        ButtonSegment(
                          value: FieldOrder.bottomFieldFirst,
                          label: Text('BFF (Bottom Field First)'),
                        ),
                      ],
                      selected: {viewModel.manualFieldOrder},
                      onSelectionChanged: (value) {
                        viewModel.setManualFieldOrder(value.first);
                      },
                    ),
                  ],
                  if (viewModel.videoInfo?.fieldOrder != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Detected: ${viewModel.videoInfo!.fieldOrderDescription}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                          ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSection(
    BuildContext context, {
    required String title,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: 12),
        child,
      ],
    );
  }
}

class _OutputSettingsTab extends StatefulWidget {
  const _OutputSettingsTab();

  @override
  State<_OutputSettingsTab> createState() => _OutputSettingsTabState();
}

class _OutputSettingsTabState extends State<_OutputSettingsTab> {
  late TextEditingController _filenamePatternController;
  late TextEditingController _customFfmpegArgsController;

  // Intel-Mac VideoToolbox uses a native target-bitrate control (no -q:v mode).
  final TextEditingController _vtBitrateController = TextEditingController();
  final FocusNode _vtBitrateFocus = FocusNode();
  late final bool _isIntelMac;

  /// Default target bitrate (kbps) applied when an Intel-VT codec is selected.
  static const int _kDefaultVtBitrateKbps = 20000;

  /// Bitrate preset shortcuts (label -> Mb/s) for Intel VideoToolbox.
  static const Map<String, int> _kVtBitratePresetsMbps = {
    'Low': 5,
    'Medium': 10,
    'High': 20,
    'Very High': 40,
  };

  @override
  void initState() {
    super.initState();
    _filenamePatternController = TextEditingController();
    _customFfmpegArgsController = TextEditingController();
    _isIntelMac = Platform.isMacOS &&
        DependencyManager.instance.platformId == 'macos-x64';
    // Kick off (idempotent) encoder detection and rebuild as probes resolve so
    // the codec list can show/clear a busy indicator per encoder live.
    HardwareEncoderDetector.instance.addListener(_onEncoderDetectionChanged);
    HardwareEncoderDetector.instance.initialize();
  }

  void _onEncoderDetectionChanged() {
    if (mounted) setState(() {});
  }

  /// Whether the codec is a VideoToolbox (macOS hardware) encoder.
  bool _isVideotoolbox(VideoCodec codec) =>
      codec == VideoCodec.h264Videotoolbox ||
      codec == VideoCodec.h265Videotoolbox;

  @override
  void dispose() {
    HardwareEncoderDetector.instance.removeListener(_onEncoderDetectionChanged);
    _filenamePatternController.dispose();
    _customFfmpegArgsController.dispose();
    _vtBitrateController.dispose();
    _vtBitrateFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<MainViewModel>(
      builder: (context, viewModel, child) {
        final settings = viewModel.encodingSettings;

        // Update controllers if values changed externally
        if (_filenamePatternController.text != settings.filenamePattern) {
          _filenamePatternController.text = settings.filenamePattern;
        }
        if (_customFfmpegArgsController.text != settings.customFfmpegArgs) {
          _customFfmpegArgsController.text = settings.customFfmpegArgs;
        }

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Output Directory
            _buildSection(
              context,
              title: 'Output Directory',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            settings.outputDirectory ?? 'Same as input file',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  fontFamily: 'monospace',
                                  fontStyle: settings.outputDirectory == null
                                      ? FontStyle.italic
                                      : FontStyle.normal,
                                ),
                          ),
                        ),
                        if (settings.outputDirectory != null)
                          IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              viewModel.updateEncodingSettings(
                                settings.copyWith(clearOutputDirectory: true),
                              );
                            },
                            tooltip: 'Use same directory as input',
                          ),
                        IconButton(
                          icon: const Icon(Icons.folder_open),
                          onPressed: () => _selectOutputDirectory(viewModel, settings),
                          tooltip: 'Choose directory',
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // Filename Pattern
            _buildSection(
              context,
              title: 'Output Filename Pattern',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _filenamePatternController,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: '{input_filename}_processed',
                    ),
                    onChanged: (value) {
                      if (value.isNotEmpty) {
                        viewModel.updateEncodingSettings(
                          settings.copyWith(filenamePattern: value),
                        );
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Available placeholders:',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '{input_filename} - Original filename\n'
                    '{date} - Current date (YYYY-MM-DD)\n'
                    '{time} - Current time (HH-MM-SS)',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.6),
                        ),
                  ),
                  if (viewModel.inputPath != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.preview,
                            size: 16,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Preview: ${viewModel.outputPath ?? ""}',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    fontFamily: 'monospace',
                                  ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 24),

            // Container Format
            _buildSection(
              context,
              title: 'Container Format',
              child: SegmentedButton<ContainerFormat>(
                segments: ContainerFormat.values.map((format) {
                  return ButtonSegment(
                    value: format,
                    label: Text(format.name.toUpperCase()),
                  );
                }).toList(),
                selected: {settings.container},
                onSelectionChanged: (value) {
                  final newContainer = value.first;
                  // If current codec isn't supported by new container, switch to first supported codec
                  var newCodec = settings.codec;
                  if (!newCodec.supportsContainer(newContainer)) {
                    newCodec = newContainer.supportedCodecs.first;
                  }
                  viewModel.updateEncodingSettings(
                      settings.copyWith(container: newContainer, codec: newCodec));
                },
              ),
            ),

            const SizedBox(height: 24),

            // Output path
            _buildSection(
              context,
              title: 'Output File',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (viewModel.outputPath != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              viewModel.outputPath!,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(fontFamily: 'monospace'),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.folder_open),
                            onPressed: () => _showInFolder(viewModel.outputPath!),
                            tooltip: 'Show in folder',
                          ),
                        ],
                      ),
                    ),
                  ] else ...[
                    Text(
                      'Output path will be set when you select an input file',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.6),
                          ),
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 24),

            // Video Codec (grouped by family, filtered by container and availability)
            _buildSection(
              context,
              title: 'Video Codec',
              child: _buildCodecList(context, viewModel, settings),
            ),

            const SizedBox(height: 24),

            // Encoder Speed (for codecs that support presets)
            if (settings.codec.availablePresets != null)
              _buildSection(
                context,
                title: 'Encoder Speed',
                child: DropdownButtonFormField<String>(
                  value: settings.codec.availablePresets!.contains(settings.encoderPreset)
                      ? settings.encoderPreset
                      : settings.codec.defaultPreset,
                  decoration: const InputDecoration(
                    labelText: 'Preset',
                    border: OutlineInputBorder(),
                  ),
                  items: settings.codec.availablePresets!.map((preset) {
                    return DropdownMenuItem(
                      value: preset,
                      child: Text(preset),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value != null) {
                      viewModel.updateEncodingSettings(
                        settings.copyWith(encoderPreset: value),
                      );
                    }
                  },
                ),
              ),

            if (settings.codec.availablePresets != null)
              const SizedBox(height: 24),

            // Quality (not applicable for lossless codecs). Intel VideoToolbox has
            // no constant-quality mode, so it gets a native target-bitrate control
            // instead of the CRF slider.
            if (!settings.codec.isLossless)
              _buildSection(
                context,
                title: 'Quality',
                child: (_isIntelMac && _isVideotoolbox(settings.codec))
                    ? _buildVideotoolboxBitrate(context, viewModel, settings)
                    : _buildCrfQuality(context, viewModel, settings),
              ),

            // Note for lossless codec
            if (settings.codec.isLossless)
              _buildSection(
                context,
                title: 'Quality',
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 20,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'This is a lossless codec. No quality setting is needed.',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            const SizedBox(height: 24),

            // Audio
            _buildSection(
              context,
              title: 'Audio',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Audio Mode Selector
                  SegmentedButton<AudioMode>(
                    segments: AudioMode.values.map((mode) {
                      return ButtonSegment(
                        value: mode,
                        label: Text(mode.displayName),
                      );
                    }).toList(),
                    selected: {settings.audioMode},
                    onSelectionChanged: (value) {
                      viewModel.updateEncodingSettings(
                        settings.copyWith(audioMode: value.first),
                      );
                    },
                  ),

                  // Show codec and quality options when Convert is selected
                  if (settings.audioMode == AudioMode.convert) ...[
                    const SizedBox(height: 16),

                    // Audio Codec Dropdown
                    DropdownButtonFormField<AudioCodec>(
                      value: settings.audioCodec,
                      decoration: const InputDecoration(
                        labelText: 'Codec',
                        border: OutlineInputBorder(),
                      ),
                      items: AudioCodec.values.map((codec) {
                        return DropdownMenuItem(
                          value: codec,
                          child: Text(codec.displayName),
                        );
                      }).toList(),
                      onChanged: (value) {
                        if (value != null) {
                          viewModel.updateEncodingSettings(
                            settings.copyWith(audioCodec: value),
                          );
                        }
                      },
                    ),

                    // Quality preset (only for lossy codecs)
                    if (!settings.audioCodec.isLossless) ...[
                      const SizedBox(height: 16),
                      DropdownButtonFormField<AudioQuality>(
                        value: settings.audioQuality,
                        decoration: const InputDecoration(
                          labelText: 'Quality',
                          border: OutlineInputBorder(),
                        ),
                        items: AudioQuality.values.map((quality) {
                          return DropdownMenuItem(
                            value: quality,
                            child: Text(quality.displayName),
                          );
                        }).toList(),
                        onChanged: (value) {
                          if (value != null) {
                            viewModel.updateEncodingSettings(
                              settings.copyWith(audioQuality: value),
                            );
                          }
                        },
                      ),
                    ],

                    // Lossless indicator
                    if (settings.audioCodec.isLossless) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.info_outline,
                              size: 20,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 12),
                            Text(
                              'Lossless codec - no quality loss',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),

            const SizedBox(height: 24),

            // Color Format (Chroma Subsampling)
            _buildSection(
              context,
              title: 'Color Format',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<ChromaSubsampling>(
                    value: settings.chromaSubsampling,
                    decoration: const InputDecoration(
                      labelText: 'Chroma Subsampling',
                      border: OutlineInputBorder(),
                    ),
                    items: ChromaSubsampling.values.map((format) {
                      return DropdownMenuItem(
                        value: format,
                        child: Text(format.displayName),
                      );
                    }).toList(),
                    onChanged: (value) {
                      if (value != null) {
                        viewModel.updateEncodingSettings(
                          settings.copyWith(chromaSubsampling: value),
                        );
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '4:2:0 is most compatible (web, mobile). 4:2:2 preserves more color detail.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.6),
                        ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // Custom FFmpeg Arguments
            _buildSection(
              context,
              title: 'Custom FFmpeg Arguments',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _customFfmpegArgsController,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: 'e.g. -level 4.1 -refs 6',
                    ),
                    onChanged: (value) {
                      viewModel.updateEncodingSettings(
                        settings.copyWith(customFfmpegArgs: value),
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Additional FFmpeg arguments appended to the encoding command. '
                    'These are added after all other settings and can override them.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.6),
                        ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// Whether a hardware encoder is relevant to the current platform's GPU APIs:
  /// VideoToolbox is macOS-only; QSV/NVENC/AMF apply to Windows and Linux.
  /// (Software/ProRes/lossless codecs are platform-agnostic.)
  bool _isHwCodecForPlatform(VideoCodec codec) {
    const videotoolbox = {
      VideoCodec.h264Videotoolbox,
      VideoCodec.h265Videotoolbox,
    };
    const qsvNvencAmf = {
      VideoCodec.h264Qsv, VideoCodec.h265Qsv,
      VideoCodec.h264Nvenc, VideoCodec.h265Nvenc,
      VideoCodec.h264Amf, VideoCodec.h265Amf,
    };
    if (videotoolbox.contains(codec)) return Platform.isMacOS;
    if (qsvNvencAmf.contains(codec)) {
      return Platform.isWindows || Platform.isLinux;
    }
    return true;
  }

  Widget _buildCodecList(BuildContext context, MainViewModel viewModel, EncodingSettings settings) {
    // Group codecs by family
    final softwareCodecs = <VideoCodec>[VideoCodec.h264, VideoCodec.h265];
    final hardwareCodecs = <VideoCodec>[
      VideoCodec.h264Nvenc, VideoCodec.h265Nvenc,
      VideoCodec.h264Qsv, VideoCodec.h265Qsv,
      VideoCodec.h264Videotoolbox, VideoCodec.h265Videotoolbox,
      VideoCodec.h264Amf, VideoCodec.h265Amf,
    ];
    final proresCodecs = <VideoCodec>[
      VideoCodec.proresProxy, VideoCodec.proresLT,
      VideoCodec.prores422, VideoCodec.proresHQ,
    ];
    final losslessCodecs = <VideoCodec>[
      VideoCodec.ffv1, VideoCodec.huffyuv, VideoCodec.ffvhuff,
    ];

    // Show only hardware encoders relevant to this platform (and supported by
    // the container). Whether each is actually usable on the machine is then
    // reflected by the per-encoder detection in _buildCodecRadio.
    final supportedHardware = hardwareCodecs
        .where((c) =>
            c.supportsContainer(settings.container) && _isHwCodecForPlatform(c))
        .toList();

    final children = <Widget>[];

    // Software section
    children.add(_buildCodecGroupLabel(context, 'Software'));
    for (final codec in softwareCodecs) {
      children.add(_buildCodecRadio(context, viewModel, settings, codec));
    }

    // Hardware section
    if (supportedHardware.isNotEmpty) {
      children.add(const SizedBox(height: 8));
      children.add(_buildCodecGroupLabel(context, 'Hardware Accelerated'));
      for (final codec in supportedHardware) {
        children.add(_buildCodecRadio(context, viewModel, settings, codec));
      }
    }

    // ProRes section
    final supportedProres = proresCodecs
        .where((c) => c.supportsContainer(settings.container))
        .toList();
    if (supportedProres.isNotEmpty) {
      children.add(const SizedBox(height: 8));
      children.add(_buildCodecGroupLabel(context, 'ProRes'));
      for (final codec in supportedProres) {
        children.add(_buildCodecRadio(context, viewModel, settings, codec));
      }
    }

    // Lossless section
    final supportedLossless = losslessCodecs
        .where((c) => c.supportsContainer(settings.container))
        .toList();
    if (supportedLossless.isNotEmpty) {
      children.add(const SizedBox(height: 8));
      children.add(_buildCodecGroupLabel(context, 'Lossless'));
      for (final codec in supportedLossless) {
        children.add(_buildCodecRadio(context, viewModel, settings, codec));
      }
    }

    return Column(children: children);
  }

  Widget _buildCodecGroupLabel(BuildContext context, String label) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, top: 4, bottom: 4),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
      ),
    );
  }

  /// The standard CRF/quality slider (software, NVENC, QSV, AMF, Apple-Silicon VT).
  Widget _buildCrfQuality(
      BuildContext context, MainViewModel viewModel, EncodingSettings settings) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Slider(
          value: settings.quality.toDouble(),
          min: 0,
          max: 51,
          divisions: 51,
          label: settings.qualityDescription,
          onChanged: (value) {
            viewModel.updateEncodingSettings(
                settings.copyWith(quality: value.round()));
          },
        ),
        Text(
          settings.qualityDescription,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        Text(
          'Lower values = higher quality, larger file',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color:
                    Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
        ),
      ],
    );
  }

  /// Native Intel-VideoToolbox control: target average bitrate (preset chips +
  /// an editable Mb/s field). Intel VT has no constant-quality (-q:v) mode.
  Widget _buildVideotoolboxBitrate(
      BuildContext context, MainViewModel viewModel, EncodingSettings settings) {
    final currentKbps = settings.videoBitrateKbps ?? _kDefaultVtBitrateKbps;
    // Sync the field when the value changes via a preset chip or codec switch,
    // but never clobber what the user is actively typing.
    final mbpsText =
        (currentKbps / 1000).toString().replaceAll(RegExp(r'\.0$'), '');
    if (!_vtBitrateFocus.hasFocus && _vtBitrateController.text != mbpsText) {
      _vtBitrateController.text = mbpsText;
    }

    void setKbps(int kbps) {
      viewModel
          .updateEncodingSettings(settings.copyWith(videoBitrateKbps: kbps));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _kVtBitratePresetsMbps.entries.map((e) {
            final kbps = e.value * 1000;
            return ChoiceChip(
              label: Text('${e.key} (${e.value} Mb/s)'),
              selected: currentKbps == kbps,
              onSelected: (_) => setKbps(kbps),
            );
          }).toList(),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: 220,
          child: TextField(
            controller: _vtBitrateController,
            focusNode: _vtBitrateFocus,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Target bitrate',
              suffixText: 'Mb/s',
              border: OutlineInputBorder(),
            ),
            onChanged: (value) {
              final mbps = double.tryParse(value.trim());
              if (mbps != null && mbps > 0) {
                setKbps((mbps * 1000).round());
              }
            },
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'VideoToolbox on Intel Macs encodes to a target average bitrate '
          '(no constant-quality mode). Higher = better quality, larger file.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color:
                    Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
        ),
      ],
    );
  }

  Widget _buildCodecRadio(BuildContext context, MainViewModel viewModel,
      EncodingSettings settings, VideoCodec codec) {
    final detector = HardwareEncoderDetector.instance;
    final isSupported = codec.supportsContainer(settings.container);
    final isHw = codec.isHardwareEncoder;
    final compiledIn = detector.isCompiledIn(codec);
    // Still querying whether this (compiled-in) hardware encoder works here.
    final probing = isSupported && isHw && compiledIn && detector.isProbing(codec);
    // The functional probe failed, but ffmpeg DID return the encoder. We keep it
    // selectable and surface the captured error as a warning rather than blocking
    // it — the synthetic probe can fail for encoders that still work in practice
    // (see issue #28-adjacent reports of h264_videotoolbox being hidden).
    final probeFailed = isSupported &&
        isHw &&
        compiledIn &&
        !probing &&
        !detector.isAvailable(codec);
    final probeError = detector.probeError(codec);

    // Any encoder ffmpeg returns (compiled-in) and the container supports is
    // selectable. Only a missing build or an incompatible container blocks it.
    final String? blockedReason = !isSupported
        ? 'Not supported in ${settings.container.name.toUpperCase()}'
        : (isHw && !compiledIn)
            ? 'Not available in this build'
            : null;
    final clickable = blockedReason == null;

    final disabledStyle = TextStyle(
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.38),
    );

    // Trailing affordance: spinner while probing; warning + info button when the
    // probe failed (still selectable); block icon only when genuinely blocked.
    Widget? indicator;
    if (probing) {
      indicator = const Tooltip(
        message: 'Checking availability…',
        child: SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    } else if (probeFailed) {
      indicator = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: 'Availability check failed — this encoder may not work on '
                'this system. Tap the info icon for details.',
            child: Icon(Icons.warning_amber_rounded,
                size: 16, color: Colors.orange[700]),
          ),
          IconButton(
            icon: const Icon(Icons.info_outline, size: 16),
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.only(left: 6),
            constraints: const BoxConstraints(),
            tooltip: 'Show availability check error',
            onPressed: () => _showCodecProbeError(context, codec, probeError),
          ),
        ],
      );
    } else if (!clickable && isHw) {
      indicator = Tooltip(
        message: blockedReason,
        child: Icon(Icons.block, size: 16, color: Colors.orange[700]),
      );
    }

    final String subtitleText;
    if (!clickable) {
      subtitleText = blockedReason;
    } else if (probeFailed) {
      subtitleText =
          'Availability check failed — selectable, but may not encode on this system.';
    } else {
      subtitleText = codec.description;
    }

    return RadioListTile<VideoCodec>(
      title: Row(
        children: [
          Flexible(
            child: Text(
              codec.displayName,
              style: clickable ? null : disabledStyle,
            ),
          ),
          if (indicator != null) ...[
            const SizedBox(width: 8),
            indicator,
          ],
        ],
      ),
      subtitle: Text(
        subtitleText,
        style: clickable ? null : disabledStyle,
      ),
      value: codec,
      groupValue: settings.codec,
      onChanged: clickable
          ? (value) {
              if (value != null) {
                // Seed a default target bitrate when switching to an Intel-VT
                // codec so the worker uses it instead of the low fallback estimate.
                final vtBitrate = (_isIntelMac &&
                        _isVideotoolbox(value) &&
                        settings.videoBitrateKbps == null)
                    ? _kDefaultVtBitrateKbps
                    : settings.videoBitrateKbps;
                // When switching encoder families, reset the preset to the new family's default
                final oldFamily = settings.codec.encoderFamily;
                final newFamily = value.encoderFamily;
                if (oldFamily != newFamily) {
                  viewModel.updateEncodingSettings(
                    settings.copyWith(
                        codec: value,
                        encoderPreset: value.defaultPreset,
                        videoBitrateKbps: vtBitrate),
                  );
                } else {
                  viewModel.updateEncodingSettings(
                    settings.copyWith(codec: value, videoBitrateKbps: vtBitrate),
                  );
                }
              }
            }
          : null,
    );
  }

  /// Show the captured ffmpeg error from a failed encoder availability probe.
  Future<void> _showCodecProbeError(
      BuildContext context, VideoCodec codec, String? error) async {
    final text = (error == null || error.isEmpty)
        ? 'No error output was captured for this encoder.'
        : error;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${codec.displayName} — availability check'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: SelectableText(
              text,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy'),
            onPressed: () => Clipboard.setData(ClipboardData(text: text)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _selectOutputDirectory(MainViewModel viewModel, EncodingSettings settings) async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select Output Directory',
      initialDirectory: settings.outputDirectory,
    );

    if (result != null) {
      viewModel.updateEncodingSettings(
        settings.copyWith(outputDirectory: result),
      );
    }
  }

  void _showInFolder(String path) {
    if (Platform.isMacOS) {
      Process.run('open', ['-R', path]);
    } else if (Platform.isWindows) {
      Process.run('explorer', ['/select,', path]);
    } else if (Platform.isLinux) {
      final parent = File(path).parent.path;
      Process.run('xdg-open', [parent]);
    }
  }

  Widget _buildSection(
    BuildContext context, {
    required String title,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: 12),
        child,
      ],
    );
  }
}

class _GeneralSettingsTab extends StatefulWidget {
  const _GeneralSettingsTab();

  @override
  State<_GeneralSettingsTab> createState() => _GeneralSettingsTabState();
}

class _GeneralSettingsTabState extends State<_GeneralSettingsTab> {
  bool _checkForUpdates = true;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final enabled = await UpdateChecker.instance.isEnabled();
    if (mounted) {
      setState(() {
        _checkForUpdates = enabled;
        _isLoading = false;
      });
    }
  }

  Future<void> _setCheckForUpdates(bool value) async {
    setState(() {
      _checkForUpdates = value;
    });
    await UpdateChecker.instance.setEnabled(value);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildSection(
          context,
          title: 'Updates',
          child: SwitchListTile(
            title: const Text('Check for updates on startup'),
            subtitle: const Text('Notify when a new version is available'),
            value: _checkForUpdates,
            onChanged: _setCheckForUpdates,
          ),
        ),
      ],
    );
  }

  Widget _buildSection(
    BuildContext context, {
    required String title,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: 12),
        child,
      ],
    );
  }
}
