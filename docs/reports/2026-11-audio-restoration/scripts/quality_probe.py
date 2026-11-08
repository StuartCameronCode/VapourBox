"""What each step does to a known signal, and how fast it runs.

Uses the filter strings the worker generates (see worker/src/audio_restoration.rs).

  - hum notches: attenuation at 50/100/150 Hz, change at 1 kHz;
  - afftdn: noise floor drop at nr 6/12/20/30 with the measured floor;
  - loudnorm (two passes, linear) + aresample: integrated loudness error;
  - DeepFilterNet: noise drop in speech pauses, change in the voiced bursts,
    delay with -D, at attenuation limits 100/30/15;
  - speed: seconds per minute of 48 kHz stereo for each step.

Run:  WORK=/scratch FFMPEG=.../ffmpeg [DEEP_FILTER=.../deep-filter] python quality_probe.py
"""
import json
import os
import re
import shutil
import subprocess
import time

import numpy as np

from common import WORK, FFMPEG, DEEP_FILTER, ff, decode, band_db, rms_db, lag_samples

RATE = 48000


def make(name, graph, secs):
    path = os.path.join(WORK, f"q_{name}.wav")
    ff("-filter_complex", graph, "-map", "[a]", "-t", str(secs), "-c:a", "pcm_f32le", path)
    return path


def timed(args):
    t = time.time()
    ff(*args)
    return time.time() - t


def main():
    # --- hum
    hum = make("hum", "sine=f=1000:r=48000:d=10[t];sine=f=50:r=48000:d=10[a1];"
               "sine=f=100:r=48000:d=10[a2];sine=f=150:r=48000:d=10[a3];"
               "[t][a1][a2][a3]amix=inputs=4:weights='1 0.8 0.4 0.3':normalize=0[a]", 10)
    notch = ",".join(f"bandreject=f={f}:width_type=q:w=8" for f in (50, 100, 150))
    x = decode(hum, RATE)[2 * RATE:8 * RATE, 0]
    y = decode(hum, RATE, af=notch)[2 * RATE:8 * RATE, 0]
    print("== hum notches (Q 8) ==")
    for f in (50, 100, 150, 1000):
        print(f"  {f:5d} Hz: {band_db(x, RATE, f) - band_db(y, RATE, f):6.1f} dB down")

    # --- afftdn
    noisy = make("noise", "sine=f=440:r=48000:d=10,volume=0.3,"
                 "aeval='val(0)*lt(mod(t\\,2)\\,1)'[t];"
                 "anoisesrc=c=white:a=0.02:r=48000:d=10:seed=7[n];[t][n]amix=inputs=2:normalize=0[a]", 10)
    x = decode(noisy, RATE)[:, 0]
    frames = x[: len(x) // 2400 * 2400].reshape(-1, 2400)
    floor = np.percentile(20 * np.log10(np.sqrt((frames ** 2).mean(axis=1)) + 1e-12), 10)
    gap = slice(int(5.2 * RATE), int(5.9 * RATE))   # a pause, after adaptation
    tone = slice(int(6.2 * RATE), int(6.9 * RATE))
    print(f"== afftdn (measured floor {floor:.1f} dB) ==")
    for nr in (6, 12, 20, 30):
        y = decode(noisy, RATE, af=f"afftdn=nr={nr}:nf={floor:.0f}")[:, 0]
        y = y[1200:]  # its 25 ms delay
        print(f"  nr={nr:2d}: pause {rms_db(x[gap]) - rms_db(y[gap]):5.1f} dB down, "
              f"tone {band_db(y[tone], RATE, 440) - band_db(x[tone], RATE, 440):+5.2f} dB")

    # --- loudnorm
    print("== loudnorm, two passes, linear ==")
    quiet = make("quiet", "aevalsrc='0.05*sin(2*PI*200*t)*(0.6+0.4*sin(2*PI*4*t))"
                 "*lt(mod(t\\,1.5)\\,1.0)':s=48000:d=20[a]", 20)
    for target in (-23, -16):
        r = subprocess.run([FFMPEG, "-hide_banner", "-nostats", "-i", quiet, "-af",
                            f"loudnorm=I={target}:TP=-1.5:LRA=11:print_format=json", "-f", "null", "-"],
                           capture_output=True, text=True).stderr
        m = json.loads(r[r.rfind("{"):r.rfind("}") + 1])
        out = os.path.join(WORK, "q_ln.wav")
        ff("-i", quiet, "-af",
           f"loudnorm=I={target}:TP=-1.5:LRA=11:measured_I={m['input_i']}:measured_TP={m['input_tp']}:"
           f"measured_LRA={m['input_lra']}:measured_thresh={m['input_thresh']}:offset={m['target_offset']}:"
           f"linear=true,aresample=48000", "-c:a", "pcm_f32le", out)
        r = subprocess.run([FFMPEG, "-hide_banner", "-nostats", "-i", out, "-af", "ebur128", "-f", "null", "-"],
                           capture_output=True, text=True).stderr
        got = float(re.findall(r"I:\s+(-?[\d.]+) LUFS", r)[-1])
        print(f"  target {target}: input {m['input_i']} LUFS -> {got} LUFS (error {got - target:+.1f} LU)")

    # --- speed (60 s stereo)
    print("== speed: seconds per minute of 48 kHz stereo ==")
    minute = make("minute", "anoisesrc=c=pink:a=0.1:r=48000:d=60,pan=stereo|c0=c0|c1=c0[a]", 60)
    for label, af in [("adeclick", "adeclick"), ("adeclip", "adeclip"),
                      ("afftdn", "afftdn=nr=12:nf=-40"), ("hum notches", notch),
                      ("drift resample", "aresample=192000,asetrate=192768,aresample=48000"),
                      ("loudnorm (one pass)", "loudnorm=I=-16:TP=-1.5:LRA=11,aresample=48000")]:
        secs = timed(["-i", minute, "-af", af, "-f", "null", "-"])
        print(f"  {label:22s} {secs:6.2f} s")

    if not DEEP_FILTER:
        print("DEEP_FILTER not set; skipping DeepFilterNet")
        return
    # --- DeepFilterNet
    speech = make("speech", "aevalsrc='(0.12*sin(2*PI*140*t)+0.08*sin(2*PI*280*t)+0.05*sin(2*PI*420*t)"
                  "+0.03*sin(2*PI*840*t))*(0.5+0.5*sin(2*PI*5*t))*lt(mod(t\\,1.6)\\,0.9)':s=48000:d=16[v];"
                  "anoisesrc=c=pink:a=0.03:r=48000:d=16:seed=3[n];[v][n]amix=inputs=2:normalize=0[a]", 16)
    clean = make("speech_clean", "aevalsrc='(0.12*sin(2*PI*140*t)+0.08*sin(2*PI*280*t)+0.05*sin(2*PI*420*t)"
                 "+0.03*sin(2*PI*840*t))*(0.5+0.5*sin(2*PI*5*t))*lt(mod(t\\,1.6)\\,0.9)':s=48000:d=16[a]", 16)
    x = decode(speech, RATE)[:, 0]
    c = decode(clean, RATE)[:, 0]
    pauses = np.concatenate([np.arange(int((k * 1.6 + 0.95) * RATE), int((k * 1.6 + 1.55) * RATE))
                             for k in range(1, 9)])
    voiced = np.concatenate([np.arange(int((k * 1.6 + 0.1) * RATE), int((k * 1.6 + 0.8) * RATE))
                             for k in range(1, 9)])
    print("== DeepFilterNet (deep-filter 0.5.6, -D) ==")
    print(f"  input: pause {rms_db(x[pauses]):.1f} dB, voiced {rms_db(x[voiced]):.1f} dB, "
          f"SNR in voiced {rms_db(c[voiced]) - rms_db((x - c)[voiced]):.1f} dB")
    for atten in (100, 30, 15):
        out_dir = os.path.join(WORK, "q_dfn")
        shutil.rmtree(out_dir, ignore_errors=True)
        t = time.time()
        subprocess.run([DEEP_FILTER, "-D", "-a", str(atten), "-o", out_dir, speech],
                       check=True, capture_output=True)
        secs = time.time() - t
        y = decode(os.path.join(out_dir, os.path.basename(speech)), RATE)[:, 0]
        y = np.pad(y, (0, len(x) - len(y)))
        err = y - c
        print(f"  -a {atten:3d}: pause {rms_db(x[pauses]) - rms_db(y[pauses]):5.1f} dB down, "
              f"voiced {rms_db(y[voiced]) - rms_db(x[voiced]):+5.1f} dB, "
              f"SNR in voiced {rms_db(c[voiced]) - rms_db(err[voiced]):5.1f} dB, "
              f"lag {lag_samples(c, y, 4800)} samples, {secs / 16 * 60:5.1f} s per minute (mono)")


if __name__ == "__main__":
    main()
