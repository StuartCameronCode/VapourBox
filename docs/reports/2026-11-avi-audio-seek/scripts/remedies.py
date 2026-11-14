"""Table 2: candidate fixes, on the chirp AVI, in-point frame 2 (0.066733 s),
a 2 s window, each compared sample by sample with
`atrim=start_sample=2135` of a decode from the start."""
import os
from audiolib import variants, samples, find, ff, work, RATE, FPS

v = variants()
t = 2 / FPS
n0 = round(t * RATE)                       # 2135
N = 2 * RATE

ref_all, _ = samples([], v['chirp'], [], af=f'atrim=start_sample={n0},asetpts=PTS-STARTPTS')
ref = ref_all[:N]


def row(name, got, failed=False):
    got = got[:N]
    k = find(got, ref_all)
    if k is None:
        print(f'| {name} | {len(got)} | not found{" (could not seek)" if failed else ""} | |')
        return
    m = max(abs(got[i] - ref_all[k + i]) for i in range(min(len(got), len(ref_all) - k)))
    print(f'| {name} | {len(got)} of {N} | {-k:+d} samples | {m:.2g} |')


print('| method | samples | offset (+ = late) | max diff |')
print('|---|---|---|---|')
got, failed = samples(['-ss', f'{t:.6f}', '-t', '2'], v['chirp'], [])
row('input -ss on the AVI (before the fix)', got, failed)
got, _ = samples(['-t', f'{t + 2:.6f}'], v['chirp'], [],
                 af=f'aresample=first_pts=0,atrim=start_sample={n0},asetpts=PTS-STARTPTS')
row('decode from 0, atrim=start_sample in the chain (the render)', got)
got, _ = samples([], v['chirp'], ['-ss', f'{t:.6f}', '-t', '2'])
row('decode from 0, output-side -ss/-t (analysis, transcription)', got)
for ext, fmt in (('mka', 'matroska'), ('audio.avi', 'avi'), ('nut', 'nut')):
    side = work(f'sound.{ext}')
    ff('-i', v['chirp'], '-map', '0:a', '-c', 'copy', '-f', fmt, side)
    got, failed = samples(['-ss', f'{t:.6f}', '-t', '2'], side, [])
    row(f'-c copy to {fmt.upper()}, input -ss on that', got, failed)
# The MP3 variant through NUT and audio-only AVI (48 kHz).
side_ref, _ = samples([], v['mp3'], [], 48000, af=f'atrim=start_sample={round(t * 48000)},asetpts=PTS-STARTPTS')
print()
print('| MP3 source, sound copy | offset (+ = late) |')
print('|---|---|')
for ext, fmt in (('mp3.nut', 'nut'), ('mp3.avi', 'avi'), ('mp3.mka', 'matroska')):
    side = work(f'sound.{ext}')
    ff('-i', v['mp3'], '-map', '0:a', '-c', 'copy', '-f', fmt, side)
    got, _ = samples(['-ss', f'{t:.6f}', '-t', '2'], side, [], 48000)
    k = find(got, side_ref, tol=2e-3, skip=4096)
    print(f'| {fmt.upper()} | ' + ('not found' if k is None else f'{-k:+d} samples ({-k / 48:.2f} ms)') + ' |')
