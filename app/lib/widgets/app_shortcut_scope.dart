import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../models/app_shortcut.dart';

/// Handles the main window's keyboard shortcuts (issue #102) without taking
/// keys away from anything that wants them.
///
/// It is a [Focus] node around the window, so it only sees a key after the
/// focused widget and everything between has declined it. Widgets that handle
/// their own keys — sliders, dropdowns, buttons activated with Space — keep
/// working. Text fields are the exception that needs care: a typed letter
/// arrives through the text input system, not as a key event the field
/// consumes, so the raw `I` would still bubble up to here. Every shortcut
/// without Cmd/Ctrl is therefore ignored while focus is inside an
/// [EditableText], and passes on to the field's own handling (arrows move the
/// caret, Home/End go to the line ends).
///
/// Dialogs and menus are separate routes, not descendants of this widget, so
/// nothing fires behind an open Settings dialog.
class AppShortcutScope extends StatefulWidget {
  /// What each shortcut does. A missing or null entry is not handled, and the
  /// key passes through.
  final Map<AppShortcut, VoidCallback?> bindings;
  final Widget child;

  const AppShortcutScope({
    super.key,
    required this.bindings,
    required this.child,
  });

  /// Whether keyboard focus is currently inside a text field.
  static bool isTextInputFocused() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    if (context.widget is EditableText) return true;
    return context.findAncestorStateOfType<EditableTextState>() != null;
  }

  /// The shortcut [event] triggers among [bindings], or null if none should
  /// fire. Separate from the widget so the text-field rule is testable without
  /// a keyboard.
  static AppShortcut? match(
    KeyEvent event,
    Map<AppShortcut, VoidCallback?> bindings, {
    required bool textInputFocused,
    HardwareKeyboard? keyboard,
  }) {
    if (event is KeyUpEvent) return null;
    final state = keyboard ?? HardwareKeyboard.instance;
    for (final entry in bindings.entries) {
      if (entry.value == null) continue;
      if (!entry.key.accepts(event, state)) continue;
      if (textInputFocused && !entry.key.allowedInTextInput) return null;
      return entry.key;
    }
    return null;
  }

  @override
  State<AppShortcutScope> createState() => _AppShortcutScopeState();
}

class _AppShortcutScopeState extends State<AppShortcutScope> {
  final FocusNode _node = FocusNode(
    debugLabel: 'AppShortcutScope',
    skipTraversal: true,
  );

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    final shortcut = AppShortcutScope.match(
      event,
      widget.bindings,
      textInputFocused: AppShortcutScope.isTextInputFocused(),
    );
    if (shortcut == null) return KeyEventResult.ignored;
    widget.bindings[shortcut]!();
    return KeyEventResult.handled;
  }

  /// Clicking somewhere that takes no focus (the preview, the timeline, empty
  /// space) after focus has left the window — a text field unfocusing hands it
  /// back to the route — would otherwise leave the shortcuts deaf until
  /// something focusable was clicked. Focus that is already inside the window
  /// is left alone.
  void _onPointerDown(PointerDownEvent event) {
    if (!_node.hasFocus) _node.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onPointerDown,
      behavior: HitTestBehavior.translucent,
      child: Focus(
        focusNode: _node,
        autofocus: true,
        onKeyEvent: _onKeyEvent,
        child: widget.child,
      ),
    );
  }
}
