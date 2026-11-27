# Draft: issue for sekrit-twc/zimg

**Not filed.** The user files it (task #115's plan). Attach `scripts/upstream_repro.c` and
`scripts/zimg-neon-v-f32-taps.patch`.

---

**Title:** NEON `resize_line_v_f32_neon` reads coefficients past `FilterContext::data` when the filter has ≤ 4 taps

`resize_line_v_f32_neon<Taps, Continue>` (`src/zimg/resize/arm/resize_impl_neon.cpp`) builds its coefficient
vectors from `filter_data[0..7]` for every `Taps`:

```cpp
const float32x4_t c[8] = {
    vdupq_n_f32(filter_data[0]),
    ...
    vdupq_n_f32(filter_data[7]),
};
```

`filter_data` is row `i` of `FilterContext::data`, whose stride is `ceil_n(filter_width, AlignmentOf<float>)`.
On ARM `ALIGNMENT` is 16, so a filter of 4 or fewer taps has a stride of 4 floats. On the last output row,
`filter_data[4..7]` are past the end of the vector. Only `c[0..Taps-1]` are used, so the output is
correct. The read is still out of bounds, and a compiler that keeps it gets caught by ASan. The same applies
to the `Continue` instances when fewer than 8 taps remain. x86 is unaffected because its stride is at least 16.
The u16 kernel is unaffected because `stride_i16` rounds to 8. It is present at 67e06032 and at master
9806db42.

### Repro

The attached `upstream_repro.c` builds one GRAYS graph through the C API and resizes vertically only:
4x4 → 4x2 point (1 tap), or with `up`, 96x64 → 96x128 bicubic (4 taps).

```
c++ -O2 -g -fsanitize=address -Izimg/src/zimg/api -x c upstream_repro.c -x none libzimg.a
```

With gcc 13.3 on aarch64 Linux (Ubuntu 24.04, Neoverse V2):

| Build | Case | Result |
|---|---|---|
| unpatched | 4x4 → 4x2 point | `heap-buffer-overflow`, `READ of size 4` in `resize_line_v_f32_neon<1, false>`, 0 bytes after a 32-byte region (2 rows × 4 floats) |
| unpatched | `up`: 96x64 → 96x128 bicubic | the same in `resize_line_v_f32_neon<4, false>`, 0 bytes after a 2048-byte region (128 rows × 4 floats) |
| with the patch below | both | clean |

clang 18 ASan on the same machine reports nothing; its build loads only the coefficients it uses. A normal
gcc `-O3` build doesn't emit the extra loads either, and valgrind is clean on it. We found it by running a set
of 158 graphs under gcc ASan: every 4:2:0 conversion with a ≤ 4-tap vertical float resize hits it (point
2:1 down, bicubic 1:2 up). The overflowed block is always the coefficient vector, *output rows × 16* bytes.

### Suggested fix

Load only the taps the instance uses. `Taps` is a template constant, so this folds away:

```diff
-		vdupq_n_f32(filter_data[0]),
+		vdupq_n_f32(Taps > 0 ? filter_data[0] : 0.0f),
 		...
-		vdupq_n_f32(filter_data[7]),
+		vdupq_n_f32(Taps > 7 ? filter_data[7] : 0.0f),
```

With it, all 158 graphs are clean under gcc ASan, at 67e06032 and at 9806db42. The output CRCs of a normal
gcc build are identical with and without it on all 158.
