#!/usr/bin/env python3
"""Count a `flutter test --file-reporter json:<file>` run's results (task #99).

    summarize_flutter_json.py <results.json> [<label>]

Prints one line per test name stem (the repeat suffix " (run k of N)"
stripped): passed / failed / errors, and the first line of each failure's
message. Exits 0 whatever the results: the caller decides.
"""
import json
import re
import sys
from collections import defaultdict

path = sys.argv[1]
label = sys.argv[2] if len(sys.argv) > 2 else path
names, results, errors = {}, {}, defaultdict(list)
for line in open(path, encoding="utf-8", errors="replace"):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    t = e.get("type")
    if t == "testStart":
        names[e["test"]["id"]] = e["test"]["name"]
    elif t == "error":
        errors[e["testID"]].append(e.get("error", ""))
    elif t == "testDone" and not e.get("hidden"):
        results[e["testID"]] = "skipped" if e.get("skipped") else e["result"]

stem = lambda n: re.sub(r" \(run \d+ of \d+\)$", "", n)
tally = defaultdict(lambda: defaultdict(int))
fails = defaultdict(list)
for tid, r in results.items():
    n = names.get(tid, "?")
    tally[stem(n)][r] += 1
    if r != "success" and r != "skipped":
        msg = " | ".join(x.strip().splitlines()[0] if x.strip() else "" for x in errors[tid])
        fails[stem(n)].append(f"{n}: {msg[:300]}")

total = defaultdict(int)
print(f"== {label}")
for n in sorted(tally):
    if n.startswith("loading ") or "(setUpAll)" in n or "(tearDownAll)" in n:
        continue
    c = tally[n]
    for k, v in c.items():
        total[k] += v
    print(f"  {n}: " + ", ".join(f"{k} {v}" for k, v in sorted(c.items())))
    for f in fails[n]:
        print(f"      {f}")
print("  TOTAL: " + ", ".join(f"{k} {v}" for k, v in sorted(total.items())))
