"""Where a TS/PS seek lands: the first packets ffmpeg reads after an input
-ss, stream-copied with -copyinkf so the non-key ones are kept (F=0x0 is not a
keyframe; F=0x1 is). Then the pictures a decode from that seek gives, named by
their index in the sequential decode.

  python3 landing_probe.py [source frame ...]"""
import os
import subprocess
import sys
from seeklib import FF, RES, probe, video_start, target, sequential, decode, indices
import make_variants


def landing(path, n):
    s = probe(path)
    t = target(n, s['fps'], video_start(path))
    out = subprocess.run([FF, '-v', 'error', '-copyts', '-ss', f'{t:.6f}', '-i', path,
                          '-map', '0:v:0', '-c', 'copy', '-copyinkf', '-frames:v', '3',
                          '-f', 'framecrc', '-'], capture_output=True, text=True).stdout
    rows = [l for l in out.splitlines() if l and not l.startswith('#')]
    pk = []
    for r in rows:
        f = [x.strip() for x in r.split(',')]
        pk.append({'dts': int(f[1]) / 90000, 'flags': f[6]})
    return s['container_start'] + t, pk


def main():
    v = make_variants.build()
    cases = [(v['dvd_pal.mpg'], 40), (v['ts_25_video_first.ts'], 40),
             (os.path.join(RES, 'seek_dvd_pal.mpg'), 40),
             (os.path.join(RES, 'seek_gop_late_video.ts'), 40),
             (os.path.join(RES, 'pal-dvbt-fieldcoded-25i.ts'), 40)]
    if len(sys.argv) > 2:
        cases = [(sys.argv[1], int(sys.argv[2]))]
    for path, n in cases:
        abs_t, pk = landing(path, n)
        seq = sequential(path)
        got = indices(decode(path, n, 1, 'plain'), seq)
        print(f"== {os.path.basename(path)} frame {n}: target {abs_t:.3f} s (file time)")
        for p in pk:
            print(f"   first packets: dts {p['dts']:.3f} s  {p['flags']}"
                  f"{'  <- keyframe' if p['flags'].endswith('1') else '  (not a keyframe)'}")
        print(f"   a plain seek decodes picture {got[0] if got else 'none'}")


if __name__ == '__main__':
    main()
