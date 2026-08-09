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

## 5. Why cancellation is inferred, not reported

There is no "cancelled" message in the protocol. The worker reports
`complete(false)` for a cancellation and for a genuine failure alike, and
`_handleStdoutLine` builds both into a `CompletionResult` with no `cancelled`
flag — so it defaults to `false` (`worker_manager.dart:312`).

The app therefore has to *infer* cancellation from a flag it set itself
(`_cancelRequested`). That inference is the only thing separating two outcomes
the queue treats very differently:

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

### (d) The completion that never arrives — NOT fixed

This is the structural one, and the likeliest cause of the remaining symptom.

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

## 7. Invariants that should hold, and are not enforced

1. Every started job produces **exactly one** `CompletionResult`. Currently
   `_completionEmitted` enforces "at most one"; nothing enforces "at least one".
2. `_state.isActive` implies a live worker **or** a pending completion. Nothing
   checks this, and nothing times out.
3. `_isQueueProcessing` implies `_currentProcessingIndex` addresses a
   `processing` item. Violated whenever a completion is dropped.
4. No `QueueItem` remains `processing` once `_isQueueProcessing` is false.
   Violated by the dropped-completion path, and unrecoverable because
   `canReprocess` excludes `processing`.
5. Cancelling is always distinguishable from failing. Currently inferred from a
   local flag rather than reported by the worker (§5).

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
