#!/usr/bin/env python3
"""The 'havsfunc mask AND (patch 8)' test's duration in ci-test.yml's flutter jobs.

Usage:
  # fetch each flutter job's log first, e.g.
  #   gh run view --job <job id> --log > logs/<run id>-<job id>.log
  python3 ci_test_durations.py logs/*.log > ../data/ci_durations.tsv

A test's time is the gap between its own result line (a check or cross mark,
then 'vapoursynth_integration_test.dart: ...') and the previous result line of
the same file in the same job. package:test runs a file's tests one after
another, so that gap is the test (plus the next test's negligible start). The
SLOWEST_EVAL and TOTAL_EVAL lines the test prints are reported when present.
"""
import datetime
import re
import sys

NAME = 'havsfunc mask AND (patch 8)'
STAMP = re.compile(r'(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+)Z')
RESULT = re.compile(r'(✅|❌) .*vapoursynth_integration_test\.dart: (.*)$')


def when(line):
    m = STAMP.search(line)
    if not m:
        return None
    return datetime.datetime.fromisoformat(m.group(1)[:26])


print('log\tjob\tresult\tseconds\tslowest_eval\ttotal_eval')
for path in sys.argv[1:]:
    job, prev, found = None, None, None
    slowest = total = ''
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            if job is None and '\t' in line:
                job = line.split('\t', 1)[0]
            m = re.search(r'SLOWEST_EVAL (\S+)', line)
            if m:
                slowest = m.group(1)
            m = re.search(r'TOTAL_EVAL (\S+)', line)
            if m:
                total = m.group(1)
            r = RESULT.search(line)
            if not r:
                continue
            if r.group(2).startswith(NAME) and found is None:
                t = when(line)
                secs = (t - prev).total_seconds() if t and prev else float('nan')
                found = ('pass' if r.group(1) == '✅' else 'fail', secs)
            else:
                prev = when(line) or prev
    if found:
        print('%s\t%s\t%s\t%.1f\t%s\t%s' % (path.rsplit('/', 1)[-1], job, found[0], found[1], slowest, total))
