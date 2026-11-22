#!/usr/bin/env python3
"""Decode one output many times the way the conformance test does (task #99, B3).

    measure_decode.py --file <out.mp4> --ffmpeg <ffmpeg> --ffprobe <ffprobe>
                      --out <dir> [--runs 500] [--parallel 1] [--hang 60]

Per variant, --runs times: `ffprobe -count_frames` (the test's check 2,
`countFrames`) and the luma decode of check 4 (`events`: rawvideo gray to
stdout, counted in pictures). Variants: FFmpeg's own choice of decoder, the
same with `-threads 1`, and each AV1 decoder this FFmpeg has forced with
`-c:v`. A run still going after --hang seconds is sampled and killed.

Prints, per variant, how many runs counted each number of pictures and how
many hung. The question it answers: does the test's own decode of a good
file ever count one picture short, or block?
"""
import argparse
import collections
import os
import re
import subprocess
from concurrent.futures import ThreadPoolExecutor


def run(cmd, hang):
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        out, err = p.communicate(timeout=hang)
        return p.returncode, out, err, ""
    except subprocess.TimeoutExpired:
        s = subprocess.run(["sample", str(p.pid), "2", "-mayDie"], capture_output=True,
                           text=True, timeout=30).stdout
        p.kill()
        out, err = p.communicate()
        return -9, out, err, s[s.find("Call graph:"):][:20000]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", required=True)
    ap.add_argument("--ffmpeg", required=True)
    ap.add_argument("--ffprobe", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--runs", type=int, default=500)
    ap.add_argument("--parallel", type=int, default=1)
    ap.add_argument("--hang", type=float, default=60)
    o = ap.parse_args()
    os.makedirs(o.out, exist_ok=True)
    f = o.file
    wh = subprocess.run([o.ffprobe, "-v", "error", "-select_streams", "v:0", "-show_entries",
                         "stream=width,height", "-of", "csv=p=0", f],
                        capture_output=True, text=True).stdout.strip().split(",")
    size = int(wh[0]) * int(wh[1])
    decs = subprocess.run([o.ffmpeg, "-hide_banner", "-decoders"], capture_output=True,
                          text=True).stdout
    av1 = [m.group(1) for m in re.finditer(r"^\s*V\S*\s+(\S*av1\S*)\s", decs, re.M)]
    print(f"AV1 decoders in this ffmpeg: {av1}")
    variants = [("default", []), ("threads1", ["-threads", "1"])]
    variants += [(f"c:v {d}", ["-c:v", d]) for d in av1]

    def probe(extra):
        rc, out, err, hung = run([o.ffprobe, "-v", "error", *extra, "-select_streams", "v:0",
                                  "-count_frames", "-show_entries", "stream=nb_read_frames",
                                  "-of", "csv=p=0", f], o.hang)
        return ("probe", rc, out.decode().strip(), hung, err.decode()[-300:])

    def luma(extra):
        rc, out, err, hung = run([o.ffmpeg, "-v", "error", *extra, "-i", f, "-map", "0:v:0",
                                  "-fps_mode", "passthrough", "-f", "rawvideo", "-pix_fmt",
                                  "gray", "-"], o.hang)
        return ("luma", rc, str(len(out) // size), hung, err.decode()[-300:])

    with open(os.path.join(o.out, "results.tsv"), "w") as tsv:
        tsv.write("variant\tcheck\trc\tpictures\thung\n")
        for name, extra in variants:
            with ThreadPoolExecutor(o.parallel) as ex:
                rows = list(ex.map(lambda _: probe(extra), range(o.runs)))
                rows += list(ex.map(lambda _: luma(extra), range(o.runs)))
            for kind in ("probe", "luma"):
                rs = [r for r in rows if r[0] == kind]
                c = collections.Counter(r[2] for r in rs)
                hung = sum(1 for r in rs if r[3])
                fails = sum(1 for r in rs if r[1] != 0)
                print(f"{name:14} {kind:5}: pictures {dict(c)}; nonzero exit {fails}; hung {hung}")
                for r in rs:
                    tsv.write(f"{name}\t{kind}\t{r[1]}\t{r[2]}\t{bool(r[3])}\n")
                for k, r in enumerate([r for r in rs if r[3] or r[1] != 0][:3]):
                    with open(os.path.join(o.out, f"bad_{name.replace(' ', '_').replace(':', '-')}_{kind}_{k}.txt"),
                              "w") as fh:
                        fh.write(f"rc {r[1]} pictures {r[2]}\n{r[4]}\n{r[3]}")


if __name__ == "__main__":
    main()
