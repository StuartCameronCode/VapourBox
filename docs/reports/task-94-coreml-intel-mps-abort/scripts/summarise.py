#!/usr/bin/env python3
"""Task #94: the tables in index.html, from data/.

  python3 scripts/summarise.py            (run from the report's directory)

data/probe/*.json   coreml_vs_cpu_test.dart's results, one file per runner
data/nightly_*.tsv  nightly_aborts.sh / nightly_timings.sh
Prints Markdown-ish rows; the report's tables are these numbers.
"""
import csv
import glob
import json
import os
import statistics as st
from collections import defaultdict

here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(here)

runs = []
for f in sorted(glob.glob("data/probe/*.json")):
    d = json.load(open(f))
    for r in d["runs"]:
        r["runner"] = d["runner"]
        runs.append(r)

print("## Probe: every run (seconds for the job)")
for r in runs:
    if "compare" in r:
        continue
    print(f"{r['runner']:16} {r['model']:13} {r['provider']:6} {r['frames']:2} {r['label']:6} "
          f"{'ok' if r['success'] else 'FAILED'} {r['seconds']:7.1f}")

print("\n## Probe: per model and provider, 16 frames (min / median / max over runners)")
by = defaultdict(list)
for r in runs:
    if "compare" in r or not r["success"] or r["frames"] != 16:
        continue
    kind = "coreml cold" if r["label"] == "cold" else ("coreml warm" if r["provider"] == "coreml" else "cpu")
    by[(r["model"], kind)].append(r["seconds"])
for (m, k), v in sorted(by.items()):
    print(f"{m:13} {k:12} n={len(v):2} {min(v):6.1f} {st.median(v):6.1f} {max(v):6.1f}")

print("\n## Probe: CPU speed-up over warm Core ML, per runner (median warm Core ML 16 / median CPU 16)")
per = defaultdict(lambda: defaultdict(list))
for r in runs:
    if "compare" in r or not r["success"] or r["frames"] != 16 or r["label"] == "cold":
        continue
    per[(r["runner"], r["model"])][r["provider"]].append(r["seconds"])
for (runner, m), v in sorted(per.items()):
    print(f"{runner:16} {m:13} {st.median(v['coreml']) / st.median(v['cpu']):4.1f}x")

print("\n## Probe: per frame and start-up (median over runners; (t16 - t4) / 12 and t4 - 4 x that)")
slope = defaultdict(list)
for runner in sorted({r["runner"] for r in runs}):
    for m in sorted({r["model"] for r in runs if "model" in r}):
        for prov, l16, l4 in (("coreml", "warm1", "warm"), ("cpu", "cpu1", "cpu")):
            t = {r["label"]: r["seconds"] for r in runs
                 if r.get("runner") == runner and r.get("model") == m and r.get("provider") == prov and r["success"]}
            if l16 in t and l4 in t:
                pf = (t[l16] - t[l4]) / 12
                slope[(m, prov)].append((pf, t[l4] - 4 * pf))
for (m, prov), v in sorted(slope.items()):
    print(f"{m:13} {prov:6} {st.median(x for x, _ in v):6.2f} s/frame  start-up {st.median(y for _, y in v):6.1f} s")

print("\n## Probe: Core ML against the CPU, the same 16 frames")
for r in runs:
    if "compare" in r:
        print(f"{r['runner']:16} {r['compare']:13} luma samples changed {r['lumaSamplesChanged']:6} "
              f"luma MAD {r['lumaMeanAbsDiff']:.4f} chroma MAD {r['chromaMeanAbsDiff']:.4f}")

print("\n## Probe: aborts")
fails = [r for r in runs if "compare" not in r and not r["success"]]
cold = [r for r in runs if r.get("label") == "cold"]
print(f"{len(fails)} failed runs of {sum(1 for r in runs if 'compare' not in r)}; "
      f"cold Core ML runs: {len(cold)}, failed {sum(1 for r in cold if not r['success'])}")

names = {}
aborts = []
for r in csv.DictReader(open("data/nightly_aborts.tsv"), delimiter="\t"):
    names[r["job"]] = r["name"]
    if r["mps_abort"] == "yes":
        aborts.append(r)
print("\n## Nightlies: jobs with the MPS abort")
for r in aborts:
    print(f"{r['run']} {r['name']:28} {r['kernel'] or '-':32} {r['test']}")

print("\n## Nightlies: Core ML encode times, seconds for 16 frames (min / median / max)")
d = defaultdict(list)
for r in csv.DictReader(open("data/nightly_timings.tsv"), delimiter="\t"):
    n = names.get(r["job"], "?")
    arch = "arm64" if "arm64" in n else ("x64-v2" if "v2" in n else "x64")
    d[(r["encode"], arch)].append(float(r["seconds"]))
for (enc, arch), v in sorted(d.items()):
    print(f"{enc:20} {arch:7} n={len(v):2} {min(v):7.1f} {st.median(v):7.1f} {max(v):7.1f}")
