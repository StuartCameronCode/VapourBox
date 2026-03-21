import 'package:flutter/material.dart';

import '../models/dvd_info.dart';

/// Dialog for selecting DVD titles to add to the processing queue.
class DvdTitlePicker extends StatefulWidget {
  final DvdInfo dvdInfo;

  const DvdTitlePicker({super.key, required this.dvdInfo});

  /// Shows the title picker dialog and returns the selected title index,
  /// or null if cancelled.
  static Future<DvdTitlePickerResult?> show({
    required BuildContext context,
    required DvdInfo dvdInfo,
  }) async {
    return showDialog<DvdTitlePickerResult>(
      context: context,
      builder: (context) => DvdTitlePicker(dvdInfo: dvdInfo),
    );
  }

  @override
  State<DvdTitlePicker> createState() => _DvdTitlePickerState();
}

class _DvdTitlePickerState extends State<DvdTitlePicker> {
  int? _selectedTitleIndex;
  final Set<int> _expandedTitles = {};

  @override
  void initState() {
    super.initState();
    // Auto-select the first title (longest, since they're sorted by duration)
    if (widget.dvdInfo.titles.isNotEmpty) {
      _selectedTitleIndex = widget.dvdInfo.titles.first.index;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.album, color: colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.dvdInfo.volumeLabel),
                Text(
                  '${widget.dvdInfo.titles.length} titles found',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 550,
        height: 400,
        child: widget.dvdInfo.titles.isEmpty
            ? const Center(child: Text('No titles found on this disc'))
            : ListView.builder(
                itemCount: widget.dvdInfo.titles.length,
                itemBuilder: (context, index) {
                  final title = widget.dvdInfo.titles[index];
                  return _buildTitleRow(context, title);
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _selectedTitleIndex != null
              ? () {
                  Navigator.pop(
                    context,
                    DvdTitlePickerResult(titleIndex: _selectedTitleIndex!),
                  );
                }
              : null,
          child: const Text('Add to Queue'),
        ),
      ],
    );
  }

  Widget _buildTitleRow(BuildContext context, DvdTitle title) {
    final isSelected = _selectedTitleIndex == title.index;
    final isExpanded = _expandedTitles.contains(title.index);
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        Material(
          color: isSelected
              ? colorScheme.primaryContainer
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () {
              setState(() {
                _selectedTitleIndex = title.index;
              });
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  // Radio button
                  Radio<int>(
                    value: title.index,
                    groupValue: _selectedTitleIndex,
                    onChanged: (value) {
                      setState(() {
                        _selectedTitleIndex = value;
                      });
                    },
                  ),

                  // Title info
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              'Title ${title.index}',
                              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              title.durationFormatted,
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: colorScheme.primary,
                                    fontWeight: FontWeight.w500,
                                  ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${title.resolution} ${title.aspectRatio} ${title.videoSystem} '
                          '- ${title.chapters.length} chapters - ${title.audioSummary}',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurface.withValues(alpha: 0.6),
                              ),
                        ),
                      ],
                    ),
                  ),

                  // Expand chapters button
                  if (title.chapters.length > 1)
                    IconButton(
                      icon: Icon(
                        isExpanded ? Icons.expand_less : Icons.expand_more,
                        size: 20,
                      ),
                      onPressed: () {
                        setState(() {
                          if (isExpanded) {
                            _expandedTitles.remove(title.index);
                          } else {
                            _expandedTitles.add(title.index);
                          }
                        });
                      },
                      tooltip: isExpanded ? 'Hide chapters' : 'Show chapters',
                    ),
                ],
              ),
            ),
          ),
        ),

        // Expanded chapter list
        if (isExpanded)
          Padding(
            padding: const EdgeInsets.only(left: 48, right: 12, bottom: 8),
            child: Container(
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: title.chapters.map((chapter) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        Text(
                          'Chapter ${chapter.index}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          chapter.durationFormatted,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurface.withValues(alpha: 0.5),
                              ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
      ],
    );
  }
}

/// Result from the DVD title picker dialog.
class DvdTitlePickerResult {
  final int titleIndex;
  final int? startChapter;
  final int? endChapter;

  const DvdTitlePickerResult({
    required this.titleIndex,
    this.startChapter,
    this.endChapter,
  });
}
