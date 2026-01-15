import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import '../models/filter_registry.dart';
import '../models/filter_schema.dart';

/// Service for loading and managing filter schemas.
///
/// Initializes the [FilterRegistry] with built-in filters and
/// scans for user-defined filters in the config directory.
class FilterLoader {
  static final FilterLoader instance = FilterLoader._();
  FilterLoader._();

  bool _isInitialized = false;

  /// Whether the filter loader has been initialized.
  bool get isInitialized => _isInitialized;

  /// Initialize the filter system.
  ///
  /// This loads built-in filters from assets and user filters from
  /// the user's config directory (~/.vapourbox/filters/).
  Future<void> initialize() async {
    if (_isInitialized) return;

    await FilterRegistry.instance.initialize();
    _isInitialized = true;

    print('FilterLoader: Loaded ${FilterRegistry.instance.filters.length} filters');
  }

  /// Reload all filters.
  Future<void> reload() async {
    await FilterRegistry.instance.reload();
  }

  /// Get the user filter directory path.
  Future<Directory> getUserFilterDirectory() async {
    String? home;
    if (Platform.isWindows) {
      home = Platform.environment['USERPROFILE'];
    } else {
      home = Platform.environment['HOME'];
    }

    if (home == null) {
      throw StateError('Could not determine home directory');
    }

    return Directory(path.join(home, '.vapourbox', 'filters'));
  }

  /// Ensure the user filter directory exists.
  Future<Directory> ensureUserFilterDirectory() async {
    final dir = await getUserFilterDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Install a filter from a JSON file path.
  Future<FilterSchema> installFilter(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw FileSystemException('Filter file not found', filePath);
    }

    final userDir = await ensureUserFilterDirectory();
    final fileName = path.basename(filePath);
    final targetPath = path.join(userDir.path, fileName);

    // Copy file to user directory
    await file.copy(targetPath);

    // Reload to pick up new filter
    await reload();

    // Return the loaded schema
    final schemaId = path.basenameWithoutExtension(fileName);
    final schema = FilterRegistry.instance.get(schemaId);
    if (schema == null) {
      throw StateError('Failed to load installed filter: $schemaId');
    }

    return schema;
  }

  /// Uninstall a user filter by ID.
  Future<void> uninstallFilter(String filterId) async {
    final schema = FilterRegistry.instance.get(filterId);
    if (schema == null) {
      throw StateError('Filter not found: $filterId');
    }

    if (schema.source != 'user') {
      throw StateError('Cannot uninstall built-in filter: $filterId');
    }

    final userDir = await getUserFilterDirectory();
    final filePath = path.join(userDir.path, '$filterId.json');
    final file = File(filePath);

    if (await file.exists()) {
      await file.delete();
    }

    await reload();
  }

  /// Get list of user-installed filters.
  List<FilterSchema> getUserFilters() {
    return FilterRegistry.instance.filters
        .where((f) => f.source == 'user')
        .toList();
  }

  /// Get list of built-in filters.
  List<FilterSchema> getBuiltInFilters() {
    return FilterRegistry.instance.filters
        .where((f) => f.source == 'builtin')
        .toList();
  }

  /// Validate a filter schema JSON string.
  ///
  /// Returns a list of validation errors, or empty if valid.
  List<String> validateSchema(String json) {
    final errors = <String>[];

    try {
      final parsed = FilterSchema.fromJson(
        Map<String, dynamic>.from(
          (json.isNotEmpty) ? (Map<String, dynamic>.from(
            (const JsonCodec().decode(json) as Map<String, dynamic>)
          )) : <String, dynamic>{},
        ),
      );

      // Check required fields
      if (parsed.id.isEmpty) {
        errors.add('Missing required field: id');
      }
      if (parsed.name.isEmpty) {
        errors.add('Missing required field: name');
      }
      if (parsed.methods.isEmpty) {
        errors.add('At least one method is required');
      }
      if (parsed.parameters.isEmpty) {
        errors.add('At least one parameter is required');
      }

      // Check method references
      for (final method in parsed.methods) {
        for (final paramId in method.parameters) {
          if (!parsed.parameters.containsKey(paramId)) {
            errors.add('Method "${method.id}" references unknown parameter: $paramId');
          }
        }
      }
    } catch (e) {
      errors.add('Invalid JSON: $e');
    }

    return errors;
  }
}
