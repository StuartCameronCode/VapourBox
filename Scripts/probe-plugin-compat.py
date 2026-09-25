#!/usr/bin/env python3
"""Load and render every plugin in a VapourBox deps bundle, one per process.

Answers "which bundled plugins can this CPU run?" (issue #92). Each plugin is
loaded by path into a core created with DISABLE_AUTO_LOADING, so one plugin
that faults while loading cannot take the others down with it. That masking is
exactly what made the first version of this probe report every plugin as
crashed: R78 autoloads the whole plugin directory, and MVTools faults in a
static initializer before any filter runs.

The parent never imports vapoursynth. Every test is a child process, so a
SIGILL / 0xC000001D in a plugin is a result, not the end of the run.

Usage:
    python probe-plugin-compat.py [DEPS_DIR] [--report FILE] [--json FILE]
                                  [--wrap "sde64 -nhm --"] [--fail-on-crash]

DEPS_DIR defaults to the installed bundle for this OS. Run it with the
bundle's own Python (see probe-plugin-compat.sh) so no system Python is needed.
"""

import argparse
import json
import os
import platform
import shlex
import subprocess
import sys
from datetime import datetime

# Namespace -> render call. `c` is a 640x480 YUV420P8 BlankClip, 12 frames long
# (temporal filters need neighbours). Calls mirror worker/templates where the
# pipeline uses the plugin, so a pass here means the shipped call runs. A
# namespace missing from this table is still load-tested.
RENDER = {
    "mv": ("sup = core.mv.Super(c, pel=2, sharp=1)\n"
           "bw = core.mv.Analyse(sup, isb=True, delta=1, blksize=8, overlap=4)\n"
           "fw = core.mv.Analyse(sup, isb=False, delta=1, blksize=8, overlap=4)\n"
           "c = core.mv.Degrain1(clip=c, super=sup, mvbw=bw, mvfw=fw)"),
    "znedi3": "c = core.znedi3.nnedi3(c, field=1, dh=False)",
    "nnedi3": "c = core.nnedi3.nnedi3(c, field=1, dh=False)",
    "eedi3m": "c = core.eedi3m.EEDI3(c, field=1, dh=False)",
    "fmtc": "c = core.fmtc.resample(c, w=320, h=240)",
    "dfttest": "c = core.dfttest.DFTTest(c)",
    "misc": "c = core.misc.SCDetect(c)",
    "rgvs": "c = core.rgvs.RemoveGrain(c, mode=2)",
    "grain": "c = core.grain.Add(c, var=4)",
    "cas": "c = core.cas.CAS(c, sharpness=0.5)",
    "dctf": "c = core.dctf.DCTFilter(c, factors=[1.0] * 8)",
    "deblock": "c = core.deblock.Deblock(c, quant=25)",
    "warp": "c = core.warp.AWarpSharp2(c, thresh=128, blur=3, type=0)",
    # opt=2 (SSE2) is what script_generator::ctmf_opt picks on a CPU without
    # AVX2, i.e. on every machine this probe exists for.
    "ctmf": "c = core.ctmf.CTMF(c, radius=2, memsize=16777216, opt=2)",
    "tcanny": "c = core.tcanny.TCanny(c, sigma=1.5, mode=-1)",
    "tmedian": "c = core.tmedian.TemporalMedian(c, radius=1)",
    "removedirt": "c = core.removedirt.RestoreMotionBlocks(c, restore=c)",
    "lghost": "c = core.lghost.LGhost(c, mode=[1], shift=[2], intensity=[10])",
    "bwdif": "c = core.bwdif.Bwdif(c, field=1)",
    "zsmooth": "c = core.zsmooth.CCD(c, threshold=4, scale=1)",
    "neo_f3kdb": "c = core.neo_f3kdb.Deband(c, y=64, cb=64, cr=64)",
    "vivtc": "c = core.vivtc.VFM(c, order=1)",
    "fb": "c = core.fb.FillBorders(c, left=2, right=2, top=2, bottom=2, mode='fillmargins')",
    "descratch": "c = core.descratch.DeScratch(c)",
    "fft3dfilter": "c = core.fft3dfilter.FFT3DFilter(c, sigma=2.0, bt=3)",
    "ttmpsm": "c = core.ttmpsm.TTempSmooth(c)",
    "flux": "c = core.flux.SmoothT(c, temporal_threshold=7)",
    "dedot": "c = core.dedot.Dedot(c)",
    "bifrost": "c = core.bifrost.Bifrost(c)",
    "retinex": "c = core.retinex.MSRCP(core.std.ShufflePlanes(c, 0, vs.GRAY))",
    "akarin": "c = core.akarin.Expr(c, 'x 1 +')",
}

# OpenCL filters need a GPU to render, which says nothing about the CPU.
LOAD_ONLY = ("knlmeanscl", "nnedi3cl")

# Plugins that call another plugin internally, by file-name substring. The
# dependency is loaded first; it is also tested on its own, so a crash that
# only shows up here is still attributable.
DEPENDS = {"ttempsmooth": ["miscfilters"]}

# Exercises the parts of VapourSynth itself every job touches: zimg resizing
# and the std.Expr JIT, both of which pick SIMD code paths at runtime.
CORE_RENDER = ("c = core.resize.Bicubic(c, width=320, height=240, format=vs.YUV444P16)\n"
               "c = core.std.Expr(c, 'x 1 +')")

CHILD = r'''
import sys, vapoursynth as vs

class _NoAutoload(vs.EnvironmentPolicy):
    def on_policy_registered(self, api):
        self._env = api.create_environment(vs.CoreCreationFlags.DISABLE_AUTO_LOADING)
    def get_current_environment(self):
        return self._env
    def set_environment(self, env):
        prev, self._env = self._env, env
        return prev

vs.register_policy(_NoAutoload())
core = vs.core
path, render = sys.argv[1], sys.argv[2]
for dep in sys.argv[3:]:
    core.std.LoadPlugin(dep)
new_ns = []
if path:
    before = {p.namespace for p in core.plugins()}
    try:
        core.std.LoadPlugin(path)
    except vs.Error as e:
        print("NOTPLUGIN " + str(e).replace("\n", " "), flush=True)
        sys.exit(3)
    new_ns = sorted({p.namespace for p in core.plugins()} - before)
print("NAMESPACES " + ",".join(new_ns), flush=True)
if render == "@load":
    sys.exit(0)
c = core.std.BlankClip(width=640, height=480, length=12, format=vs.YUV420P8)
if render == "@auto":
    snippets = [RENDER[n] for n in new_ns if n in RENDER]
    if not snippets:
        print("NORENDER", flush=True)
        sys.exit(0)
    render = "\n".join(snippets)
exec(render)
for i in range(len(c)):
    c.get_frame(i)
print("RENDERED", flush=True)
'''

# Under SDE on Windows, Microsoft's runtime DLLs pick SIMD paths from what the
# *host* kernel reports (IsProcessorFeaturePresent reads shared kernel memory,
# which SDE cannot virtualise), so they execute AVX that SDE then flags — on
# code that is fine on real pre-AVX hardware. A fault in one of these says
# nothing about the plugin under test.
EMULATION_ARTIFACT_IMAGES = ("vcruntime140", "ucrtbase", "msvcp140", "ntdll",
                             "kernelbase", "kernel32")

WINDOWS_CRASH_NAMES = {
    0xC000001D: "illegal instruction",
    0xC0000005: "access violation",
    0xC00000FD: "stack overflow",
    0xC0000094: "integer divide by zero",
    0xC0000409: "stack buffer overrun",
}


def default_deps_dir():
    system = platform.system()
    home = os.path.expanduser("~")
    if system == "Darwin":
        arch = "macos-arm64" if platform.machine() == "arm64" else "macos-x64"
        return os.path.join(home, "Library", "Application Support", "VapourBox", "deps", arch)
    if system == "Linux":
        arch = "linux-arm64" if platform.machine() == "aarch64" else "linux-x64"
        base = os.environ.get("XDG_DATA_HOME") or os.path.join(home, ".local", "share")
        return os.path.join(base, "VapourBox", "deps", arch)
    return os.path.join(os.getcwd(), "deps", "windows-x64")


def bundle_layout(deps):
    """Python executable, child environment and plugin files for a bundle."""
    env = {k: v for k, v in os.environ.items()
           if k not in ("PYTHONHOME", "PYTHONPATH", "VAPOURSYNTH_EXTRA_PLUGIN_PATH")}
    env["PYTHONNOUSERSITE"] = "1"
    vs_dir = os.path.join(deps, "vapoursynth")
    if platform.system() == "Windows":
        python = os.path.join(vs_dir, "python.exe")
        env["PYTHONHOME"] = vs_dir
        env["PYTHONPATH"] = os.pathsep.join([
            os.path.join(deps, "python-packages"),
            os.path.join(vs_dir, "Lib", "site-packages"),
        ])
        env["PATH"] = os.pathsep.join([vs_dir, env.get("PATH", "")])
        plugin_dir, exts = os.path.join(vs_dir, "vs-plugins"), (".dll",)
    else:
        py_home = os.path.join(deps, "python")
        python = os.path.join(py_home, "bin", "python3")
        env["PYTHONHOME"] = py_home
        env["PYTHONPATH"] = os.pathsep.join([
            os.path.join(deps, "python-packages"),
            deps,
            os.path.join(py_home, "lib", "python3.12", "site-packages"),
        ])
        libs = [vs_dir, os.path.join(py_home, "lib"), os.path.join(deps, "lib")]
        var = "DYLD_LIBRARY_PATH" if platform.system() == "Darwin" else "LD_LIBRARY_PATH"
        env[var] = os.pathsep.join(libs + ([env[var]] if env.get(var) else []))
        plugin_dir = os.path.join(vs_dir, "plugins")
        exts = (".dylib",) if platform.system() == "Darwin" else (".so",)

    files = []
    for d in (plugin_dir, os.path.join(vs_dir, "zsmooth")):
        if os.path.isdir(d):
            files += sorted(os.path.join(d, f) for f in os.listdir(d)
                            if f.lower().endswith(exts))
    return python, env, files


def classify(proc, sde_wrapped):
    out, err, code = proc.stdout, proc.stderr, proc.returncode
    namespaces = ""
    for line in out.splitlines():
        if line.startswith("NAMESPACES "):
            namespaces = line[len("NAMESPACES "):]
    tail = "\n".join(err.strip().splitlines()[-6:])

    if sde_wrapped and ("SDE-ERROR" in err or "not valid for specified chip" in err):
        image = next((l.split("Image:", 1)[1].strip() for l in err.splitlines()
                      if "Image:" in l), "")
        where = os.path.basename(image.replace("\\", "/")) or "unknown image"
        if any(a in where.lower() for a in EMULATION_ARTIFACT_IMAGES):
            return ("INCONCLUSIVE",
                    f"SDE flagged the OS runtime ({where}), not this plugin",
                    namespaces, tail)
        return "CRASHED", f"illegal instruction in {where}", namespaces, tail
    if code < 0:
        sig = -code
        try:
            import signal
            name = signal.Signals(sig).name
        except (ValueError, ImportError):
            name = f"signal {sig}"
        return "CRASHED", name, namespaces, tail
    if code & 0xFFFFFFFF in WINDOWS_CRASH_NAMES:
        return "CRASHED", WINDOWS_CRASH_NAMES[code & 0xFFFFFFFF], namespaces, tail
    if code == 3 and "NOTPLUGIN" in out:
        return "SKIPPED", "not a VapourSynth plugin", namespaces, ""
    if code == 0 and "NORENDER" in out:
        return "LOADED", "no render test for this namespace", namespaces, ""
    if code == 0 and "RENDERED" in out:
        return "PASS", "", namespaces, ""
    if code == 0:
        return "LOADED", "load-only test", namespaces, ""
    return "ERROR", f"exit {code}", namespaces, tail


def cpu_summary():
    lines = [f"Machine: {platform.system()} {platform.release()} ({platform.machine()})"]
    system = platform.system()
    try:
        if system == "Darwin":
            def sysctl(key):
                r = subprocess.run(["sysctl", "-n", key], capture_output=True, text=True)
                return r.stdout.strip()
            feats = sysctl("machdep.cpu.features").split()
            leaf7 = sysctl("machdep.cpu.leaf7_features").split()
            lines.append(f"CPU: {sysctl('machdep.cpu.brand_string')}")
            # macOS spells plain AVX as "AVX1.0".
            lines.append(f"AVX: {int('AVX1.0' in feats)}   AVX2: {int('AVX2' in leaf7)}")
        elif system == "Linux":
            with open("/proc/cpuinfo") as f:
                info = f.read()
            model = next((l.split(":", 1)[1].strip() for l in info.splitlines()
                          if l.startswith("model name")), "unknown")
            flags = next((l.split(":", 1)[1].split() for l in info.splitlines()
                          if l.startswith("flags")), [])
            lines.append(f"CPU: {model}")
            lines.append(f"AVX: {int('avx' in flags)}   AVX2: {int('avx2' in flags)}")
        elif system == "Windows":
            import ctypes
            present = ctypes.windll.kernel32.IsProcessorFeaturePresent
            lines.append(f"CPU: {platform.processor()}")
            # PF_AVX_INSTRUCTIONS_AVAILABLE = 39, PF_AVX2_INSTRUCTIONS_AVAILABLE = 40
            lines.append(f"AVX: {int(bool(present(39)))}   AVX2: {int(bool(present(40)))}")
    except Exception as e:  # the report is still useful without CPU details
        lines.append(f"CPU: unavailable ({e})")
    return lines


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("deps", nargs="?", default=None)
    ap.add_argument("--report", default=None, help="text report path")
    ap.add_argument("--json", default=None, help="machine-readable results path")
    ap.add_argument("--wrap", default="", help='prefix for each test, e.g. "sde64 -nhm --"')
    ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--fail-on-crash", action="store_true",
                    help="exit 1 if anything crashed, errored or was inconclusive (for CI gates)")
    args = ap.parse_args()

    deps = os.path.abspath(args.deps or default_deps_dir())
    if not os.path.isdir(os.path.join(deps, "vapoursynth")):
        sys.exit(f"No VapourBox deps bundle found at {deps}\n"
                 "Pass the path to your deps folder as the first argument.")
    python, env, files = bundle_layout(deps)
    wrap = shlex.split(args.wrap)
    child_src = f"RENDER = {RENDER!r}\n" + CHILD

    if args.report is None:
        desktop = os.path.join(os.path.expanduser("~"), "Desktop")
        where = desktop if os.path.isdir(desktop) else os.getcwd()
        args.report = os.path.join(where, "vapourbox-plugin-compat-report.txt")

    version = ""
    try:
        with open(os.path.join(deps, "version.json")) as f:
            version = json.dumps(json.load(f))
    except (OSError, ValueError):
        pass

    header = ["VapourBox plugin compatibility report",
              f"Generated: {datetime.now():%Y-%m-%d %H:%M:%S}",
              f"Deps: {deps}",
              f"Bundle: {version or 'unknown'}"]
    header += cpu_summary()
    if wrap:
        header.append(f"Wrapped with: {' '.join(wrap)}")
    header.append("=" * 72)

    report = open(args.report, "w")

    def emit(line=""):
        print(line, flush=True)
        report.write(line + "\n")

    for line in header:
        emit(line)

    tests = [("(core: VapourSynth, zimg, Expr)", "", CORE_RENDER)]
    for f in files:
        stem = os.path.basename(f)
        tests.append((stem, f, None))

    def deps_for(path):
        low = os.path.basename(path).lower()
        wanted = next((v for k, v in DEPENDS.items() if k in low), [])
        return [f for f in files
                if any(w in os.path.basename(f).lower() for w in wanted)]

    results = []
    for label, path, render in tests:
        extra = []
        if render is None:
            # Unknown until the child reports its namespaces; OpenCL is load-only.
            render = "@auto"
            if any(k in os.path.basename(path).lower() for k in LOAD_ONLY):
                render = "@load"
            extra = deps_for(path)
        cmd = wrap + [python, "-c", child_src, path, render] + extra
        try:
            proc = subprocess.run(cmd, env=env, capture_output=True, text=True,
                                  timeout=args.timeout)
            status, detail, ns, tail = classify(proc, bool(wrap))
        except subprocess.TimeoutExpired:
            status, detail, ns, tail = "ERROR", f"timed out after {args.timeout}s", "", ""
        results.append({"file": label, "namespaces": ns, "status": status,
                        "detail": detail})
        shown = f"{label} [{ns}]" if ns else label
        emit(f"{shown:<46} {status}{' (' + detail + ')' if detail else ''}")
        if tail and status in ("CRASHED", "ERROR"):
            for t in tail.splitlines():
                emit(f"    {t}")

    counts = {s: sum(r["status"] == s for r in results)
              for s in ("PASS", "LOADED", "CRASHED", "ERROR", "INCONCLUSIVE", "SKIPPED")}
    emit("=" * 72)
    emit("Summary: " + ", ".join(f"{n} {s.lower()}" for s, n in counts.items()))
    report.close()
    print(f"\nReport written to: {args.report}")

    if args.json:
        with open(args.json, "w") as f:
            json.dump({"deps": deps, "bundle": version, "results": results}, f, indent=2)
    if args.fail_on_crash and (counts["CRASHED"] or counts["ERROR"] or counts["INCONCLUSIVE"]):
        sys.exit(1)


if __name__ == "__main__":
    main()
