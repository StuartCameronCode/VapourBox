"""Every start frame of each source, decoded the way the worker's seeking
decoder does under four rules, each picture named by its index in an
independent sequential decode (MD5 of the luma plane). Prints the number of
wrong start frames per rule and the first few.

  python3 sweep.py [--json out.json] [source ...]

With no sources: the three AVI fixtures, the controls and make_avi_variants'
variants. Rules: see avilib.seek_args (old, delay, ceil, fix)."""
import json
import os
import sys
from avilib import RES, decoder_delay, indices, probe, raw, seek_args, sequential
import make_avi_variants

FIXTURES = ['hard_telecine_test.avi', 'avi_h264_bframes.avi', 'avi_ntsc_intra.avi',
            'small_clip.mp4', 'seek_timebase_2997.mov', 'face_restore_test.mp4']
MODES = ('old', 'delay', 'ceil', 'fix')


def run(path):
    s = probe(path)
    seq = sequential(path)
    delay = decoder_delay(path)
    out = {'source': os.path.basename(path), 'codec': s['codec_name'], 'time_base': s['time_base'],
           'has_b_frames': s['has_b_frames'], 'decoder_delay': delay, 'frames': len(seq)}
    last = min(len(seq) - 3, 90)
    for mode in MODES:
        bad = []
        for n in range(1, last):
            pre, vf = seek_args(n, s['fps'], mode, delay)
            got = raw([*pre, '-apply_cropping', 'codec', '-i', path, '-map', '0:v:0',
                       '-frames:v', '3', '-vf', vf], s['width'], s['height'])
            idx = indices(got, seq)
            if idx != [n, n + 1, n + 2]:
                bad.append([n, idx[0] if idx else None])
        out[mode] = {'starts': last - 1, 'wrong': len(bad), 'examples': bad[:8]}
    return out


def main():
    args = sys.argv[1:]
    dest = None
    if args[:1] == ['--json']:
        dest, args = args[1], args[2:]
    paths = args or [os.path.join(RES, f) for f in FIXTURES] + make_avi_variants.build()
    results = []
    for p in paths:
        r = run(p)
        results.append(r)
        print(f"== {r['source']}  {r['codec']}  tb {r['time_base']}  has_b_frames {r['has_b_frames']}  "
              f"decoder delay {r['decoder_delay']}  {r['frames']} frames")
        for m in MODES:
            print(f"  {m:6s} wrong {r[m]['wrong']:3d}/{r[m]['starts']}  e.g. (start, got) {r[m]['examples']}")
    if dest:
        with open(dest, 'w') as f:
            json.dump(results, f, indent=1)


if __name__ == '__main__':
    main()
