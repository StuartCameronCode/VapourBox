# Filter Schema Reference

Every filter in VapourBox's pipeline is described by a JSON schema in
`app/assets/filters/core/`, listed in `app/assets/filters/manifest.json`. The
schema drives the settings UI: parameter widgets, ranges, conditional visibility
and the explanatory text are all generated from it, so adding a filter to the core
app means writing one of these. This is the field reference.

> **Scope: built-in filters only.** User-supplied filters are **not** a supported
> feature — don't document or expose one. `app/lib/models/filter_schema.dart` is
> the authority for everything below; a key the model doesn't declare is silently
> dropped at parse time, which is a quiet way to lose an afternoon.
>
> The full checklist for adding a filter (Rust models, templates, converters, UI
> wiring, tests) is in [CLAUDE.md](../CLAUDE.md) — the schema is step 1 of about ten.

## Top-Level Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `$schema` | string | No | Schema URL, informational only |
| `id` | string | **Yes** | Unique identifier (snake_case), must match the filter id used in the UI wiring |
| `version` | string | **Yes** | Semantic version, e.g. `"1.0.0"` |
| `name` | string | **Yes** | Display name |
| `description` | string | No | One-line summary shown under the name |
| `longDescription` | string | No | The **More** expander text — what the filter does and when to reach for it. Supports `\n\n` paragraphs |
| `category` | string | No | One of `deinterlace`, `cleanup`, `color`, `enhancement`, `transform` (free-form in the model; these are the values in use) |
| `icon` | string | No | Material icon name |
| `order` | integer | No | Sort order, lower first (default `0`) |
| `maxBitDepth` | integer | No | Native bit-depth ceiling. Drives the warning in `app/lib/utils/pixel_format.dart` when a higher-depth source meets a filter that can't take it (`descratch` is 8) |
| `dependencies` | object | No | See below |
| `methods` | array | **Yes** | See below |
| `parameters` | object | **Yes** | See below |
| `parameterPresets` | object | No | See below |
| `presets` | object | No | Named value sets, `{"fast": {"tr0": 1}}` |
| `ui` | object | No | Section layout |
| `codeTemplate` | object | No | Code generation hints |

## Dependencies

```json
"dependencies": {
  "plugins": ["havsfunc", "mvsfunc"],
  "vs_plugins": ["RemoveGrainVS.dll", "CTMF.dll"],
  "optional": ["libawarpsharp2.dll"]
}
```

| Field | Description |
|-------|-------------|
| `plugins` | Python packages (havsfunc, mvsfunc, …) |
| `vs_plugins` | VapourSynth plugin binaries |
| `optional` | Plugins the filter works without |

New plugin binaries must also be added to every `Scripts/download-deps-*` script
**and** to `Scripts/deps-expected-plugins.json`, or the bundle ships incomplete.

## Methods

A method is one VapourSynth function the filter can call, with the subset of
parameters that apply to it.

```json
"methods": [
  {
    "id": "dehalo_alpha",
    "name": "DeHalo Alpha",
    "description": "Standard dehalo with adjustable strength",
    "function": "haf.DeHalo_alpha",
    "parameters": ["rx", "ry", "darkStr", "brightStr"]
  }
]
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | **Yes** | Method identifier, referenced by `visibleWhen` |
| `name` | string | **Yes** | Display name |
| `description` | string | No | Shown beside the method in the dropdown |
| `function` | string | **Yes** | VapourSynth/Python function to call |
| `parameters` | array | **Yes** | Parameter ids this method uses |
| `advancedOnly` | boolean | No (`false`) | Method is only offered in advanced mode |

> **A method must gate something, or it should not exist.** The listed
> `parameters` do **not** drive the panel when the schema declares `ui.sections`
> — sections take priority — so a method only changes what the user sees through
> `visibleWhen: {"method": [...]}` on the parameters themselves, and only changes
> the render if the worker has a matching field to switch on. `color_correction`
> declared two methods with neither: the dropdown rendered, both groups of
> controls stayed on screen, and the converter hardcoded one value the worker
> never read. One method means no dropdown at all, which is the honest result.

### `advancedOnly` on a method

This is how a filter offers a short list to everyone and the full set to someone
who has asked for it — the mechanism that stops a slot like Noise Reduction
becoming a dropdown of sixteen names as methods are added. It is gated by the
same app-wide switch as an `advancedOnly` **section**
(`AdvancedModeService`, **Settings → General → Show advanced options**).

Three behaviours to know before using it:

- **Order is the curation.** `visibleMethods()` preserves schema order, so put
  the method a regular user should land on first. It is also the default, since
  `methods.first` is what an unset `method` resolves to — so **never mark the
  first method `advancedOnly`**.
- **A selected method is always shown**, even in simple mode. A preset or a
  saved job can select an advanced-only method; hiding it would misreport what
  the pipeline is doing, and would hand the dropdown a value that isn't among
  its items (a Flutter assertion, not a graceful degradation). Pinned by
  `dynamic_filter_panel_advanced_test.dart`.
- **Leave at least one method un-advanced.** Marking every method advanced-only
  leaves simple mode showing one arbitrary choice with no dropdown.

When a filter drops to a single visible method the dropdown is suppressed
entirely and replaced by a line telling the user more exist in advanced mode.

## Parameters

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
    "ui": { "label": "Method", "widget": "dropdown" }
  },
  "rx": {
    "type": "number",
    "default": 2.0,
    "min": 1.0,
    "max": 3.0,
    "step": 0.1,
    "optional": true,
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

### Types

| Type | Description | Extra fields |
|------|-------------|--------------|
| `boolean` | Toggle | `ui.booleanLabels` to name the two states |
| `integer` | Whole number | `min`, `max`, `step` |
| `number` | Decimal | `min`, `max`, `step`, `ui.precision` |
| `enum` | Choice | `options` (array of strings) — required |
| `string` | Text | — |

### Parameter fields

| Field | Type | Description |
|-------|------|-------------|
| `type` | string | One of the above |
| `default` | varies | Default value |
| `min` / `max` / `step` | number | Numeric bounds |
| `options` | array | Enum values (required for `enum`) |
| `optional` | boolean | Adds an enable checkbox; when unticked the parameter is **omitted** from the generated script so the VapourSynth default applies |
| `vapoursynth` | object | `{"name": "…"}` — the argument name in the function, when it differs from the schema key. **`name` is the only field**; there is no type-transform option |
| `ui` | object | See below |

> **`optional: true` has a converter consequence.** For a parameter that should
> default to *off*, the `fromX()` converter in
> `app/lib/models/parameter_converter.dart` must put its value in
> `lastOptionalValues`, not `values` — otherwise the UI opens with every optional
> parameter already enabled. See the note in [CLAUDE.md](../CLAUDE.md).

### `ui` on a parameter

| Field | Type | Description |
|-------|------|-------------|
| `label` | string | Display label |
| `description` | string | Help text under the control |
| `widget` | string | `slider`, `dropdown`, `checkbox`, `textfield`, `number` |
| `precision` | integer | Decimal places shown |
| `hidden` | boolean | Never shown (used for `enabled`) |
| `visibleWhen` | object | Conditional visibility |
| `booleanLabels` | object | Names the two states of a boolean, e.g. `{"true": "Top Field First (TFF)", "false": "Bottom Field First (BFF)"}` |

There is **no `advancedOnly` on a parameter** — only on a section (below) or a
method (above).

### Conditional visibility

```json
"visibleWhen": { "method": ["dehalo_alpha", "fine_dehalo"] }   // any of these
"visibleWhen": { "method": "standard" }                         // single value
"visibleWhen": { "enabled": true, "method": "advanced" }        // all must match
"visibleWhen": { "applyAutoChroma": false }                     // booleans too
```

Multiple keys are ANDed; a list of values for one key is ORed. `method` is read
from the values map like any other key, so a condition on the selected method
works the same way as one on a checkbox.

> **It belongs at `parameters.<id>.ui.visibleWhen` and nowhere else.**
> `ParameterDefinition` doesn't declare the key, so a copy written one level up
> is dropped at parse time — no error, and the control is simply always visible.
> **Eight of the shipped schemas had it in the wrong place** (35 parameters and
> 12 sections), which is how Chroma Fixes came to show its automatic-alignment
> sliders with automatic alignment switched off, and Noise Reduction its mClean
> knobs under SMDegrain. Fixed 2026-08-18 and now linted by
> `app/test/filter_schema_curation_test.dart`.
>
> The same test asserts the opposite failure: a condition naming a parameter
> that doesn't exist, or a `method` condition naming a method the filter doesn't
> offer, can *never* be satisfied — so the control it guards is invisible
> forever, which is the worse of the two silent failures.

## Parameter Presets

A dropdown that writes several parameters at once — distinct from the top-level
`presets`. Note the JSON key is `default`, which maps to `defaultOption` in the model.

```json
"parameterPresets": {
  "cropPreset": {
    "label": "Crop Preset",
    "description": "Quick crop presets for common scenarios",
    "default": "None",
    "options": {
      "None":            { "cropEnabled": false, "cropLeft": 0, "cropRight": 0 },
      "Remove Overscan": { "cropEnabled": true,  "cropLeft": 8, "cropRight": 8 },
      "PAL Overscan":    { "cropEnabled": true,  "cropLeft": 10, "cropRight": 10 }
    }
  }
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `label` | string | **Yes** | Label for the selector |
| `description` | string | No | Help text |
| `default` | string | No | Initially selected option key |
| `options` | object | **Yes** | Option name → parameter values to apply |
| `visibleWhen` | object | No | Conditional visibility |

## UI Sections

```json
"ui": {
  "sections": [
    { "title": "Method", "parameters": ["method"], "expanded": true },
    {
      "title": "Sampling",
      "parameters": ["pointsLow", "pointsMedium", "scale"],
      "expanded": false,
      "advancedOnly": true
    }
  ]
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `title` | string | — | Section header |
| `parameters` | array | — | Parameter ids in this section |
| `expanded` | boolean | `true` | Initially expanded |
| `advancedOnly` | boolean | `false` | Only in advanced mode |

A section has **no `visibleWhen`** — `UiSection` doesn't declare one, so putting
it there does nothing. Put the condition on every parameter in the section
instead; `filter_schema_curation_test.dart` fails if a section carries one.

**A section is a heading, but only where there is more than one.**
`DynamicFilterPanelCompact` prints `title` above the section's controls whenever
the schema declares two or more sections, in both modes; an `advancedOnly` one is
printed in the accent colour, so it stays obvious which controls appeared because
advanced mode is on. A schema with a **single** section gets no heading at all —
there is nothing to tell it apart from, and most of those call it "Settings".

Order still carries the structure, because a heading is all you get — there is no
indent, box or rule. Put the switch that turns a feature on first, the controls it
reveals next, and its thresholds in an `advancedOnly` section immediately after.
`chroma_fixes.json` is the worked example (a switch per repair, and a tuning
section per filter directly after it).

> Until 2026-08-18 the heading was printed **only** for an `advancedOnly` section
> in advanced mode, so every ordinary section ran together into one flat list and
> a `title` was, in practice, a comment. Don't assume a section groups anything
> visually beyond its heading.

## Code Template

```json
"codeTemplate": {
  "imports": ["import havsfunc as haf"],
  "generate": "method"
}
```

| Field | Description |
|-------|-------------|
| `imports` | Python import statements the filter needs |
| `generate` | `"method"` to call the selected method's `function`, otherwise use `body` |
| `body` | Custom code body, when `generate` is not `"method"` |

With `generate: "method"` the generator resolves the selected method from the
`method` parameter, calls its `function`, and formats arguments using each
parameter's `vapoursynth.name` where given.

> The **encode path does not run on this**. The real script comes from
> `worker/templates/pipeline_template.vpy` plus `worker/src/script_generator.rs`,
> and the preview from `preview_template.vpy`. A new filter needs a template block
> in **both**, whatever `codeTemplate` says.

## Worked Example

Read a real one rather than starting from this page:

- **`dehalo.json`** (690 lines) — seven methods with per-method `visibleWhen`, the
  best model for a multi-method filter.
- **`crop_resize.json`** (753 lines) — the only user of `parameterPresets`.
- **`deinterlace.json`** (2242 lines) — every QTGMC parameter; the extreme case.
- **`spotless.json`** (112 lines) — near-minimal, a good starting skeleton.
- **`descratch.json`** — the only user of `maxBitDepth`.
- **`chroma_fixes.json`** — one pass holding five unrelated repairs: the model
  for progressive disclosure (a switch per repair, controls gated on it, an
  `advancedOnly` tuning section per repair) and for two controls that are
  alternatives rather than a pair (`applyAutoChroma` hides the manual sliders,
  and `ChromaFixParameters::effective_apply_chroma_shift` keeps the generated
  script agreeing with what the panel shows).
- **`color_correction.json`** — an adjustment offered both automatically and by
  hand belongs in **one** section with the automatic control first, not in a
  separate "Automatic" group. It also shows the two ways that pairing can go:
  automatic levels hides the manual input/output points it supersedes but leaves
  gamma, which it never touches, while automatic white balance leaves temperature
  and tint alone because an offset still means what it says after a correction.
