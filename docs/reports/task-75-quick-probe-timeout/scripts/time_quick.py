"""Task #75: every quick-probe call timed, serially or in parallel.
Usage: time_quick.py <ffmpeg> <jobs> [memo|nomemo]. Run with the bundle's Python under WorkerHarness.workerEnv (see reproduce.sh)."""
import os
import importlib.util, sys, time, json, tempfile, concurrent.futures
spec = importlib.util.spec_from_file_location('probe', os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..', '..', 'Scripts', 'probe-plugin-formats.py'))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
calls = m._calls(); limited = m.limited_calls(); padded = m.padded_calls()
grids = {k: m.quick_grid(k in limited, k in padded) for k in calls}
sizes = sorted({(c['w'], c['h']) for g in grids.values() for c in g})
out = {}
memo = len(sys.argv) < 4 or sys.argv[3] != 'nomemo'
with tempfile.TemporaryDirectory() as tmp:
    fx = m.make_fixtures(tmp, sizes, sys.argv[1])
    def one(k):
        t = time.time(); r = m.run_cells(k, grids[k], fx, k in padded, memo); return k, time.time() - t, len(grids[k]), sum(1 for v in r.values() if 'crash' in v.get('error',''))
    t0 = time.time()
    with concurrent.futures.ThreadPoolExecutor(int(sys.argv[2])) as ex:
        for k, dt, n, cr in ex.map(one, list(calls)):
            out[k] = dt; print('%-42s %7.1f s %3d cells%s' % (k, dt, n, ' CRASH %d' % cr if cr else ''), flush=True)
    print('TOTAL wall %.1f s, sum %.1f s' % (time.time() - t0, sum(out.values())))
