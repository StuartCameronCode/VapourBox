"""Print the headline of one or more probe.py outputs. argv: probe.json ..."""
import io
import json
import sys

for path in sys.argv[1:]:
    d = json.load(io.open(path, encoding='utf-8-sig'))
    print('==', path, '|', d.get('machine'), '|', d.get('processor'), '| cpus', d.get('cpu_count'))
    for m, v in d.get('xproc', {}).items():
        print('  measure %-7s keys with >1 hash over %d processes: %s'
              % (m, d['processes'], v['keys_with_more_than_one'] or 'none'))
    if 'wisdom' in d:
        print('  0 after 1 in one process differs from fresh 0:', d['wisdom']['differs_from_fresh_0'] or 'none')
