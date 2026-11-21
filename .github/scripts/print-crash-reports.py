#!/usr/bin/env python3
"""Print the faulting thread of recent native crashes, for CI logs.

A plugin that segfaults inside vspipe leaves nothing in the test output but
"signal 11", and the hosted runners can't be logged into.

- macOS writes a crash report (.ips) for every crashed process, naming the
  library and function that faulted; this prints the newest few for the given
  process names: the faulting thread, then every other thread's top frames
  (task #72: the teardown race's other half is the main thread, in
  `freeScript` or `exit`). The workflows also upload the raw reports.
- Linux keeps nothing unless the job asked for core dumps
  (`.github/scripts/enable-core-dumps.sh`: `kernel.core_pattern` piped to a
  handler that writes into `$VAPOURBOX_CORE_DIR`, default /tmp/cores). This
  runs gdb over the newest few cores: the faulting thread's backtrace, every
  thread's top frames, and the shared-library map, so an address in a stripped
  frame can still be resolved later (task #66).
- Windows: nothing to read; says so.

Each crash is then classified: the first frame outside the system libraries
names the image that faulted, and one signature is recognised by name,
vspipe R78's teardown race (task #68): that frame is vspipe's own
`frameDoneCallback` or `outputFrame`. On macOS it arrives as SIGILL
(`pthread_cond_signal` on the freed condition variable traps in
`_os_unfair_lock_unowned_abort`), on Linux as SIGSEGV (task #72). The line
also says whether the installed bundle's vspipe carries the fix (its
`--version` marker, read from the binary). A second signature is Core ML's
kernel compile on an Intel Mac (task #94): Metal Performance Shaders
asserting in `MPSLibrary::MPSKey_Compile` (via `MTLReportFailure`) under
an ONNX Runtime prediction, SIGABRT. Intel Macs no longer run Core ML, so
seeing it means something offered Core ML there again.

Never fails the step: it is diagnostic.

Usage:
  print-crash-reports.py [process-name ...]   (default: vspipe-bin python3 python3.12)
  print-crash-reports.py --classify FILE ...  one line per file: FILE<TAB>verdict
                                              (.ips, or gdb backtrace text)
"""
import glob
import json
import os
import re
import shutil
import subprocess
import sys

DEFAULT_NAMES = ["vspipe-bin", "python3", "python3.12"]
NEWEST = 3

TEARDOWN = "vspipe-teardown"
MPS_COMPILE = "coreml-mps-compile"
# The marker task #68's patch adds to `vspipe --version`; it is a literal in
# the binary, so it can be found without running vspipe (which needs the
# bundle's environment).
FIX_MARKER = b"VapourBox patch: vspipe frame-done count"
VSPIPE_IMAGES = {"vspipe", "vspipe-bin", "vspipe-bin.real", "vspipe.exe"}
VSPIPE_CALLBACKS = ("frameDoneCallback", "outputFrame")
TEARDOWN_MAIN = ("freeScript", "vpy4_freeScript", "exit", "__cxa_finalize")
_SYSTEM = re.compile(
    r"^(libsystem_\w+\.dylib|libc\+\+(abi)?\.1\.dylib|libdyld\.dylib|dyld"
    r"|libc\.so\.\d+|libpthread\.so\.\d+|libstdc\+\+\.so\.\d+|libgcc_s\.so\.\d+"
    r"|ld-linux[-\w]*\.so\.\d+|\?\?)$"
)


def is_system(image):
    return bool(_SYSTEM.match(image or "??"))


def classify(frames, other_threads=()):
    """frames: the faulting thread, top first, as (image basename, symbol).
    other_threads: the other threads' frames, the same way. Returns
    (verdict, detail): verdict is TEARDOWN for task #68's race,
    MPS_COMPILE for task #94's Metal kernel compile abort, else
    "image:<name>" for the first frame outside the system libraries, else
    "unknown"."""
    if any(img == "MPSCore" and "MPSKey_Compile" in sym for img, sym in frames[:12]):
        via = next((img for img, _ in frames if img in ("Espresso", "CoreML", "libonnxruntime")), None)
        return MPS_COMPILE, "MPSLibrary::MPSKey_Compile" + (f" under {via}" if via else "")
    first = next(((img, sym) for img, sym in frames if not is_system(img)), None)
    if first is None:
        return "unknown", "every frame is in a system library"
    img, sym = first
    if img in VSPIPE_IMAGES and any(cb in sym for cb in VSPIPE_CALLBACKS):
        main = next((s for t in other_threads for _, s in t[:12]
                     if any(m in s for m in TEARDOWN_MAIN)), None)
        detail = f"{img} {sym.split('(')[0]}"
        if main:
            detail += f"; another thread is in {main.split('(')[0]}"
        return TEARDOWN, detail
    return f"image:{img}", sym


def vspipe_fix_state():
    """'yes' / 'no' for the installed bundle's vspipe, or None if not found."""
    deps = os.environ.get("VAPOURBOX_DEPS_DIR", "")
    if not deps:
        return None
    for pattern in ("vapoursynth/vspipe-bin.real", "vapoursynth/vspipe-bin",
                    "vapoursynth/Lib/site-packages/vapoursynth/vspipe.exe"):
        path = os.path.join(deps, pattern)
        if os.path.isfile(path):
            with open(path, "rb") as f:
                return "yes" if FIX_MARKER in f.read() else "no"
    return None


def verdict_line(verdict, detail):
    if verdict == TEARDOWN:
        fix = vspipe_fix_state()
        has = {"yes": "the installed vspipe carries the fix, so this is NOT that race being unfixed: look again",
               "no": "the installed vspipe does not carry the fix (deps before 1.18.0)",
               None: "could not check the installed vspipe for the fix"}[fix]
        return (f"  => vspipe R78's teardown race (task #68): {detail}. "
                f"Not a plugin or an instruction-set fault; {has}.")
    if verdict == MPS_COMPILE:
        return (f"  => Core ML's Metal kernel compile aborted the process (task #94): {detail}. "
                "Intel Macs should not be running Core ML: check ai_runtime.preferred_providers() "
                "and VAPOURBOX_AI_COREML_ON_INTEL.")
    if verdict.startswith("image:"):
        return f"  => faulted in {verdict[6:]}: {detail}"
    return f"  => {detail}"


# --- macOS -----------------------------------------------------------------

def ips_threads(path):
    """(exception summary, faulting thread frames, other threads' frames)."""
    with open(path, encoding="utf-8", errors="replace") as f:
        f.readline()  # one-line JSON header
        body = json.loads(f.read())
    exc = body.get("exception", {})
    summary = f"{exc.get('type')} {exc.get('signal')} {exc.get('subtype', '')}".rstrip()
    images = body.get("usedImages", [])

    def frames_of(thread):
        out = []
        for frame in thread.get("frames", []):
            idx = frame.get("imageIndex", -1)
            image = images[idx] if 0 <= idx < len(images) else {}
            lib = os.path.basename(image.get("path", image.get("name", "??")) or "??")
            sym = frame.get("symbol", f"+{frame.get('imageOffset', 0):#x}")
            out.append((lib, sym))
        return out

    threads = body.get("threads", [])
    faulting = body.get("faultingThread", 0)
    fault = frames_of(threads[faulting]) if faulting < len(threads) else []
    others = [(i, frames_of(t)) for i, t in enumerate(threads) if i != faulting]
    return summary, fault, others


def print_ips(path):
    print(f"=== {os.path.basename(path)}")
    try:
        summary, fault, others = ips_threads(path)
    except (OSError, ValueError) as e:
        print(f"  (unparseable: {e})")
        return
    print(f"  {summary}")
    print("  --- faulting thread")
    for i, (lib, sym) in enumerate(fault[:30]):
        print(f"  {i:2} {lib:32} {sym}")
    for n, frames in others:
        print(f"  --- thread {n}")
        for i, (lib, sym) in enumerate(frames[:8]):
            print(f"  {i:2} {lib:32} {sym}")
    print(verdict_line(*classify(fault, [f for _, f in others])))


def macos(names):
    dirs = [os.path.expanduser("~/Library/Logs/DiagnosticReports"), "/Library/Logs/DiagnosticReports"]
    reports = sorted(
        (p for d in dirs for p in glob.glob(os.path.join(d, "*.ips"))
         if any(os.path.basename(p).startswith(n) for n in names)),
        key=os.path.getmtime,
        reverse=True,
    )[:NEWEST]

    if not reports:
        print(f"No crash reports for {', '.join(names)}.")
    for path in reports:
        print_ips(path)


# --- Linux -----------------------------------------------------------------

_GDB_FRAME = re.compile(r"^\s*#\d+\s+(?:0x[0-9a-fA-F]+ in )?(.*?)(?: from (\S+))?\s*$")


def gdb_threads(text, exe="vspipe-bin"):
    """(faulting thread frames, other threads' frames) from gdb's output.
    The faulting thread is the block after "--- faulting thread" if this
    script printed it, else the first backtrace in the text."""
    def parse(block):
        out = []
        for line in block:
            m = _GDB_FRAME.match(line)
            if m:
                sym, lib = m.group(1), m.group(2)
                out.append((os.path.basename(lib) if lib else exe, sym))
        return out

    lines = text.splitlines()
    blocks, cur, start = [], [], 0  # (index of the block's first line, its lines)
    for i, line in enumerate(lines):
        if _GDB_FRAME.match(line) and line.strip().startswith("#"):
            if not cur:
                start = i
            cur.append(line)
        elif cur:
            blocks.append((start, cur))
            cur = []
    if cur:
        blocks.append((start, cur))
    marker = next((i for i, l in enumerate(lines) if "--- faulting thread" in l), -1)
    chosen = next((b for s, b in blocks if s > marker), None)
    fault = parse(chosen) if chosen else []
    others = [parse(b) for _, b in blocks if b is not chosen]
    return fault, others


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
        fault, others = gdb_threads(text, os.path.basename(exe))
        print(verdict_line(*classify(fault, others)))


# --- command line ----------------------------------------------------------

def classify_file(path):
    if path.endswith(".ips"):
        _, fault, others = ips_threads(path)
        return classify(fault, [f for _, f in others])
    with open(path, encoding="utf-8", errors="replace") as f:
        fault, others = gdb_threads(f.read())
    return classify(fault, others)


def main(argv):
    if argv and argv[0] == "--classify":
        for path in argv[1:]:
            try:
                verdict, detail = classify_file(path)
            except (OSError, ValueError) as e:
                verdict, detail = "unreadable", str(e)
            print(f"{path}\t{verdict}\t{detail}")
        return
    names = argv or DEFAULT_NAMES
    try:
        if sys.platform == "darwin":
            macos(names)
        elif sys.platform.startswith("linux"):
            linux()
        else:
            print(f"No crash reports are collected on {sys.platform}.")
    except Exception as e:  # diagnostic only: never fail the step
        print(f"print-crash-reports: {e}")


if __name__ == "__main__":
    main(sys.argv[1:])
