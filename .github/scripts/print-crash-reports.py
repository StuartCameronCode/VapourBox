#!/usr/bin/env python3
"""Print the faulting thread of recent macOS crash reports, for CI logs.

A plugin that segfaults inside vspipe leaves nothing in the test output but
"signal 11", and the hosted runners can't be logged into. macOS writes a crash
report (.ips) for every crashed process, naming the library and function that
faulted; this prints the newest few for the given process names.

Usage: print-crash-reports.py [process-name ...]   (default: vspipe-bin python3)
"""
import glob
import json
import os
import sys

names = sys.argv[1:] or ["vspipe-bin", "python3", "python3.12"]
dirs = [os.path.expanduser("~/Library/Logs/DiagnosticReports"), "/Library/Logs/DiagnosticReports"]
reports = sorted(
    (p for d in dirs for p in glob.glob(os.path.join(d, "*.ips"))
     if any(os.path.basename(p).startswith(n) for n in names)),
    key=os.path.getmtime,
    reverse=True,
)[:3]

if not reports:
    print(f"No crash reports for {', '.join(names)}.")
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
