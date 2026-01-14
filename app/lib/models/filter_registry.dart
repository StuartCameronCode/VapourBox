import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import 'filter_schema.dart';

/// Registry for all available filter schemas.
///
/// Loads built-in filters from assets and user filters from the filesystem.
class FilterRegistry {
  static final FilterRegistry instance = FilterRegistry._();
  FilterRegistry._();

  final Map<String, FilterSchema> _filters = {};
  final List<String> _loadOrder = [];
  bool _isLoaded = false;

  /// Whether the registry has been initialized.
  bool get isLoaded => _isLoaded;

  /// Get all registered filters in order.
  List<FilterSchema> get filters =>
      _loadOrder.map((id) => _filters[id]!).toList();

  /// Get all filters sorted by their order property.
  List<FilterSchema> get orderedFilters =>
      filters.toList()..sort((a, b) => a.order.compareTo(b.order));

  /// Get filters by category.
  List<FilterSchema> getByCategory(String category) =>
      filters.where((f) => f.category == category).toList();

  /// Get a filter by ID.
  FilterSchema? get(String id) => _filters[id];

  /// Check if a filter exists.
  bool has(String id) => _filters.containsKey(id);

  /// Initialize the registry by loading all filters.
  Future<void> initialize() async {
    if (_isLoaded) return;

    // Load built-in filters first
    await _loadBuiltInFilters();

    // Then load user filters (can override built-in)
    await _loadUserFilters();

    _isLoaded = true;
  }

  /// Reload all filters (useful after user adds new filters).
  Future<void> reload() async {
    _filters.clear();
    _loadOrder.clear();
    _isLoaded = false;
    await initialize();
  }

  /// Load built-in filters from app assets.
  Future<void> _loadBuiltInFilters() async {
    try {
      // Load the manifest to get list of filter files
      final manifestJson =
          await rootBundle.loadString('assets/filters/manifest.json');
      final manifest = json.decode(manifestJson) as List;

      for (final filename in manifest) {
        try {
          final schemaJson =
              await rootBundle.loadString('assets/filters/core/$filename');
          final schema = FilterSchema.fromJson(json.decode(schemaJson));
          schema.source = 'builtin';
          _register(schema);
        } catch (e) {
          print('Failed to load built-in filter $filename: $e');
        }
      }
    } catch (e) {
      // Manifest doesn't exist yet, that's fine during development
      print('No filter manifest found: $e');
    }
  }

  /// Load user filters from the user's filter directory.
  Future<void> _loadUserFilters() async {
    final userDir = await _getUserFilterDirectory();
    if (userDir == null || !await userDir.exists()) return;

    await for (final entity in userDir.list(recursive: true)) {
      if (entity is File && entity.path.endsWith('.json')) {
        try {
          final content = await entity.readAsString();
          final schema = FilterSchema.fromJson(json.decode(content));
          schema.source = 'user';
          _register(schema);
        } catch (e) {
          print('Failed to load user filter ${entity.path}: $e');
        }
      }
    }
  }

  /// Get the user filter directory path.
  Future<Directory?> _getUserFilterDirectory() async {
    String? home;
    if (Platform.isWindows) {
      home = Platform.environment['USERPROFILE'];
    } else {
      home = Platform.environment['HOME'];
    }

    if (home == null) return null;

    return Directory(path.join(home, '.vapourbox', 'filters'));
  }

  /// Register a filter schema.
  void _register(FilterSchema schema) {
    // Remove from load order if already exists (for overrides)
    _loadOrder.remove(schema.id);

    _filters[schema.id] = schema;
    _loadOrder.add(schema.id);
  }

  /// Register a filter from JSON (useful for testing).
  void registerFromJson(Map<String, dynamic> json, {String source = 'dynamic'}) {
    final schema = FilterSchema.fromJson(json);
    schema.source = source;
    _register(schema);
  }

  /// Validate that all required dependencies are available.
  Future<Map<String, List<String>>> validateDependencies() async {
    final missing = <String, List<String>>{};

    for (final filter in filters) {
      final deps = filter.dependencies;
      if (deps == null) continue;

      final filterMissing = <String>[];

      // Check VS plugins
      if (deps.vsPlugins != null) {
        for (final plugin in deps.vsPlugins!) {
          // This would need to be implemented based on platform
          // For now, we'll assume they're available
        }
      }

      if (filterMissing.isNotEmpty) {
        missing[filter.id] = filterMissing;
      }
    }

    return missing;
  }
}
