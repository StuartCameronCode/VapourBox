import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../models/processing_preset.dart';

/// Service for loading and saving processing presets.
///
/// Presets are stored in ~/.vapourbox/presets/ as JSON files.
class PresetService {
  static final PresetService instance = PresetService._();
  PresetService._();

  bool _isInitialized = false;
  final List<ProcessingPreset> _presets = [];

  /// Whether the preset service has been initialized.
  bool get isInitialized => _isInitialized;

  /// All available presets (built-in + user).
  List<ProcessingPreset> get presets => List.unmodifiable(_presets);

  /// User presets only.
  List<ProcessingPreset> get userPresets =>
      _presets.where((p) => !p.isBuiltIn).toList();

  /// Built-in presets only.
  List<ProcessingPreset> get builtInPresets =>
      _presets.where((p) => p.isBuiltIn).toList();

  /// Initialize the preset system.
  Future<void> initialize() async {
    if (_isInitialized) return;

    // Load built-in presets
    _presets.addAll(ProcessingPreset.builtInPresets());

    // Load user presets
    await _loadUserPresets();

    _isInitialized = true;
    print('PresetService: Loaded ${_presets.length} presets (${userPresets.length} user)');
  }

  /// Get the presets directory path.
  Future<Directory> getPresetsDirectory() async {
    String? home;
    if (Platform.isWindows) {
      home = Platform.environment['USERPROFILE'];
    } else {
      home = Platform.environment['HOME'];
    }

    if (home == null) {
      throw StateError('Could not determine home directory');
    }

    return Directory(path.join(home, '.vapourbox', 'presets'));
  }

  /// Ensure the presets directory exists.
  Future<Directory> _ensurePresetsDirectory() async {
    final dir = await getPresetsDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Load user presets from disk.
  Future<void> _loadUserPresets() async {
    try {
      final dir = await getPresetsDirectory();
      if (!await dir.exists()) return;

      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.json')) {
          try {
            final content = await entity.readAsString();
            final json = jsonDecode(content) as Map<String, dynamic>;
            final preset = ProcessingPreset.fromJson(json);
            // Mark user presets as non-built-in
            _presets.add(preset.copyWith(isBuiltIn: false));
          } catch (e) {
            print('Failed to load preset from ${entity.path}: $e');
          }
        }
      }
    } catch (e) {
      print('Failed to load user presets: $e');
    }
  }

  /// Save a preset to disk.
  Future<void> savePreset(ProcessingPreset preset) async {
    if (preset.isBuiltIn) {
      throw ArgumentError('Cannot save built-in presets');
    }

    final dir = await _ensurePresetsDirectory();
    final filename = _sanitizeFilename(preset.name) + '.json';
    final file = File(path.join(dir.path, filename));

    final json = jsonEncode(preset.toJson());
    await file.writeAsString(json, flush: true);

    // Update in-memory list
    final existingIndex = _presets.indexWhere((p) => p.id == preset.id);
    if (existingIndex >= 0) {
      _presets[existingIndex] = preset;
    } else {
      _presets.add(preset);
    }
  }

  /// Delete a user preset.
  Future<void> deletePreset(ProcessingPreset preset) async {
    if (preset.isBuiltIn) {
      throw ArgumentError('Cannot delete built-in presets');
    }

    // Remove from disk
    final dir = await getPresetsDirectory();
    final filename = _sanitizeFilename(preset.name) + '.json';
    final file = File(path.join(dir.path, filename));
    if (await file.exists()) {
      await file.delete();
    }

    // Also try finding by ID in case filename doesn't match
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        try {
          final content = await entity.readAsString();
          final json = jsonDecode(content) as Map<String, dynamic>;
          if (json['id'] == preset.id) {
            await entity.delete();
            break;
          }
        } catch (_) {}
      }
    }

    // Remove from in-memory list
    _presets.removeWhere((p) => p.id == preset.id);
  }

  /// Find a preset by name.
  ProcessingPreset? findByName(String name) {
    return _presets.where((p) => p.name == name).firstOrNull;
  }

  /// Find a preset by ID.
  ProcessingPreset? findById(String id) {
    return _presets.where((p) => p.id == id).firstOrNull;
  }

  /// Reload presets from disk.
  Future<void> reload() async {
    _presets.clear();
    _presets.addAll(ProcessingPreset.builtInPresets());
    await _loadUserPresets();
  }

  /// Sanitize a filename by removing invalid characters.
  String _sanitizeFilename(String name) {
    return name
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .toLowerCase();
  }
}
