#!/usr/bin/env python3
"""Print the faulting thread of recent native crashes, for CI logs.

A plugin that segfaults inside vspipe leaves nothing in the test output but
"signal 11", and the hosted runners can't be logged into.

- macOS writes a crash report (.ips) for every crashed process, naming the
  library and function that faulted; this prints the newest few for the given
  process names.
- Linux keeps nothing unless the job asked for core dumps
  (`.github/scripts/enable-core-dumps.sh`: `kernel.core_pattern` into
  `$VAPOURBOX_CORE_DIR`, default /tmp/cores, and `ulimit -c unlimited`). This
  runs gdb over the newest few cores: the faulting thread's backtrace, every
  thread's top frames, and the shared-library map, so an address in a stripped
  frame can still be resolved later (task #66).
- Windows: nothing to read; says so.

Never fails the step: it is diagnostic.

Usage: print-crash-reports.py [process-name ...]   (default: vspipe-bin python3)
"""
import glob
import json
import os
import re
import shutil
import subprocess
import sys

NAMES = sys.argv[1:] or ["vspipe-bin", "python3", "python3.12"]
NEWEST = 3


def macos():
    dirs = [os.path.expanduser("~/Library/Logs/DiagnosticReports"), "/Library/Logs/DiagnosticReports"]
    reports = sorted(
        (p for d in dirs for p in glob.glob(os.path.join(d, "*.ips"))
         if any(os.path.basename(p).startswith(n) for n in NAMES)),
        key=os.path.getmtime,
        reverse=True,
    )[:NEWEST]

    if not reports:
        print(f"No crash reports for {', '.join(NAMES)}.")
    for path in reports:
        print(f"=== {os.path.basename(path)}")
        with open(path, encoding="utf-8", errors="replace") as f:
            f.readline()  # one-line JSON header
            try:
                body = json.loads(f.read())
            except json.JSONDecodeError as e:
                print(f"  (unparseable: {e})")
                continue
        exc = body.get("exception", {})
        print(f"  {exc.get('type')} {exc.get('signal')} {exc.get('subtype', '')}".rstrip())
        images = body.get("usedImages", [])
        threads = body.get("threads", [])
        faulting = body.get("faultingThread", 0)
        if faulting >= len(threads):
            continue
        for i, frame in enumerate(threads[faulting].get("frames", [])[:30]):
            image = images[frame.get("imageIndex", -1)] if 0 <= frame.get("imageIndex", -1) < len(images) else {}
            lib = os.path.basename(image.get("path", image.get("name", "?")))
            sym = frame.get("symbol", f"+{frame.get('imageOffset', 0):#x}")
            print(f"  {i:2} {lib:32} {sym}")


def core_executable(core):
    """The crashed program's path, from the core's own note (`file` prints it
    as execfn), else a vspipe-bin under the deps directory."""
    try:
        out = subprocess.run(["file", core], capture_output=True, text=True, timeout=30).stdout
        m = re.search(r"execfn: '([^']+)'", out)
        if m and os.path.exists(m.group(1)):
            return m.group(1)
    except (OSError, subprocess.SubprocessError):
        pass
    deps = os.environ.get("VAPOURBOX_DEPS_DIR", "")
    for cand in glob.glob(os.path.join(deps, "**", "vspipe-bin"), recursive=True):
        return cand
    return None


def linux():
    core_dir = os.environ.get("VAPOURBOX_CORE_DIR", "/tmp/cores")
    cores = sorted(glob.glob(os.path.join(core_dir, "core*")), key=os.path.getmtime, reverse=True)
    if not cores:
        print(f"No core dumps in {core_dir} (were they enabled? see enable-core-dumps.sh).")
        return
    print(f"{len(cores)} core dump(s) in {core_dir}; the newest {min(NEWEST, len(cores))}:")
    gdb = shutil.which("gdb")
    for core in cores[:NEWEST]:
        print(f"=== {os.path.basename(core)}")
        exe = core_executable(core)
        if not exe:
            print("  (could not find the executable that wrote it)")
            continue
        if not gdb:
            print(f"  executable: {exe} (gdb not installed: no backtrace)")
            continue
        cmd = [gdb, "-batch", "-nx", "-q",
               "-ex", "set pagination off",
               "-ex", "set print thread-events off",
               "-ex", "echo \\n--- faulting thread\\n",
               "-ex", "bt 40",
               "-ex", "echo \\n--- registers\\n",
               "-ex", "info registers rip rsp rbp rdi rsi rdx rcx",
               "-ex", "x/6i $pc",
               "-ex", "echo \\n--- every thread (top frames)\\n",
               "-ex", "thread apply all bt 8",
               "-ex", "echo \\n--- shared libraries\\n",
               "-ex", "info sharedlibrary",
               exe, core]
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
            text = r.stdout + r.stderr
        except (OSError, subprocess.SubprocessError) as e:
            text = f"(gdb failed: {e})"
        # gdb's own chatter about missing debug info adds nothing here.
        lines = [l for l in text.splitlines()
                 if not l.startswith(("warning: Could not load shared library symbols",
                                      "Do you need \"set solib-search-path\"",
                                      "Use the \"info sharedlibrary\""))]
        print(f"  executable: {exe}")
        for line in lines:
            print(f"  {line}")


def main():
    try:
        if sys.platform == "darwin":
            macos()
        elif sys.platform.startswith("linux"):
            linux()
        else:
            print(f"No crash reports are collected on {sys.platform}.")
    except Exception as e:  # diagnostic only: never fail the step
        print(f"print-crash-reports: {e}")


if __name__ == "__main__":
    main()
