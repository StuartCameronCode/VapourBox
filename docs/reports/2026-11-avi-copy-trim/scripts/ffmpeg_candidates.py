"""Table 1: the candidate fixes, in the encode's own shape (a lavfi picture
standing in for vspipe's Y4M, the source as input 1 with the trim's -ss,
-shortest), into AVI, with today's MKV/MP4 as the reference.

  copy (today)          -c:a copy
  copypriorss           -c:a copy -copypriorss:a 0, the input seeked to the in-point
  copypriorss, early    the same, the input seeked half a packet early

ffmpeg drops a copied packet whose timestamp, in the stream's own time base,
is below the seek rounded to that time base. An AVI's compressed audio counts
in packets, so the plain seek already keeps the nearest packet; a fine time
base (MP4 1/48000) keeps the first at or after the seek, so the early seek
is what finds the nearest. The time base column shows which.
  decode to PCM         -c:a pcm_s16le (input -ss + decode: ffmpeg trims to the sample)
"""
from cutlib import fixtures, ff, work, decode, lag, exact_from, video_start, packet_ms, time_base, FPS, RATE, FRAMES

METHODS = (
    ('MKV, copy (today)', 'mkv', ['-c:a', 'copy'], False),
    ('MP4, copy (today)', 'mp4', ['-c:a', 'copy'], False),
    ('AVI, copy (today)', 'avi', ['-c:a', 'copy'], False),
    ('AVI, -copypriorss 0', 'avi', ['-c:a', 'copy', '-copypriorss:a', '0'], False),
    ('AVI, -copypriorss 0, half a packet early', 'avi', ['-c:a', 'copy', '-copypriorss:a', '0'], True),
    ('AVI, decode to PCM', 'avi', ['-c:a', 'pcm_s16le'], False),
)

src = fixtures()
print('| source | packet | time base | in-point | method | sound vs picture | peak | max diff from in-point |')
print('|---|---|---|---|---|---|---|---|')
for name in ('PCM s16 in AVI', 'MP3 in AVI', 'AC-3 in AVI', 'AAC in MP4', 'AC-3 in MKV'):
    path = src[name]
    ref, ref_full = decode(path), decode(path, rate=RATE)
    p = packet_ms(path)
    tb = time_base(path)
    for start in FRAMES:
        t = start / FPS
        for label, ext, audio, early in METHODS:
            if ext == 'mp4' and name.startswith('PCM'):
                continue  # MP4 holds no PCM
            ss = t - p / 2000 if early else t
            out = work(f'cand.{ext}')
            ff('-f', 'lavfi', '-i', f'testsrc2=s=320x240:r=30000/1001:d={90 / FPS:.6f}',
               '-ss', f'{ss:.6f}', '-i', path, '-map', '0:v', '-map', '1:a',
               '-c:v', 'ffv1', *audio, '-shortest', out)
            vs = video_start(out)
            l, peak = lag(ref, decode(out), start, vs)
            diff = ''
            if 'PCM' in label and name.startswith('PCM'):
                diff = f'{exact_from(ref_full, decode(out, rate=RATE), start, vs, RATE):.1e}'
            ls = 'not found' if l is None else f'{l * 1000:+.1f} ms'
            print(f'| {name} | {p:.1f} ms | {tb} | {start} | {label} | {ls} | {peak:.3f} | {diff} |', flush=True)
