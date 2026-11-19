"""summarise.py <results.csv>: median per (filter, source, encoder, arm) and the
demuxer's change against vspipe in wall time and total CPU."""
import csv, sys, statistics as st
from collections import defaultdict
rows = list(csv.DictReader(open(sys.argv[1])))
g = defaultdict(list)
for r in rows:
    g[(r['filter'], r['source'], r['encoder'], r['arm'])].append(r)
med = lambda rs, k: st.median(float(r[k]) for r in rs)
print("filter,source,encoder,vspipe_wall,demux_wall,wall_change_pct,vspipe_cpu,demux_cpu,cpu_change_pct,"
      "vspipe_fps,demux_fps,vspipe_proc_cpu,vspipe_rss_mb,demux_rss_mb,reps")
for (f, s, e, a), rs in g.items():
    if a != 'vspipe':
        continue
    d = g[(f, s, e, 'demuxer')]
    vw, dw, vc, dc = med(rs, 'wall_s'), med(d, 'wall_s'), med(rs, 'cpu_s'), med(d, 'cpu_s')
    print(f"{f},{s},{e},{vw:.2f},{dw:.2f},{100*(dw/vw-1):+.0f},{vc:.1f},{dc:.1f},{100*(dc/vc-1):+.0f},"
          f"{med(rs,'fps'):.1f},{med(d,'fps'):.1f},{med(rs,'vs_cpu_s'):.1f},"
          f"{med(rs,'maxrss_mb'):.0f},{med(d,'maxrss_mb'):.0f},{len(rs)}")
