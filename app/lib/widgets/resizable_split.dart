import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A two-pane layout with a divider the user can drag to resize the panes.
///
/// The first pane is sized in pixels; the second takes whatever is left. Until
/// the user drags the divider, the first pane follows [initialFirstSize], which
/// the parent may recompute on every build to size the pane to its content (see
/// the queue panel in `main_window.dart`). Once dragged, the user's size wins
/// and is kept — persisted across launches when [storageKey] is set.
///
/// Sizes are always clamped so both panes keep at least their minimum, which
/// means a window resize can shrink the first pane below the user's chosen size
/// without discarding it — widen the window again and it comes back.
class ResizableSplit extends StatefulWidget {
  /// [Axis.horizontal] puts the panes side by side with a vertical divider;
  /// [Axis.vertical] stacks them with a horizontal divider.
  final Axis axis;

  /// Leading pane — left (horizontal) or top (vertical). This is the sized one.
  final Widget first;

  /// Trailing pane, which fills the remaining space.
  final Widget second;

  /// Size of [first] before the user has dragged the divider.
  final double initialFirstSize;

  /// Smallest size [first] may be dragged to.
  final double minFirstSize;

  /// Space always left for [second].
  final double minSecondSize;

  /// When set, the dragged size is saved under this key and restored on launch.
  final String? storageKey;

  const ResizableSplit({
    super.key,
    required this.axis,
    required this.first,
    required this.second,
    required this.initialFirstSize,
    this.minFirstSize = 120,
    this.minSecondSize = 120,
    this.storageKey,
  });

  @override
  State<ResizableSplit> createState() => _ResizableSplitState();
}

class _ResizableSplitState extends State<ResizableSplit> {
  static const double _handleThickness = 8;

  /// Size the user dragged to, or null while the pane still auto-sizes.
  double? _userSize;

  /// Size actually used by the last build — the base for drag deltas, so the
  /// handle tracks the pointer even when clamping moved the pane.
  double _resolvedSize = 0;

  bool _isDragging = false;
  bool _isHovering = false;

  @override
  void initState() {
    super.initState();
    _restoreSize();
  }

  Future<void> _restoreSize() async {
    final key = widget.storageKey;
    if (key == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getDouble(_prefsKey(key));
      if (stored != null && mounted) {
        setState(() => _userSize = stored);
      }
    } catch (_) {
      // Persisted layout is a nicety — fall back to the auto size.
    }
  }

  Future<void> _persistSize(double size) async {
    final key = widget.storageKey;
    if (key == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_prefsKey(key), size);
    } catch (_) {
      // Ignore — losing the saved size is harmless.
    }
  }

  static String _prefsKey(String key) => 'split.$key';

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final total = widget.axis == Axis.horizontal
            ? constraints.maxWidth
            : constraints.maxHeight;
        final available = (total - _handleThickness).clamp(0.0, double.infinity);

        // Both minimums may not fit in a small window; the first pane's minimum
        // yields so the second pane keeps its share.
        final lower = widget.minFirstSize.clamp(0.0, available);
        final upper = (available - widget.minSecondSize).clamp(lower, available);
        _resolvedSize = (_userSize ?? widget.initialFirstSize).clamp(lower, upper);

        return Flex(
          direction: widget.axis,
          children: [
            widget.axis == Axis.horizontal
                ? SizedBox(width: _resolvedSize, child: widget.first)
                : SizedBox(height: _resolvedSize, child: widget.first),
            _buildHandle(context, canResize: upper > lower),
            Expanded(child: widget.second),
          ],
        );
      },
    );
  }

  Widget _buildHandle(BuildContext context, {required bool canResize}) {
    final colorScheme = Theme.of(context).colorScheme;
    final horizontal = widget.axis == Axis.horizontal;
    final active = _isDragging || _isHovering;

    // A thin line the user sees, inside a thicker invisible strip they can grab.
    final line = Container(
      width: horizontal ? (active ? 2 : 1) : double.infinity,
      height: horizontal ? double.infinity : (active ? 2 : 1),
      color: active
          ? colorScheme.primary
          : colorScheme.outline.withValues(alpha: 0.2),
    );

    final handle = SizedBox(
      width: horizontal ? _handleThickness : double.infinity,
      height: horizontal ? double.infinity : _handleThickness,
      child: Center(child: line),
    );

    if (!canResize) return handle;

    return MouseRegion(
      cursor: horizontal
          ? SystemMouseCursors.resizeColumn
          : SystemMouseCursors.resizeRow,
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart:
            horizontal ? (_) => setState(() => _isDragging = true) : null,
        onHorizontalDragUpdate:
            horizontal ? (details) => _drag(details.delta.dx) : null,
        onHorizontalDragEnd: horizontal ? (_) => _endDrag() : null,
        onVerticalDragStart:
            horizontal ? null : (_) => setState(() => _isDragging = true),
        onVerticalDragUpdate:
            horizontal ? null : (details) => _drag(details.delta.dy),
        onVerticalDragEnd: horizontal ? null : (_) => _endDrag(),
        onDoubleTap: _resetSize,
        child: handle,
      ),
    );
  }

  void _drag(double delta) {
    setState(() => _userSize = _resolvedSize + delta);
  }

  void _endDrag() {
    setState(() => _isDragging = false);
    // Persist the clamped size, not the raw drag total, so a drag past the end
    // stop isn't stored.
    _persistSize(_resolvedSize);
  }

  /// Double-clicking the divider gives the pane back to its automatic size.
  void _resetSize() {
    setState(() => _userSize = null);
    final key = widget.storageKey;
    if (key == null) return;
    SharedPreferences.getInstance()
        .then((prefs) => prefs.remove(_prefsKey(key)))
        .catchError((_) => false);
  }
}
