import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The app's colour themes (issue #102), chosen in Settings -> General ->
/// Appearance.
enum AppTheme {
  /// Light or dark to match the operating system — the default, and the only
  /// behaviour before themes existed.
  auto,
  light,
  dark,

  /// The Monokai Pro editor palette: pastel purple, cyan, yellow and pink
  /// accents on a neutral dark grey. Always dark.
  monokai,

  /// Purple accents with the six-stripe rainbow under the toolbar and on the
  /// title. Follows the system's light/dark setting, like [auto].
  pride;

  static AppTheme fromName(String? name) {
    return AppTheme.values.firstWhere(
      (theme) => theme.name == name,
      orElse: () => AppTheme.auto,
    );
  }

  String get label {
    switch (this) {
      case AppTheme.auto:
        return 'Auto';
      case AppTheme.light:
        return 'Light';
      case AppTheme.dark:
        return 'Dark';
      case AppTheme.monokai:
        return 'Monokai';
      case AppTheme.pride:
        return 'Pride';
    }
  }

  String get description {
    switch (this) {
      case AppTheme.auto:
        return 'Follow the system light/dark setting';
      case AppTheme.light:
        return 'Always light';
      case AppTheme.dark:
        return 'Always dark';
      case AppTheme.monokai:
        return 'Dark grey with pastel Monokai accents';
      case AppTheme.pride:
        return 'Rainbow accents; follows the system light/dark setting';
    }
  }

  /// Which of [light]/[dark] MaterialApp shows for this theme.
  ThemeMode get themeMode {
    switch (this) {
      case AppTheme.auto:
      case AppTheme.pride:
        return ThemeMode.system;
      case AppTheme.light:
        return ThemeMode.light;
      case AppTheme.dark:
      case AppTheme.monokai:
        return ThemeMode.dark;
    }
  }

  /// The theme MaterialApp uses in light mode.
  ThemeData get lightTheme => AppThemes.build(this, Brightness.light);

  /// The theme MaterialApp uses in dark mode.
  ThemeData get darkTheme => AppThemes.build(this, Brightness.dark);
}

/// Decorations a theme can add beyond [ColorScheme], read by the few widgets
/// that draw them (the toolbar stripe and title).
@immutable
class AppDecorations extends ThemeExtension<AppDecorations> {
  /// Colours for a stripe under the toolbar and a gradient on the title, or
  /// null to draw neither.
  final List<Color>? accentStripe;

  const AppDecorations({this.accentStripe});

  static AppDecorations of(BuildContext context) =>
      Theme.of(context).extension<AppDecorations>() ?? const AppDecorations();

  @override
  AppDecorations copyWith({List<Color>? accentStripe}) =>
      AppDecorations(accentStripe: accentStripe ?? this.accentStripe);

  @override
  AppDecorations lerp(AppDecorations? other, double t) =>
      t < 0.5 ? this : (other ?? this);
}

/// Builds [ThemeData] for each [AppTheme].
class AppThemes {
  /// The six-stripe rainbow flag.
  static const List<Color> prideStripe = [
    Color(0xFFE40303),
    Color(0xFFFF8C00),
    Color(0xFFFFED00),
    Color(0xFF008026),
    Color(0xFF004CFF),
    Color(0xFF732982),
  ];

  static ThemeData build(AppTheme theme, Brightness brightness) {
    switch (theme) {
      case AppTheme.auto:
      case AppTheme.light:
      case AppTheme.dark:
        return _seeded(Colors.blue, brightness);
      case AppTheme.monokai:
        return _monokai();
      case AppTheme.pride:
        return _seeded(const Color(0xFF8E44AD), brightness).copyWith(
          extensions: const [AppDecorations(accentStripe: prideStripe)],
        );
    }
  }

  static ThemeData _seeded(Color seed, Brightness brightness) {
    return ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: seed,
        brightness: brightness,
      ),
      useMaterial3: true,
    );
  }

  // The Monokai Pro palette: pastel accents on a neutral dark grey. Each
  // accent has its own role so no one colour dominates — purple for primary
  // actions and selection, cyan secondary, yellow tertiary, pink for errors.
  // Green is deliberately not a role colour: the in/out markers and the
  // completed state already use green, and a green primary turned the whole
  // window green.
  static const Color _monokaiBackground = Color(0xFF2D2A2E);
  static const Color _monokaiDarker = Color(0xFF221F22);
  static const Color _monokaiForeground = Color(0xFFFCFCFA);
  static const Color _monokaiDimText = Color(0xFFC1C0C0);
  static const Color _monokaiComment = Color(0xFF727072);
  static const Color _monokaiLine = Color(0xFF403E41);
  static const Color _monokaiPurple = Color(0xFFAB9DF2);
  static const Color _monokaiCyan = Color(0xFF78DCE8);
  static const Color _monokaiYellow = Color(0xFFFFD866);
  static const Color _monokaiPink = Color(0xFFFF6188);

  static ThemeData _monokai() {
    final scheme = ColorScheme.fromSeed(
      seedColor: _monokaiPurple,
      brightness: Brightness.dark,
    ).copyWith(
      primary: _monokaiPurple,
      onPrimary: _monokaiDarker,
      primaryContainer: const Color(0xFF4A4458),
      onPrimaryContainer: _monokaiForeground,
      secondary: _monokaiCyan,
      onSecondary: _monokaiDarker,
      secondaryContainer: const Color(0xFF34494D),
      onSecondaryContainer: _monokaiForeground,
      tertiary: _monokaiYellow,
      onTertiary: _monokaiDarker,
      tertiaryContainer: const Color(0xFF55492D),
      onTertiaryContainer: _monokaiForeground,
      error: _monokaiPink,
      onError: _monokaiDarker,
      errorContainer: const Color(0xFF5C2F3A),
      onErrorContainer: _monokaiForeground,
      surface: _monokaiBackground,
      onSurface: _monokaiForeground,
      onSurfaceVariant: _monokaiDimText,
      surfaceTint: Colors.transparent,
      surfaceDim: _monokaiDarker,
      surfaceBright: const Color(0xFF4A474B),
      surfaceContainerLowest: _monokaiDarker,
      surfaceContainerLow: const Color(0xFF29262A),
      surfaceContainer: const Color(0xFF333034),
      surfaceContainerHigh: const Color(0xFF39363A),
      surfaceContainerHighest: _monokaiLine,
      outline: _monokaiComment,
      outlineVariant: const Color(0xFF4F4D50),
      inverseSurface: _monokaiForeground,
      onInverseSurface: _monokaiBackground,
      inversePrimary: const Color(0xFF6A5ACD),
    );
    return ThemeData(colorScheme: scheme, useMaterial3: true);
  }
}

/// The chosen [AppTheme], persisted in shared_preferences under `appTheme`.
///
/// Provided above the MaterialApp so a change repaints the whole app,
/// including open dialogs. Call [initialize] before `runApp` so the first
/// frame is already in the saved theme rather than flashing from the default.
class ThemeService extends ChangeNotifier {
  static final ThemeService instance = ThemeService._();
  ThemeService._();

  static const String _prefsKey = 'appTheme';

  AppTheme _theme = AppTheme.auto;
  bool _loaded = false;

  AppTheme get theme => _theme;

  /// Load the saved choice. Safe to call again; only the first call reads
  /// storage.
  Future<void> initialize() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _theme = AppTheme.fromName(prefs.getString(_prefsKey));
    } catch (_) {
      // Unreadable preferences shouldn't stop the app starting.
      _theme = AppTheme.auto;
    }
    _loaded = true;
  }

  Future<void> setTheme(AppTheme value) async {
    if (_theme == value && _loaded) return;

    _theme = value;
    _loaded = true;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, value.name);
    } catch (_) {
      // Keep the in-memory choice for this session even if it can't be saved.
    }
  }

  /// Reset to the unloaded default. Tests only — the singleton outlives a
  /// single test case otherwise.
  @visibleForTesting
  void resetForTesting() {
    _theme = AppTheme.auto;
    _loaded = false;
  }
}
