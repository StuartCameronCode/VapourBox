"""What counts as a reset (task #21): the worker's --scan-timestamps on
variants built here, each checked against the rule (a DTS > 0.1 s back or
> 10 s forward, per stream).

- forward gaps of 5 s (a drop-out: not a reset) and 15 s (a reset)
- a TS whose clock passes the 33-bit wrap (unwrapped by the demuxer: none)
- a DVD-style PS with AC-3 and LPCM sound, joined: copied, continuous
"""
import os

from resetlib import FF, WORK, run, worker_json


def seg(out, fmt, offset=0.0, duration=4, audio=('-c:a', 'mp2')):
    args = [FF, '-y', '-v', 'error',
            '-f', 'lavfi', '-i', f'testsrc2=size=176x144:rate=25:duration={duration}',
            '-f', 'lavfi', '-i', f'sine=sample_rate=48000:duration={duration}',
            '-c:v', 'mpeg2video', '-g', '12', '-bf', '2', *audio]
    if offset:
        args += ['-output_ts_offset', str(offset)]
    run(args + ['-f', fmt, out])
    return out


def join(out, parts):
    with open(out, 'wb') as f:
        for p in parts:
            f.write(open(p, 'rb').read())
    return out


def scan(path):
    s = worker_json('--scan-timestamps', path)[0]
    video = [r['packet'] for r in s['resets'] if r['codecType'] == 'video']
    return len(s['resets']), video


def main():
    w = lambda n: os.path.join(WORK, n)
    a = seg(w('gap_a.ts'), 'mpegts')
    cases = {
        'forward gap 5 s (drop-out)': join(w('gap5.ts'), [a, seg(w('gap_b5.ts'), 'mpegts', 9.0)]),
        'forward gap 15 s': join(w('gap15.ts'), [a, seg(w('gap_b15.ts'), 'mpegts', 19.0)]),
        '33-bit wrap inside one stream': seg(w('wrap.ts'), 'mpegts', 2 ** 33 / 90000 - 2.0),
        'backward reset (two clocks)': join(w('back.ts'), [a, seg(w('back_b.ts'), 'mpegts')]),
    }
    for label, path in cases.items():
        n, video = scan(path)
        print(f'{label}: {n} reset(s), video at picture(s) {video}')

    dvd = [seg(w(f'dvd{i}.mpg'), 'vob', audio=('-map', '0:v', '-map', '1:a', '-map', '1:a',
                                                 '-c:a:0', 'ac3', '-c:a:1', 'pcm_dvd'))
           for i in (1, 2)]
    joined = join(w('dvd_joined.mpg'), dvd)
    n, video = scan(joined)
    out = w('dvd_continuous.mpg')
    msgs = worker_json('--make-continuous', joined, '--output', out)
    ok = msgs[-1].get('success')
    after = scan(out) if ok else None
    print(f'PS with AC-3 + LPCM, joined: {n} reset(s) (video {video}); copy '
          f'{"succeeded" if ok else "FAILED " + str(msgs[-2:])}, resets after: {after}')


if __name__ == '__main__':
    main()
