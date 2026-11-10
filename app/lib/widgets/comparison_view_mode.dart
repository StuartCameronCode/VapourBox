import '../models/app_shortcut.dart';

/// What the before/after preview shows: either frame whole, or the two split
/// by the draggable divider. Lives in `MainViewModel`, so it survives
/// scrubber moves and new previews.
enum ComparisonViewMode {
  original('Original', 'Show only the original frame'),
  split('Split', 'Compare original and processed with the divider'),
  processed('Processed', 'Show only the processed frame');

  final String label;
  final String description;
  const ComparisonViewMode(this.label, this.description);

  /// The keyboard shortcut that selects this mode.
  AppShortcut get shortcut => switch (this) {
        ComparisonViewMode.original => AppShortcut.previewOriginal,
        ComparisonViewMode.split => AppShortcut.previewSplit,
        ComparisonViewMode.processed => AppShortcut.previewProcessed,
      };

  /// The button's tooltip, with the shortcut's keys.
  String get tooltip => shortcut.tooltipFor(description);
}
