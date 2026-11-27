# Rust ↔ Dart twins

A **twin** is a decision written twice: once in the worker (Rust), which acts
on it, and once in the app (Dart), which shows or prepares it. Two copies
drift, and a drift is a silent disagreement between what the app shows and
what the encode does. Task #42's plan (R5) set the rule; task #50 made the
first inventory.

Every twin is one of:

- **Deleted (worker call)** — the app asks the worker instead.
- **One data file** — both sides read the same committed file (the add-on
  manifests and `Tests/TestResources/audio_codec_containers.json` are the
  pattern), so there is nothing to keep in step.
- **Kept + pinned** — still two copies, with a test that checks one against
  the other (by parsing the Rust, or through a shared vector file), and a
  stated reason a worker call isn't feasible yet.

No new hand-maintained twin should appear where a worker call is feasible.
`app/test/twin_registry_test.dart` (push gate) fails when a file in `app/lib`
says "twin of", "mirrors", "second implementation" or "in step with" and is
not listed here, or when a listed file no longer exists.

## Kept + pinned

| App file | What | Worker side | Pinned by | Disposition and reason |
|---|---|---|---|---|
| `app/lib/services/field_order_detector.dart` | `SeekPlan.seekArgs` / `frameSeekArgs` / `formatSeek`, `SourceGrid.startAt` / `filters` (the arguments; the values come from the source model) | `source_decode::decoder_seek`, `source_seek`, `seek_arg`, `decode_start` | `avi_seek_test.dart`, `mpeg_seek_plan_test.dart`, `source_grid_test.dart`; `seek_arg_cases.json`, `source_grid_vectors.json` | **Delete with R3b**: the Original and the thumbnails through the worker (`--source-frame`, `--thumbnails`), awaiting the go-ahead and a latency measurement (task #50 plan, stage C) |
| `app/lib/services/preview_generator.dart` | `beforeFrameArgs`, `thumbnailArgs`, `sourceDecodeOptions` (`-apply_cropping codec`) | `source_decode` | the heavy seek / grid / video-start / reserved-tag suites | **Delete with R3b** (as above) |
| `app/lib/models/color_tags.dart` | `decodeNeutraliser` and FFmpeg's accepted tag lists | `ColorMetadata::decode_tag_neutraliser` | `color_tags_test.dart` (parses `color_metadata.rs`) | **Delete with R3b**: only the app's own decodes use it |
| `app/lib/models/hdr_display.dart` | `HdrDisplay.toneMapFilter` (`rangeLabel` and `DolbyVisionInfo`'s label are UI, not twins) | `ColorMetadata::display_tonemap_filter` | `hdr_display_test.dart` (fills the Rust `format!`) | **Delete with R3b** |
| `app/lib/models/encoding_settings.dart` | audio codec short names, `supportsContainer` / `containerProblem`, `ChromaSubsampling` / `ProResQuantMat` values, effective / output chroma | `AudioCodec`, `ChromaSubsampling`, `VideoJob::output_chroma_subsampling` | `audio_codec_containers.json` (one data file already), `pixel_format_test.dart`, `av1_test.dart` | **One data file, under task #49** (the output capability table). The dropdowns need the answer synchronously, so a worker call per change is not the shape; enum values are the wire format |
| `app/lib/models/video_job.dart` | `VideoCodec` container rules, ProRes profile, `fixedOutputFormat`, CRF range, presets, `ContainerFormat.storesStreamStart` | `VideoCodec::*`, `ContainerFormat::stores_stream_start` | `v210_test.dart`, `av1_test.dart`, `prores_options_test.dart` | **One data file, under task #49** (as above) |
| `app/lib/views/settings/settings_dialog.dart` | ProRes `bits_per_mb` maximum | `PRORES_MAX_BITS_PER_MB` | none (the worker clamps whatever arrives) | **Kept**: a UI bound only, the worker clamps regardless; moves with task #49's table |
| `app/lib/utils/pixel_format.dart` | `ChromaClass`; the hardware-encoder, ProRes, v210 and AV1 chroma warnings | `pixel_format::ChromaClass`, `VideoCodec::forced_pix_fmt`, `fixed_output_format`, `output_chroma_subsampling` | `hardware_encoder_chroma_warning_test.dart`, `prores_chroma_pin_warning_test.dart`, `v210_test.dart`, `av1_test.dart` (parse the Rust case tables) | **Kept + pinned**: live warning text on every settings change. Candidate for a generated case table under task #49 |
| `app/lib/models/processing_pipeline.dart` | `enabledPasses` | `ProcessingPipeline::enabled_passes` | `pass_list_stages_test.dart`, `integration_filter_parameters_test.dart` | **Kept**: synchronous pass-list state |
| `app/lib/models/unblend_parameters.dart` | `unblendInputFps`, `unblendTargetProblem` | the Deinterlace `FrameMap`s, `unblend_ratio` | `unblend_parameters_test.dart`; `docs/reports/2026-11-srestore/data/ratio_table.json` | **Kept + pinned**. Candidate for an asynchronous worker check (like the GPU probes) for the warning text |
| `app/lib/models/audio_restoration_parameters.dart` | `hasEffect`, `startWithPicture` | `AudioRestorationParameters::has_effect`, `start_with_picture` | `audio_restoration_test.dart` | **Kept**: one-line predicates over the same fields |
| `app/lib/models/color_correction_parameters.dart` | `effectiveLevelsPoints` | `ColorCorrectionParameters::effective_levels_points` | `color_correction_panel_test.dart` | **Kept**: one line; the panel hides sliders from it |
| `app/lib/services/preview_generator.dart` | `vspipeEchoPrefix` (the preview's echoed vspipe lines, left out of a failed preview's error text) | `VSPIPE_ECHO_PREFIX` | `vspipe_echo_prefix_test.dart` (parses the Rust const) | **Kept**: one string; the error text is assembled in the app (task #122) |
| `app/lib/services/pitch_factor_file.dart` | the factor file's line rules (for the summary shown when a video is added) | `parse_pitch_factors` | `pitch_factor_file_test.dart` | **Candidate for a worker call** (`--check-pitch-file`), so the error wording and line number are the worker's. The worker already refuses a bad file at job time |

### Test-side twins

Not app code, so `twin_registry_test.dart` doesn't look for them, but kept
the same way:

| Test file | What | Worker side | Pinned by |
|---|---|---|---|
| `app/test/support/worker_harness.dart` | `previewScaleFilter` / `previewScaleFlags`: the preview's YUV -> RGB `scale` for a picture's tags, so a heavy test decodes the side it compares with a preview as the preview converts (task #67) | `preview_scale_filter`, `ColorMetadata::swscale_input_opts`, `is_full_range` | `preview_scale_filter_test.dart` (parses both Rust functions; the matrix list through `ColorTags.matrices`, pinned by `color_tags_test.dart`) |
| `app/test/support/vspipe_process.dart` | `vspipeFinalKind`, `vspipeFinalErrorPrefixes`, the exit grace and its variable (`runVspipe`, for tests that run vspipe without the worker, task #124) | `vspipe_exit::final_kind`, `ERROR_PREFIXES`, `DEFAULT_GRACE`, `GRACE_ENV` | `vspipe_process_test.dart` (parses the Rust: prefixes in order, constants, the Rust test's lines) |

## Deleted or single-sourced

| What | Now | Since |
|---|---|---|
| Video start offset, leading pictures | the worker's `SourceModel` (`--probe-source`) | task #50 |
| Decoder delay | the source model | task #50 |
| Seek plan (the values) | the source model | task #50 |
| Source grid (the values) | the source model | task #50 |
| Frame count (stored, by duration, untimed tail, last picture, VFR) | the source model (`source_model::frame_count`) | task #50 |
| Frame rate choice (`selectFrameRate`), VFR test, SAR normalising, colour tag reading, Dolby Vision record | the source model | task #50 |
| Soft Telecine's pulldown rate | the source model's `pulldownRate` | task #50 |
| Metadata field order (the app's own ffprobe call) | read from the source model | task #50 |
| Add-on manifests | one data file each, compiled into the worker by `build.rs` | deps 1.16.0 |
| CPU tier | `--probe-cpu` | issue #92 |
| GPU plugin, AI runtime and KNLMeans device status, with their wording | `--probe-rife`, `--probe-upscale`, `--probe-ai-runtime`, `--probe-opencl` | app 1.7.0 |
| Crop, native resolution, noise and halo verdicts | `--detect-*` reports | app 1.7.0 |
| Timestamp resets | the source model's `continuity` (`--scan-timestamps` remains for the CLI) | task #21, #50 |

## Not twins

These say "mirrors" or "in step" about app-internal state, not about a
worker decision:

- `app/lib/services/preset_service.dart`
- `app/lib/views/settings/settings_dialog.dart` (the temp directory and
  overwrite rows mirror their own services; its ProRes row is listed above)

Inside the worker: `pixel_format::NATIVE_FORMATS` ↔ `templates/pipe_source.py`
`_FORMAT_MAP` (Rust ↔ Python), pinned by `test_native_formats_match_pipe_source`.
