#!/usr/bin/env python3
"""Replay one job's encoder ffmpeg many times from its captured Y4M (task #99, B2).

    replay_encoder.py --log <job log> --y4m <vspipe output> --ffmpeg <ffmpeg>
                      --ffprobe <ffprobe> --out <dir> [--runs 300]
                      [--parallel 1] [--mode file|throttled] [--hang 60]

<job log> is the worker's stdout as the conformance test keeps it
(`VAPOURBOX_CONFORMANCE_KEEP`, log.txt): its `Encoder args: [...]` line is the
encoder command (worker/src/pipeline_executor.rs). <y4m> is what vspipe wrote
for that job (capture-vspipe-stdout.sh). Each run feeds the Y4M to the same
command on stdin, either as fast as ffmpeg reads (`file`) or one frame at a
time with a short sleep, as vspipe does under load (`throttled`), and records:
exit status, wall time, the output's video packet count
(`ffprobe -count_packets`) and an MD5 of the video packets
(`-map 0:v -c copy -f md5`). A run still going after --hang seconds is
sampled (macOS `sample`) and killed.

Writes <out>/results.tsv and prints a summary: how many runs wrote each packet
count, how many distinct video hashes there were, and every non-zero exit or
hang. The question it answers: does the encoder alone ever write fewer
packets than frames in, or block?
"""
import argparse
import collections
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor


def encoder_args(log_path):
    for line in open(log_path, encoding="utf-8", errors="replace"):
        line = line.strip()
        msg = line
        try:
            msg = json.loads(line).get("message", "")
        except ValueError:
            pass
        if msg.startswith("Encoder args: "):
            return json.loads(msg[len("Encoder args: "):])
    sys.exit(f"no 'Encoder args:' line in {log_path}")


def y4m_frames(path):
    """The Y4M stream split into its header and its frames (FRAME + payload)."""
    data = open(path, "rb").read()
    head_end = data.index(b"\n") + 1
    head = data[:head_end].decode()
    w = h = None
    cs = "420"
    for tok in head.split()[1:]:
        if tok[0] == "W":
            w = int(tok[1:])
        elif tok[0] == "H":
            h = int(tok[1:])
        elif tok[0] == "C":
            cs = tok[1:]
    depth = 2 if "p1" in cs else 1
    chroma = {"420": 0.5, "422": 1.0, "444": 2.0}.get(cs[:3], 0.5)
    size = int(w * h * (1 + chroma) * depth)
    frames = []
    i = head_end
    while i < len(data):
        nl = data.index(b"\n", i) + 1
        frames.append(data[i:nl + size])
        i = nl + size
    return data[:head_end], frames


def prepare(args, tmp, run_dir):
    """The command for one run: stdin for `-i -`, its own output and progress
    file, and an empty FFMETADATA file where the job's has gone."""
    a = list(args)
    out = os.path.join(run_dir, "out" + os.path.splitext(a[-1])[1])
    a[-1] = out
    for k in range(len(a) - 1):
        if a[k] == "-progress":
            a[k + 1] = os.path.join(run_dir, "progress.txt")
        if a[k] == "-i" and a[k + 1] != "-" and not os.path.exists(a[k + 1]):
            if "vb_metadata_" in a[k + 1]:
                meta = os.path.join(tmp, "metadata.txt")
                with open(meta, "w") as f:
                    f.write(";FFMETADATA1\n")
                a[k + 1] = meta
            else:
                sys.exit(f"input {a[k + 1]} is gone: replay a job whose inputs remain")
    return a, out


def feed(proc, header, frames, mode):
    try:
        proc.stdin.write(header)
        for f in frames:
            proc.stdin.write(f)
            if mode == "throttled":
                proc.stdin.flush()
                time.sleep(0.01)
        proc.stdin.close()
    except BrokenPipeError:
        pass


def sample(pid):
    try:
        r = subprocess.run(["sample", str(pid), "2", "-mayDie"], capture_output=True,
                           text=True, timeout=30)
        return r.stdout[r.stdout.find("Call graph:"):][:20000]
    except Exception as e:  # noqa: BLE001
        return f"(sample failed: {e})"


def one(i, a, ffmpeg, ffprobe, header, frames, mode, out_root, hang, tmp):
    run_dir = os.path.join(out_root, f"run{i:04d}")
    os.makedirs(run_dir, exist_ok=True)
    cmd, out = prepare(a, tmp, run_dir)
    env = dict(os.environ, SVT_LOG="2")
    t0 = time.time()
    proc = subprocess.Popen([ffmpeg] + cmd, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                            stderr=subprocess.PIPE, env=env)
    errbuf = []
    te = threading.Thread(target=lambda: errbuf.append(proc.stderr.read()))
    te.start()
    tf = threading.Thread(target=feed, args=(proc, header, frames, mode))
    tf.start()
    hung = ""
    try:
        rc = proc.wait(timeout=hang)
    except subprocess.TimeoutExpired:
        hung = sample(proc.pid)
        proc.kill()
        rc = proc.wait()
    tf.join()
    te.join()
    wall = time.time() - t0
    packets, md5 = -1, ""
    if os.path.exists(out):
        p = subprocess.run([ffprobe, "-v", "error", "-select_streams", "v:0", "-count_packets",
                            "-show_entries", "stream=nb_read_packets", "-of", "csv=p=0", out],
                           capture_output=True, text=True, timeout=120)
        packets = int(p.stdout.strip() or -1)
        m = subprocess.run([ffmpeg, "-v", "error", "-i", out, "-map", "0:v", "-c", "copy",
                            "-f", "md5", "-"], capture_output=True, text=True, timeout=120)
        md5 = m.stdout.strip().replace("MD5=", "")
    if rc == 0 and not hung and packets == len(frames):
        # Keep only what tells a bad run apart; a good run's output is noise.
        for f in os.listdir(run_dir):
            os.remove(os.path.join(run_dir, f))
        os.rmdir(run_dir)
    else:
        with open(os.path.join(run_dir, "stderr.txt"), "wb") as f:
            f.write(b"".join(errbuf))
        if hung:
            with open(os.path.join(run_dir, "sample.txt"), "w") as f:
                f.write(hung)
    return i, rc, round(wall, 3), packets, md5, bool(hung)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", required=True)
    ap.add_argument("--y4m", required=True)
    ap.add_argument("--ffmpeg", required=True)
    ap.add_argument("--ffprobe", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--runs", type=int, default=300)
    ap.add_argument("--parallel", type=int, default=1)
    ap.add_argument("--mode", choices=["file", "throttled"], default="file")
    ap.add_argument("--hang", type=float, default=60)
    o = ap.parse_args()
    os.makedirs(o.out, exist_ok=True)
    args = encoder_args(o.log)
    header, frames = y4m_frames(o.y4m)
    tmp = tempfile.mkdtemp()
    print(f"encoder: {' '.join(args)}")
    print(f"input: {len(frames)} frames; {o.runs} runs, {o.parallel} at once, {o.mode}")
    rows = []
    with ThreadPoolExecutor(o.parallel) as ex:
        futs = [ex.submit(one, i, args, o.ffmpeg, o.ffprobe, header, frames, o.mode, o.out,
                          o.hang, tmp) for i in range(o.runs)]
        for f in futs:
            rows.append(f.result())
    with open(os.path.join(o.out, "results.tsv"), "w") as f:
        f.write("run\trc\twall_s\tpackets\tmd5\thung\n")
        for r in rows:
            f.write("\t".join(map(str, r)) + "\n")
    counts = collections.Counter(r[3] for r in rows)
    hashes = collections.Counter(r[4] for r in rows if r[3] == len(frames))
    walls = sorted(r[2] for r in rows)
    print(f"packets written: {dict(counts)} (frames in: {len(frames)})")
    print(f"distinct video hashes among full outputs: {len(hashes)} {dict(hashes)}")
    print(f"wall s: min {walls[0]} median {walls[len(walls) // 2]} max {walls[-1]}")
    bad = [r for r in rows if r[1] != 0 or r[5] or r[3] != len(frames)]
    print(f"bad runs: {len(bad)} of {len(rows)}")
    for r in bad[:20]:
        print(f"  run {r[0]}: rc {r[1]} packets {r[3]} hung {r[5]} wall {r[2]}")


if __name__ == "__main__":
    main()
