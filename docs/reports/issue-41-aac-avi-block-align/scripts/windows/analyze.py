"""Run every reader on every fixture and summarise the timing.

    python analyze.py <avi_timing.exe> <work dir>  > results.jsonl

One JSON line per reader x file:
- packets        chunks in the file (ffmpeg's count)
- delivered      samples the reader delivered
- late_steps     for a compressed reader: places where one sample's time is
                 more than 1 ms after the previous one's + 1024/48000 s
                 (a packet timed as two shows here)
- end_offset_ms  the last sample's time less where it plays (its index
                 x 1024/48000 for a compressed reader; the samples decoded
                 before it for mf_pcm). 0 = in time; +21.3 per packet timed
                 as two
- bytes_delivered / bytes_in_file  for the compressed readers: whether the
                 reader handed over every byte of the stream
- vfw: VfW reads by its own "samples", so only its reads and the bytes it
                 returned are listed
- ok / note / format as the reader reported
"""
import json
import os
import subprocess
import sys

exe, work = sys.argv[1], sys.argv[2]
FRAME = 1024 / 48000
FILES = ['mono256', 'mono256_patched', 'mono192', 'mono192_patched', 'stereo192']
READERS = ['dshow', 'mf', 'mf_pcm', 'vfw']

for name in FILES:
    path = os.path.join(work, name + '.avi')
    packets = json.load(open(os.path.join(work, name + '.packets.json')))
    channels = 2 if name.startswith('stereo') else 1
    for reader in READERS:
        try:
            out = subprocess.run([exe, reader, path], capture_output=True, text=True, timeout=120).stdout.strip()
            r = json.loads(out.splitlines()[-1])
        except Exception as e:  # noqa: BLE001 - report whatever went wrong
            print(json.dumps({'reader': reader, 'file': name, 'ok': False, 'note': f'probe failed: {e}'}))
            continue
        times = [(t / 1e7, n) for t, n in r.get('times', [])]
        row = {'reader': reader, 'file': name, 'ok': r['ok'], 'note': r['note'], 'format': r['format'],
               'packets': len(packets), 'delivered': len(times),
               'largest_packet': max(packets), 'over_768_per_channel': sum(p > 768 * channels for p in packets)}
        if reader in ('vfw', 'mf', 'dshow'):
            row['bytes_delivered'] = sum(n for _, n in times)
            row['bytes_in_file'] = sum(packets)
        if reader == 'vfw':
            row['reads'] = len(times)
            row['vfw_reads'] = [[round(t, 4), n] for t, n in times[:6]]
            row['end_s'] = round(times[-1][0], 4) if times else None
        elif times and reader != 'mf_pcm':
            row['late_steps'] = sum(1 for (a, _), (b, _) in zip(times, times[1:]) if b - a > FRAME + 0.001)
            row['early_steps'] = sum(1 for (a, _), (b, _) in zip(times, times[1:]) if b - a < FRAME - 0.001)
            row['first_s'] = round(times[0][0], 6)
            row['end_offset_ms'] = round((times[-1][0] - times[0][0] - (len(times) - 1) * FRAME) * 1000, 2)
            row['sizes_match'] = [n for _, n in times] == packets
        elif times:
            decoded = 0
            worst = 0.0
            for t, n in times:
                worst = max(worst, abs(t - times[0][0] - decoded / 48000), key=abs)
                decoded += n // (2 * channels)
            row['first_s'] = round(times[0][0], 6)
            row['max_offset_ms'] = round(worst * 1000, 2)
            row['decoded_samples'] = decoded
        print(json.dumps(row), flush=True)
