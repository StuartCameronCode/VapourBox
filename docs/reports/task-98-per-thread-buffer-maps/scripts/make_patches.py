#!/usr/bin/env python3
"""Writes the five task #98 thread-safety patches into Scripts/patches/.

Usage: make_patches.py <work dir>

Clones each plugin at the commit the download-deps-* scripts pin, rewrites
its per-thread buffer map access mechanically (below), and saves `git diff`
behind a header. Re-running it reproduces the committed patches byte for
byte, so a reviewer can see that nothing but the locking changed.

The rewrite, the same for every plugin:
  - the header gets `mutable std::shared_mutex bufferMutex;` beside the maps
    and `threadBuffer(map)`, which looks the calling thread's buffer up under
    a shared lock;
  - getFrame checks for the thread's buffers under the shared lock and
    allocates and emplaces them under a unique lock (only the calling thread
    inserts its own key, so nothing can insert it between the two);
  - every kernel's `d->X.at(threadId).get()` becomes `d->threadBuffer(d->X)`,
    and the kernel's now-unused `threadId` local goes;
  - the plugin's name gets MARKER, so a test (`core.<ns>.name`) and the deps
    scripts (a byte search of the binary) can tell a patched build from an
    old one: none of these report a version that changed.
EEDI3m r10 already locks its insert and lookup; only its first count()
moves under the shared lock.
"""
import pathlib
import subprocess
import sys
import textwrap

MARKER = " (VapourBox: locked per-thread buffers, task #98)"
REPO = pathlib.Path(__file__).resolve().parents[4]
OUT = REPO / "Scripts" / "patches"

PLUGINS = {
    "dfttest": ("https://github.com/HomeOfVapourSynthEvolution/VapourSynth-DFTTest.git",
                "bc5e0186a7f309556f20a8e9502f2238e39179b8"),
    "lghost": ("https://github.com/HomeOfVapourSynthEvolution/VapourSynth-LGhost.git", "r1"),
    "ctmf": ("https://github.com/HomeOfVapourSynthEvolution/VapourSynth-CTMF.git", "r5"),
    "tcanny": ("https://github.com/HomeOfVapourSynthEvolution/VapourSynth-TCanny.git",
               "14ac2ceeb59afc7089974d0ae233fe8d0ea183c8"),
    "eedi3m": ("https://github.com/HomeOfVapourSynthEvolution/VapourSynth-EEDI3.git", "r10"),
}

HEADER_COMMON = """
The filter is fmParallel and keeps scratch buffers per worker thread in
std::unordered_map<std::thread::id, ...> members of the filter instance.
{how} Two threads starting their first frame of an instance together corrupt
the map or lose an insert, and the kernel's .at() then throws
std::out_of_range inside a noexcept function: std::terminate, so vspipe
aborts ("unordered_map::at: key not found"; on Windows the UCRT's abort is a
fail-fast, exit 0xC0000409). {measured}

The patch locks the map: getFrame checks for the thread's buffers under a
shared lock and allocates them under a unique lock (only the calling thread
inserts its own key), and the kernels look them up through threadBuffer(),
under the shared lock. The buffers, their reuse and so the output are
unchanged, sample for sample. It also appends "{marker}"
to the plugin's name, which is how a test and the deps scripts recognise a
patched build. No upstream release fixes this.

Made by docs/reports/task-98-per-thread-buffer-maps/scripts/make_patches.py
and applied by download-deps-{{macos,linux}}.sh and download-deps-windows.ps1
right after the clone; each build fails if it stops applying.

"""

HEADERS = {
    "dfttest": (
        "DFTTest at bc5e018 (HomeOfVapourSynthEvolution/VapourSynth-DFTTest, r7 + 2:\n"
        "meson's fftw3f_threads fix and a faster create loop); the same patch applies\n"
        "unchanged to yuygfgg/VapourSynth-DFTTest e6f580a (bc5e018 + an sse2neon port),\n"
        "which macOS arm64 builds. VapourBox task #98,\n"
        "docs/reports/task-98-per-thread-buffer-maps.\n",
        "Four maps (ebuff, dftr, dftc, dftc2) are filled from getFrame and read by\n"
        "every kernel with no lock at all.",
        "Measured on an M1 with 8 threads: one graph of 1000\n"
        "instances aborted in 14 of 20 runs, one instance in a fresh vspipe in 5 of\n"
        "200; with the patch, none in 20 and 200. Upstream issue #12 (2021) reported\n"
        "this abort and was closed unreproduced. QTGMC's dfttest denoiser (and its\n"
        "knlmeanscl fallback), SMDegrain's and MCTemporalDenoise's prefilters and\n"
        "TemporalDegrain2 reach it."),
    "lghost": (
        "LGhost r1 (HomeOfVapourSynthEvolution/VapourSynth-LGhost, the only tag).\n"
        "VapourBox task #98, docs/reports/task-98-per-thread-buffer-maps.\n",
        "One map (buffer) is filled from getFrame and read by every kernel with\n"
        "no lock at all.",
        "Measured on an M1 with 8 threads: one graph of 1000 instances\n"
        "aborted in 17 of 20 runs; with the patch, none in 40."),
    "ctmf": (
        "CTMF r5 (HomeOfVapourSynthEvolution/VapourSynth-CTMF, the last tag and HEAD).\n"
        "VapourBox task #98, docs/reports/task-98-per-thread-buffer-maps.\n",
        "Two maps (hCoarse, hFine; every radius but 2, which has its own kernel)\n"
        "are filled from getFrame and read by every kernel with no lock at all.",
        "Measured on an M1 with 8 threads, radius 3: one graph of\n"
        "1000 instances aborted in 19 of 20 runs, one instance in a fresh vspipe in\n"
        "11 of 200; with the patch, none in 40 and 200. The Noise Reduction CTMF\n"
        "method and havsfunc's MinBlur(r=3) reach it."),
    "tcanny": (
        "TCanny at 14ac2ce (HomeOfVapourSynthEvolution/VapourSynth-TCanny, r14 + \"Use\n"
        "alignof operator to query alignment\": r14 itself asks aligned_alloc for\n"
        "4-byte alignment, which arm64 refuses, so every frame fails there).\n"
        "VapourBox task #98 (task #52 found the race),\n"
        "docs/reports/task-98-per-thread-buffer-maps.\n",
        "Four maps (blur, gradient, direction, found) are filled from getFrame\n"
        "and read by every kernel with no lock at all.",
        "Measured on an M1 with 8 threads: one graph of\n"
        "1000 instances aborted in 20 of 20 runs, one instance in a fresh vspipe in\n"
        "2 of 200; with the patch, none in 40 and 200. VapourBox's templates still\n"
        "never call TCanny (test_250, gauss_blur.py); this protects a user's own\n"
        "VapourSynth code."),
    "eedi3m": (
        "EEDI3m r10 (HomeOfVapourSynthEvolution/VapourSynth-EEDI3). VapourBox task #98,\n"
        "docs/reports/task-98-per-thread-buffer-maps.\n",
        "r8 held one mutex around the whole check-insert-lookup; r9.1's 61e14ab\n"
        "(\"Use shared_mutex for unordered_map\") locks the insert (unique) and the\n"
        "lookup (shared) but runs the first count() with no lock, so it can read the\n"
        "map while another thread inserts into it or rehashes it.",
        "Not reproduced (0 aborts in\n"
        "10 graphs of 1000 instances on an M1): reserve(numThreads) makes a rehash\n"
        "rare. The patch moves that count() under the shared lock; nothing else\n"
        "changes. Windows and macOS x64 ship r8 and are not patched."),
}

NAMES = {
    "dfttest": ("DFTTest/DFTTest.cpp", '"2D/3D frequency domain denoiser"'),
    "lghost": ("LGhost/LGhost.cpp", '"Ghost Reduction"'),
    "ctmf": ("CTMF/CTMF.cpp", '"Constant Time Median Filtering"'),
    "tcanny": ("TCanny/TCanny.cpp", '"Build an edge map using canny edge detection"'),
    "eedi3m": ("EEDI3/EEDI3.cpp", '"Enhanced Edge Directed Interpolation 3"'),
}


def sub(text, old, new, count=1, path=""):
    n = text.count(old)
    if n != count:
        sys.exit(f"{path}: expected {count} of {old!r}, found {n}")
    return text.replace(old, new)


def known_block(indent, check, mutex="bufferMutex"):
    i = " " * indent
    return (f"{i}bool known;\n{i}{{\n{i}    std::shared_lock<std::shared_mutex> lock(d->{mutex});\n"
            f"{i}    known = {check};\n{i}}}\n{i}if (!known) {{\n"
            f"{i}    std::unique_lock<std::shared_mutex> lock(d->{mutex});\n")


HELPER = ("    mutable std::shared_mutex bufferMutex;\n", "    // The calling thread's buffer, looked up under bufferMutex (task #98).\n"
          "    template<typename M> auto threadBuffer(const M & m) const {\n"
          "        std::shared_lock<std::shared_mutex> lock(bufferMutex);\n"
          "        return m.at(std::this_thread::get_id()).get();\n    }\n")


def lock_header(path, first_map_line, last_map_line):
    t = path.read_text()
    t = sub(t, "#include <memory>\n", "#include <memory>\n#include <mutex>\n#include <shared_mutex>\n", path=path)
    t = sub(t, first_map_line, HELPER[0] + first_map_line, path=path)
    t = sub(t, last_map_line, last_map_line + HELPER[1], path=path)
    path.write_text(t)


def lock_kernels(src, maps, thread_local_lines):
    for f in sorted(src.glob("*.cpp")):
        t = f.read_text()
        for m in maps:
            t = t.replace(f"d->{m}.at(threadId).get()", f"d->threadBuffer(d->{m})")
        for line in thread_local_lines:
            t = t.replace(line, "")
        if ".at(threadId)" in t:
            sys.exit(f"{f}: an unlocked lookup is left")
        f.write_text(t)


def rewrite(name, root):
    src_file, title = NAMES[name]
    main = root / src_file
    if name == "dfttest":
        d = root / "DFTTest"
        lock_header(d / "DFTTest.h", "    std::unordered_map<std::thread::id, unique_VSFrameRef> ebuff;\n",
                    "    std::unordered_map<std::thread::id, unique_fftwf_complex> dftc, dftc2;\n")
        t = main.read_text()
        t = sub(t, "            if (!d->ebuff.count(threadId)) {\n",
                known_block(12, "d->ebuff.count(threadId)"), path=main)
        main.write_text(t)
        lock_kernels(d, ["ebuff", "dftr", "dftc2", "dftc"],
                     ["    const auto threadId = std::this_thread::get_id();\n"])
    elif name == "lghost":
        d = root / "LGhost"
        lock_header(d / "LGhost.h", "    std::unordered_map<std::thread::id, unique_float> buffer;\n",
                    "    std::unordered_map<std::thread::id, unique_float> buffer;\n")
        t = main.read_text()
        t = sub(t, "            if (!d->buffer.count(threadId)) {\n",
                known_block(12, "d->buffer.count(threadId)"), path=main)
        main.write_text(t)
        lock_kernels(d, ["buffer"], ["    const auto threadId = std::this_thread::get_id();\n"])
    elif name == "ctmf":
        d = root / "CTMF"
        lock_header(d / "CTMF.h", "    std::unordered_map<std::thread::id, unique_uint16> hCoarse, hFine;\n",
                    "    std::unordered_map<std::thread::id, unique_uint16> hCoarse, hFine;\n")
        t = main.read_text()
        t = sub(t, "            if (!d->isRadius2 && !d->hCoarse.count(threadId)) {\n",
                known_block(12, "d->isRadius2 || d->hCoarse.count(threadId)"), path=main)
        main.write_text(t)
        lock_kernels(d, ["hCoarse", "hFine"], ["    const auto threadId = std::this_thread::get_id();\n"])
    elif name == "tcanny":
        d = root / "TCanny"
        lock_header(d / "TCanny.h", "    std::unordered_map<std::thread::id, std::unique_ptr<bool[]>> found;\n",
                    "    std::unordered_map<std::thread::id, unique_int> direction;\n")
        t = main.read_text()
        t = sub(t, "            if (!d->blur.count(threadId)) {\n",
                known_block(12, "d->blur.count(threadId)"), path=main)
        main.write_text(t)
        lock_kernels(d, ["blur", "gradient", "direction", "found"],
                     ["            const auto threadId{ std::this_thread::get_id() };\n"])
    elif name == "eedi3m":
        t = main.read_text()
        t = sub(t, "            if (!d->srcVector.count(threadID)) {\n"
                   "                std::unique_lock<std::shared_mutex> lock(d->mutex);\n",
                known_block(12, "d->srcVector.count(threadID)", mutex="mutex"), path=main)
        main.write_text(t)
    t = main.read_text()
    main.write_text(sub(t, title, title[:-1] + MARKER + '"', path=main))


def main():
    work = pathlib.Path(sys.argv[1]).resolve()
    work.mkdir(parents=True, exist_ok=True)
    for name, (url, ref) in PLUGINS.items():
        root = work / name
        if not root.exists():
            subprocess.run(["git", "clone", "-q", url, str(root)], check=True)
        subprocess.run(["git", "-C", root, "checkout", "-q", "-f", ref], check=True)
        subprocess.run(["git", "-C", root, "clean", "-q", "-fdx"], check=True)
        rewrite(name, root)
        diff = subprocess.run(["git", "-C", root, "diff", "--no-color"], check=True,
                              capture_output=True, text=True).stdout
        intro, how, measured = HEADERS[name]
        header = intro + HEADER_COMMON.format(how=how, measured=measured, marker=MARKER.strip())
        header = "\n\n".join(textwrap.fill(" ".join(par.split()), 78, break_on_hyphens=False)
                               for par in header.strip().split("\n\n")) + "\n\n"
        ver = {"dfttest": "bc5e018", "tcanny": "14ac2ce"}.get(name, ref)
        out = OUT / f"{name}-{ver}-thread-safety.patch"
        out.write_text(header + diff)
        print(out.relative_to(REPO))


if __name__ == "__main__":
    main()
