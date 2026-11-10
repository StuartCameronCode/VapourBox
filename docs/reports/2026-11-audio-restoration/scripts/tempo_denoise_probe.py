"""Two follow-ups from the first heavy-test run.

1. Does atempo shift the audio as well as stretching it? (The drift test
   found every click ~20 ms early.)
2. Why did afftdn take only 0.7 dB off white noise at -39 dBFS with nr=20?
   Its noise floor `nf` defaults to -50 dB; try the measured floor.

Run:  WORK=/scratch FFMPEG=.../ffmpeg python tempo_denoise_probe.py
"""
import os

import numpy as np

from common import WORK, ff, decode, rms_db

RATE = 48000
CLICKS = ("aevalsrc='0.8*sin(2*PI*3000*t)*(lt(mod(t\\,0.7)\\,0.003)"
          "+lt(mod(t+0.23\\,1.1)\\,0.003))':s=48000:d=8")


def onsets(x, thr=0.3, gap=0.1):
    out, last = [], -1e9
    for i in np.flatnonzero(np.abs(x) > thr):
        t = i / RATE
        if t - last > gap:
            out.append(t)
        last = t
    return np.array(out)


def main():
    src = os.path.join(WORK, "probe_clicks.wav")
    ff("-f", "lavfi", "-i", CLICKS, "-c:a", "pcm_f32le", src)
    ref = onsets(decode(src, RATE)[:, 0])
    print("== atempo: first click positions vs expected t / factor ==")
    for factor in (1.004, 0.996, 1.02):
        for chain in (f"atempo={factor}", f"asetrate={RATE*factor:.3f},aresample={RATE}",
                      f"aresample={RATE}:async=0,rubberband=tempo={factor}" if False else None):
            if chain is None:
                continue
            got = onsets(decode(src, RATE, af=chain)[:, 0])
            exp = ref / factor
            n = min(len(got), len(exp))
            err = got[:n] - exp[:n]
            print(f"  {chain:40s} error mean {err.mean()*1000:7.2f} ms, "
                  f"first {err[0]*1000:7.2f} ms, last {err[n-1]*1000:7.2f} ms")

    print("== afftdn on white noise (-39 dBFS RMS) + clicks ==")
    noisy = os.path.join(WORK, "probe_noise.wav")
    ff("-f", "lavfi", "-i", CLICKS, "-f", "lavfi", "-i",
       "anoisesrc=c=white:a=0.02:r=48000:d=8:seed=7",
       "-filter_complex", "[0][1]amix=inputs=2:normalize=0", "-c:a", "pcm_f32le", noisy)
    x = decode(noisy, RATE)[:, 0]
    win = slice(int(4.0 * RATE), int(4.12 * RATE))
    # The floor afftdn would be told: the 10th percentile of 50 ms RMS.
    frames = x[: len(x) // 2400 * 2400].reshape(-1, 2400)
    floor = np.percentile(20 * np.log10(np.sqrt((frames ** 2).mean(axis=1)) + 1e-12), 10)
    print(f"  input floor {rms_db(x[win]):.1f} dB; 10th-percentile 50 ms RMS {floor:.1f} dB")
    for chain in ("afftdn=nr=20:nf=-50:tn=1", "afftdn=nr=20:nf=-50",
                  f"afftdn=nr=20:nf={floor:.0f}", f"afftdn=nr=20:nf={floor:.0f}:tn=1",
                  f"afftdn=nr=12:nf={floor:.0f}:tn=1"):
        y = decode(noisy, RATE, af=chain)[:, 0]
        print(f"  {chain:34s} floor {rms_db(y[win]):6.1f} dB (down {rms_db(x[win]) - rms_db(y[win]):5.1f})")


if __name__ == "__main__":
    main()
