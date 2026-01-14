import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vapourbox/models/filter_schema.dart';

void main() {
  group('FilterSchema', () {
    test('parses valid dehalo schema', () {
      const json = '''
{
  "id": "dehalo",
  "version": "1.0.0",
  "name": "Dehalo",
  "description": "Remove halo artifacts",
  "category": "restoration",
  "order": 4,
  "dependencies": {
    "plugins": ["havsfunc"],
    "vs_plugins": ["RemoveGrainVS.dll"]
  },
  "methods": [
    {
      "id": "dehalo_alpha",
      "name": "DeHalo Alpha",
      "description": "Standard dehalo",
      "function": "haf.DeHalo_alpha",
      "parameters": ["rx", "ry"]
    }
  ],
  "parameters": {
    "enabled": {
      "type": "boolean",
      "default": false,
      "ui": { "hidden": true }
    },
    "method": {
      "type": "enum",
      "default": "dehalo_alpha",
      "options": ["dehalo_alpha"],
      "ui": { "widget": "dropdown" }
    },
    "rx": {
      "type": "number",
      "default": 2.0,
      "min": 1.0,
      "max": 3.0,
      "vapoursynth": { "name": "rx" },
      "ui": { "label": "Horizontal Radius", "widget": "slider" }
    },
    "ry": {
      "type": "number",
      "default": 2.0,
      "min": 1.0,
      "max": 3.0,
      "vapoursynth": { "name": "ry" },
      "ui": { "label": "Vertical Radius", "widget": "slider" }
    }
  },
  "ui": {
    "sections": [
      {
        "title": "Method",
        "parameters": ["method"],
        "expanded": true
      }
    ]
  },
  "codeTemplate": {
    "imports": ["import havsfunc as haf"],
    "generate": "method"
  }
}
''';

      final schema = FilterSchema.fromJson(jsonDecode(json));

      expect(schema.id, 'dehalo');
      expect(schema.version, '1.0.0');
      expect(schema.name, 'Dehalo');
      expect(schema.category, 'restoration');
      expect(schema.order, 4);
      expect(schema.methods.length, 1);
      expect(schema.methods.first.id, 'dehalo_alpha');
      expect(schema.methods.first.function, 'haf.DeHalo_alpha');
      expect(schema.parameters.length, 4);
      expect(schema.parameters['rx']?.type, ParameterType.number);
      expect(schema.parameters['rx']?.defaultValue, 2.0);
      expect(schema.dependencies?.plugins, contains('havsfunc'));
    });

    test('getDefaults returns correct default values', () {
      const json = '''
{
  "id": "test",
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

      final schema = FilterSchema.fromJson(jsonDecode(json));
      final defaults = schema.getDefaults();

      expect(defaults['enabled'], false);
      expect(defaults['strength'], 1.5);
      expect(defaults['radius'], 3);
      expect(defaults['method'], 'fast');
    });

    test('getMethod returns correct method', () {
      const json = '''
{
  "id": "test",
  "version": "1.0.0",
  "name": "Test",
  "description": "Test filter",
  "category": "test",
  "methods": [
    { "id": "method_a", "name": "Method A", "function": "func_a", "parameters": [] },
    { "id": "method_b", "name": "Method B", "function": "func_b", "parameters": [] }
  ],
  "parameters": {},
  "codeTemplate": { "generate": "method" }
}
''';

      final schema = FilterSchema.fromJson(jsonDecode(json));

      expect(schema.getMethod('method_a')?.name, 'Method A');
      expect(schema.getMethod('method_b')?.function, 'func_b');
      expect(schema.getMethod('nonexistent'), isNull);
    });

    test('validate catches out-of-range values', () {
      const json = '''
{
  "id": "test",
  "version": "1.0.0",
  "name": "Test",
  "description": "Test filter",
  "category": "test",
  "methods": [],
  "parameters": {
    "value": { "type": "number", "default": 5.0, "min": 0.0, "max": 10.0 }
  },
  "codeTemplate": { "generate": "method" }
}
''';

      final schema = FilterSchema.fromJson(jsonDecode(json));

      // Valid value
      expect(schema.validate({'value': 5.0}), isEmpty);

      // Out of range - too high
      expect(schema.validate({'value': 15.0}), isNotEmpty);

      // Out of range - too low
      expect(schema.validate({'value': -5.0}), isNotEmpty);
    });
  });

  group('ParameterDefinition', () {
    test('parses all parameter types', () {
      final boolParam = ParameterDefinition.fromJson({
        'type': 'boolean',
        'default': true,
      });
      expect(boolParam.type, ParameterType.boolean);
      expect(boolParam.defaultValue, true);

      final intParam = ParameterDefinition.fromJson({
        'type': 'integer',
        'default': 5,
        'min': 0,
        'max': 10,
      });
      expect(intParam.type, ParameterType.integer);
      expect(intParam.min, 0);
      expect(intParam.max, 10);

      final numParam = ParameterDefinition.fromJson({
        'type': 'number',
        'default': 2.5,
        'step': 0.1,
      });
      expect(numParam.type, ParameterType.number);
      expect(numParam.step, 0.1);

      final enumParam = ParameterDefinition.fromJson({
        'type': 'enum',
        'default': 'option1',
        'options': ['option1', 'option2'],
      });
      expect(enumParam.type, ParameterType.enumType);
      expect(enumParam.options, ['option1', 'option2']);
    });

    test('getVsName returns correct name', () {
      final param = ParameterDefinition.fromJson({
        'type': 'number',
        'default': 1.0,
        'vapoursynth': {'name': 'strength'},
      });
      expect(param.getVsName('original'), 'strength');

      final paramNoVs = ParameterDefinition.fromJson({
        'type': 'number',
        'default': 1.0,
      });
      expect(paramNoVs.getVsName('original'), 'original');
    });
  });

  group('MethodDefinition', () {
    test('parses method definition', () {
      final method = MethodDefinition.fromJson({
        'id': 'test_method',
        'name': 'Test Method',
        'description': 'A test method',
        'function': 'module.TestFunction',
        'parameters': ['param1', 'param2'],
      });

      expect(method.id, 'test_method');
      expect(method.name, 'Test Method');
      expect(method.description, 'A test method');
      expect(method.function, 'module.TestFunction');
      expect(method.parameters, ['param1', 'param2']);
    });
  });

  group('UiSection', () {
    test('parses UI section', () {
      final section = UiSection.fromJson({
        'title': 'Advanced',
        'parameters': ['param1', 'param2'],
        'expanded': false,
        'advancedOnly': true,
      });

      expect(section.title, 'Advanced');
      expect(section.parameters, ['param1', 'param2']);
      expect(section.expanded, false);
      expect(section.advancedOnly, true);
    });
  });
}
