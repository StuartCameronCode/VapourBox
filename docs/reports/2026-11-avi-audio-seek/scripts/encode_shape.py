"""The encode's own shape: a picture input (lavfi, standing in for vspipe's
Y4M), the source as input 1 with the sound's -ss, `-c:a copy`, `-shortest`,
to MKV and AVI. Before the fix the sound's -ss is on the AVI; after, on a NUT
copy of its sound (`audio_restoration::sound_copy_args`). Reports each
stream's start, the output's frame count and where its sound sits against
the picture (+ = sound late), for in-points 2 (the fix's window) and 20
(the control, which the fix does not touch)."""
from audiolib import variants, ff, probe, work, samples, find, RATE, FPS

v = variants()
nut = work('sound_full.nut')
ff('-i', v['chirp'], '-map', '0:a', '-c', 'copy', '-f', 'nut', nut)
src, _ = samples([], v['chirp'], [])

print('| in-point | sound from | container | video start | audio start | frames | sound vs picture |')
print('|---|---|---|---|---|---|---|')
for start in (2, 20):
    t = start / FPS
    for label, sound in (('the AVI (before)', v['chirp']), ('a NUT copy (after)', nut)):
        if start == 20 and sound == nut:
            continue  # the fix only acts below 0.5 s
        for ext in ('mkv', 'avi'):
            out = work(f'enc_{start}_{"nut" if sound == nut else "avi"}.{ext}')
            ff('-f', 'lavfi', '-i', f'testsrc2=s=320x240:r=30000/1001:d={60 / FPS:.6f}',
               '-ss', f'{t:.6f}', '-i', sound, '-map', '0:v', '-map', '1:a',
               '-c:v', 'ffv1', '-c:a', 'copy', '-shortest', out)
            j = probe(out, '-count_packets', '-show_entries',
                      'stream=codec_type,start_time,nb_read_packets:format=start_time')
            s = {x['codec_type']: x for x in j['streams']}
            vs, as_ = float(s['video']['start_time']), float(s['audio']['start_time'])
            got, _ = samples([], out, [], af='aresample=first_pts=0')
            k = find(got, src)
            # Output sample i holds source sample i + k; the picture's first
            # frame (source time t) sits at output time vs.
            lag = None if k is None else round(t * RATE) - (round(vs * RATE) + k)
            print(f'| {start} | {label} | {ext} | {vs:.3f} | {as_:.3f} | '
                  f'{s["video"]["nb_read_packets"]} of 60 | '
                  + ('not found' if lag is None else f'{lag:+d} samples ({lag / RATE * 1000:+.1f} ms)') + ' |')
