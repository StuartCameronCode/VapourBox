"""One process: a hash per call x picture x depth, as JSON on stdout.
FFTW plans once per process, so a second process is the only way to see a
different plan: probe.py runs this in many fresh processes.
argv: [dump_dir key ...] -- with a dump dir, also writes the named keys' raw
output to <dump_dir>/<md5>.raw (once per distinct picture), so probe.py can
measure how far two pictures are apart."""
import os
import sys
# Windows' embeddable Python (._pth) does not put the script's folder on sys.path.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hashlib
import json

from common import CASES, INFO_CASES, core, digest, keys, pictures, plugin_name, raw

core.num_threads = 8
dump_dir = sys.argv[1] if len(sys.argv) > 1 else None
dump_keys = set(sys.argv[2:])
pics = pictures()
cases = dict(CASES, **INFO_CASES)
out = {}
for key, name, pname, depth in keys(cases):
    if dump_dir is not None and key not in dump_keys:
        continue
    clip = cases[name](pics[pname][depth])
    if dump_dir is None:
        out[key] = digest(clip)
        continue
    data = b''.join(raw(clip))
    h = hashlib.md5(data).hexdigest()
    path = os.path.join(dump_dir, h + '.raw')
    if not os.path.exists(path):
        with open(path, 'wb') as fh:
            fh.write(data)
    out[key] = h
print(json.dumps({'plugin': plugin_name(), 'hashes': out}, sort_keys=True))
