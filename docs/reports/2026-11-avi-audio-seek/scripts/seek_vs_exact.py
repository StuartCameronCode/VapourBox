"""Table 1: the sound of an input -ss against an exact trim of the same file.

For each source and in-point: how many seconds of sound an input-seeked decode
skips (+) or repeats (-) against the exact output-side trim
(`-af atrim=start=t`), found by matching samples, and whether ffmpeg reported
"could not seek". The committed fixture's 440 Hz sine cannot be placed by its
samples (1.3 s is a whole number of periods), so its row says only whether
the seek failed; the chirp copy of its picture measures the same seek. MP3 is
measured at 48 kHz, after its decoder's first 4096 samples."""
from audiolib import variants, samples, find

ROWS = [('fixture', 'avi_h264_bframes.avi (H.264 B, PCM 32 k)', 32000),
        ('chirp', 'its picture + a chirp (AVI, PCM)', 32000),
        ('mp3', 'MPEG-4 ASP B + MP3 in AVI', 48000),
        ('mov', 'the chirp AVI remuxed to MOV', 32000),
        ('mp4', 'the chirp AVI remuxed to MP4', 32000)]
POINTS = [0.0334, 0.0667, 0.1, 0.12, 0.2]

v = variants()
print('| source | ' + ' | '.join(f'{t} s' for t in POINTS) + ' |')
print('|---' * (len(POINTS) + 1) + '|')
for key, label, rate in ROWS:
    cells = []
    for t in POINTS:
        seeked, failed = samples(['-ss', f'{t}'], v[key], [], rate)
        exact, _ = samples([], v[key], [], rate, af=f'atrim=start={t},asetpts=PTS-STARTPTS')
        if key == 'fixture':
            cells.append('could not seek' if failed else 'seeks')
            continue
        lossy = key == 'mp3'
        k = find(seeked, exact, tol=2e-3 if lossy else 1e-3, skip=4096 if lossy else 0)
        cell = 'not found' if k is None else ('exact' if k == 0 else f'{k / rate:+.4f} s')
        cells.append(cell + (' (could not seek)' if failed else ''))
    print(f'| {label} | ' + ' | '.join(cells) + ' |')
