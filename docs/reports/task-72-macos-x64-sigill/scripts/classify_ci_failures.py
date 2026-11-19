#!/usr/bin/env python3
"""Task #72: classify the push gate's failed jobs from their CI logs.

For each run ID, every failed job's log is fetched with `gh run view --job
--log` and summarised: the deps bundle it installed, the tests that failed,
the format-sweep rows that died natively, and each crash report the
on-failure step printed, classified with print-crash-reports.py's own
`classify` (task #68's teardown race, or the first image outside the system
libraries).

Run from the repository root (needs `gh`, authenticated, and read access to
the repository):

    python3 docs/reports/task-72-macos-x64-sigill/scripts/classify_ci_failures.py RUN_ID ... > out.tsv

Prints one TSV row per failed job:
run, job, deps, failing tests, native-crash rows, crash-report verdicts.
"""
import importlib.util
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "..", "..", "..", ".github", "scripts", "print-crash-reports.py")
spec = importlib.util.spec_from_file_location("pcr", SCRIPT)
pcr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pcr)

TS = re.compile(r"^\S*\d{4}-\d\d-\d\dT[\d:.]+Z ?")


def gh(*args):
    return subprocess.run(["gh", *args], capture_output=True, text=True, check=True).stdout


def log_lines(job_id):
    out = []
    for raw in gh("run", "view", "--job", str(job_id), "--log").splitlines():
        parts = raw.split("\t", 2)
        out.append(TS.sub("", parts[-1]).lstrip("﻿"))
    return out


def printed_reports(lines):
    """Crash reports as print-crash-reports.py printed them: macOS frame lines
    ('  N lib  symbol') after '=== <name>.ips', gdb text after '=== core.'."""
    reports, cur, kind = [], None, None
    for line in lines:
        m = re.match(r"^=== (\S+)", line)
        if m:
            if cur is not None:
                reports.append((name, kind, cur))
            name, kind, cur = m.group(1), ("ips" if m.group(1).endswith(".ips") else "core"), []
            continue
        if cur is None:
            continue
        if line.startswith(("Post job cleanup", "##[")):
            reports.append((name, kind, cur))
            cur = None
            continue
        cur.append(line)
    if cur is not None:
        reports.append((name, kind, cur))
    verdicts = []
    for name, kind, body in reports:
        if kind == "ips":
            frames = []
            for l in body:
                m = re.match(r"^\s+\d+ (\S+)\s+(.*)$", l)
                if m and not l.strip().startswith(("---", "=>")):
                    frames.append((m.group(1), m.group(2)))
                elif l.strip().startswith("--- thread"):
                    break  # the faulting thread is printed first
            verdict, detail = pcr.classify(frames)
        else:
            fault, others = pcr.gdb_threads("\n".join(l[2:] if l.startswith("  ") else l for l in body))
            verdict, detail = pcr.classify(fault, others)
        verdicts.append(f"{name}: {verdict} ({detail})")
    return verdicts


def main(run_ids):
    print("run\tjob\tdeps\tfailed tests\tnative-crash rows\tcrash reports")
    for run in run_ids:
        jobs = gh("api", f"repos/{{owner}}/{{repo}}/actions/runs/{run}/jobs",
                  "--jq", '.jobs[]|select(.conclusion=="failure")|"\\(.id)\\t\\(.name)"')
        for row in jobs.splitlines():
            job_id, name = row.split("\t", 1)
            lines = log_lines(job_id)
            deps = sorted(set(re.findall(r"deps-v\d+\.\d+\.\d+(?:-rc\d+)?", "\n".join(lines))))
            failed = sorted({re.sub(r".*app/test/", "", l).replace(" (failed)", "")
                             for l in lines if l.startswith("##[group]❌")})
            crashes = [l.strip() for l in lines if "native crash:" in l]
            print("\t".join([run, name, ",".join(deps), " | ".join(failed),
                             " | ".join(c.split(": native crash")[0] + " " +
                                        (re.search(r"signal \d+ \(\w+\)", c) or [""])[0] for c in crashes),
                             " | ".join(printed_reports(lines))]))


if __name__ == "__main__":
    main(sys.argv[1:])
