# Draft: issue for sekrit-twc/zimg

**Not filed.** For the user to approve before it is posted with `gh issue create -R sekrit-twc/zimg`.

---

**Title:** get_tmp_size() leaves out an error-diffusion node's context since graphengine f6211289 (heap overflow, master e2e43d09)

Since e2e43d09 ("Update graphengine", graphengine cb5b2ce1 → 91c6af4c), any graph that dithers with `ZIMG_DITHER_ERROR_DIFFUSION` writes past the end of the buffer whose size `zimg_filter_graph_get_tmp_size()` returns. The overrun is about `2 × (width + 2) × sizeof(float)` bytes (792 at width 96, 5784 at 720).

We hit it through VapourSynth R78. Its meson `zimg.wrap` builds master, and `resize.*(dither_type="error_diffusion")` aborted in `vszimg::real_get_frame` with glibc's `double free or corruption (!prev)` or `malloc(): ... assertion failed` on every frame. The 67e06032 / cb5b2ce1 build is unaffected.

### Repro (C API only)

A GRAY16 → GRAY8 conversion at 96x64, with error diffusion. The buffer is allocated at exactly `tmp_size` with a guard pattern after it (full file attached / below):

```c
zimg_image_format_default(&src, ZIMG_API_VERSION);
src.width = 96; src.height = 64;
src.pixel_type = ZIMG_PIXEL_WORD; src.depth = 16; src.pixel_range = ZIMG_RANGE_LIMITED;
dst = src; dst.pixel_type = ZIMG_PIXEL_BYTE; dst.depth = 8;
zimg_graph_builder_params_default(&params, ZIMG_API_VERSION);
params.dither_type = ZIMG_DITHER_ERROR_DIFFUSION;
graph = zimg_filter_graph_build(&src, &dst, &params);
zimg_filter_graph_get_tmp_size(graph, &tmp_size);
/* tmp: tmp_size bytes, 64-aligned, followed by 0xA5 guard bytes */
zimg_filter_graph_process(graph, &sb, &db, tmp, NULL, NULL, NULL, NULL);
```

Results with master built by its own autotools (`./configure --disable-shared`, macOS arm64, Apple clang 21):

| graphengine | tmp_size | bytes changed past it |
|---|---|---|
| cb5b2ce1 (67e06032) | 1344 | 0 |
| 91c6af4c (e2e43d09, master) | **384** | **791** (furthest +792) |
| 91c6af4c + the change below | 1216 | 0 |

With `-fsanitize=address` and no guard:

```
ERROR: AddressSanitizer: heap-buffer-overflow
WRITE of size 792
  #1 zimg::depth::(anonymous namespace)::ErrorDiffusionNEON::init_context(void*) const
  #2 graphengine::zimg::(anonymous namespace)::TransformNodeBase::begin_frame(...)
  #3 graphengine::zimg::GraphImpl::impl::run_node(...)
0 bytes after 384-byte region
```

Without NDEBUG, the guard pages catch it instead: `Assertion failed: (word == pattern()), function assert_page, file state.h, line 149`.

### Bisect

Each graphengine commit from cb5b2ce1 to 91c6af4c was built into zimg 67e06032 and run over 158 graphs: the conversions VapourSynth makes, at 96x64, 98x64 and 720x480, progressive and per field. Results:

- 7014d9f2 through 562889d3: no overrun.
- **f6211289 "Exclude fused nodes from buffer sizing calculation"**: the first commit that overruns.
- Every later commit, and graphengine HEAD e9b10267, are the same.

All 36 error-diffusion graphs among the 158 trip the guard pages (NDEBUG unset). With NDEBUG, 18 of them write past the end (24 on x86_64 under Rosetta), and the rest overwrite another region of the buffer. No graph without error diffusion is affected: `none`, ordered and random dither are fine. The same commit is first bad on every setup tried:

| | x64 gcc 13 | x64 clang 18 | arm64 gcc 13 | macOS arm64 (Apple clang) | macOS x86_64 (Rosetta) |
|---|---|---|---|---|---|
| cb5b2ce1 … 562889d3 | clean | clean | clean | clean | clean |
| f6211289 … e9b10267 | 36 corrupt | 36 corrupt | 36 corrupt | 36 corrupt | 36 corrupt |
| 91c6af4c / e9b10267 + change below | clean | clean | clean | clean | clean |

Linux is ubuntu-24.04 (glibc 2.39).

### Cause

f6211289 added an early `continue` for nodes with no live rows in `compile_simulation_result`:

```cpp
unsigned live_rows = sim.live_range(id);
if (!live_rows)
    continue;
```

That skips the cache sizing as intended. It also skips the lines after the plane loop:

```cpp
node_result.context_size = (sim.context_size(id) + ALIGNMENT_MASK) & ~static_cast<size_t>(ALIGNMENT_MASK);
node_result.initial_cursor = sim.cursor_min(id);
sat_add(result.tmp_size, node_result.context_size);
```

So a fused node's context is never counted in `tmp_size`. Error diffusion is the only zimg filter in these graphs whose context is non-trivial (its error rows). `begin_frame` → `init_context` then `memset`s it past the end of the buffer.

Skipping only the plane loop fixes every case above, with and without NDEBUG and under ASan:

```diff
-			unsigned live_rows = sim.live_range(id);
-			if (!live_rows)
-				continue;
-
-			for (unsigned p = 0; p < node->num_planes(); ++p) {
+			// A fused node (no live rows) has no cache, but its filter context
+			// is still allocated from tmp and initialised in begin_frame.
+			unsigned live_rows = sim.live_range(id);
+
+			for (unsigned p = 0; live_rows && p < node->num_planes(); ++p) {
```

I haven't checked whether `initial_cursor` matters for a fused node; the change keeps setting it as before f6211289.

The repro, the case list and the bisect scripts are at https://github.com/StuartCameronCode/VapourBox/tree/main/docs/reports/task-109-graphengine-tmp-overrun/scripts (the link works once our PR merges; until then use branch `stuart/109-zimg-master-e2e43d09-graphengine-91c6af4`).
