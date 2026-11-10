"""Telecine paths through a trimmed encode, before and after the fix: the
output frame count (IVTC's decimation and Soft Telecine's relabel depend on
the decoder handing over every slot) and which pictures come out.

  python3 telecine_probe.py --before WORKER --after WORKER"""
import os
import subprocess
import sys
from seeklib import RES, WORK, probe
from identity_probe import framemd5
from worker_probe import job_for

CASES = [('hard_telecine_test.avi', 'ivtc', 10, 69), ('soft_telecine_test.mkv', 'softTelecine', 10, 69),
         ('soft_telecine_test.mkv', None, 10, 69)]


def encode(worker, src, method, start, end, tag):
    s = probe(src)
    out = os.path.join(WORK, f'tc_{tag}.mkv')
    if os.path.exists(out):
        os.remove(out)
    extra = {'startFrame': start, 'endFrame': end, 'totalFrames': end - start + 1}
    if method:
        q = {'enabled': True, 'method': method, 'tff': True, 'ivtcCycle': 5}
        extra.update({'qtgmcParameters': q, 'processingPipeline': {'deinterlace': q}})
    r = subprocess.run([worker, '--config', job_for(src, s, out, **extra)], capture_output=True)
    if r.returncode:
        raise SystemExit(r.stderr.decode(errors='replace')[-800:])
    return framemd5(out)


def main():
    a = sys.argv[1:]
    before, after = a[a.index('--before') + 1], a[a.index('--after') + 1]
    for name, method, start, end in CASES:
        src = os.path.join(RES, name)
        b = encode(before, src, method, start, end, 'b')
        f = encode(after, src, method, start, end, 'a')
        lead_b = sum(1 for x in b[1:4] if x == b[0])
        lead_a = sum(1 for x in f[1:4] if x == f[0])
        print(f"{name:24s} {method or 'no passes':13s} trim {start}..{end}: frames {len(b)} -> {len(f)}; "
              f"identical: {b == f}; first frame repeated {lead_b} -> {lead_a} times")


if __name__ == '__main__':
    main()
