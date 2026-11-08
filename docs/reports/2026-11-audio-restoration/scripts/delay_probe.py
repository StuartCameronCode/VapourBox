"""How far does each processing step move the audio in time?

Measures, by cross-correlating a click track before and after:
  - afftdn at several sample rates and strengths (Video-Enhancer reported 1200
    samples at 48 kHz);
  - DeepFilterNet's deep-filter, with and without -D (--compensate-delay);
  - atempo, adeclick, adeclip, highpass/bandreject, loudnorm (expected 0).

Run:  WORK=/scratch FFMPEG=.../ffmpeg [DEEP_FILTER=.../deep-filter] python delay_probe.py
"""
import os
import shutil
import subprocess

from common import WORK, DEEP_FILTER, ff, decode, lag_samples

CLICKS = ("aevalsrc='if(lt(mod(t\\,0.37)\\,0.002)\\,0.8*sin(2*PI*2000*t)\\,0)"
          "+0.05*sin(2*PI*440*t)':s={rate}:d=12")


def fixture(rate):
    path = os.path.join(WORK, f"clicks_{rate}.wav")
    ff("-f", "lavfi", "-i", CLICKS.format(rate=rate) + ",aformat=channel_layouts=mono",
       "-f", "lavfi", "-i", f"anoisesrc=c=pink:a=0.02:r={rate}:d=12",
       "-filter_complex", "[0][1]amix=inputs=2:normalize=0", "-c:a", "pcm_f32le", path)
    return path


def measure(src, rate, af):
    ref = decode(src, rate)[:, 0]
    out = decode(src, rate, af=af)[:, 0]
    return lag_samples(ref, out, rate // 2)


def peak(src, rate, af):
    import numpy as np
    return 20 * np.log10(np.abs(decode(src, rate, af=af)[:, 0]).max())


def main():
    src48 = fixture(48000)
    print("== alimiter level: peak dBFS of a 0.85-peak click track, limit 0.5 (-6 dB) ==")
    for af in ("anull", "alimiter=limit=0.5", "alimiter=limit=0.5:level=0:latency=1"):
        print(f"  {af:40s} peak {peak(src48, 48000, af):6.2f} dBFS")
    print("== ffmpeg filters (lag in samples, + = output late) ==")
    for rate in (48000, 44100, 32000):
        src = fixture(rate)
        for af in ["afftdn=nr=12", "afftdn=nr=24:nf=-40", "afftdn=nr=6",
                   "adeclick", "adeclip", "highpass=f=40",
                   "bandreject=f=50:width_type=q:w=4,bandreject=f=100:width_type=q:w=4",
                   "loudnorm=I=-16:TP=-1.5:LRA=11,aresample=%d" % rate,
                   "alimiter=limit=0.5", "alimiter=limit=0.5:level=0:latency=1",
                   "aresample=%d,asetrate=%d,aresample=%d" % (rate * 4, rate * 4, rate)]:
            print(f"{rate:6d} Hz  {af:60s} lag={measure(src, rate, af):6d}")

    if not DEEP_FILTER:
        print("DEEP_FILTER not set; skipping DeepFilterNet")
        return
    print("== deep-filter ==")
    for rate in (48000, 44100):
        src = fixture(rate)
        for flags in ([], ["-D"]):
            out_dir = os.path.join(WORK, "dfn_out")
            shutil.rmtree(out_dir, ignore_errors=True)
            r = subprocess.run([DEEP_FILTER, *flags, "-o", out_dir, src],
                               capture_output=True, text=True)
            if r.returncode != 0:
                print(f"{rate} Hz {flags}: FAILED {r.stderr.strip()[-300:]}")
                continue
            out = os.path.join(out_dir, os.path.basename(src))
            ref = decode(src, 48000)[:, 0]
            got = decode(out, 48000)[:, 0]
            print(f"{rate:6d} Hz in, flags={flags}: out frames={len(got)} "
                  f"(in {len(ref)}), lag={lag_samples(ref, got, 24000)} samples @48k")


if __name__ == "__main__":
    main()
