#!/usr/bin/env python3
# Summarise a VB_MAD_LOG file (see mad_log.patch): per test and calling line,
# the lowest difference (the frame the test matched), then the max / median.
import sys,re,collections
# per (file, test name, caller line): min value = the matched frame; report max over tests of that min
d=collections.defaultdict(list)
for l in open(sys.argv[1]):
    p=l.rstrip('\n').split('\t')
    if len(p)<3: continue
    m=re.search(r'(integration_\w+_test)\.dart:(\d+)',p[1])
    if not m: continue
    d[(m.group(1),m.group(2),p[0])].append(float(p[2]))
agg=collections.defaultdict(list)
for (f,ln,t),v in d.items(): agg[(f,ln)].append(min(v))
for k in sorted(agg):
    v=agg[k]; print(f"{k[0]}:{k[1]:5s} tests={len(v):4d} best-match max={max(v):.3f} median={sorted(v)[len(v)//2]:.3f}")
