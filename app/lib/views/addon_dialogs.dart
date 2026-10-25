import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/addon_service.dart';

/// Human-readable size for a download.
String formatAddonSize(int bytes) {
  if (bytes >= 1000000000) return '${(bytes / 1000000000).toStringAsFixed(1)} GB';
  if (bytes >= 1000000) return '${(bytes / 1000000).toStringAsFixed(0)} MB';
  return '${(bytes / 1000).toStringAsFixed(0)} KB';
}

/// What a feature calls when it needs add-ons: if any of [ids] (or what they
/// require) is missing, say what will be downloaded, from where and under
/// what licence, and download it on the user's say-so. Returns true when
/// everything is installed at the end. Settings → Add-ons installs through
/// the same [AddonService].
class AddonPrompt {
  static Future<bool> ensure(
    BuildContext context,
    List<String> ids, {
    required String reason,
    AddonService? service,
  }) async {
    final addons = service ?? AddonService.instance;
    await addons.load();
    final missing = addons.missing(ids);
    if (missing.isEmpty) return true;
    if (!context.mounted) return false;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AddonConfirmDialog(service: addons, ids: missing, reason: reason),
    );
    if (confirmed != true || !context.mounted) return false;
    final done = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AddonProgressDialog(service: addons, ids: missing),
    );
    return done == true;
  }
}

/// One add-on's licence and source, as both the prompt and the Settings page
/// show it. The usage restriction, when there is one, comes first and bold:
/// it is the one thing the user must not miss.
class AddonTerms extends StatelessWidget {
  final AddonInfo info;
  const AddonTerms({super.key, required this.info});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (info.usageNote != null)
          Text(info.usageNote!,
              style: small?.copyWith(fontWeight: FontWeight.bold, color: theme.colorScheme.error)),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          children: [
            Text('${info.credit} · ', style: small),
            _Link(text: info.licence, url: info.licenceUrl, style: small),
            Text('·', style: small),
            _Link(text: 'Source', url: info.sourceUrl, style: small),
          ],
        ),
      ],
    );
  }
}

class _Link extends StatelessWidget {
  final String text;
  final String? url;
  final TextStyle? style;
  const _Link({required this.text, required this.url, this.style});

  @override
  Widget build(BuildContext context) {
    if (url == null) return Text(text, style: style);
    return InkWell(
      onTap: () => launchUrl(Uri.parse(url!)),
      child: Text(text,
          style: style?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              decoration: TextDecoration.underline)),
    );
  }
}

class AddonConfirmDialog extends StatelessWidget {
  final AddonService service;
  final List<String> ids;
  final String reason;

  const AddonConfirmDialog({
    super.key,
    required this.service,
    required this.ids,
    required this.reason,
  });

  @override
  Widget build(BuildContext context) {
    final infos = ids.map(service.info).whereType<AddonInfo>().toList();
    final unavailable = infos.where((i) => i.unavailableReason != null).toList();
    return AlertDialog(
      title: const Text('Download add-on?'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$reason It is not included with VapourBox and is '
                'downloaded from its own source:'),
            for (final info in infos) ...[
              const SizedBox(height: 12),
              Text('${info.name} (${formatAddonSize(info.downloadBytes)})',
                  style: Theme.of(context).textTheme.titleSmall),
              AddonTerms(info: info),
            ],
            if (unavailable.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(unavailable.first.unavailableReason!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 12),
            Text('You can remove it later in Settings → Add-ons.',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: unavailable.isEmpty ? () => Navigator.of(context).pop(true) : null,
          child: Text('Download ${formatAddonSize(service.downloadBytes(ids))}'),
        ),
      ],
    );
  }
}

/// Installs [ids] in order, showing progress; pops true when all are in.
class AddonProgressDialog extends StatefulWidget {
  final AddonService service;
  final List<String> ids;
  const AddonProgressDialog({super.key, required this.service, required this.ids});

  @override
  State<AddonProgressDialog> createState() => _AddonProgressDialogState();
}

class _AddonProgressDialogState extends State<AddonProgressDialog> {
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() => _error = null);
    try {
      for (final id in widget.ids) {
        if (!await widget.service.install(id)) {
          if (mounted) Navigator.of(context).pop(false);
          return;
        }
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Downloading add-on'),
      content: SizedBox(
        width: 400,
        child: ListenableBuilder(
          listenable: widget.service,
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: _error != null
                ? [
                    Text('Download failed', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 4),
                    SelectableText(_error!, style: Theme.of(context).textTheme.bodySmall),
                  ]
                : [
                    Text(widget.service.status.isEmpty ? 'Preparing…' : widget.service.status),
                    const SizedBox(height: 12),
                    LinearProgressIndicator(value: widget.service.progress),
                  ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            if (_error == null) widget.service.cancel();
            Navigator.of(context).pop(false);
          },
          child: const Text('Cancel'),
        ),
        if (_error != null) FilledButton(onPressed: _run, child: const Text('Retry')),
      ],
    );
  }
}
