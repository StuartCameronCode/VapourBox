"""Summarise a nightly format-sweep results file (task #103).

    python3 sweep_failures.py results-*.json [...]

The nightly sweep leg uploads its per-row results as an artifact
(`format-sweep-<platform>`; `gh run download <run> -n format-sweep-linux-x64`).
For each file this prints the row count, the failing rows by variant, and how
many failures are a native crash (vspipe exited with a signal).
"""
import collections
import json
import sys


def main(paths):
    for path in paths:
        rows = json.load(open(path))
        bad = [r for r in rows if not r.get("ok")]
        crash = [r for r in bad if "signal" in json.dumps(r) or "native crash" in json.dumps(r)]
        print(f"== {path}")
        print(f"   rows {len(rows)}, failing {len(bad)}, of which native crashes {len(crash)}")
        by_variant = collections.Counter(r["variant"] for r in bad)
        for variant, n in sorted(by_variant.items()):
            print(f"   {n:3d}  {variant}")


if __name__ == "__main__":
    main(sys.argv[1:])
