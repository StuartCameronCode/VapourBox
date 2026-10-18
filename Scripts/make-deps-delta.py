#!/usr/bin/env python3
"""Turn a full v2-tier deps bundle into a delta over the v3 bundle.

From deps 1.13.0 an x64 platform publishes ONE full bundle (the v3 tier, under
the plain asset name) plus a small delta for older CPUs:

    VapourBox-deps-<version>-<platform>.zip            full bundle, v3 tier
    VapourBox-deps-<version>-<platform>-v2-delta.zip   the files v2 replaces

The app (and every CI consumer) installs the v2 tier by extracting the delta
over the full bundle. The delta holds exactly the files listed for the platform
under `_tierFiles` in Scripts/deps-expected-plugins.json, taken from a real v2
build, plus a version.json stamped `tier: v2` — so "unzip the bundle, unzip the
delta over it" yields a correct tree with nothing else to do.

It is NOT made by diffing the two builds: two builds of the same sources are
not byte-identical, so a diff names nearly every binary. What IS checked is
that the two builds hold the same set of paths, which is what makes a pure
overwrite sufficient (a file only one tier has would need a delete step).

The delta records the sha256 of the bundle it was cut against (`baseSha256`,
in its version.json and its sidecar). The app refuses to apply it over any
other bundle, so a rebuilt v3 can never be paired with a stale delta.

Usage:
    make-deps-delta.py --platform linux-x64 --version 1.13.0 \\
        --base dist/VapourBox-deps-1.13.0-linux-x64.zip \\
        --v2 build/VapourBox-deps-1.13.0-linux-x64-v2.zip \\
        --out dist [--composed dist-composed]

--composed also writes the full v2 bundle obtained by applying the delta to the
base (VapourBox-deps-<version>-<platform>-v2.zip). That file is a CI
intermediate for the CPU gate, which must test what a user ends up with rather
than the v2 build the delta was cut from. It is never published.
"""
import argparse
import datetime
import hashlib
import json
import os
import sys
import zipfile

MANIFEST = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "deps-expected-plugins.json")
VERSION_FILE = "version.json"


def norm(name):
    # Compress-Archive writes backslash separators on Windows; everything here
    # compares and writes forward slashes.
    return name.replace("\\", "/")


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def file_entries(zf):
    """{normalized path: ZipInfo} for every non-directory entry."""
    return {norm(i.filename): i for i in zf.infolist() if not i.is_dir()}


def copy_entry(dst, src, info, name):
    """Copy one entry, keeping its mode bits (and so its symlink-ness)."""
    out = zipfile.ZipInfo(name, date_time=info.date_time)
    out.external_attr = info.external_attr
    out.create_system = info.create_system
    out.compress_type = zipfile.ZIP_DEFLATED
    dst.writestr(out, src.read(info))


def write_sidecar(zip_path, version, extra=None):
    sidecar = {
        "filename": os.path.basename(zip_path),
        "sha256": sha256_of(zip_path),
        "size": os.path.getsize(zip_path),
        "version": version,
    }
    sidecar.update(extra or {})
    with open(zip_path + ".sha256.json", "w") as f:
        json.dump(sidecar, f, indent=2)
        f.write("\n")
    return sidecar


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--platform", required=True, help="e.g. linux-x64")
    ap.add_argument("--version", required=True)
    ap.add_argument("--base", required=True, help="the published v3 bundle zip")
    ap.add_argument("--v2", required=True, help="a full v2-tier build zip")
    ap.add_argument("--out", required=True, help="directory for the delta zip")
    ap.add_argument("--composed", help="also write base+delta as a full zip here")
    args = ap.parse_args()

    tier_files = json.load(open(MANIFEST, encoding="utf-8")) \
        .get("_tierFiles", {}).get(args.platform)
    if not tier_files:
        sys.exit(f"no _tierFiles entry for {args.platform} in {MANIFEST}")

    base_sha = sha256_of(args.base)
    version_json = json.dumps({
        "version": args.version,
        "tier": "v2",
        "baseSha256": base_sha,
        "installedAt": datetime.datetime.now(datetime.timezone.utc)
                               .strftime("%Y-%m-%dT%H:%M:%SZ"),
    }, indent=2) + "\n"

    os.makedirs(args.out, exist_ok=True)
    stem = f"VapourBox-deps-{args.version}-{args.platform}"
    delta_path = os.path.join(args.out, f"{stem}-v2-delta.zip")

    with zipfile.ZipFile(args.base) as base, zipfile.ZipFile(args.v2) as v2:
        base_files, v2_files = file_entries(base), file_entries(v2)

        for label, zf, files in (("base", args.base, base_files), ("v2", args.v2, v2_files)):
            if VERSION_FILE not in files:
                sys.exit(f"{zf} has no {VERSION_FILE}; not a deps bundle")
            tier = json.loads(zipfile.ZipFile(zf).read(files[VERSION_FILE])).get("tier", "v3")
            want = "v3" if label == "base" else "v2"
            if tier != want:
                sys.exit(f"{zf} is a {tier} bundle; --{label} must be the {want} one")

        # A pure overwrite only works if neither tier has a file the other lacks.
        only_base = sorted(set(base_files) - set(v2_files))
        only_v2 = sorted(set(v2_files) - set(base_files))
        if only_base or only_v2:
            for p in only_base:
                print(f"  only in the v3 bundle: {p}", file=sys.stderr)
            for p in only_v2:
                print(f"  only in the v2 build:  {p}", file=sys.stderr)
            sys.exit("the two tiers do not hold the same files, so extracting a "
                     "delta over the v3 bundle cannot reproduce the v2 one")

        missing = [p for p in tier_files if p not in v2_files]
        if missing:
            sys.exit("_tierFiles names files the v2 build does not contain: "
                     + ", ".join(missing))

        # A tier file identical in both builds was not built differently at
        # all, which means the tier switch in download-deps-* did nothing.
        same = [p for p in tier_files
                if base.read(base_files[p]) == v2.read(v2_files[p])]
        if same:
            sys.exit("these tier files are byte-identical in both tiers, so the "
                     "v2 build did not actually build them for older CPUs: "
                     + ", ".join(same))

        with zipfile.ZipFile(delta_path, "w", zipfile.ZIP_DEFLATED) as delta:
            for p in tier_files:
                copy_entry(delta, v2, v2_files[p], p)
            delta.writestr(VERSION_FILE, version_json)

        if args.composed:
            os.makedirs(args.composed, exist_ok=True)
            composed_path = os.path.join(args.composed, f"{stem}-v2.zip")
            with zipfile.ZipFile(delta_path) as delta, \
                    zipfile.ZipFile(composed_path, "w", zipfile.ZIP_DEFLATED) as out:
                overlay = file_entries(delta)
                for p, info in base_files.items():
                    if p not in overlay:
                        copy_entry(out, base, info, p)
                for p, info in overlay.items():
                    copy_entry(out, delta, info, p)
            write_sidecar(composed_path, args.version)
            print(f"composed: {composed_path}")

    sidecar = write_sidecar(delta_path, args.version,
                            {"tier": "v2", "baseSha256": base_sha})
    print(f"delta:    {delta_path} ({sidecar['size']} bytes, "
          f"{len(tier_files)} file(s))")
    print(f"base:     {os.path.basename(args.base)} sha256 {base_sha}")


if __name__ == "__main__":
    main()
