import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/dynamic_parameters.dart';
import 'package:vapourbox/models/filter_schema.dart';

void main() {
  group('DynamicParameters', () {
    test('creates from schema defaults', () {
      const schemaJson = '''
{
  "id": "test_filter",
  "version": "1.0.0",
  "name": "Test",
  "description": "Test filter",
  "category": "test",
  "methods": [],
  "parameters": {
    "enabled": { "type": "boolean", "default": false },
    "strength": { "type": "number", "default": 1.5 },
    "radius": { "type": "integer", "default": 3 },
    "method": { "type": "enum", "default": "fast", "options": ["fast", "slow"] }
  },
  "codeTemplate": { "generate": "method" }
}
''';

      final schema = FilterSchema.fromJson(jsonDecode(schemaJson));
      final params = DynamicParameters.fromSchema(schema, enabled: true);

      expect(params.filterId, 'test_filter');
      expect(params.enabled, true);
      expect(params.getBool('enabled'), false);
      expect(params.getDouble('strength'), 1.5);
      expect(params.getInt('radius'), 3);
      expect(params.getString('method'), 'fast');
    });

    test('get returns typed values', () {
      final params = DynamicParameters(
        filterId: 'test',
        enabled: true,
        values: {
          'boolVal': true,
          'intVal': 42,
          'doubleVal': 3.14,
          'stringVal': 'hello',
        },
      );

      expect(params.get<bool>('boolVal'), true);
      expect(params.get<int>('intVal'), 42);
      expect(params.get<double>('doubleVal'), 3.14);
      expect(params.get<String>('stringVal'), 'hello');
      expect(params.get<String>('nonexistent'), isNull);
    });

    test('type coercion works for numbers', () {
      final params = DynamicParameters(
        filterId: 'test',
        enabled: true,
        values: {
          'intAsDouble': 5,
          'doubleAsInt': 3.7,
        },
      );

      // int to double
      expect(params.getDouble('intAsDouble'), 5.0);

      // double to int (truncates)
      expect(params.getInt('doubleAsInt'), 3);
    });

    test('withEnabled creates new instance', () {
      final params = DynamicParameters(
        filterId: 'test',
        enabled: false,
        values: {'key': 'value'},
      );

      final newParams = params.withEnabled(true);

      expect(params.enabled, false);
      expect(newParams.enabled, true);
      expect(newParams.filterId, 'test');
      expect(newParams.values['key'], 'value');
    });

    test('withValue creates new instance with updated value', () {
      final params = DynamicParameters(
        filterId: 'test',
        enabled: true,
        values: {'a': 1, 'b': 2},
      );

      final newParams = params.withValue('a', 10);

      expect(params.values['a'], 1);
      expect(newParams.values['a'], 10);
      expect(newParams.values['b'], 2);
    });

    test('withValues merges multiple values', () {
      final params = DynamicParameters(
        filterId: 'test',
        enabled: true,
        values: {'a': 1, 'b': 2, 'c': 3},
      );

      final newParams = params.withValues({'a': 10, 'b': 20});

      expect(newParams.values['a'], 10);
      expect(newParams.values['b'], 20);
      expect(newParams.values['c'], 3);
    });

    test('method getter returns method string', () {
      final params = DynamicParameters(
        filterId: 'test',
        enabled: true,
        values: {'method': 'dehalo_alpha'},
      );

      expect(params.method, 'dehalo_alpha');
    });

    test('serializes to and from JSON', () {
      final params = DynamicParameters(
        filterId: 'test_filter',
        enabled: true,
        values: {
          'method': 'fast',
          'strength': 2.5,
          'radius': 3,
        },
      );

      final json = params.toJson();
      final restored = DynamicParameters.fromJson(json);

      expect(restored.filterId, params.filterId);
      expect(restored.enabled, params.enabled);
      expect(restored.values['method'], 'fast');
      expect(restored.values['strength'], 2.5);
      expect(restored.values['radius'], 3);
    });
  });

  group('DynamicPipeline', () {
    test('stores multiple filters', () {
      final pipeline = DynamicPipeline(
        filters: {
          'dehalo': DynamicParameters(
            filterId: 'dehalo',
            enabled: true,
            values: {'method': 'dehalo_alpha'},
          ),
          'deband': DynamicParameters(
            filterId: 'deband',
            enabled: false,
            values: {'range': 15},
          ),
        },
      );

      expect(pipeline.get('dehalo')?.enabled, true);
      expect(pipeline.get('deband')?.enabled, false);
      expect(pipeline.get('nonexistent'), isNull);
    });

    test('isEnabled checks filter state', () {
      final pipeline = DynamicPipeline(
        filters: {
          'dehalo': DynamicParameters(
            filterId: 'dehalo',
            enabled: true,
            values: {},
          ),
          'deband': DynamicParameters(
            filterId: 'deband',
            enabled: false,
            values: {},
          ),
        },
      );

      expect(pipeline.isEnabled('dehalo'), true);
      expect(pipeline.isEnabled('deband'), false);
      expect(pipeline.isEnabled('nonexistent'), false);
    });

    test('enabledFilterIds returns only enabled filters', () {
      final pipeline = DynamicPipeline(
        filters: {
          'dehalo': DynamicParameters(filterId: 'dehalo', enabled: true, values: {}),
          'deband': DynamicParameters(filterId: 'deband', enabled: false, values: {}),
          'sharpen': DynamicParameters(filterId: 'sharpen', enabled: true, values: {}),
        },
      );

      final enabled = pipeline.enabledFilterIds;
      expect(enabled, contains('dehalo'));
      expect(enabled, contains('sharpen'));
      expect(enabled, isNot(contains('deband')));
    });

    test('withFilter adds or updates filter', () {
      final pipeline = DynamicPipeline(
        filters: {
          'dehalo': DynamicParameters(filterId: 'dehalo', enabled: true, values: {}),
        },
      );

      final newPipeline = pipeline.withFilter(
        'deband',
        DynamicParameters(filterId: 'deband', enabled: true, values: {'range': 20}),
      );

      expect(pipeline.get('deband'), isNull);
      expect(newPipeline.get('deband')?.values['range'], 20);
      expect(newPipeline.get('dehalo')?.enabled, true);
    });

    test('withFilterEnabled toggles filter', () {
      final pipeline = DynamicPipeline(
        filters: {
          'dehalo': DynamicParameters(filterId: 'dehalo', enabled: false, values: {}),
        },
      );

      final newPipeline = pipeline.withFilterEnabled('dehalo', true);

      expect(pipeline.isEnabled('dehalo'), false);
      expect(newPipeline.isEnabled('dehalo'), true);
    });

    test('serializes to and from JSON', () {
      final pipeline = DynamicPipeline(
        filters: {
          'dehalo': DynamicParameters(
            filterId: 'dehalo',
            enabled: true,
            values: {'method': 'dehalo_alpha', 'rx': 2.0},
          ),
        },
      );

      final json = pipeline.toJson();
      final restored = DynamicPipeline.fromJson(json);

      expect(restored.get('dehalo')?.filterId, 'dehalo');
      expect(restored.get('dehalo')?.enabled, true);
      expect(restored.get('dehalo')?.values['method'], 'dehalo_alpha');
    });
  });
}
