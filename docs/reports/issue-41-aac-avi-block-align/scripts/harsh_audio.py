"""The synthetic sound the sweep and the Windows probe encode: hard on ffmpeg's
AAC encoder (transients and noise bursts over a quiet tone), 12 s, 48 kHz.

    python3 harsh_audio.py <ffmpeg> <out_stereo.wav> <out_mono.wav>

Left: white-noise bursts every 0.37 s; right: pink-noise bursts every 0.29 s;
both carry a quiet 200 Hz tone and a 40 ms 1 kHz beep every 0.5 s. The mono
file is the left channel alone. Deterministic (seeded noise).
"""
import subprocess
import sys

ffmpeg, stereo, mono = sys.argv[1:4]
graph = (
    "[0]volume='lt(mod(t,0.37),0.03)':eval=frame[n0];"
    "[1]volume='lt(mod(t+0.1,0.29),0.02)':eval=frame[n1];"
    "[2]asplit[t0][t1];"
    "[n0][t0]amix=inputs=2:normalize=0[l];"
    "[n1][t1]amix=inputs=2:normalize=0[r];"
    "[l][r]join=inputs=2:channel_layout=stereo[a]"
)
subprocess.run([
    ffmpeg, '-v', 'error', '-y',
    '-f', 'lavfi', '-i', 'anoisesrc=r=48000:a=0.5:c=white:seed=1:d=12',
    '-f', 'lavfi', '-i', 'anoisesrc=r=48000:a=0.5:c=pink:seed=7:d=12',
    '-f', 'lavfi', '-i', 'aevalsrc=0.05*sin(2*PI*200*t)+0.6*sin(2*PI*1000*t)*lt(mod(t\\,0.5)\\,0.04):s=48000:d=12',
    '-filter_complex', graph, '-map', '[a]', '-c:a', 'pcm_s24le', stereo,
], check=True)
subprocess.run([ffmpeg, '-v', 'error', '-y', '-i', stereo, '-af', 'pan=mono|c0=c0', '-c:a', 'pcm_s24le', mono],
               check=True)
