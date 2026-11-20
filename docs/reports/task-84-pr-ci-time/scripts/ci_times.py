#!/usr/bin/env python3
"""Where a GitHub Actions run of ci-test.yml spends its time (task #84).

Every number in the report comes from this script, reading the run through
the `gh` CLI (authenticated, repository from the current checkout):

    ci_times.py steps RUN_ID            per job: total, queue, every step > 0.2 min
    ci_times.py files RUN_ID [N]        per job: the N slowest Dart test files
                                        (span between a file's first and last
                                        result in the GitHub reporter's
                                        timestamps; files run concurrently, so
                                        spans overlap)
    ci_times.py rust RUN_ID             per job: cargo compile time and each
                                        test binary's time
    ci_times.py json RUN_ID             steps + rust + files as JSON (data/)

Job logs are fetched once per job into $CI_TIMES_CACHE (default: a
directory under the system temp dir) and reused.
"""
import collections
import datetime as dt
import json
import os
import re
import subprocess
import sys
import tempfile

CACHE = os.environ.get('CI_TIMES_CACHE') or os.path.join(tempfile.gettempdir(), 'ci-times-cache')
STAMP = re.compile(r'(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?)Z')
RESULT = re.compile(r'(\d{4}-\d\d-\d\dT[\d:.]+)Z (✅|❌)\S*\s+\S*/app/test/([\w/]+\.dart): (.*)')


def t(s):
    return dt.datetime.fromisoformat(s.replace('Z', '+00:00'))


def ts(s):
    s = s[:26]
    return dt.datetime.fromisoformat(s + ('' if '.' in s else '.0')).replace(tzinfo=dt.timezone.utc)


def gh_json(*args):
    return json.loads(subprocess.check_output(['gh', *args]))


def jobs(run):
    r = gh_json('run', 'view', str(run), '--json', 'jobs,createdAt')
    return r['createdAt'], r['jobs']


def log(job_id):
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, f'{job_id}.log')
    if not os.path.exists(path):
        with open(path, 'wb') as f:
            f.write(subprocess.check_output(['gh', 'run', 'view', '--job', str(job_id), '--log']))
    with open(path, encoding='utf-8', errors='replace') as f:
        return f.read().splitlines()


def step_lines(lines, step):
    return [l for l in lines if l.split('\t')[1:2] == [step]]


def steps(run):
    created, js = jobs(run)
    out = []
    for j in sorted(js, key=lambda j: j['name']):
        if not j.get('completedAt'):
            continue
        total = (t(j['completedAt']) - t(j['startedAt'])).total_seconds() / 60
        queue = (t(j['startedAt']) - t(created)).total_seconds() / 60
        st = {s['name']: round((t(s['completedAt']) - t(s['startedAt'])).total_seconds() / 60, 2)
              for s in j['steps'] if s.get('completedAt') and s.get('startedAt')}
        out.append({'job': j['name'], 'id': j['databaseId'], 'conclusion': j['conclusion'],
                    'minutes': round(total, 2), 'queued': round(queue, 2),
                    'wall': round(queue + total, 2), 'steps': st})
    return out


def files(run, job_id):
    lines = step_lines(log(job_id), 'Flutter tests')
    start = None
    per = collections.defaultdict(list)
    for l in lines:
        m = STAMP.search(l)
        if m and start is None:
            start = ts(m.group(1))
        m = RESULT.search(l)
        if m:
            per[m.group(3)].append((ts(m.group(1)) - start).total_seconds())
    rows = [{'file': f, 'tests': len(v), 'first': round(min(v)), 'last': round(max(v)),
             'span': round(max(v) - min(v))} for f, v in per.items()]
    return sorted(rows, key=lambda r: -r['span'])


def rust(run, job_id, step='Rust tests'):
    lines = step_lines(log(job_id), step)
    start = None
    compiled = None
    binaries = []
    cur = None
    for l in lines:
        m = STAMP.search(l)
        if not m:
            continue
        at = ts(m.group(1))
        start = start or at
        if 'Finished' in l and compiled is None:
            compiled = (at - start).total_seconds()
        # Cargo's own lines only (the worker logs JSON that says "Running …").
        r = None if '"type":' in l else re.search(r'(?:Running|Doc-tests)\S*\s+(\S+ ?\S*)', l)
        if r:
            if cur:
                binaries.append({'binary': cur[0], 'seconds': round((at - cur[1]).total_seconds(), 1)})
            cur = (r.group(1), at)
        end = at
    if cur:
        binaries.append({'binary': cur[0], 'seconds': round((end - cur[1]).total_seconds(), 1)})
    return {'compile': round(compiled or 0), 'step': round((end - start).total_seconds()) if start else 0,
            'binaries': binaries}


def main():
    cmd, run = sys.argv[1], sys.argv[2]
    data = steps(run)
    if cmd == 'steps':
        for j in data:
            print(f"{j['job']}: {j['minutes']} min (queued {j['queued']}, wall {j['wall']}) {j['conclusion']}")
            for name, m in j['steps'].items():
                if m > 0.2:
                    print(f'    {m:5.2f}  {name}')
    elif cmd == 'files':
        n = int(sys.argv[3]) if len(sys.argv) > 3 else 8
        for j in data:
            if 'Flutter tests' not in j['steps']:
                continue
            print(j['job'])
            for r in files(run, j['id'])[:n]:
                print(f"    {r['span']:5d} s span  ({r['first']}-{r['last']} s)  {r['tests']:4d}  {r['file']}")
    elif cmd == 'rust':
        for j in data:
            if 'Rust tests' not in j['steps']:
                continue
            r = rust(run, j['id'])
            print(f"{j['job']}: compile {r['compile']} s, step {r['step']} s")
            for b in r['binaries']:
                if b['seconds'] >= 1:
                    print(f"    {b['seconds']:6.1f} s  {b['binary']}")
    elif cmd == 'json':
        for j in data:
            if 'Flutter tests' in j['steps']:
                j['files'] = files(run, j['id'])[:12]
            if 'Rust tests' in j['steps']:
                j['rust'] = rust(run, j['id'])
        json.dump({'run': int(run), 'jobs': data}, sys.stdout, indent=1)
        print()
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main()
