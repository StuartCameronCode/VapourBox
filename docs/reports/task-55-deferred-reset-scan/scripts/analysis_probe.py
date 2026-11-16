#!/usr/bin/env python3
"""Task #55: what analysis waits for on a network share, before and after the
timestamp-reset scan was deferred.

Usage:
  analysis_probe.py share  BEFORE AFTER OUT.json VOB1 VOB2 VOB3 VOB4
  analysis_probe.py local  BEFORE AFTER OUT.json FILE [RUNS]
  analysis_probe.py reset  BEFORE AFTER OUT.json FILE      (a local file with a reset)

BEFORE / AFTER are the worker binaries built from the commit before this task
and from this branch. On the share every whole-file read goes to a different
1 GB VOB part each round (the parts are rotated), so no measure reads a part
another measure has just cached; a read faster than 5 s/GB is flagged
`cached`. Wall time is what the user waits for; CPU time (user + sys of the
process and its children) is given beside it.

Steps, as the app runs them:
  probe       --probe-source            (before: includes the whole-file scan)
  probeDefer  --probe-source --defer-scan
  complete    --complete-source <the deferred model>   (the scan, after analysis)
  scanBefore  --scan-timestamps, BEFORE (buffers ffprobe's whole answer)
  scanAfter   --scan-timestamps, AFTER  (streams it; adds the `pos` column)
  idetSeek    idet as the app ran it on every source (-ss 2)
  idetSeq     idet as it now runs on a TS/PS (from the start, trim by frames)
  frame0      the frame-0 decode
  contention  probeDefer + idetSeq + frame0 on one part while `complete`
              reads another (the next video's analysis during a scan)
"""
import json
import os
import resource
import subprocess
import sys
import tempfile
import threading
import time

DEPS = os.environ.get(
    "VAPOURBOX_DEPS_DIR",
    os.path.expanduser("~/Library/Application Support/VapourBox/deps/macos-arm64"))
FFMPEG = os.path.join(DEPS, "ffmpeg", "ffmpeg")
NULL = "/dev/null"


def run(cmd, out_file=None):
    """Wall and CPU seconds of one command, and its stdout."""
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    t0 = time.monotonic()
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    wall = time.monotonic() - t0
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu = (after.ru_utime - before.ru_utime) + (after.ru_stime - before.ru_stime)
    if p.returncode != 0:
        raise SystemExit(f"failed ({p.returncode}): {' '.join(cmd)}")
    if out_file:
        with open(out_file, "wb") as f:
            f.write(p.stdout)
    return wall, cpu, p.stdout


def gb(path):
    return os.path.getsize(path) / 1e9


def idet_seek(path):
    return [FFMPEG, "-ss", "2", "-i", path, "-vf", "idet", "-frames:v", "200",
            "-an", "-f", "rawvideo", "-y", NULL]


def idet_seq(path, fps=25.0):
    return [FFMPEG, "-i", path, "-vf", f"trim=start_frame={round(2 * fps)},idet",
            "-frames:v", "200", "-an", "-f", "rawvideo", "-y", NULL]


def frame0(path):
    return [FFMPEG, "-i", path, "-frames:v", "1", "-an", "-f", "rawvideo", "-y", NULL]


def first_picture(before, after, path, tmp):
    """Time to what analysis shows first, after: the deferred probe, idet,
    frame 0, in sequence (as the app runs them)."""
    model = os.path.join(tmp, "model.json")
    w1, c1, _ = run([after, "--probe-source", path, "--defer-scan"], model)
    w2, c2, _ = run(idet_seq(path))
    w3, c3, _ = run(frame0(path))
    return model, {"probeDefer": [w1, c1], "idetSeq": [w2, c2], "frame0": [w3, c3],
                   "total": [w1 + w2 + w3, c1 + c2 + c3]}


def share(before, after, out, vobs):
    rows = []
    with tempfile.TemporaryDirectory() as tmp:
        for r in range(3):
            part = lambda k: vobs[(r + k) % len(vobs)]
            row = {"round": r}
            # Today: the probe analysis waited for (its scan reads part 0).
            p = part(0)
            w, c, _ = run([before, "--probe-source", p])
            row["probe"] = {"file": os.path.basename(p), "gb": gb(p), "wall": w, "cpu": c,
                            "sPerGb": w / gb(p), "cached": w / gb(p) < 5}
            # Now: the deferred probe and what follows it, on part 1 ...
            p = part(1)
            model, first = first_picture(before, after, p, tmp)
            w, c, _ = run(idet_seek(p))
            first["idetSeek"] = [w, c]
            row["firstPicture"] = {"file": os.path.basename(p), **first}
            # ... then its scan, in the background after analysis.
            w, c, out_c = run([after, "--complete-source", model])
            progress = sum(1 for l in out_c.splitlines() if b'"progress"' in l)
            row["complete"] = {"file": os.path.basename(p), "gb": gb(p), "wall": w, "cpu": c,
                               "sPerGb": w / gb(p), "cached": w / gb(p) < 5,
                               "progressLines": progress}
            # The scan alone, before and after streaming (parts 2 and 3).
            for key, worker, k in [("scanBefore", before, 2), ("scanAfter", after, 3)]:
                p = part(k)
                w, c, _ = run([worker, "--scan-timestamps", p])
                row[key] = {"file": os.path.basename(p), "gb": gb(p), "wall": w, "cpu": c,
                            "sPerGb": w / gb(p), "cached": w / gb(p) < 5}
            rows.append(row)
            print(json.dumps(row), flush=True)

        # Contention: the next video's analysis while a scan reads the link.
        contention = []
        for r in range(2):
            scan_part, other = vobs[(r + 2) % len(vobs)], vobs[(r + 1) % len(vobs)]
            model = os.path.join(tmp, "c.json")
            run([after, "--probe-source", scan_part, "--defer-scan"], model)
            result = {}

            def scan():
                result["scan"] = run([after, "--complete-source", model])[:2]

            t = threading.Thread(target=scan)
            t.start()
            time.sleep(2.0)  # the scan is reading
            _, first = first_picture(before, after, other, tmp)
            t.join()
            contention.append({"scanFile": os.path.basename(scan_part),
                               "scanGb": gb(scan_part),
                               "scan": result["scan"],
                               "otherFile": os.path.basename(other), **first})
            print(json.dumps(contention[-1]), flush=True)
    json.dump({"rows": rows, "contention": contention}, open(out, "w"), indent=1)


def local(before, after, out, path, runs=3):
    rows = []
    with tempfile.TemporaryDirectory() as tmp:
        for r in range(runs):
            row = {"round": r}
            w, c, _ = run([before, "--probe-source", path])
            row["probe"] = [w, c]
            model, first = first_picture(before, after, path, tmp)
            row["firstPicture"] = first
            row["complete"] = list(run([after, "--complete-source", model])[:2])
            row["scanBefore"] = list(run([before, "--scan-timestamps", path])[:2])
            row["scanAfter"] = list(run([after, "--scan-timestamps", path])[:2])
            rows.append(row)
            print(json.dumps(row), flush=True)
    json.dump({"file": os.path.basename(path), "gb": gb(path), "rows": rows},
              open(out, "w"), indent=1)


def reset(before, after, out, path):
    """A file with a reset: the join with and without the model's scan."""
    rows = []
    with tempfile.TemporaryDirectory() as tmp:
        model = os.path.join(tmp, "m.json")
        for r in range(3):
            run([after, "--probe-source", path], model)
            for key, extra in [("joinRescans", []), ("joinFromModel", ["--source", model])]:
                dst = os.path.join(tmp, f"{key}.mpg")
                w, c, o = run([after, "--make-continuous", path, "--output", dst, *extra])
                assert b'"success":true' in o, o[-400:]
                used = b"Using the source model" in o
                rows.append({"round": r, "step": key, "wall": w, "cpu": c, "usedModel": used})
                os.remove(dst)
                print(json.dumps(rows[-1]), flush=True)
    json.dump({"file": os.path.basename(path), "gb": gb(path), "rows": rows},
              open(out, "w"), indent=1)


if __name__ == "__main__":
    mode, before, after, out = sys.argv[1:5]
    rest = sys.argv[5:]
    if mode == "share":
        share(before, after, out, rest)
    elif mode == "local":
        local(before, after, out, rest[0], int(rest[1]) if len(rest) > 1 else 3)
    elif mode == "reset":
        reset(before, after, out, rest[0])
    else:
        raise SystemExit(__doc__)
