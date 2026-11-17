"""Which frame heights each refusing call accepts on 4:2:0, called as the
plugin alone and as the template calls it now (run_within / module fix).

Section 1 of the report. Prints one JSON object: {call: {cell: [plain, now]}}.
"""
import importlib.util
import json
import os
import sys

from common import clip, first_line, probe_calls
import plugin_formats as pf

CALLS = ['havsfunc.QTGMC', 'bifrost.Bifrost', 'havsfunc.MCTemporalDenoise', 'dctf.DCTFilter',
         'deblock.Deblock', 'havsfunc.Deblock_QED', 'havsfunc.FixChromaBleedingMod',
         'havsfunc.LSFmod', 'sangnom.SangNom', 'temporaldegrain2.TemporalDegrain2',
         'srestore.unblend', 'stabilize.weave']
HEIGHTS = [int(h) for h in (sys.argv[1] if len(sys.argv) > 1 else '480,482,484,486,488,490,270,1082').split(',')]
BITS = [8, 10, 16]


def attempt(make):
    try:
        out = make()
        out.get_frame(min(5, out.num_frames - 1))
        return 'ok %dx%d' % (out.width, out.height)
    except Exception as e:  # noqa: BLE001 -- the error is the measurement
        return first_line(e)


calls = probe_calls()
OLD = os.environ.get('OLD_TEMPLATES')  # the templates before task #57


def old_module(name):
    spec = importlib.util.spec_from_file_location('old_' + name, os.path.join(OLD, name + '.py'))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


old_runs = {}
if OLD:
    old_runs = {'srestore.unblend': lambda c: old_module('srestore').unblend(c, 24000, 1001),
                'stabilize.weave': lambda c: old_module('stabilize').weave(c)}
res = {}
for key in CALLS:
    run = calls[key]['run']
    for h in HEIGHTS:
        w = 1440 if h > 1000 else 720
        for bits in BITS:
            for field in (0, 2):
                c = clip('420', bits, field, w, h)
                plain = attempt(lambda: old_runs.get(key, run)(c))
                if key in pf.CONTRACTS:
                    now = attempt(lambda: pf.run_within(c, key, run, delta_only=False))
                else:
                    now = attempt(lambda: run(c))  # fixed in its module
                res.setdefault(key, {})['420p%d/f%d/%dx%d' % (bits, field, w, h)] = [plain, now]
                print(key, h, bits, field, plain[:40], '|', now[:40], file=sys.stderr, flush=True)
print(json.dumps(res))
