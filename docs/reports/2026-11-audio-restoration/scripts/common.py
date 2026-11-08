"""Shared helpers for the audio restoration probes.

Environment:
  FFMPEG      path to the deps bundle's ffmpeg (default: ffmpeg on PATH)
  DEEP_FILTER path to a deep-filter v0.5.6 binary (optional; DFN probes skip)
  WORK        scratch directory for generated fixtures (required)
"""
import os
import subprocess
import sys

import numpy as np

FFMPEG = os.environ.get("FFMPEG", "ffmpeg")
DEEP_FILTER = os.environ.get("DEEP_FILTER")
WORK = os.environ.get("WORK")
if not WORK:
    sys.exit("set WORK to a scratch directory")
os.makedirs(WORK, exist_ok=True)


def ff(*args):
    """Run ffmpeg quietly; return stderr text."""
    r = subprocess.run([FFMPEG, "-hide_banner", "-nostdin", "-y", *args],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(r.stderr[-2000:])
    return r.stderr


def decode(path, rate, channels=1, af=None):
    """Decode to float32 numpy array (frames, channels)."""
    cmd = [FFMPEG, "-hide_banner", "-nostdin", "-v", "error", "-i", path]
    if af:
        cmd += ["-af", af]
    cmd += ["-ac", str(channels), "-ar", str(rate), "-f", "f32le", "-"]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.float32).reshape(-1, channels)


def lag_samples(ref, sig, max_lag):
    """Lag (samples) of sig relative to ref by cross-correlation; + = sig late."""
    n = min(len(ref), len(sig))
    a = ref[:n] - ref[:n].mean()
    b = sig[:n] - sig[:n].mean()
    size = 1 << int(np.ceil(np.log2(2 * n)))
    c = np.fft.irfft(np.fft.rfft(b, size) * np.conj(np.fft.rfft(a, size)), size)
    lags = np.concatenate([c[: max_lag + 1], c[-max_lag:]])
    idx = np.concatenate([np.arange(0, max_lag + 1), np.arange(-max_lag, 0)])
    return int(idx[np.argmax(lags)])


def band_db(x, rate, f, width=2.0):
    """Energy (dB) in a narrow band around f, from one long FFT."""
    spec = np.abs(np.fft.rfft(x * np.hanning(len(x)))) ** 2
    freqs = np.fft.rfftfreq(len(x), 1.0 / rate)
    sel = (freqs > f - width) & (freqs < f + width)
    return 10 * np.log10(spec[sel].sum() + 1e-30)


def rms_db(x):
    return 20 * np.log10(np.sqrt(np.mean(np.square(x))) + 1e-12)
