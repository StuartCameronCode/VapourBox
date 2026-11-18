"""Which output samples of bare.vpy's call are uninitialised (task #66).

valgrind reports a write() of uninitialised bytes once per call stack, so one
process can only say "somewhere". This runs one process per region, each
writing only its region's bytes, under memcheck, and prints the regions that
complain: first plane x 8-row bands, then 8-column bands of each band hit.

  locate.py <python> <call> <WxH> <format> [jobs]
Run with the bundle's environment (python, plugins); needs valgrind.
"""
import concurrent.futures
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

CHILD = r'''
import os, sys
import vapoursynth as vs
call, size, fmt, plane, y0, y1, x0, x1 = sys.argv[1:9]
g = {'call': call, 'size': size, 'fmt': fmt}
exec(compile(open(os.path.join(sys.argv[9], 'bare.vpy')).read(), 'bare.vpy', 'exec'), g)
f = vs.get_output(0)[0].get_frame(0)
p = int(plane)
m = f[p]
h, w = m.shape
data = memoryview(m).tobytes()  # copying uninitialised bytes is not reported
bps = len(data) // (w * h)
fd = os.open(os.devnull, os.O_WRONLY)
for y in range(int(y0), min(int(y1), h)):
    row = data[y * w * bps:(y + 1) * w * bps]
    os.write(fd, row[int(x0) * bps:min(int(x1), w) * bps])
print('dims', w, h)
'''


def run(py, call, size, fmt, plane, y0, y1, x0, x1):
    r = subprocess.run(['valgrind', '--error-exitcode=99', '--num-callers=4', py, '-c', CHILD,
                        call, size, fmt, str(plane), str(y0), str(y1), str(x0), str(x1), HERE],
                       capture_output=True, text=True, env={**os.environ, 'PYTHONMALLOC': 'malloc'})
    dims = [l for l in r.stdout.splitlines() if l.startswith('dims')]
    return r.returncode, (tuple(map(int, dims[0].split()[1:])) if dims else None), r.stderr[-400:]


def main():
    py, call, size, fmt = sys.argv[1:5]
    jobs = int(sys.argv[5]) if len(sys.argv) > 5 else os.cpu_count()
    w, h = map(int, size.split('x'))
    ex = concurrent.futures.ThreadPoolExecutor(jobs)
    planes = range(3)
    dims = {}
    rows = {}
    futs = {}
    for p in planes:
        rc, d, err = run(py, call, size, fmt, p, 0, 1, 0, 1)
        if d is None:
            print('child failed:', err)
            return 1
        dims[p] = d
        for y0 in range(0, d[1], 8):
            futs[ex.submit(run, py, call, size, fmt, p, y0, y0 + 8, 0, d[0])] = (p, y0)
    for f, (p, y0) in futs.items():
        rows[(p, y0)] = f.result()[0] == 99
    hit = sorted(k for k, v in rows.items() if v)
    print('%s %s %s: planes %s' % (call, size, fmt, dims))
    print('row bands with uninitialised samples (plane, first row):', hit or 'none')
    futs = {}
    for (p, y0) in hit:
        for x0 in range(0, dims[p][0], 8):
            futs[ex.submit(run, py, call, size, fmt, p, y0, y0 + 8, x0, x0 + 8)] = (p, y0, x0)
    cols = {}
    for f, (p, y0, x0) in futs.items():
        if f.result()[0] == 99:
            cols.setdefault((p, y0), []).append(x0)
    for k in sorted(cols):
        print('  plane %d rows %d..%d: columns from %s (8 wide each)' % (k[0], k[1], k[1] + 7, sorted(cols[k])))
    return 0


sys.exit(main())
