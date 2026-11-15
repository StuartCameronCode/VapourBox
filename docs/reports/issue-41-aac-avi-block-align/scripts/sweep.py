"""Which AAC settings write a packet over avienc's 768 bytes per channel?

    python3 sweep.py <ffmpeg> <work dir> > sweep.jsonl

Encodes each source at each bitrate (and sample rate, channel count, seek
point) into AVI with ffmpeg's native AAC encoder and counts the packets over
768 x channels, the nBlockAlign avienc declares. Sources: the repo's
late_video.mkv and small_clip.mp4, and the synthetic sounds of harsh_audio.py
and a loud noise + sweep (made here). One JSON line per row of the report's
table.
"""
import json
import os
import subprocess
import sys

ffmpeg, work = sys.argv[1], sys.argv[2]
ffprobe = os.path.join(os.path.dirname(ffmpeg), 'ffprobe')
here = os.path.dirname(os.path.abspath(__file__))
res = os.path.normpath(os.path.join(here, '..', '..', '..', '..', 'Tests', 'TestResources'))
os.makedirs(work, exist_ok=True)
harsh_st, harsh_mono = os.path.join(work, 'harsh_stereo.wav'), os.path.join(work, 'harsh_mono.wav')
subprocess.run([sys.executable, os.path.join(here, 'harsh_audio.py'), ffmpeg, harsh_st, harsh_mono], check=True)
noise = os.path.join(work, 'noise_sweep.wav')
subprocess.run([ffmpeg, '-v', 'error', '-y',
                '-f', 'lavfi', '-i', 'anoisesrc=r=48000:a=0.9:c=white:seed=3:d=10',
                '-f', 'lavfi', '-i', 'aevalsrc=0.9*sin(2*PI*(200+9000*mod(t\\,0.25))*t)*lt(mod(t\\,0.25)\\,0.05):s=48000:d=10',
                '-filter_complex', '[0]volume=0.3[n];[n][1]amix=inputs=2:normalize=0', '-c:a', 'pcm_s24le', noise],
               check=True)


def packets(src, ss, ch, kbps, rate=None, extra=()):
    out = os.path.join(work, 'o.avi')
    cmd = [ffmpeg, '-v', 'error', '-y', '-ss', str(ss), '-i', src, '-map', '0:a:0', '-ac', str(ch)]
    if rate:
        cmd += ['-ar', str(rate)]
    cmd += ['-c:a', 'aac', '-b:a', f'{kbps}k', *extra, out]
    subprocess.run(cmd, check=True)
    sizes = subprocess.run([ffprobe, '-v', 'error', '-select_streams', 'a:0', '-show_entries', 'packet=size',
                            '-of', 'csv=p=0', out], check=True, capture_output=True, text=True).stdout.split()
    return [int(s) for s in sizes]


def row(label, src, ch, kbps, seeks, rate=None, extra=()):
    over_files = over_packets = largest = total = 0
    for ss in seeks:
        p = packets(src, ss, ch, kbps, rate, extra)
        n = sum(s > 768 * ch for s in p)
        over_files += n > 0
        over_packets += n
        largest = max(largest, max(p))
        total += len(p)
    print(json.dumps({'source': label, 'channels': ch, 'kbps': kbps, 'per_channel': kbps // ch,
                      'rate': rate or 48000, 'options': ' '.join(extra), 'encodes': len(seeks),
                      'encodes_over': over_files, 'packets_over': over_packets, 'packets': total,
                      'largest': largest, 'limit': 768 * ch}), flush=True)


late = os.path.join(res, 'late_video.mkv')
seeks30 = [round(0.9 + i * 0.0213, 6) for i in range(30)]
for kbps in (96, 128, 160, 192, 256):
    row('late_video.mkv, 30 seeks 0.9-1.5 s', late, 1, kbps, seeks30)
for kbps in (192, 256, 384, 512):
    row('late_video.mkv upmixed (L = R)', late, 2, kbps, seeks30[:10])
clip = os.path.join(res, 'small_clip.mp4')
for ch, rates in ((1, (96, 128, 160, 192, 256)), (2, (128, 192, 256, 320))):
    for kbps in rates:
        row('small_clip.mp4 (music, speech), 5 starts', clip, ch, kbps, [0, 0.0107, 0.0213, 7.5, 30])
for kbps in (96, 128, 160, 192, 256):
    row('synthetic: beeps + noise bursts', harsh_mono, 1, kbps, [0, 0.0107, 0.0213, 0.032, 0.5])
for kbps in (128, 192, 256, 320, 384, 512):
    row('synthetic, uncorrelated stereo', harsh_st, 2, kbps, [0, 0.0107, 0.0213, 0.032, 0.5])
for kbps in (96, 128, 160, 192):
    for rate in (48000, 44100, 32000):
        row('synthetic: loud noise + sweeps', noise, 1, kbps, [0], rate=rate)
for extra in (('-aac_coder', 'fast'), ('-aac_coder', 'twoloop'), ('-aac_pns', '0'), ('-maxrate', '192k', '-bufsize', '6144')):
    for kbps in (192, 256):
        row('synthetic: beeps + noise bursts, encoder option', harsh_mono, 1, kbps, [0], extra=extra)
