# Tabulates probe.py's results: each case for build A vs build B, and A vs a
# second run of A (which shows which cases are nondeterministic).
#
#   python3 compare.py a.json b.json a-rerun.json
import json, sys
a, b, a2 = (json.load(open(p)) for p in sys.argv[1:4])
for k in sorted(a):
    ab = "same" if a[k] == b[k] else "DIFF"
    rerun = "same" if a[k] == a2.get(k) else "DIFF"
    note = " (" + a[k] + ")" if a[k].startswith("ERROR") else ""
    print(f"{k:32s} A-vs-B {ab:4s}  A-rerun {rerun:4s}{note}")
