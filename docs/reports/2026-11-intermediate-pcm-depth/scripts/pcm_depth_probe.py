"""How much a 16-bit restored track loses against the 32-bit float render,
next to 24-bit, for audio like a VHS or DV capture's (F1, F2), and what each
muxer writes (F3). Prints JSON lines; run.sh collects them.

The float render is the worker's own: `vapourbox-worker --audio-plan` prints
every ffmpeg / DeepFilterNet argument list for a job, and this script runs
them in order exactly as `AudioRestorer::render` does. The one argument list
it cannot print is the finish run's with loudness measured (it depends on the
measurement), so the loudnorm stage is inserted here in the same format as
`AudioPlan::finish_filter_chain`.
"""
import json
import os
import uuid
import shutil
import subprocess
import sys

import numpy as np

FF = os.environ["FFMPEG"]
FP = os.environ.get("FFPROBE", os.path.join(os.path.dirname(FF), "ffprobe"))
WORKER = os.environ["WORKER"]
DFN = os.environ.get("DEEP_FILTER")
SPEECH = os.environ["SPEECH"]
W = os.environ["WORK"]
os.makedirs(W, exist_ok=True)

SECS = 64           # 4 x (10 s speech + 3 s gap), then a 6 s fade (from 56 s) and 2 s of tail
GAPS = [(13 * k + 10.4, 13 * k + 12.6) for k in range(4)]   # inside each gap, clear of the edges
TAIL = (60.0, 64.0)                                          # the end of the fade


def run(cmd, cwd=None):
    p = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd)
    if p.returncode:
        sys.exit(f"{cmd[0]} failed ({p.returncode}):\n{(p.stderr or p.stdout)[-3000:]}")
    return p


def ff(*a, cwd=None):
    return run([FF, "-hide_banner", "-nostdin", "-nostats", "-y", *a], cwd=cwd).stderr


def decode(path, fmt="f32le"):
    """The first audio stream as stored (stereo, its own rate), no conversion
    beyond the sample format."""
    raw = subprocess.run([FF, "-v", "error", "-i", path, "-map", "0:a:0", "-f", fmt, "-"],
                         capture_output=True, check=True).stdout
    dt = {"f32le": np.float32, "s32le": np.int32}[fmt]
    return np.frombuffer(raw, dt).reshape(-1, 2)


def db(x):
    x = np.asarray(x, np.float64)
    return 20 * np.log10(max(float(np.sqrt(np.mean(np.square(x)))), 1e-30))


def corr(a, b):
    a, b = np.ravel(a), np.ravel(b)
    return round(float(np.corrcoef(a, b)[0, 1]), 4) if np.std(a) > 0 and np.std(b) > 0 else 0.0


def mask(n, rate, spans):
    m = np.zeros(n, bool)
    for a, b in spans:
        m[int(a * rate): int(b * rate)] = True
    return m


def pink(n, rng):
    """Pink-ish noise (Voss-McCartney with 16 rows), unit RMS."""
    rows = 16
    out = np.zeros(n)
    for r in range(rows):
        step = 1 << r
        v = rng.standard_normal(n // step + 2)
        out += np.repeat(v, step)[:n]
    return out / np.sqrt(np.mean(out ** 2))


# --- fixtures -----------------------------------------------------------------
# Speech: small_clip.mp4's 5-19 s (committed fixture), tiled into four 10 s
# blocks with 3 s gaps and a fifth block that fades out, at SPEECH_DBFS. Noise:
# the medium's hiss at its typical distance below the programme: linear VHS
# ~40 dB, Hi-Fi ~60 (the format claims more; capture electronics add their
# own), DV 16-bit ~66 (mic and camera preamp, then 16-bit), DV 12-bit ~48
# (12-bit quantisation alone is ~50 below). Stored as each medium stores it:
# VHS captures as 24-bit, DV as 16-bit or 12-bit-in-16.
SPEECH_DBFS = -24.0
MEDIA = {
    "vhs_linear": dict(rate=48000, noise="pink", level=-64.0, bits=24),
    "vhs_hifi": dict(rate=48000, noise="pink", level=-84.0, bits=24),
    "dv_16bit_48k": dict(rate=48000, noise="white", level=-90.0, bits=16),
    "dv_12bit_32k": dict(rate=32000, noise="white", level=-72.0, bits=12),
}


def fixture(name, spec):
    rate = spec["rate"]
    out = os.path.join(W, f"{name}.mkv")
    if os.path.exists(out):
        return out
    # small_clip.mp4 holds speech from 5 to 19 s and mostly music after it;
    # DeepFilterNet removes music, so only the speech is used, tiled.
    raw = subprocess.run([FF, "-v", "error", "-ss", "5", "-t", "14", "-i", SPEECH, "-vn", "-ac", "2",
                          "-ar", str(rate), "-f", "f32le", "-"], capture_output=True, check=True).stdout
    sp = np.frombuffer(raw, np.float32).reshape(-1, 2).astype(np.float64)
    # A capture's speech at -24 dBFS RMS over the voiced 50 ms windows (peaks
    # come out around -6), the level the hiss levels below are relative to.
    win = sp[: len(sp) // 2400 * 2400].reshape(-1, 2400, 2)
    wr = np.sqrt(np.mean(win ** 2, axis=(1, 2)))
    voiced = wr > np.percentile(wr, 30)
    sp *= 10 ** (SPEECH_DBFS / 20) / np.sqrt(np.mean(win[voiced] ** 2))
    n = SECS * rate
    s = np.zeros((n, 2))
    blocks = [(13 * k, (k % 2) * 4) for k in range(4)] + [(52, 0)]   # (where, offset into the speech)
    for at, off in blocks:
        seg = sp[off * rate: (off + 10) * rate]
        s[at * rate: at * rate + len(seg)] = seg[: n - at * rate]
    t = np.arange(n) / rate
    # The last block fades out over 56-62 s.
    fade = np.clip((62 - t) / 6, 0, 1) ** 2
    fade[t < 56] = 1
    s *= fade[:, None]
    rng = np.random.default_rng(20261114)
    gen = pink if spec["noise"] == "pink" else (lambda m, r: r.standard_normal(m))
    noise = np.stack([gen(n, rng), gen(n, rng)], axis=1) * 10 ** (spec["level"] / 20)
    x = s + noise
    q = 2.0 ** (spec["bits"] - 1)
    x = np.round(np.clip(x, -1, 1 - 1 / q) * q) / q
    pcm = os.path.join(W, f"{name}.f32")
    x.astype(np.float32).tofile(pcm)
    codec = ["-c:a", "flac", "-sample_fmt", "s16"] if spec["bits"] <= 16 else ["-c:a", "flac", "-sample_fmt", "s32"]
    ff("-f", "lavfi", "-i", f"color=s=160x120:r=25:d={SECS}",
       "-f", "f32le", "-ar", str(rate), "-ac", "2", "-i", pcm,
       "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
       *codec, "-t", str(SECS), out)
    os.remove(pcm)
    return out


# --- the worker's render ------------------------------------------------------
CASES = {
    # The panel's defaults for each step: afftdn 12 dB, loudness -16 LUFS, limiter -1 dB.
    "denoise12": dict(denoise=True, denoiseStrength=12.0, loudnessNormalize=True, limiter=True),
    "denoise40": dict(denoise=True, denoiseStrength=40.0, loudnessNormalize=True, limiter=True),
    "deepfilter": dict(deepFilter=True, deepFilterAttenuation=100, loudnessNormalize=True, limiter=True),
    # Broadcast loudness, no limiter: how often the float render goes over full scale.
    "denoise12_ebu_nolimit": dict(denoise=True, denoiseStrength=12.0, loudnessNormalize=True,
                                  loudnessTarget=-23.0, limiter=False),
}


def num(v):
    s = f"{v:.4f}".rstrip("0").rstrip(".")
    return "0" if s == "-0" else s


def render(src, case, audio):
    d = os.path.join(W, case)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    job = {
        "id": str(uuid.uuid5(uuid.NAMESPACE_URL, case)), "inputPath": src, "outputPath": os.path.join(d, "out.mov"),
        "qtgmcParameters": {"enabled": False},
        "processingPipeline": {"deinterlace": {"enabled": False}, "audio": {"enabled": True, **audio}},
        "encodingSettings": {"container": "mov", "codec": "prores_ks -profile:v 0", "audioMode": "passthrough"},
        "inputFrameRate": 25.0, "inputWidth": 160, "inputHeight": 120, "inputPixelFormat": "yuv420p",
    }
    cfg = os.path.join(d, "job.json")
    json.dump(job, open(cfg, "w"))
    plan = json.loads(run([WORKER, "--audio-plan", "--config", cfg]).stdout.strip().splitlines()[-1])
    assert plan["active"], plan
    ff(*plan["restore"][4:], cwd=d)        # restore_args begin with the four quiet flags ff() adds
    current = "restored.wav" if plan["finish"] is None else "restore.wav"
    if plan["deepFilter"]:
        run([DFN, *plan["deepFilter"]], cwd=d)
        current = os.path.join("dfn", current)
    if plan["finish"] is not None:
        finish = list(plan["finish"][4:])
        finish[finish.index("-i") + 1] = current
        if plan["measure"]:
            measure = list(plan["measure"][4:])
            measure[measure.index("-i") + 1] = current
            err = ff(*measure, cwd=d)
            m = json.loads(err[err.rfind("{", 0, err.rfind('"input_i"')): err.find("}", err.rfind('"input_i"')) + 1])
            target = audio.get("loudnessTarget", -16.0)
            ln = (f"loudnorm=I={num(target)}:TP=-1.5:LRA=11:measured_I={num(float(m['input_i']))}:"
                  f"measured_TP={num(float(m['input_tp']))}:measured_LRA={num(float(m['input_lra']))}:"
                  f"measured_thresh={num(float(m['input_thresh']))}:offset={num(float(m['target_offset']))}:"
                  "linear=true:print_format=summary")
            k = finish.index("-af") + 1
            finish[k] = ln + "," + finish[k]
        ff(*finish, cwd=d)
    return os.path.join(d, "restored.wav"), plan["outRate"]


# --- measurement ----------------------------------------------------------------
VARIANTS = {
    "s16": ["-c:a", "pcm_s16le"],                                                  # what the intermediates got before
    "s16_tpdf": ["-af", "aresample=dither_method=triangular", "-c:a", "pcm_s16le"],
    "s24": ["-c:a", "pcm_s24le"],                                                  # what this change writes
}


def measure(name, case, wav, rate):
    ref = decode(wav).astype(np.float64)
    n = len(ref)
    gaps, tail = mask(n, rate, GAPS), mask(n, rate, [TAIL])
    row = {"medium": name, "case": case, "rate": rate,
           "peak_dbfs": round(20 * np.log10(np.max(np.abs(ref))), 2),
           "overs": int(np.sum(np.abs(ref) > 1.0)),
           "gap_floor": round(db(ref[gaps]), 1), "tail_level": round(db(ref[tail]), 1)}
    for label, args in VARIANTS.items():
        mov = os.path.join(os.path.dirname(wav), f"{label}.mov")
        # The encoder's own mux: ProRes beside the track, -c:a:0 as encode_codec_args gives it.
        ff("-f", "lavfi", "-i", f"color=s=64x64:r=25:d={SECS}", "-i", wav, "-map", "0:v", "-map", "1:a",
           "-c:v", "prores_ks", "-profile:v", "0", *args, "-shortest", mov)
        y = decode(mov).astype(np.float64)[:n]
        e = y - ref[: len(y)]
        nz = ref[: len(y)] != 0

        def zeroed(span):
            """Non-zero float samples in span that came out exactly zero."""
            sel = span[: len(y), None] & nz
            return round(float(np.mean(y[sel] == 0)), 4) if np.any(sel) else 0.0

        row[label] = {
            "err": round(db(e), 1),
            "gap_err": round(db(e[gaps[: len(y)]]), 1),
            "tail_err": round(db(e[tail[: len(y)]]), 1),
            "gap_zeroed": zeroed(gaps),
            "tail_zeroed": zeroed(tail),
            # error correlated with the signal is distortion, not noise
            "corr": corr(ref[: len(y)], e),
            "gap_corr": corr(ref[: len(y)][gaps[: len(y)]], e[gaps[: len(y)]]),
        }
    print(json.dumps(row), flush=True)
    return row


def muxers(wav, rate):
    """F3: what pcm_s24le becomes in each container, and that it is the same
    samples as the FLAC a restored track gets in MKV."""
    d = os.path.join(W, "mux")
    os.makedirs(d, exist_ok=True)
    out = {}
    for name, vc, ext, ac in [("prores_mov", "prores_ks", "mov", "pcm_s24le"), ("v210_mov", "v210", "mov", "pcm_s24le"),
                              ("v210_mkv", "v210", "mkv", "pcm_s24le"), ("v210_avi", "v210", "avi", "pcm_s24le"),
                              ("h264_mkv_flac", "libx264", "mkv", "flac"), ("v210_avi_s24be", "v210", "avi", "pcm_s24be")]:
        f = os.path.join(d, f"{name}.{ext}")
        p = subprocess.run([FF, "-hide_banner", "-nostdin", "-y", "-f", "lavfi", "-i", "color=s=64x64:r=25:d=2",
                            "-t", "2", "-i", wav, "-map", "0:v", "-map", "1:a", "-c:v", vc, "-c:a", ac, "-shortest", f],
                           capture_output=True, text=True)
        if p.returncode:
            lines = [l for l in p.stderr.splitlines() if "Error" in l or "not supported" in l or "Could not" in l]
            out[name] = {"error": (lines or p.stderr.strip().splitlines())[0].strip()}
            continue
        info = json.loads(run([FP, "-v", "error", "-select_streams", "a", "-show_entries",
                               "stream=codec_name,codec_tag_string,sample_fmt,bits_per_sample,bits_per_raw_sample,bit_rate",
                               "-of", "json", f]).stdout)["streams"][0]
        raw = subprocess.run([FF, "-v", "error", "-i", f, "-map", "0:a:0", "-f", "s32le", "-"],
                             capture_output=True, check=True).stdout
        info["s32_md5"] = __import__("hashlib").md5(raw).hexdigest()
        data = open(f, "rb").read()
        if ext == "mov":
            i = data.find(b"in24")
            info["mov_sample_entry"] = data[i - 4: i + 92].hex()
            info["mov_enda_little_endian"] = data.find(b"enda\x00\x01", i) > 0
        if ext == "avi":
            i = data.find(b"auds")
            j = data.find(b"strf", i)
            fmt = data[j + 8: j + 8 + 40]
            tag = int.from_bytes(fmt[0:2], "little")
            info["avi_format_tag"] = hex(tag)
            info["avi_bits"] = int.from_bytes(fmt[14:16], "little")
            if tag == 0xFFFE:
                info["avi_valid_bits"] = int.from_bytes(fmt[18:20], "little")
                info["avi_subformat"] = fmt[24:40].hex()
        if ext == "mkv":
            info["mkv_codec_id"] = "A_PCM/INT/LIT" if b"A_PCM/INT/LIT" in data else ("A_FLAC" if b"A_FLAC" in data else "?")
        out[name] = info
    print(json.dumps({"muxers": out}), flush=True)
    return out


def main():
    rows = []
    for name, spec in MEDIA.items():
        src = fixture(name, spec)
        for case, audio in CASES.items():
            if audio.get("deepFilter") and not DFN:
                continue
            wav, rate = render(src, f"{name}__{case}", audio)
            rows.append(measure(name, case, wav, rate))
    mux = muxers(os.path.join(W, "dv_16bit_48k__denoise12", "restored.wav"), 48000)
    json.dump({"rows": rows, "muxers": mux}, open(os.path.join(W, "pcm_depth.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
