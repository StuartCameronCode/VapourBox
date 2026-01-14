# VapourBox Filter Schema Reference

This document describes the JSON schema format for defining custom VapourBox filters.

## Overview

VapourBox uses JSON schemas to define video processing filters. Each filter schema specifies:
- Filter metadata (name, description, category)
- Available processing methods (VapourSynth functions)
- Parameters with types, ranges, defaults, and UI configuration
- Dependencies (Python packages, VapourSynth plugins)

## File Location

- **Built-in filters**: `app/assets/filters/core/`
- **User filters**: `~/.vapourbox/filters/` (or `%USERPROFILE%\.vapourbox\filters\` on Windows)

## Schema Structure

```json
{
  "$schema": "https://vapourbox.app/schemas/filter-v1.json",
  "id": "my_filter",
  "version": "1.0.0",
  "name": "My Filter",
  "description": "What this filter does",
  "category": "restoration",
  "icon": "auto_fix_high",
  "order": 10,

  "dependencies": {
    "plugins": ["havsfunc"],
    "vs_plugins": ["plugin.dll"]
  },

  "methods": [...],
  "parameters": {...},
  "ui": {...},
  "codeTemplate": {...}
}
```

## Top-Level Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `$schema` | string | No | Schema URL for validation |
| `id` | string | Yes | Unique identifier (snake_case) |
| `version` | string | Yes | Semantic version (e.g., "1.0.0") |
| `name` | string | Yes | Display name |
| `description` | string | Yes | Brief description |
| `category` | string | Yes | Category: `deinterlace`, `restoration`, `enhancement`, `transform`, `custom` |
| `icon` | string | No | Material icon name |
| `order` | integer | No | Sort order in UI (lower = first) |

## Dependencies

Specifies required packages and plugins:

```json
"dependencies": {
  "plugins": ["havsfunc", "mvsfunc"],
  "vs_plugins": ["RemoveGrainVS.dll", "CTMF.dll"],
  "optional": ["libawarpsharp2.dll"]
}
```

| Field | Description |
|-------|-------------|
| `plugins` | Python packages (havsfunc, mvsfunc, etc.) |
| `vs_plugins` | VapourSynth plugins (.dll/.dylib) |
| `optional` | Optional plugins (filter works without them) |

## Methods

Methods define the VapourSynth functions this filter can use:

```json
"methods": [
  {
    "id": "dehalo_alpha",
    "name": "DeHalo Alpha",
    "description": "Standard dehalo with adjustable strength",
    "function": "haf.DeHalo_alpha",
    "parameters": ["rx", "ry", "darkStr", "brightStr"]
  },
  {
    "id": "yahr",
    "name": "YAHR",
    "description": "Yet Another Halo Reducer",
    "function": "haf.YAHR",
    "parameters": ["yahrBlur", "yahrDepth"]
  }
]
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique method identifier |
| `name` | string | Yes | Display name |
| `description` | string | No | Method description |
| `function` | string | Yes | VapourSynth function to call |
| `parameters` | array | Yes | Parameter IDs used by this method |

## Parameters

Parameters define the configurable values:

```json
"parameters": {
  "enabled": {
    "type": "boolean",
    "default": false,
    "ui": { "hidden": true }
  },
  "method": {
    "type": "enum",
    "default": "dehalo_alpha",
    "options": ["dehalo_alpha", "fine_dehalo", "yahr"],
    "ui": {
      "label": "Method",
      "widget": "dropdown"
    }
  },
  "rx": {
    "type": "number",
    "default": 2.0,
    "min": 1.0,
    "max": 3.0,
    "step": 0.1,
    "vapoursynth": { "name": "rx" },
    "ui": {
      "label": "Horizontal Radius",
      "description": "Horizontal dehalo radius",
      "widget": "slider",
      "precision": 1,
      "visibleWhen": { "method": ["dehalo_alpha", "fine_dehalo"] }
    }
  }
}
```

### Parameter Types

| Type | Description | Additional Fields |
|------|-------------|-------------------|
| `boolean` | True/false toggle | - |
| `integer` | Whole number | `min`, `max`, `step` |
| `number` | Decimal number | `min`, `max`, `step` |
| `enum` | Selection from options | `options` (array of strings) |
| `string` | Text input | - |

### Parameter Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | Yes | Data type (see above) |
| `default` | varies | Yes | Default value |
| `min` | number | No | Minimum value (integer/number) |
| `max` | number | No | Maximum value (integer/number) |
| `step` | number | No | Step increment (integer/number) |
| `options` | array | Yes* | Enum options (*required for enum type) |
| `vapoursynth` | object | No | VapourSynth mapping |
| `ui` | object | No | UI configuration |

### VapourSynth Mapping

Maps parameter to VapourSynth function argument:

```json
"vapoursynth": {
  "name": "rx",
  "transform": "int"
}
```

| Field | Description |
|-------|-------------|
| `name` | Argument name in VapourSynth function |
| `transform` | Optional type conversion: `int`, `float`, `bool` |

### UI Configuration

Controls how the parameter appears in the UI:

```json
"ui": {
  "label": "Horizontal Radius",
  "description": "Adjust the horizontal dehalo radius",
  "widget": "slider",
  "precision": 1,
  "hidden": false,
  "advancedOnly": false,
  "visibleWhen": { "method": ["dehalo_alpha"] }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `label` | string | Display label |
| `description` | string | Tooltip/help text |
| `widget` | string | Widget type: `slider`, `dropdown`, `checkbox`, `number`, `text` |
| `precision` | integer | Decimal places for number display |
| `hidden` | boolean | Hide from UI entirely |
| `advancedOnly` | boolean | Only show in advanced mode |
| `visibleWhen` | object | Conditional visibility rules |

### Conditional Visibility

The `visibleWhen` field controls when a parameter is shown:

```json
// Show when method is "dehalo_alpha" OR "fine_dehalo"
"visibleWhen": { "method": ["dehalo_alpha", "fine_dehalo"] }

// Show when method is "standard" (single value)
"visibleWhen": { "method": "standard" }

// Show when enabled is true AND method is "advanced"
"visibleWhen": { "enabled": true, "method": "advanced" }
```

## UI Sections

Organize parameters into collapsible sections:

```json
"ui": {
  "sections": [
    {
      "title": "Method",
      "parameters": ["method"],
      "expanded": true
    },
    {
      "title": "DeHalo Alpha Settings",
      "parameters": ["rx", "ry", "darkStr", "brightStr"],
      "expanded": true,
      "visibleWhen": { "method": ["dehalo_alpha"] }
    },
    {
      "title": "Advanced",
      "parameters": ["showMask"],
      "expanded": false,
      "advancedOnly": true
    }
  ]
}
```

| Field | Type | Description |
|-------|------|-------------|
| `title` | string | Section header |
| `parameters` | array | Parameter IDs in this section |
| `expanded` | boolean | Initially expanded/collapsed |
| `advancedOnly` | boolean | Only show in advanced mode |
| `visibleWhen` | object | Conditional visibility |

## Code Template

Controls code generation:

```json
"codeTemplate": {
  "imports": ["import havsfunc as haf"],
  "generate": "method"
}
```

| Field | Description |
|-------|-------------|
| `imports` | Python import statements |
| `generate` | Generation mode: `method` (auto) or `custom` |

When `generate` is `method`, the code generator:
1. Finds the selected method from `parameters.method`
2. Calls the method's `function` with the specified parameters
3. Parameters are formatted using `vapoursynth.name` mappings

## Presets (Optional)

For complex filters, define parameter presets:

```json
"presets": {
  "fast": {
    "tr0": 1,
    "tr1": 1,
    "tr2": 1
  },
  "high_quality": {
    "tr0": 2,
    "tr1": 2,
    "tr2": 3
  }
}
```

## Complete Example

```json
{
  "$schema": "https://vapourbox.app/schemas/filter-v1.json",
  "id": "my_custom_filter",
  "version": "1.0.0",
  "name": "My Custom Filter",
  "description": "Example custom filter",
  "category": "custom",
  "icon": "extension",
  "order": 100,

  "dependencies": {
    "plugins": ["havsfunc"]
  },

  "methods": [
    {
      "id": "method_one",
      "name": "Method One",
      "description": "First processing method",
      "function": "haf.SomeFunction",
      "parameters": ["param1", "param2"]
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
      "default": "method_one",
      "options": ["method_one"],
      "ui": {
        "label": "Method",
        "widget": "dropdown"
      }
    },
    "param1": {
      "type": "number",
      "default": 1.0,
      "min": 0.0,
      "max": 10.0,
      "step": 0.1,
      "vapoursynth": { "name": "strength" },
      "ui": {
        "label": "Strength",
        "widget": "slider",
        "precision": 1
      }
    },
    "param2": {
      "type": "integer",
      "default": 2,
      "min": 1,
      "max": 5,
      "vapoursynth": { "name": "radius" },
      "ui": {
        "label": "Radius",
        "widget": "slider"
      }
    }
  },

  "ui": {
    "sections": [
      {
        "title": "Method",
        "parameters": ["method"],
        "expanded": true
      },
      {
        "title": "Settings",
        "parameters": ["param1", "param2"],
        "expanded": true
      }
    ]
  },

  "codeTemplate": {
    "imports": ["import havsfunc as haf"],
    "generate": "method"
  }
}
```

## Installing Custom Filters

1. Create your filter JSON file following this schema
2. Copy to `~/.vapourbox/filters/` (macOS/Linux) or `%USERPROFILE%\.vapourbox\filters\` (Windows)
3. Restart VapourBox or use the filter reload option
4. Your filter will appear in the filter list

## Validation

Before installing, validate your filter:
- Check JSON syntax is valid
- Ensure all required fields are present
- Verify method parameter references exist
- Test with a sample video

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Filter not appearing | Check JSON syntax, verify file location |
| Parameters not showing | Check `visibleWhen` conditions |
| VapourSynth errors | Verify `function` name and `vapoursynth.name` mappings |
| Missing dependencies | Install required plugins/packages |
