# VapourSynth script (run it with the bundle's vspipe -i, not python): every
# plugin a deps bundle ships must load in vspipe, as the worker runs it
# (task #116).
#
# The deps-v1.18.0-rc3 Windows bundle shipped DCTFilter, DFTTest and
# FFT3DFilter without libfftw3f-3.dll beside them in vs-plugins\. Every file
# was present, so the packaging check passed. The v2 CPU gate loads plugins
# through vapoursynth\python.exe, whose own directory held the DLL, so it
# passed too. Under vspipe.exe all three failed with GetLastError 126.
#
# Input: VAPOURBOX_CHECK_PLUGINS, absolute paths separated by os.pathsep.
# These are the files the bundle promises (deps-expected-plugins.json).
# Each must be a plugin that autoload or LoadPlugin loads, or a support
# library LoadPlugin opens but finds no entry point in (libzstd.dll). Any other
# error, such as a missing dependency, fails the check. The caller also fails
# on any "Failed to load" line vspipe prints while autoloading.
#
# Prints PLUGIN_LOAD_OK / PLUGIN_LOAD_SUPPORT / PLUGIN_LOAD_FAIL lines on stderr
# and raises if any failed.

import os
import sys

import vapoursynth as vs

core = vs.core


def norm(path):
    return os.path.normcase(os.path.normpath(os.path.abspath(path)))


files = [f for f in os.environ.get("VAPOURBOX_CHECK_PLUGINS", "").split(os.pathsep) if f]
if not files:
    raise vs.Error("check-plugins-load: VAPOURBOX_CHECK_PLUGINS names no files")

loaded = {norm(p.plugin_path) for p in core.plugins() if p.plugin_path}
failed = []
for f in files:
    if norm(f) in loaded:
        print(f"PLUGIN_LOAD_OK {f}", file=sys.stderr)
        continue
    if not os.path.isfile(f):
        failed.append(f"{f}: file missing")
        continue
    try:
        core.std.LoadPlugin(f)
    except vs.Error as e:
        text = str(e).replace("\n", " ")
        if text.startswith("No entry point found"):
            print(f"PLUGIN_LOAD_SUPPORT {f}", file=sys.stderr)
        elif "already loaded" in text:
            print(f"PLUGIN_LOAD_OK {f}", file=sys.stderr)
        else:
            failed.append(f"{f}: {text}")
        continue
    print(f"PLUGIN_LOAD_OK {f}", file=sys.stderr)

for line in failed:
    print(f"PLUGIN_LOAD_FAIL {line}", file=sys.stderr)
if failed:
    raise vs.Error(f"{len(failed)} plugin(s) do not load under vspipe")

print(f"PLUGIN_LOAD_DONE {len(files)} checked", file=sys.stderr)
core.std.BlankClip(length=1).set_output()
