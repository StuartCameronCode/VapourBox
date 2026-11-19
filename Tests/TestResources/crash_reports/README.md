# Crash-report fixtures (task #72)

Inputs for `app/test/crash_report_classifier_test.dart`, which runs
`.github/scripts/print-crash-reports.py --classify` over them.

- `macos-x64-vspipe-teardown-sigill.ips`: the faulting thread of
  `vspipe-bin-2026-11-18-023804.ips` from the push gate's macOS x64 job,
  run 44088351262 attempt 2 (deps 1.17.0-rc3), rebuilt as an `.ips` from the
  frames CI printed. CI printed only the faulting thread, so it has only that
  thread; the image paths are placeholders. vspipe R78's teardown race (task
  #68) as macOS reports it: SIGILL in `_os_unfair_lock_unowned_abort`.
- `macos-arm64-moltenvk-sigsegv.ips`: run 44064242986's macOS arm64
  `vspipe-bin-2026-11-17-103557.ips` (RIFE creating its Vulkan device
  through MoltenVK), rebuilt the same way, with some frames left out. A
  crash that is not the race.
- `linux-vspipe-teardown-sigsegv.gdb.txt`: the gdb output CI printed for
  `core.vspipe-bin.52015.1795010338`, run 44318045317's Linux job, from
  "faulting thread" to the end of "every thread (top frames)". The same race
  on Linux: SIGSEGV in `outputFrame`, main in `vpy4_freeScript`.
