import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../models/processing_preset.dart';

/// A preset file on disk that could not be read.
///
/// These used to be swallowed by a `print()`, which in a release build means
/// the preset simply never appears and nothing says why. That is tolerable for
/// a file the app wrote itself; it is the wrong behaviour for one a user
/// hand-edited or was sent, which is exactly what import makes common.
class PresetLoadFailure {
  const PresetLoadFailure(this.path, this.reason);

  /// Full path of the file that failed.
  final String path;

  /// Why, in terms a user can act on.
  final String reason;

  /// Just the filename, for display.
  String get filename => path.split(RegExp(r'[/\\]')).last;
}

/// What reading a preset file found, before anything is committed to disk.
///
/// Import is two-phase on purpose: a preset carries `customVapoursynth` and
/// `customFfmpegArgs`, and the first of those is Python that the worker
/// executes. Importing someone else's preset is therefore closer to running
/// their script than to loading their settings, and the user has to be able to
/// see that before saying yes — so inspecting a file and committing it are
/// separate steps.
class PresetImportPreview {
  const PresetImportPreview({
    this.preset,
    this.error,
    this.customVapoursynth = '',
    this.customFfmpegArgs = '',
    this.existingWithSameId,
    this.existingWithSameName,
  });

  /// The preset read from the file, or null when [error] is set.
  final ProcessingPreset? preset;

  /// Why the file could not be read, in terms a user can act on.
  final String? error;

  /// Custom VapourSynth the preset would bring with it. **This is Python, run
  /// in the worker process.**
  final String customVapoursynth;

  /// Custom FFmpeg arguments the preset would bring with it.
  final String customFfmpegArgs;

  /// An already-installed preset with the same id — i.e. this file is another
  /// copy of one the user already has, so importing updates it in place.
  final ProcessingPreset? existingWithSameId;

  /// An already-installed preset with the same *name* but a different id.
  /// Both can coexist, but the menu would show two identical labels.
  final ProcessingPreset? existingWithSameName;

  bool get ok => preset != null;

  /// Whether the file carries executable extras that deserve an explicit
  /// yes before they are installed.
  bool get carriesCustomCode =>
      customVapoursynth.trim().isNotEmpty || customFfmpegArgs.trim().isNotEmpty;
}

/// Service for loading and saving processing presets.
///
/// Presets are stored in ~/.vapourbox/presets/ as JSON files.
class PresetService {
  static final PresetService instance = PresetService._();
  PresetService._();

  bool _isInitialized = false;
  final List<ProcessingPreset> _presets = [];
  final List<PresetLoadFailure> _loadFailures = [];

  /// Overrides the presets directory. Tests only — the real path is derived
  /// from the home directory, which a test cannot safely move.
  Directory? directoryOverride;

  /// Whether the preset service has been initialized.
  bool get isInitialized => _isInitialized;

  /// Preset files that could not be read on the last load.
  ///
  /// Surfaced in the preset menu rather than only logged: a preset that
  /// silently fails to appear is indistinguishable from one that was never
  /// saved.
  List<PresetLoadFailure> get loadFailures => List.unmodifiable(_loadFailures);

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
    debugPrint('PresetService: loaded ${_presets.length} presets '
        '(${userPresets.length} user, ${_loadFailures.length} failed)');
  }

  /// Get the presets directory path.
  Future<Directory> getPresetsDirectory() async {
    final override = directoryOverride;
    if (override != null) return override;

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
    _loadFailures.clear();
    try {
      final dir = await getPresetsDirectory();
      if (!await dir.exists()) return;

      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.json')) {
          try {
            final content = await entity.readAsString();
            final json = jsonDecode(content) as Map<String, dynamic>;
            final preset = ProcessingPreset.fromJson(json);
            // Never take `isBuiltIn` from a file. A built-in cannot be deleted
            // or overwritten, so a preset claiming to be one would be stuck in
            // the menu permanently — and the flag survives decoding, verified.
            _presets.add(preset.copyWith(isBuiltIn: false));
          } catch (e) {
            _loadFailures.add(PresetLoadFailure(entity.path, describeJsonError(e)));
          }
        }
      }
    } catch (e) {
      _loadFailures.add(PresetLoadFailure(
        (await getPresetsDirectory()).path,
        'The presets folder could not be read: $e',
      ));
    }
  }

  /// Turn a decode failure into something a user can act on.
  ///
  /// The raw exceptions are accurate and unreadable — a `FormatException` from
  /// `jsonDecode` quotes a byte offset, and json_serializable throws a bare
  /// `TypeError` naming Dart types the user has never heard of.
  static String describeJsonError(Object e) {
    if (e is FormatException) {
      return 'The file is not valid JSON.';
    }
    if (e is TypeError) {
      return 'The file is JSON but not a VapourBox preset, or a setting in it '
          'has the wrong type.';
    }
    return e.toString();
  }

  /// Save a preset to disk.
  Future<void> savePreset(ProcessingPreset preset) async {
    if (preset.isBuiltIn) {
      throw ArgumentError('Cannot save built-in presets');
    }

    final dir = await _ensurePresetsDirectory();
    final file = File(path.join(dir.path, _filenameFor(preset)));

    await file.writeAsString(encodePreset(preset), flush: true);

    // Remove any older file holding this same preset under a different name.
    // Filenames used to be derived from the preset's name, so renaming one
    // left the original behind as a duplicate, and two names that sanitize
    // alike ("VHS Cleanup" and "vhs cleanup") overwrote each other silently.
    await _removeOtherFilesWithId(dir, preset.id, keep: file.path);

    // Update in-memory list
    final existingIndex = _presets.indexWhere((p) => p.id == preset.id);
    if (existingIndex >= 0) {
      _presets[existingIndex] = preset;
    } else {
      _presets.add(preset);
    }
  }

  /// The on-disk filename for a preset: its id, not its name.
  ///
  /// The name is still what the user sees — it lives inside the file — but it
  /// makes a poor filename. Two different presets can share one, renaming
  /// changes it, and sanitizing collapses distinct names together.
  static String _filenameFor(ProcessingPreset preset) => '${preset.id}.json';

  /// Pretty-printed, because a preset is now a file people send each other and
  /// read; one long line is hostile to both.
  static String encodePreset(ProcessingPreset preset) =>
      const JsonEncoder.withIndent('  ').convert(preset.toJson());

  /// Delete every file in [dir] whose JSON carries [id], except [keep].
  Future<void> _removeOtherFilesWithId(
    Directory dir,
    String id, {
    required String keep,
  }) async {
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      if (entity.path == keep) continue;
      try {
        final json = jsonDecode(await entity.readAsString());
        if (json is Map && json['id'] == id) {
          await entity.delete();
        }
      } catch (_) {
        // An unreadable file is not ours to delete — it is reported as a load
        // failure instead, where the user can decide.
      }
    }
  }

  /// Write [preset] to [destinationPath] so it can be shared.
  ///
  /// Deliberately the same JSON as the on-disk copy, so exporting is a copy
  /// and importing is a validated copy back. A separate "export format" would
  /// be a second thing to keep in step for no gain.
  Future<void> exportPreset(ProcessingPreset preset, String destinationPath) async {
    await File(destinationPath).writeAsString(encodePreset(preset), flush: true);
  }

  /// The filename to suggest when exporting [preset].
  static String suggestedExportFilename(ProcessingPreset preset) {
    final base = _sanitizeFilenameStatic(preset.name);
    return '${base.isEmpty ? 'preset' : base}.json';
  }

  /// Read a preset file and report what importing it would mean, without
  /// changing anything.
  Future<PresetImportPreview> inspectPresetFile(String sourcePath) async {
    final file = File(sourcePath);
    if (!await file.exists()) {
      return const PresetImportPreview(error: 'That file no longer exists.');
    }

    ProcessingPreset preset;
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, dynamic>) {
        return const PresetImportPreview(
            error: 'That file is JSON, but not a preset.');
      }
      // As on the load path: never trust `isBuiltIn` from a file.
      preset = ProcessingPreset.fromJson(json).copyWith(isBuiltIn: false);
    } catch (e) {
      return PresetImportPreview(error: describeJsonError(e));
    }

    if (preset.name.trim().isEmpty) {
      return const PresetImportPreview(
          error: 'That preset has no name, so there would be nothing to pick '
              'it by.');
    }

    return PresetImportPreview(
      preset: preset,
      customVapoursynth: preset.encodingSettings.customVapoursynth,
      customFfmpegArgs: preset.encodingSettings.customFfmpegArgs,
      existingWithSameId: findById(preset.id),
      existingWithSameName: _presets
          .where((p) => p.name == preset.name && p.id != preset.id)
          .firstOrNull,
    );
  }

  /// Install a preset that [inspectPresetFile] already validated.
  ///
  /// [stripCustomCode] drops the custom VapourSynth and FFmpeg arguments,
  /// which is the safe way to accept someone else's filter settings without
  /// also accepting their Python.
  Future<ProcessingPreset> commitImport(
    PresetImportPreview preview, {
    bool stripCustomCode = false,
  }) async {
    final source = preview.preset;
    if (source == null) {
      throw StateError('commitImport called on a preview that failed to read');
    }

    var preset = source.copyWith(isBuiltIn: false);
    if (stripCustomCode) {
      preset = preset.copyWith(
        encodingSettings: preset.encodingSettings.copyWith(
          customVapoursynth: '',
          customFfmpegArgs: '',
        ),
      );
    }

    await savePreset(preset);
    return preset;
  }

  /// Delete a user preset.
  Future<void> deletePreset(ProcessingPreset preset) async {
    if (preset.isBuiltIn) {
      throw ArgumentError('Cannot delete built-in presets');
    }

    // Remove from disk, by id only.
    //
    // This used to delete `<sanitized-name>.json` first and then scan for the
    // id, which deletes the wrong file whenever two presets' names sanitize to
    // the same thing — "VHS Cleanup" and "vhs cleanup" both produce
    // `vhs_cleanup.json`. Deleting one would take the other's file with it.
    final dir = await getPresetsDirectory();
    if (await dir.exists()) {
      await _removeOtherFilesWithId(dir, preset.id, keep: '');
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
  ///
  /// No longer decides where a preset is stored — that is the id now — so this
  /// only has to produce something reasonable to *suggest* in a save dialog.
  /// Collisions here are harmless: the user sees the name and can change it.
  static String _sanitizeFilenameStatic(String name) {
    return name
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .toLowerCase();
  }
}
