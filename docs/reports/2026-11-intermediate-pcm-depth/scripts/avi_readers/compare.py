#!/usr/bin/env python3
"""Run every reader over every fixture and compare with ffmpeg (F6 of ../../index.html).

  python compare.py <avi_readers.exe>

Reads $WORK/avi (from make_fixtures.py) and, if present, the WAVs that
virtualdub.ps1 saved in $WORK/vdub. Prints one JSON line per (fixture, reader)
and writes a Markdown table to $GITHUB_STEP_SUMMARY when set.

"exact" means the reader returned exactly the stored samples. A reader that
returns 16 bits from a 24-bit file is compared with the 24-bit samples rounded
and truncated to 16, so a quiet reduction is named rather than called a miss.
Pure Python: the runner needs nothing installed.
"""
import json
import os
import struct
import subprocess
import sys

WORK = os.environ["WORK"]
AVI = os.path.join(WORK, "avi")
VDUB = os.path.join(WORK, "vdub")
LOCAL = os.path.join(WORK, "local")  # vlc_read.sh: other players, any platform
FIXTURES = ["ffv1_s24", "huffyuv_s24", "h264_s24", "ffv1_s16"]
READERS = ["vfw", "acm", "acm_plain24", "dshow", "mf"]


def ints(data, bits):
    if bits == 16:
        return list(struct.unpack("<%dh" % (len(data) // 2), data[: len(data) // 2 * 2]))
    if bits == 24:
        n = len(data) // 3
        return [int.from_bytes(data[3 * i:3 * i + 3], "little", signed=True) for i in range(n)]
    if bits == 32:
        return list(struct.unpack("<%di" % (len(data) // 4), data[: len(data) // 4 * 4]))
    raise ValueError(bits)


def floats(data):
    return list(struct.unpack("<%df" % (len(data) // 4), data[: len(data) // 4 * 4]))


def compare(out, out_bits, ref, ref_bits, out_float=False):
    """Describe `out` (samples at out_bits) against the stored reference."""
    r = ints(ref, ref_bits)
    if out_float:
        o = [round(x * (1 << (ref_bits - 1))) for x in floats(out)]
        out_bits = ref_bits
    else:
        o = ints(out, out_bits)
    res = {"samples": len(o), "ref_samples": len(r)}
    if out_bits > ref_bits:  # a wider container: the stored samples in its top bits
        o = [x >> (out_bits - ref_bits) for x in o]
        out_bits = ref_bits
    if out_bits == ref_bits:
        res["verdict"] = "exact" if o == r else "differs"
    elif ref_bits == 24 and out_bits == 16:
        rounded = [max(-32768, min(32767, (x + 128) >> 8)) for x in r]
        trunc = [x >> 8 for x in r]
        if o == rounded:
            res["verdict"] = "16-bit (rounded)"
        elif o == trunc:
            res["verdict"] = "16-bit (truncated)"
        else:
            n = min(len(o), len(rounded))
            res["verdict"] = "16-bit, differs"
            res["max_abs_diff_vs_rounded"] = max((abs(o[i] - rounded[i]) for i in range(n)), default=None)
    else:
        res["verdict"] = f"{out_bits}-bit from {ref_bits}-bit"
    if res["verdict"] in ("differs", "16-bit, differs"):
        n = min(len(o), len(r))
        rr = r if out_bits == ref_bits else [(x + 128) >> 8 for x in r]
        first = next((i for i in range(n) if o[i] != rr[i]), None)
        res["first_mismatch"] = first
        if first is None and len(o) != len(r):
            res["verdict"] = "exact, but %d samples %s" % (abs(len(o) - len(r)), "short" if len(o) < len(r) else "long")
    return res


def wav(path):
    d = open(path, "rb").read()
    if d[:4] != b"RIFF" or d[8:12] != b"WAVE":
        return None
    i, fmt, data = 12, None, None
    while i + 8 <= len(d):
        cid, n = d[i:i + 4], struct.unpack("<I", d[i + 4:i + 8])[0]
        if cid == b"fmt ":
            fmt = d[i + 8:i + 8 + n]
        elif cid == b"data":
            data = d[i + 8:i + 8 + n]
        i += 8 + n + (n & 1)
    tag, ch, rate, _, _, bits = struct.unpack("<HHIIHH", fmt[:16])
    sub = None
    if tag == 0xFFFE and len(fmt) >= 40:
        sub = struct.unpack("<H", fmt[24:26])[0]
    return {"wFormatTag": f"0x{tag:04X}", "subformat_tag": sub, "channels": ch, "rate": rate, "bits": bits}, data


rows = []
exe = sys.argv[1] if len(sys.argv) > 1 else None
for fx in FIXTURES:
    ref_bits = 16 if fx.endswith("s16") else 24
    ref = open(os.path.join(AVI, fx + ".ref.raw"), "rb").read()
    avi = os.path.join(AVI, fx + ".avi")
    for reader in READERS if exe else []:
        out = os.path.join(AVI, f"{fx}.{reader}.raw")
        if os.path.exists(out):
            os.remove(out)
        p = subprocess.run([exe, reader, avi, out], capture_output=True, text=True, timeout=120)
        line = p.stdout.strip().splitlines()[-1] if p.stdout.strip() else ""
        try:
            got = json.loads(line)
        except ValueError:
            got = {"reader": reader, "ok": False, "note": f"exit {p.returncode}: {p.stderr.strip()[:200]}"}
        row = {"fixture": fx, **got}
        if got.get("ok") and os.path.exists(out):
            data = open(out, "rb").read()
            if reader.startswith("acm"):
                bits = 16
            elif reader == "mf":
                bits = got["format"]["delivered"]["bits"]
            else:
                bits = ref_bits
            row["result"] = compare(data, bits, ref, ref_bits)
        rows.append(row)
    for where, name in [(VDUB, f"{t}_{m}") for t in ("vd1104", "vd2") for m in ("direct", "full")] + [(LOCAL, "vlc")]:
        path = os.path.join(where, f"{name}_{fx}.wav")
        status = os.path.join(where, f"{name}_{fx}.status")
        if not os.path.exists(status):
            continue
        row = {"fixture": fx, "reader": name, "note": open(status).read().strip()}
        w = wav(path) if os.path.exists(path) and os.path.getsize(path) > 44 else None
        row["ok"] = w is not None
        if w:
            h, data = w
            row["format"] = h
            is_float = h["wFormatTag"] == "0x0003" or h["subformat_tag"] == 3
            row["result"] = compare(data, h["bits"], ref, ref_bits, out_float=is_float)
        rows.append(row)

for r in rows:
    print(json.dumps(r))
summary = os.environ.get("GITHUB_STEP_SUMMARY")
if summary:
    with open(summary, "a") as f:
        f.write("| fixture | reader | read | verdict | samples / ref | note |\n|---|---|---|---|---|---|\n")
        for r in rows:
            res = r.get("result", {})
            f.write(f"| {r['fixture']} | {r['reader']} | {'yes' if r.get('ok') else 'no'} | {res.get('verdict', '—')} "
                    f"| {res.get('samples', '—')} / {res.get('ref_samples', '—')} | {r.get('note', '')} |\n")
