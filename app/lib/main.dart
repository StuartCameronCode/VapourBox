import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:rhttp/rhttp.dart';
import 'package:window_manager/window_manager.dart';

import 'models/filter_registry.dart';
import 'services/dependency_manager.dart';
import 'services/preset_service.dart';
import 'services/update_checker.dart';
import 'viewmodels/main_viewmodel.dart';
import 'views/dependency_download_dialog.dart';
import 'views/main_window.dart';
import 'views/update_available_dialog.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize rhttp (required for Rust FFI on Windows)
  await Rhttp.init();

  // Initialize window manager for desktop
  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(
    size: Size(900, 700),
    minimumSize: Size(700, 550),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.normal,
    title: 'VapourBox',
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const VapourBoxApp());
}

class VapourBoxApp extends StatelessWidget {
  const VapourBoxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VapourBox',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: const AppStartupWrapper(),
    );
  }
}

/// Wrapper widget that handles dependency checking before showing the main app.
class AppStartupWrapper extends StatefulWidget {
  const AppStartupWrapper({super.key});

  @override
  State<AppStartupWrapper> createState() => _AppStartupWrapperState();
}

class _AppStartupWrapperState extends State<AppStartupWrapper> {
  bool _isReady = false;
  bool _dependenciesOk = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      // Check dependencies first
      final status = await DependencyManager.instance.checkDependencies();

      if (status != DependencyStatus.installed) {
        // Dependencies need to be downloaded
        if (mounted) {
          final success = await DependencyDownloadDialog.show(context, status);
          if (!success) {
            // User cancelled, exit app
            setState(() {
              _errorMessage = 'Dependencies are required to run VapourBox.';
            });
            return;
          }
        }
      }

      // Initialize other services
      await FilterRegistry.instance.initialize();
      await PresetService.instance.initialize();

      setState(() {
        _isReady = true;
        _dependenciesOk = true;
      });

      // Check for updates asynchronously (non-blocking)
      _checkForUpdatesAsync();
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
      });
    }
  }

  /// Check for updates in the background without blocking startup.
  Future<void> _checkForUpdatesAsync() async {
    // Wait for the next frame to ensure UI is fully built
    await Future.delayed(const Duration(milliseconds: 500));

    // Check if updates are enabled
    final enabled = await UpdateChecker.instance.isEnabled();
    if (!enabled) return;

    // Check for updates
    final updateInfo = await UpdateChecker.instance.checkForUpdates();
    if (updateInfo != null && mounted) {
      // Show update dialog
      UpdateAvailableDialog.show(context, updateInfo);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_errorMessage != null) {
      return _buildErrorScreen();
    }

    if (!_isReady) {
      return _buildLoadingScreen();
    }

    return ChangeNotifierProvider(
      create: (_) => MainViewModel(),
      child: const MainWindow(),
    );
  }

  Widget _buildLoadingScreen() {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.video_settings,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 24),
            Text(
              'VapourBox',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 48),
            const SizedBox(
              width: 200,
              child: LinearProgressIndicator(),
            ),
            const SizedBox(height: 16),
            Text(
              'Starting up...',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorScreen() {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 64,
              color: Colors.red[400],
            ),
            const SizedBox(height: 24),
            Text(
              'Failed to Start',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: 400,
              child: Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            const SizedBox(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton(
                  onPressed: () {
                    // Exit app
                    windowManager.close();
                  },
                  child: const Text('Exit'),
                ),
                const SizedBox(width: 16),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _errorMessage = null;
                    });
                    _initialize();
                  },
                  child: const Text('Retry'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
