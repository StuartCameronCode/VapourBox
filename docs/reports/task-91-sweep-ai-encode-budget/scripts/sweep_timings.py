#!/usr/bin/env python3
"""Task #91: the add-on variants' times in the nightly format sweep.

Reads what fetch.sh cached (CACHE=<dir>, one subdirectory per run) and writes
two tables to the report's data/ directory:

  preview_rows.tsv  each add-on variant's preview row times (results-*.json),
                    per run and bundle
  delta_groups.tsv  each delta-only group's wall time (from the previous
                    group's finish to its own, in the job log), rows that
                    timed out, and the slowest

  CACHE=<dir> python3 -I scripts/sweep_timings.py
"""
import glob, json, os, re, statistics, sys
from datetime import datetime

CACHE = os.environ.get("CACHE") or sys.exit("set CACHE")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data")
ADDON = ("colorize/", "face_restore")
GROUP = re.compile(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)\.\d+Z .*bit-exact outside a delta-only pass \(nightly\) (\S+)")
TIMEOUT = re.compile(r"^\s+(\S+): encode failed: TimeoutException")

def runs():
    return sorted(d for d in os.listdir(CACHE) if os.path.isdir(os.path.join(CACHE, d)))

with open(os.path.join(OUT, "preview_rows.tsv"), "w") as out:
    out.write("run\tbundle\tvariant\trows ok\tmin s\tmedian s\tmax s\n")
    for run in runs():
        for f in sorted(glob.glob(os.path.join(CACHE, run, "format-sweep-*", "results-*.json"))):
            bundle = os.path.basename(os.path.dirname(f))[len("format-sweep-"):]
            by = {}
            for r in json.load(open(f)):
                if r["suite"] == "addon" and r["variant"].startswith(ADDON):
                    by.setdefault(r["variant"], []).append(r)
            for v, rs in by.items():
                s = [r["secs"] for r in rs if r["ok"]]
                if not s:
                    continue
                out.write(f"{run}\t{bundle}\t{v}\t{len(s)}/{len(rs)}\t{min(s):.1f}\t"
                          f"{statistics.median(s):.1f}\t{max(s):.1f}\n")

with open(os.path.join(OUT, "delta_groups.tsv"), "w") as out:
    out.write("run\tbundle\tvariant\tgroup wall s\trows timed out at 300 s\n")
    for run in runs():
        for log in sorted(glob.glob(os.path.join(CACHE, run, "*.log"))):
            bundle = os.path.basename(log)[:-4]
            prev, cur, timeouts = None, None, {}
            lines = open(log, errors="replace").read().splitlines()
            ends = []
            for i, line in enumerate(lines):
                m = GROUP.search(line)
                if m:
                    t = datetime.fromisoformat(m.group(1))
                    cur = m.group(2)
                    ends.append((cur, t, prev))
                    prev = t
                    timeouts.setdefault(cur, 0)
                elif cur and TIMEOUT.search(line.split("Z ", 1)[-1]):
                    timeouts[cur] += 1
            for v, t, p in ends:
                if v.startswith(ADDON) and p:
                    out.write(f"{run}\t{bundle}\t{v}\t{(t - p).total_seconds():.0f}\t{timeouts[v]}\n")
