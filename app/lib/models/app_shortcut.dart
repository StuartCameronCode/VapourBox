import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Groups for the keyboard shortcuts dialog, in display order.
enum AppShortcutGroup {
  navigation('Moving around'),
  range('Export range'),
  preview('Preview'),
  zoom('Timeline zoom'),
  app('General');

  final String label;
  const AppShortcutGroup(this.label);
}

/// Every keyboard shortcut in the main window (issue #102), and the single
/// source of both what triggers it and how it is written in a tooltip.
///
/// Keys follow the common NLE conventions — arrows to step frames, Home/End,
/// I/O for in and out, Shift+I/O to go to them, =/- to zoom, \ to fit — so
/// they do what someone coming from Premiere or Resolve expects. The preview's
/// Cmd/Ctrl+1 (actual pixels) and Cmd/Ctrl+0 (fit) are the image-editor
/// convention.
///
/// Shortcuts without the platform's primary modifier (Cmd on macOS, Ctrl
/// elsewhere) are suppressed while a text field has focus, so typing "i" in a
/// filename never sets an in point; see [AppShortcutScope].
enum AppShortcut {
  previousFrame(
    'Previous frame',
    AppShortcutGroup.navigation,
    LogicalKeyboardKey.arrowLeft,
    repeats: true,
  ),
  nextFrame(
    'Next frame',
    AppShortcutGroup.navigation,
    LogicalKeyboardKey.arrowRight,
    repeats: true,
  ),
  back10Frames(
    'Back 10 frames',
    AppShortcutGroup.navigation,
    LogicalKeyboardKey.arrowLeft,
    shift: true,
    repeats: true,
  ),
  forward10Frames(
    'Forward 10 frames',
    AppShortcutGroup.navigation,
    LogicalKeyboardKey.arrowRight,
    shift: true,
    repeats: true,
  ),
  goToStart('Go to start', AppShortcutGroup.navigation, LogicalKeyboardKey.home),
  goToEnd('Go to end', AppShortcutGroup.navigation, LogicalKeyboardKey.end),
  setInPoint('Set in point', AppShortcutGroup.range, LogicalKeyboardKey.keyI),
  setOutPoint('Set out point', AppShortcutGroup.range, LogicalKeyboardKey.keyO),
  goToInPoint(
    'Go to in point',
    AppShortcutGroup.range,
    LogicalKeyboardKey.keyI,
    shift: true,
  ),
  goToOutPoint(
    'Go to out point',
    AppShortcutGroup.range,
    LogicalKeyboardKey.keyO,
    shift: true,
  ),
  clearInOut(
    'Clear in and out points',
    AppShortcutGroup.range,
    LogicalKeyboardKey.keyX,
    alt: true,
  ),
  previewActualSize(
    'Preview at actual pixels (1:1)',
    AppShortcutGroup.preview,
    LogicalKeyboardKey.digit1,
    alternates: [LogicalKeyboardKey.numpad1],
    primary: true,
  ),
  previewFit(
    'Fit preview to panel',
    AppShortcutGroup.preview,
    LogicalKeyboardKey.digit0,
    alternates: [LogicalKeyboardKey.numpad0],
    primary: true,
  ),
  zoomIn(
    'Zoom in',
    AppShortcutGroup.zoom,
    LogicalKeyboardKey.equal,
    alternates: [LogicalKeyboardKey.add, LogicalKeyboardKey.numpadAdd],
    repeats: true,
  ),
  zoomOut(
    'Zoom out',
    AppShortcutGroup.zoom,
    LogicalKeyboardKey.minus,
    alternates: [LogicalKeyboardKey.numpadSubtract],
    repeats: true,
  ),
  zoomToFit(
    'Zoom to fit',
    AppShortcutGroup.zoom,
    LogicalKeyboardKey.backslash,
  ),
  addVideos(
    'Add videos',
    AppShortcutGroup.app,
    LogicalKeyboardKey.keyO,
    primary: true,
  ),
  startProcessing(
    'Start processing',
    AppShortcutGroup.app,
    LogicalKeyboardKey.enter,
    alternates: [LogicalKeyboardKey.numpadEnter],
    primary: true,
  ),
  openSettings(
    'Settings',
    AppShortcutGroup.app,
    LogicalKeyboardKey.comma,
    primary: true,
  ),
  showShortcuts(
    'Keyboard shortcuts',
    AppShortcutGroup.app,
    LogicalKeyboardKey.slash,
    shift: true,
  );

  final String label;
  final AppShortcutGroup group;
  final LogicalKeyboardKey key;

  /// Other keys that trigger the same shortcut with the same modifiers — the
  /// numpad, and `+` for keyboards that report Shift+= as its own key.
  final List<LogicalKeyboardKey> alternates;

  /// Cmd on macOS, Ctrl elsewhere.
  final bool primary;
  final bool shift;
  final bool alt;

  /// Whether holding the key down repeats it (frame stepping, zoom), as
  /// opposed to firing once per press.
  final bool repeats;

  const AppShortcut(
    this.label,
    this.group,
    this.key, {
    this.alternates = const [],
    this.primary = false,
    this.shift = false,
    this.alt = false,
    this.repeats = false,
  });

  static bool get _isMac => defaultTargetPlatform == TargetPlatform.macOS;

  /// Whether this shortcut may fire while a text field is focused. Only
  /// primary-modifier shortcuts can: nothing types a character with Cmd/Ctrl
  /// held, whereas a bare letter, arrow or Home/End belongs to the field.
  bool get allowedInTextInput => primary;

  /// The activators for this platform, the main key first.
  List<SingleActivator> get activators => [
        for (final k in [key, ...alternates])
          SingleActivator(
            k,
            shift: shift,
            alt: alt,
            meta: primary && _isMac,
            control: primary && !_isMac,
            includeRepeats: repeats,
          ),
        // `+` is Shift+= on most layouts, which reports the `=` key with
        // Shift held rather than a key of its own.
        if (this == AppShortcut.zoomIn)
          SingleActivator(key, shift: true, includeRepeats: repeats),
      ];

  /// Whether [event] triggers this shortcut.
  bool accepts(KeyEvent event, HardwareKeyboard state) =>
      activators.any((activator) => activator.accepts(event, state));

  /// The keys as written on screen: `⇧←` / `⌘,` on macOS, `Shift+←` /
  /// `Ctrl+,` elsewhere. `?` is written as itself rather than as Shift+/.
  String get keyLabel {
    if (this == AppShortcut.showShortcuts) return '?';
    final keyName = _keyName(key);
    if (_isMac) {
      return '${primary ? '⌘' : ''}${alt ? '⌥' : ''}${shift ? '⇧' : ''}$keyName';
    }
    return [
      if (primary) 'Ctrl',
      if (alt) 'Alt',
      if (shift) 'Shift',
      keyName,
    ].join('+');
  }

  /// A tooltip naming the action and its shortcut, e.g. `Next frame (→)`.
  String get tooltip => '$label ($keyLabel)';

  /// [tooltip] with a different description in front of the same keys, for
  /// buttons whose wording is more specific than the shortcut's.
  String tooltipFor(String description) => '$description ($keyLabel)';

  static String _keyName(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.arrowLeft) return '←';
    if (key == LogicalKeyboardKey.arrowRight) return '→';
    if (key == LogicalKeyboardKey.arrowUp) return '↑';
    if (key == LogicalKeyboardKey.arrowDown) return '↓';
    if (key == LogicalKeyboardKey.enter) return _isMac ? '↩' : 'Enter';
    if (key == LogicalKeyboardKey.home) return 'Home';
    if (key == LogicalKeyboardKey.end) return 'End';
    return key.keyLabel.toUpperCase();
  }
}
