"""rtime.py <outfile> <cmd...>: run cmd (stdin/stdout inherited), write
"<wall> <user> <sys> <maxrss_bytes>" for it and its children to outfile.
Stands in for /usr/bin/time, which macOS SIP strips DYLD_* from."""
import os, sys, time, subprocess, resource
out, cmd = sys.argv[1], sys.argv[2:]
t0 = time.time()
p = subprocess.Popen(cmd)
_, status, ru = os.wait4(p.pid, 0)
wall = time.time() - t0
open(out, 'w').write(f"{wall:.3f} {ru.ru_utime:.3f} {ru.ru_stime:.3f} {ru.ru_maxrss}\n")
sys.exit(os.waitstatus_to_exitcode(status) if os.waitstatus_to_exitcode(status) >= 0 else 1)
