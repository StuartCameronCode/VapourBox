"""What the preroll costs: wall time of an 11-frame preview-style decode from
the middle of a 30 s 1080p H.264 TS (2 s GOPs), plain seek vs the fix at its
plan's preroll and at 3 s. Median of 5 runs."""
import statistics
import subprocess
import time
from seeklib import FF, probe, seek_plan, target, RESET_PTS
import make_variants

path = make_variants.build()['hd_gop50.ts']
s = probe(path)
plan = seek_plan(path)
t = target(500, s['fps'], 0.0)


def run(args):
    times = []
    for _ in range(5):
        t0 = time.perf_counter()
        subprocess.run([FF, '-v', 'error', *args, '-f', 'rawvideo', '-pix_fmt', 'yuv420p',
                        '-y', '-'], stdout=subprocess.DEVNULL, check=True)
        times.append(time.perf_counter() - t0)
    return statistics.median(times)


def fixed(pre):
    return ['-copyts', '-ss', f'{t - pre:.6f}', '-i', path, '-map', '0:v:0', '-frames:v', '11',
            '-vf', f'trim=start={s["container_start"] + t:.6f},{RESET_PTS}']


print(f"plan: preroll {plan['preroll']:.2f} s (GOP {plan['gop']:.2f} s)")
print(f"plain seek          {run(['-ss', f'{t:.6f}', '-i', path, '-map', '0:v:0', '-frames:v', '11', '-vf', RESET_PTS]):.3f} s")
print(f"fix, plan preroll   {run(fixed(plan['preroll'])):.3f} s")
print(f"fix, 3 s preroll    {run(fixed(3.0)):.3f} s")
