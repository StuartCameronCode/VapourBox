#!/usr/bin/env python3
"""Every number in docs/reports/task-40-av1-svtav1/index.html.

Usage:
    python3 -I measure.py --deps <deps/macos-arm64> [--ffmpeg-x64 <x64 ffmpeg>] \
        [--scratch <dir>] > results.json

--deps        a VapourBox deps bundle (its ffmpeg/ffmpeg and ffprobe are used)
--ffmpeg-x64  optional: another bundle's ffmpeg, for the encoder matrix only
              (the macOS x64 one runs under Rosetta with `arch -x86_64`)
--scratch     where decoded inputs and encodes go (default: $SCRATCH or a
              temp dir); nothing is written into the repo.

Inputs are committed fixtures (Tests/TestResources); no network access.
"""
import argparse
import json
import os
import platform
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
RES = REPO / "Tests" / "TestResources"


def run(cmd, env=None, capture=True):
    e = dict(os.environ)
    e["SVT_LOG"] = "1"  # errors only; the banner is noise here
    if env:
        e.update(env)
    return subprocess.run(cmd, capture_output=capture, text=True, env=e)


def encoders(ffmpeg, prefix=()):
    out = run([*prefix, ffmpeg, "-hide_banner", "-encoders"]).stdout
    names = set()
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0].startswith("V"):
            names.add(parts[1])
    ver = run([*prefix, ffmpeg, "-hide_banner", "-version"]).stdout.splitlines()[0]
    return {
        "version": ver,
        "av1_encoders": sorted(n for n in names if "av1" in n or n == "librav1e"),
        "libsvtav1": "libsvtav1" in names,
    }


def probe(ffprobe, path, entries="codec_name,pix_fmt,codec_tag_string"):
    r = run([ffprobe, "-v", "error", "-select_streams", "v:0", "-show_entries",
             f"stream={entries}", "-of", "json", str(path)])
    s = json.loads(r.stdout or "{}").get("streams") or [{}]
    return s[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--deps", required=True)
    ap.add_argument("--ffmpeg-x64")
    ap.add_argument("--scratch", default=os.environ.get("SCRATCH"))
    a = ap.parse_args()
    ff = str(Path(a.deps) / "ffmpeg" / "ffmpeg")
    fp = str(Path(a.deps) / "ffmpeg" / "ffprobe")
    scratch = Path(a.scratch or tempfile.mkdtemp(prefix="av1-report-"))
    scratch.mkdir(parents=True, exist_ok=True)
    out = {"machine": f"{platform.machine()} {platform.platform()}"}

    # F1: which AV1 encoders each bundled FFmpeg has.
    out["F1_encoders"] = {"bundle": encoders(ff)}
    if a.ffmpeg_x64:
        prefix = ("arch", "-x86_64") if platform.system() == "Darwin" else ()
        out["F1_encoders"]["x64"] = encoders(a.ffmpeg_x64, prefix)
    svt = run([ff, "-hide_banner", "-h", "encoder=libsvtav1"]).stdout
    m = re.search(r"Supported pixel formats: (.*)", svt)
    out["F1_svt_pixel_formats"] = m.group(1).split() if m else None
    lib = run([ff, "-v", "info", "-f", "lavfi", "-i", "testsrc2=s=64x64:d=0.04",
               "-c:v", "libsvtav1", "-f", "null", "-"], env={"SVT_LOG": "3"}).stderr
    m = re.search(r"SVT-AV1 Encoder Lib (v[\d.]+)", lib)
    out["F1_svt_version"] = m.group(1) if m else None

    # F2: containers.
    out["F2_containers"] = {}
    for ext in ["mp4", "mkv", "mov", "avi"]:
        dst = scratch / f"container.{ext}"
        r = run([ff, "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=320x240:r=25:d=1",
                 "-f", "lavfi", "-i", "sine=d=1", "-c:v", "libsvtav1", "-preset", "10",
                 "-crf", "35", "-c:a", "aac", "-shortest", str(dst)])
        out["F2_containers"][ext] = {
            "ok": r.returncode == 0,
            "error": r.stderr.strip().splitlines()[0] if r.returncode else None,
            "stream": probe(fp, dst) if r.returncode == 0 else None,
        }

    # F3: what ffmpeg negotiates unasked for formats libsvtav1 can't take.
    out["F3_negotiation"] = {}
    for pf in ["yuv420p", "yuv420p10le", "yuv422p", "yuv422p10le", "yuv444p", "yuv420p12le"]:
        dst = scratch / f"neg_{pf}.mkv"
        run([ff, "-v", "error", "-y", "-f", "lavfi", "-i",
             f"testsrc2=s=320x240:r=25:d=0.2,format={pf}", "-c:v", "libsvtav1",
             "-preset", "10", str(dst)])
        out["F3_negotiation"][pf] = probe(fp, dst).get("pix_fmt")

    # F4: interlaced 4:2:2 with different chroma per field (top red, bottom
    # blue). Cr row means of the 4:2:0 encode: swscale (-pix_fmt, what ffmpeg
    # does unasked) vs a field-aware conversion (separate, convert, weave —
    # what the script's zimg does with _FieldBased set).
    src = scratch / "field_chroma_422.mkv"
    run([ff, "-v", "error", "-y",
         "-f", "lavfi", "-i", "color=c=red:size=720x288:rate=50:duration=0.4",
         "-f", "lavfi", "-i", "color=c=blue:size=720x288:rate=50:duration=0.4",
         "-filter_complex", "[0:v]format=yuv422p[a];[1:v]format=yuv422p[b];"
         "[a][b]interleave,tinterlace=mode=merge,setfield=tff[v]",
         "-map", "[v]", "-c:v", "ffv1", str(src)])

    def cr_rows(vf):
        dst = scratch / "field_chroma_av1.mkv"
        run([ff, "-v", "error", "-y", "-i", str(src), *(["-vf", vf] if vf else []),
             "-pix_fmt", "yuv420p", "-c:v", "libsvtav1", "-crf", "10", "-preset", "8", str(dst)])
        raw = subprocess.run([ff, "-v", "error", "-i", str(dst), "-frames:v", "1",
                              "-f", "rawvideo", "-pix_fmt", "yuv420p", "-"],
                             capture_output=True).stdout
        w, h, cw, ch = 720, 576, 360, 288
        v = raw[w * h + cw * ch: w * h + 2 * cw * ch]
        rows = range(20, ch - 20, 2)
        even = sum(sum(v[r * cw:(r + 1) * cw]) / cw for r in rows) / len(rows)
        odd = sum(sum(v[(r + 1) * cw:(r + 2) * cw]) / cw for r in rows) / len(rows)
        return {"field0_cr": round(even, 1), "field1_cr": round(odd, 1)}

    out["F4_field_chroma"] = {
        "swscale_pix_fmt": cr_rows(None),
        "field_aware": cr_rows("separatefields,format=yuv420p,weave=first_field=top"),
    }

    # F5: HDR10 metadata through -svtav1-params, read back.
    hdr = scratch / "hdr.mkv"
    params = ("mastering-display=G(0.265,0.69)B(0.15,0.06)R(0.68,0.32)"
              "WP(0.3127,0.329)L(1000,0.0001):content-light=1000,400")
    run([ff, "-v", "error", "-y", "-f", "lavfi", "-i",
         "testsrc2=s=320x240:r=25:d=0.2,format=yuv420p10le", "-c:v", "libsvtav1",
         "-preset", "10", "-svtav1-params", params, "-color_primaries", "bt2020",
         "-color_trc", "smpte2084", "-colorspace", "bt2020nc", str(hdr)])
    sd = run([fp, "-v", "error", "-select_streams", "v", "-read_intervals", "%+#1",
              "-show_frames", "-show_entries", "frame=side_data_list", "-of", "json", str(hdr)])
    frames = json.loads(sd.stdout or "{}").get("frames") or [{}]
    out["F5_hdr"] = {"params": params, "side_data": frames[0].get("side_data_list")}

    # Real content for F6/F7: interlaced_test.avi (720x576 25i VHS capture,
    # 79 frames), deinterlaced with bwdif (single rate) and played forwards
    # then backwards twice (316 frames) so timings aren't dominated by
    # start-up. The 1080p copy is that picture resized with Spline36:
    # speed only — an upscale is unrealistically smooth for quality numbers.
    sd_y4m = scratch / "sd.y4m"
    hd_y4m = scratch / "hd.y4m"
    base = ("bwdif=mode=send_frame,split[a][b];[b]reverse[r];[a][r]concat=n=2:v=1,"
            "split[c][d];[c][d]concat=n=2:v=1,format=yuv420p")
    if not sd_y4m.exists():
        run([ff, "-v", "error", "-y", "-i", str(RES / "interlaced_test.avi"),
             "-filter_complex", base, "-an", str(sd_y4m)])
    if not hd_y4m.exists():
        run([ff, "-v", "error", "-y", "-i", str(sd_y4m),
             "-vf", "scale=1920:1080:flags=spline,setsar=1", str(hd_y4m)])
    frames_n = int(probe(fp, sd_y4m, "nb_frames").get("nb_frames") or 0) or None
    if frames_n is None:
        cnt = run([fp, "-v", "error", "-count_frames", "-select_streams", "v:0",
                   "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", str(sd_y4m)])
        frames_n = int(cnt.stdout.strip())
    out["frames"] = frames_n

    def encode(src, dst, args, n=None, fps=25):
        n = n or frames_n
        t = time.time()
        r = run([ff, "-v", "error", "-y", "-i", str(src), *args, str(dst)])
        dt = time.time() - t
        assert r.returncode == 0, r.stderr
        return {"fps": round(n / dt, 1), "kbps": round(dst.stat().st_size * 8 / 1000 / (n / fps), 1)}

    def vmaf(dist, ref):
        # The score is logged at info level.
        r = run([ff, "-v", "info", "-nostats", "-i", str(dist), "-i", str(ref), "-lavfi",
                 # Align by frame index: PTS-based pairing misaligned the
                 # 29.97 fps clip (min PSNR 14 dB; see the report's correction).
                 "[0:v]settb=1/25,setpts=N[d];[1:v]settb=1/25,setpts=N[r];"
                 "[d][r]libvmaf=n_threads=8", "-f", "null", "-"])
        m = re.search(r"VMAF score: ([\d.]+)", r.stderr)
        return float(m.group(1)) if m else None

    # F6: speed and size per preset, CRF 28.
    out["F6_presets"] = {}
    for label, src in [("sd", sd_y4m), ("1080p", hd_y4m)]:
        rows = {}
        for preset in [2, 4, 6, 8, 10]:
            dst = scratch / f"p{preset}_{label}.mkv"
            rows[preset] = encode(src, dst, ["-c:v", "libsvtav1", "-preset", str(preset), "-crf", "28"])
            if label == "sd":
                rows[preset]["vmaf"] = vmaf(dst, src)
        for name, args in [("x264 medium crf18", ["-c:v", "libx264", "-preset", "medium", "-crf", "18"]),
                           ("x265 medium crf18", ["-c:v", "libx265", "-preset", "medium", "-crf", "18",
                                                  "-x265-params", "log-level=error"])]:
            dst = scratch / f"{name.split()[0]}_{label}.mkv"
            rows[name] = encode(src, dst, args)
            if label == "sd":
                rows[name]["vmaf"] = vmaf(dst, src)
        out["F6_presets"][label] = rows

    # F7: CRF vs VMAF at preset 6, against x264 CRF 18 (VapourBox's default).
    # Two clips: the VHS capture above, and small_clip.mp4 (320x240 29.97
    # camera footage, frames 0-299), which has more fine detail.
    cam_y4m = scratch / "cam.y4m"
    if not cam_y4m.exists():
        run([ff, "-v", "error", "-y", "-i", str(RES / "small_clip.mp4"), "-frames:v", "300",
             "-an", "-pix_fmt", "yuv420p", str(cam_y4m)])
    out["F7_crf"] = {}
    for label, src, n, fps in [("vhs_sd", sd_y4m, frames_n, 25), ("camera_320x240", cam_y4m, 300, 29.97)]:
        rows = {}
        for crf in [16, 20, 24, 28, 32, 36, 40]:
            dst = scratch / f"crf{crf}_{label}.mkv"
            r = encode(src, dst, ["-c:v", "libsvtav1", "-preset", "6", "-crf", str(crf)], n, fps)
            r["vmaf"] = vmaf(dst, src)
            rows[crf] = r
        dst = scratch / f"x264_{label}.mkv"
        r = encode(src, dst, ["-c:v", "libx264", "-preset", "medium", "-crf", "18"], n, fps)
        r["vmaf"] = vmaf(dst, src)
        rows["x264 medium crf18"] = r
        out["F7_crf"][label] = rows

    json.dump(out, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
