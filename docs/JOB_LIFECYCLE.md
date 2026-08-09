# Job lifecycle and state management

How a conversion actually runs, which layer owns which piece of state, and where
those layers can disagree. Written after three failed attempts at the same
cancellation bug, each of which fixed a real defect without fixing the symptom —
because the symptom is produced by the *structure*, not by any one of them.

Read the "Where it breaks" section before changing any of this.

---

## 1. The processes

```
Flutter app (Dart)                 worker (Rust)              children
─────────────────────              ─────────────                ────────
MainViewModel                                                  ffmpeg (decode)
  └─ WorkerManager  ──spawn──▶  vapourbox-worker  ──spawn──▶   vspipe
       ▲                              │                        ffmpeg (encode)
       └────── JSON lines on stdout ──┘
```

- **Config** in: a JSON file path via `--config`.
- **Progress** out: JSON lines on the worker's stdout (`progress`, `log`,
  `complete`).
- **Cancel** in: a signal. There is no cancel *message* — see §5.

Since PR #64 the worker calls `setpgid(0,0)` at startup
(`worker/src/main.rs`), so it leads its own process group and the app can
signal the whole tree with `kill(-pid)` (`app/lib/services/process_tree.dart`).

---

## 2. Where state lives

This is the core problem: **the same fact is represented four times, in four
places, with no single owner.**

| Layer | State | Set by | Cleared by |
|---|---|---|---|
| Worker | process alive; exit code (0 / 1 / 130) | itself | exiting |
| `WorkerManager` | `_process`, `_pendingCompletion`, `_completionEmitted`, `_generation`, `_cancelRequested` | `startJob`, stdout handler, `cancel` | `_cleanup()` |
| `MainViewModel` | `_state` (`ProcessingState`), `_isQueueProcessing`, `_currentProcessingIndex` | `startQueueProcessing`, `_processNextItem`, `cancelProcessing` | `_handleQueueItemCompletion` **only** |
| `QueueItem` | `status` (`ready`/`processing`/`completed`/`failed`/`cancelled`) | `_processNextItem`, `_handleQueueItemCompletion` | same |

Nothing reconciles these. Each is advanced optimistically on the assumption
that a later event will arrive to advance it again.

### The two latches

Whether the user can start anything is governed by **two independent booleans**
that must *both* be cleared:

```dart
bool get canProcess =>
    _queue.isNotEmpty && queueReadyCount > 0 && _state == ProcessingState.idle;
                                               // main_viewmodel.dart:325

Future<void> startQueueProcessing() async {
  if (!canProcess || _isQueueProcessing) return;   // :1065
```

`startQueueProcessing` returns **silently** when either latch is stuck. No log,
no error, no state change. From the user's side the button does nothing and the
spinner keeps turning — which is exactly the reported symptom, and why it looks
like "no progress" rather than "an error".

Both latches are cleared in exactly one place: `_handleQueueItemCompletion`
(`:1194`), driven by a `CompletionResult` from `WorkerManager`. **If that event
never arrives, or is dropped, the app is stuck permanently** with no path back to
`idle` short of restarting it.

---

## 3. A normal run

```
user clicks Start
  └─ startQueueProcessing            _isQueueProcessing = true
      └─ _processNextItem            item.status = processing
                                     _state = preparingJob → processing
          └─ WorkerManager.startJob  _generation++, _process = <proc>
              └─ worker runs         stdout: progress… progress… complete
                                     └─ _pendingCompletion = <result>
              └─ worker exits (0)
                  └─ exitCode.then   _emitCompletion(pending), _cleanup()
                      └─ _handleQueueItemCompletion
                            item.status = completed
                            └─ _processNextItem  (next item, or finish)
```

At the end, `_processNextItem` finds nothing `ready`, clears
`_isQueueProcessing`, and sets `_state` to `completed`/`failed`.

---

## 4. A cancellation

```
user clicks Cancel
  └─ cancelProcessing               _state = cancelling      ← latch set here
      └─ cancelQueueProcessing
          └─ WorkerManager.cancel()
                _cancelRequested = true
                ProcessTree.killTree(process)      → SIGTERM to -pid
                await process.exitCode  (≤5s, then SIGKILL, ≤3s more)
                  └─ meanwhile: exitCode.then fires first
                       _emitCompletion(completionFor(cancelRequested: true, …))
                       _cleanup()
                          └─ _handleQueueItemCompletion
                                item.status = cancelled
                                _isQueueProcessing = false
                                _state = idle              ← both latches cleared
                if (generation != _generation) return;     ← don't touch a newer job
                _cleanup(); _emitCompletion(…)             ← suppressed by _completionEmitted
```

The worker's side: `ctrlc` sets an atomic flag; the progress loop notices it
within `progress_interval` (500 ms), calls `PipelineExecutor::terminate()`, and
exits **130**. It also sends `complete(false)` on the way out — which is the
subtlety behind the third bug below.

**Preview mode is different**: `main()` returns at the `--preview` branch
*before* `ctrlc` is installed, so it has no handler at all and dies immediately
on SIGTERM without unwinding.

---

## 5. How cancellation is recognised

There is no "cancelled" message in the protocol. The worker reports
`complete(false)` for a cancellation and for a genuine failure alike, and
`_handleStdoutLine` builds both into a `CompletionResult` with no `cancelled`
flag — so it defaults to `false` (`worker_manager.dart:312`).

So the app recognises a cancellation two ways, either of which suffices:
`_cancelRequested` (what it asked for) or **exit code 130** (what the worker
actually did). Relying on the flag alone was fragile — that is how bug (c) below
became unreachable. The distinction separates two outcomes the queue treats very
differently:

| `result` | `_handleQueueItemCompletion` does |
|---|---|
| `cancelled: true` | stop the queue, `_state = idle` |
| `success: false` | mark item **failed**, then `_processNextItem()` — *start the next job* |

So a mis-inference does not merely mislabel an item; it silently starts more
work and leaves `_isQueueProcessing` true.

---

## 6. Where it breaks

Four distinct defects, three already fixed, all sharing one cause: **UI state is
advanced optimistically and only ever retired by an event that is not
guaranteed to arrive.**

### (a) Orphaned children — fixed in #64

Killing the worker's pid did not kill `vspipe`/`ffmpeg`. They normally died on
EPIPE when the worker's pipes closed, but a child blocked on slow input (a
network share) writes nothing for minutes and never notices. Fixed with process
groups.

### (b) Cancel tearing down its successor — fixed in #65

`cancel()` waits for a real exit, which takes seconds. Cancellation emits a
completion, the queue starts the next job on that event, and the *cancelling*
call's trailing `_cleanup()` then nulled `_process` and cancelled the **new**
job's stdout subscription. Fixed with `_generation`.

### (c) Cancellation reported as failure — fixed in #66

`cancelled: _cancelRequested` was placed in a `??` fallback behind
`_pendingCompletion`, which is always set (§5), so it was unreachable. The queue
saw a plain failure and started the next job.

### (d) The completion that never arrives — fixed in #67

This is the structural one, and the actual cause of the reported symptom.

`cancelProcessing` sets `_state = cancelling` **before** doing anything, then
calls `WorkerManager.cancel()`. But:

```dart
Future<void> cancel() async {
  final process = _process;
  if (process == null) return;      // ← emits nothing at all
```

If `_process` is null, `cancel()` returns silently, **no `CompletionResult` is
ever emitted**, and `_state` stays `cancelling` forever. `canProcess` is false,
`startQueueProcessing` returns at its guard, and the UI spins with no progress
and no error — permanently, until the app is restarted.

`_process` is null more often than it looks:

- during `preparingJob`, before `startJob` has finished spawning — and
  `canCancel` includes `preparingJob`, so the Cancel button is live in exactly
  that window;
- if the job finished microseconds before the click;
- if `startJob` threw (its `catch` runs `_cleanup()`);
- after any earlier `_cleanup()`.

There is a second version of the same hazard: `_handleQueueItemCompletion`
opens with

```dart
if (_currentProcessingIndex < 0 || _currentProcessingIndex >= _queue.length) return;
```

A completion arriving when the index is out of range is **dropped silently**.
The latches are never cleared, and the item stays `processing` — a status that
is neither `ready` nor `canReprocess`, so `startQueueProcessing`'s reset loop
cannot recover it either. That item can never be run again.

---

## 7. Invariants, and what enforces them

Each of these was violated by one of the bugs above. They are now enforced, and
the enforcement is exercised by `app/test/main_viewmodel_lifecycle_test.dart`,
which drives the real viewmodel against a `FakeJobRunner`.

1. **Every started job produces exactly one `CompletionResult`.**
   `_completionEmitted` gives "at most one"; `_jobInFlight` gives "at least
   one" — `cancel()` reports even when there is no process to signal.
2. **`_state` never latches on an event that did not arrive.** `cancelProcessing`
   reconciles to `idle` if nothing retired the `cancelling` latch, and logs that
   it did so.
3. **An unattributable completion stands the queue down** rather than being
   dropped. `_handleQueueItemCompletion` calls `_stopProcessing()` instead of
   returning early.
4. **No `QueueItem` is left `processing`.** `_stopProcessing()` resets any it
   finds, and every path that ends processing goes through it — so the rescue
   cannot be forgotten on one of them.
5. **Cancelling is distinguishable from failing**, and is *observed* rather than
   inferred: `WorkerManager.completionFor` treats `cancelRequested` **or**
   `exitCode == 130` (what the worker actually returns) as cancelled.

### Testability

`MainViewModel` takes a `JobRunner` (`app/lib/services/job_runner.dart`),
defaulting to `WorkerManager`. Before that seam existed the queue state machine
could not be driven from a test at all, which is why three fixes for the same
hang shipped unverified — two of them "verified" by tests that only read source
text. Prefer behavioural tests here; source-scanning assertions have twice
produced false failures during ordinary refactoring.

### (e) The stale progress file — the actual cause, fixed in #67

The one that produced "the UI never updates". Everything above is real, but none
of it was this.

The worker polls `${TMPDIR}/vb_progress_${job.id}` for ffmpeg's progress, and
**`job.id` is the queue item's id** — identical every time that item is re-run.
ffmpeg writes `progress=end` as it terminates, so a cancelled run leaves one
behind. The next run's loop polls immediately, before its own ffmpeg has opened
and truncated the file, reads the previous run's tail, concludes the encode has
already finished, and **breaks out of the progress loop on its first
iteration** — then blocks forever in `decoder.wait()` while the pipeline encodes
at full speed behind it.

Confirmed by sampling the stuck worker: `__wait4` under `execute`, 0% CPU, while
vspipe sat at 440% and both ffmpegs ran. No progress was ever reported and the
job never completed.

Why it took four attempts to find:

- **The app was innocent throughout.** It never received a progress event,
  because none was ever sent. Every app-side fix was for a symptom.
- **It only follows a cancel**, because only a re-run of the same queue item
  reuses the id.
- **It is a race** between the first poll and ffmpeg's truncate, so it came and
  went. Adding `debugPrint` calls shifted the timing enough to hide it — which
  is why one traced build "seemed to work" with functionally identical code.
- **No test could reproduce it**: every test generated a fresh job id, so the
  file never pre-existed. Even seeding one deliberately does not fail against
  the broken worker locally, because ffmpeg truncates a local file almost
  instantly. The window is wide over a network share, which is where it showed.

Fixed two ways: the file is deleted before the pipeline starts, and
`progress_end_is_ours()` refuses to believe a `progress=end` seen before this run
has reported a frame. The second is what `test_94` pins, because it is the half
that can be tested deterministically.

## 8. Preview generation

A separate lifecycle with different rules, worth knowing because it shares the
worker binary and the same orphan hazards:

- one worker per preview, `--preview --frame N`, PNG on stdout;
- every scrubber movement cancels the in-flight preview and starts another;
- tracked in `_livePreviews` (a set, registered at spawn — a single field lost
  processes in the window between `await Process.start` returning and the
  assignment);
- cancellation signals the group and reaps in the background, so seeking is not
  blocked by a shutdown grace. `dispose()` uses the waiting variant.

Preview has **no** completion protocol and no queue interaction, so its failures
are leaks rather than hangs.
