import 'package:flutter/material.dart';

import '../../services/addon_service.dart';
import '../addon_dialogs.dart';

/// Settings → Add-ons: every optional download, grouped by the feature that
/// uses it, with its size, licence and source, installed or not, to install
/// or remove. Installing here and from a feature's prompt is the same
/// [AddonService] call, so both show the same state.
class AddonsSettingsTab extends StatefulWidget {
  final AddonService? service;
  const AddonsSettingsTab({super.key, this.service});

  /// The app version this tab shipped in, for its "NEW" badge.
  static const sinceAppVersion = '1.5.0';

  @override
  State<AddonsSettingsTab> createState() => _AddonsSettingsTabState();
}

class _AddonsSettingsTabState extends State<AddonsSettingsTab> {
  AddonService get _service => widget.service ?? AddonService.instance;
  String? _error;

  @override
  void initState() {
    super.initState();
    _service.load().then((_) => _service.refresh());
  }

  Future<void> _install(AddonInfo info) async {
    setState(() => _error = null);
    try {
      await _service.install(info.id);
    } catch (e) {
      if (mounted) setState(() => _error = '${info.name}: $e');
    }
  }

  Future<void> _remove(AddonInfo info) async {
    final also = _service.dependants(info.id).map((id) => _service.info(id)!.name).toList();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${info.name}?'),
        content: Text([
          'Features that use it will ask to download it again.',
          if (also.isNotEmpty) 'This also removes: ${also.join(', ')}.',
        ].join('\n\n')),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _service.remove(info.id);
    } catch (e) {
      if (mounted) setState(() => _error = '${info.name}: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: _service,
      builder: (context, _) {
        final byFeature = <String, List<AddonInfo>>{};
        for (final info in _service.catalog) {
          byFeature.putIfAbsent(info.feature, () => []).add(info);
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Optional downloads from third parties, for features that need '
              'them. Each is fetched from its own source when you install it '
              'here or first use the feature.',
              style: theme.textTheme.bodySmall,
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            for (final MapEntry(key: feature, value: infos) in byFeature.entries) ...[
              const SizedBox(height: 16),
              Text(feature, style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              for (final info in infos) _row(context, info),
            ],
          ],
        );
      },
    );
  }

  Widget _row(BuildContext context, AddonInfo info) {
    final theme = Theme.of(context);
    final installed = _service.isInstalled(info.id);
    final installing = _service.installingId == info.id;
    final busy = _service.installingId != null;
    final Widget action;
    if (installing) {
      action = TextButton(onPressed: _service.cancel, child: const Text('Cancel'));
    } else if (installed) {
      action = OutlinedButton(
        key: ValueKey('remove-${info.id}'),
        onPressed: busy ? null : () => _remove(info),
        child: const Text('Remove'),
      );
    } else {
      action = FilledButton.tonal(
        key: ValueKey('install-${info.id}'),
        onPressed: busy || info.unavailableReason != null ? null : () => _install(info),
        child: const Text('Install'),
      );
    }
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(child: Text(info.name, style: theme.textTheme.titleSmall)),
                      const SizedBox(width: 8),
                      Text(
                        installed ? 'Installed' : formatAddonSize(info.downloadBytes),
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: installed ? theme.colorScheme.primary : null),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(info.description, style: theme.textTheme.bodySmall),
                  const SizedBox(height: 4),
                  AddonTerms(info: info),
                  if (info.unavailableReason != null)
                    Text(info.unavailableReason!, style: theme.textTheme.bodySmall),
                  if (installing) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: _service.progress),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            action,
          ],
        ),
      ),
    );
  }
}
