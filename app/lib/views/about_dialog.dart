import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/dependency_manager.dart';

class AboutDialog extends StatefulWidget {
  const AboutDialog({super.key});

  @override
  State<AboutDialog> createState() => _AboutDialogState();
}

class _AboutDialogState extends State<AboutDialog> {
  String _version = '';
  String _depsVersion = '';
  String _githubUrl = 'https://github.com/StuartCameron/VapourBox';
  static const String _authorUrl = 'https://stuart-cameron.com';

  @override
  void initState() {
    super.initState();
    _loadVersionInfo();
  }

  Future<void> _loadVersionInfo() async {
    // Get app version from package info
    final packageInfo = await PackageInfo.fromPlatform();

    // Get deps version from dependency manager
    final depsInfo = await DependencyManager.instance.getExpectedVersion();

    setState(() {
      _version = packageInfo.version;
      _depsVersion = depsInfo.version;
      _githubUrl = 'https://github.com/${depsInfo.githubRepo}';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500, maxHeight: 650),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Center(
                child: Column(
                  children: [
                    Text(
                      'VapourBox',
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _version.isEmpty ? 'Loading...' : 'Version $_version',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.6),
                          ),
                    ),
                    if (_depsVersion.isNotEmpty)
                      Text(
                        'Dependencies: $_depsVersion',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withValues(alpha: 0.4),
                            ),
                      ),
                    const SizedBox(height: 12),
                    Text(
                      'Video restoration and cleanup powered by VapourSynth',
                      style: Theme.of(context).textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    InkWell(
                      onTap: () => _launchUrl(_authorUrl),
                      child: Text(
                        'by Stuart Cameron',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // License notice
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'License',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'This program is free software: you can redistribute it and/or modify '
                      'it under the terms of the GNU General Public License as published by '
                      'the Free Software Foundation, either version 3 of the License, or '
                      '(at your option) any later version.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // Third-party components header
              Text(
                'Third-Party Components',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 8),

              // Scrollable component list
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Theme.of(context)
                          .colorScheme
                          .outline
                          .withValues(alpha: 0.2),
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ListView(
                    padding: const EdgeInsets.all(8),
                    children: const [
                      _ComponentTile(
                        name: 'VapourSynth',
                        license: 'LGPL 2.1',
                        copyright: 'Fredrik Mellbin',
                        url: 'https://github.com/vapoursynth/vapoursynth',
                      ),
                      _ComponentTile(
                        name: 'havsfunc',
                        license: 'Unlicense',
                        copyright: 'HolyWu',
                        url: 'https://github.com/HomeOfVapourSynthEvolution/havsfunc',
                      ),
                      _ComponentTile(
                        name: 'mvtools',
                        license: 'GPL 2.0',
                        copyright: 'Manao, Fizick, Pinterf, dubhater',
                        url: 'https://github.com/dubhater/vapoursynth-mvtools',
                      ),
                      _ComponentTile(
                        name: 'znedi3',
                        license: 'GPL 2.0',
                        copyright: 'sekrit-twc',
                        url: 'https://github.com/sekrit-twc/znedi3',
                      ),
                      _ComponentTile(
                        name: 'EEDI3',
                        license: 'GPL 2.0',
                        copyright: 'tritical, HolyWu',
                        url: 'https://github.com/HomeOfVapourSynthEvolution/VapourSynth-EEDI3',
                      ),
                      _ComponentTile(
                        name: 'FFmpeg',
                        license: 'LGPL 2.1+',
                        copyright: 'FFmpeg contributors',
                        url: 'https://github.com/FFmpeg/FFmpeg',
                      ),
                      _ComponentTile(
                        name: 'ffms2',
                        license: 'MIT',
                        copyright: 'FFMS contributors',
                        url: 'https://github.com/FFMS/ffms2',
                      ),
                      _ComponentTile(
                        name: 'DFTTest',
                        license: 'GPL 3.0',
                        copyright: 'HolyWu',
                        url: 'https://github.com/HomeOfVapourSynthEvolution/VapourSynth-DFTTest',
                      ),
                      _ComponentTile(
                        name: 'neo-f3kdb',
                        license: 'GPL 3.0',
                        copyright: 'HomeOfAviSynthPlusEvolution',
                        url: 'https://github.com/HomeOfAviSynthPlusEvolution/neo_f3kdb',
                      ),
                      _ComponentTile(
                        name: 'CAS',
                        license: 'MIT',
                        copyright: 'HolyWu',
                        url: 'https://github.com/HomeOfVapourSynthEvolution/VapourSynth-CAS',
                      ),
                      _ComponentTile(
                        name: 'fmtconv',
                        license: 'WTFPL',
                        copyright: 'Firesledge (Laurent de Soras)',
                        url: 'https://github.com/EleonoreMizo/fmtconv',
                      ),
                      _ComponentTile(
                        name: 'Flutter',
                        license: 'BSD 3-Clause',
                        copyright: 'The Flutter Authors',
                        url: 'https://github.com/flutter/flutter',
                      ),
                      _ComponentTile(
                        name: 'Python',
                        license: 'PSF License',
                        copyright: 'Python Software Foundation',
                        url: 'https://github.com/python/cpython',
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // Buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('View on GitHub'),
                    onPressed: () => _launchUrl(_githubUrl),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }
}

class _ComponentTile extends StatelessWidget {
  final String name;
  final String license;
  final String copyright;
  final String url;

  const _ComponentTile({
    required this.name,
    required this.license,
    required this.copyright,
    required this.url,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => _launchUrl(url),
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                  ),
                  Text(
                    copyright,
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
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                license,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.open_in_new,
              size: 14,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }
}
