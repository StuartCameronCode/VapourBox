#!/usr/bin/env python3
"""Fail if any Mach-O file in a macOS deps bundle needs something outside it.

Task #36: deps 1.16.0's macos-arm64 libdvdread was Homebrew's bottle, which
carries LC_LOAD_DYLIB /opt/homebrew/opt/libdvdcss/lib/libdvdcss.2.dylib. On a
Mac without Homebrew's libdvdcss dyld refused to load it, so DVD import failed
there. The old guard in download-deps-macos.sh let that through on purpose
(it whitelisted libdvdcss, believing the reference weak) and only looked at
plugins/ and lib/.

This walks EVERY Mach-O file under the bundle root and fails on:

  * a dependency (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB,
    LC_LAZY_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB) with an absolute path outside
    /usr/lib/ and /System/ — Homebrew, MacPorts, /usr/local, Nix, anything.
    A weak one counts too: whatever it resolves to on the build machine is
    not what a user has.
  * an absolute LC_RPATH. A bundle is relocatable, so an absolute rpath can
    only point at the build machine; it is inert until something gains an
    @rpath/ dependency, and then it silently loads from there.

Only load commands are read, never strings: a library may legitimately name
an outside path as a dlopen() argument (the patched libdvdread looks for a
user-installed libdvdcss in /opt/homebrew/lib), which is not a dependency.
Each file's own LC_ID_DYLIB is not a dependency either (python's libpython
keeps an absolute /install/lib id from its build) and is ignored.

Usage:
  check-macho-refs.py ROOT                         check; exit 1 on a problem
  check-macho-refs.py --strip-absolute-rpaths ROOT delete every absolute
      LC_RPATH (install_name_tool -delete_rpath), re-sign ad hoc, then check
"""

import argparse
import os
import subprocess
import sys

DEPENDENCY_COMMANDS = {
    "LC_LOAD_DYLIB",
    "LC_LOAD_WEAK_DYLIB",
    "LC_REEXPORT_DYLIB",
    "LC_LAZY_LOAD_DYLIB",
    "LC_LOAD_UPWARD_DYLIB",
}
SYSTEM_PREFIXES = ("/usr/lib/", "/System/")
MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",  # 32-bit
    b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",  # 64-bit
    b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf",  # fat (also Java class files;
                                               # otool sorts those out)
}


def is_macho(path):
    try:
        with open(path, "rb") as f:
            return f.read(4) in MACHO_MAGICS
    except OSError:
        return False


def load_commands(path):
    """Yield (cmd, value) for each dylib/rpath load command, every slice."""
    r = subprocess.run(["otool", "-l", path], capture_output=True, text=True)
    if r.returncode != 0:
        return
    cmd = None
    for line in r.stdout.splitlines():
        words = line.split()
        if len(words) >= 2 and words[0] == "cmd":
            cmd = words[1]
        elif cmd and len(words) >= 2 and words[0] in ("name", "path"):
            # "name /opt/x/libfoo.dylib (offset 24)"; a path may hold spaces.
            value = line.strip()[len(words[0]):].strip()
            if value.endswith(")") and " (offset " in value:
                value = value[: value.rindex(" (offset ")]
            yield cmd, value
            cmd = None


def problems_in(path):
    found = []
    for cmd, value in load_commands(path):
        if cmd in DEPENDENCY_COMMANDS:
            if value.startswith("/") and not value.startswith(SYSTEM_PREFIXES):
                found.append(f"{cmd} {value}")
        elif cmd == "LC_RPATH":
            if value.startswith("/"):
                found.append(f"LC_RPATH {value}")
    return sorted(set(found))


def macho_files(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            path = os.path.join(dirpath, name)
            if not os.path.islink(path) and is_macho(path):
                yield path


def strip_absolute_rpaths(path):
    rpaths = sorted({v for c, v in load_commands(path) if c == "LC_RPATH" and v.startswith("/")})
    if not rpaths:
        return []
    for rp in rpaths:
        subprocess.run(["install_name_tool", "-delete_rpath", rp, path],
                       check=True, capture_output=True)
    subprocess.run(["codesign", "-s", "-", "-f", path], check=True, capture_output=True)
    return rpaths


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("root", help="the deps bundle root (deps/macos-<arch>)")
    ap.add_argument("--strip-absolute-rpaths", action="store_true",
                    help="delete absolute LC_RPATHs (and re-sign) before checking")
    args = ap.parse_args()
    root = os.path.abspath(args.root)
    if not os.path.isdir(root):
        sys.exit(f"not a directory: {root}")

    files = list(macho_files(root))
    if args.strip_absolute_rpaths:
        for path in files:
            for rp in strip_absolute_rpaths(path):
                print(f"  stripped LC_RPATH {rp} from {os.path.relpath(path, root)}")

    bad = 0
    for path in files:
        for problem in problems_in(path):
            print(f"  ✗ {os.path.relpath(path, root)}: {problem}")
            bad += 1
    if bad:
        print(f"ERROR: {bad} load command(s) above reach outside the bundle; they "
              "will not resolve on a user's Mac (task #36).", file=sys.stderr)
        return 1
    print(f"  ✓ {len(files)} Mach-O files depend only on the bundle and the system")
    return 0


if __name__ == "__main__":
    sys.exit(main())
