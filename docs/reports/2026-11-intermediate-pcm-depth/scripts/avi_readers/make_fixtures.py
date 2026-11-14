#!/usr/bin/env python3
"""Fixtures for the AVI reader probe (F6 of ../../index.html).

Writes, into $WORK/avi:
  ffv1_s24.avi, huffyuv_s24.avi, h264_s24.avi   24-bit PCM, as the worker would
                                                 mux a restored track beside them
  ffv1_s16.avi                                   the same audio at 16 bits: the control
  <name>.ref.raw                                 the stored PCM bytes, extracted by ffmpeg
and prints one JSON line per fixture with its audio `strf` header.

The audio is 2.5 s of stereo at 48 kHz: a -60 dBFS tone (440 Hz left, 660 Hz
right, so a channel swap shows) for 1 s, a 1 s exponential fade to -120 dBFS,
then 0.5 s of silence. Below -96 dBFS the 24-bit file holds detail the 16-bit
one cannot, so a reader that quietly truncates to 16 bits fails the comparison.

Env: FFMPEG (the deps bundle's ffmpeg), WORK (scratch directory).
"""
import json
import os
import struct
import subprocess
import sys

FFMPEG = os.environ["FFMPEG"]
OUT = os.path.join(os.environ["WORK"], "avi")
os.makedirs(OUT, exist_ok=True)

ENV = "if(lt(t,1),1,if(lt(t,2),pow(10,-3*(t-1)),0))*0.001"
AUDIO = (f"aevalsrc=exprs='{ENV}*sin(2*PI*440*t)|{ENV}*sin(2*PI*660*t)'"
         ":s=48000:d=2.5:c=stereo")
VIDEO = "testsrc2=s=160x120:r=25:d=2.5"

FIXTURES = [
    ("ffv1_s24", ["-c:v", "ffv1"], "pcm_s24le", "s24le"),
    ("huffyuv_s24", ["-c:v", "huffyuv", "-pix_fmt", "yuv422p"], "pcm_s24le", "s24le"),
    ("h264_s24", ["-c:v", "libx264", "-pix_fmt", "yuv420p"], "pcm_s24le", "s24le"),
    ("ffv1_s16", ["-c:v", "ffv1"], "pcm_s16le", "s16le"),
]


def run(args):
    subprocess.run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", *args], check=True)


def audio_strf(path):
    """The first audio stream's `strf` chunk (WAVEFORMATEX[TENSIBLE]), decoded."""
    data = open(path, "rb").read()
    i = 0
    while True:
        i = data.find(b"strh", i + 1)
        if i < 0:
            return None
        if data[i + 8:i + 12] != b"auds":
            continue
        j = data.find(b"strf", i)
        n = struct.unpack("<I", data[j + 4:j + 8])[0]
        b = data[j + 8:j + 8 + n]
        tag, ch, rate, byte_rate, align, bits = struct.unpack("<HHIIHH", b[:16])
        h = {"bytes": n, "wFormatTag": f"0x{tag:04X}", "nChannels": ch, "nSamplesPerSec": rate,
             "nAvgBytesPerSec": byte_rate, "nBlockAlign": align, "wBitsPerSample": bits}
        if tag == 0xFFFE and n >= 40:
            cb, valid, mask = struct.unpack("<HHI", b[16:24])
            g = b[24:40]
            guid = "%08X-%04X-%04X-%s-%s" % (struct.unpack("<I", g[:4])[0], *struct.unpack("<HH", g[4:8]),
                                             g[8:10].hex().upper(), g[10:16].hex().upper())
            h.update(cbSize=cb, wValidBitsPerSample=valid, dwChannelMask=f"0x{mask:X}", SubFormat=guid)
        return h


for name, vargs, acodec, raw in FIXTURES:
    avi = os.path.join(OUT, name + ".avi")
    run(["-f", "lavfi", "-i", VIDEO, "-f", "lavfi", "-i", AUDIO, "-map", "0:v", "-map", "1:a",
         *vargs, "-c:a", acodec, avi])
    ref = os.path.join(OUT, name + ".ref.raw")
    run(["-i", avi, "-map", "0:a:0", "-c:a", "copy", "-f", raw, ref])
    print(json.dumps({"fixture": name, "codec": acodec, "ref_bytes": os.path.getsize(ref),
                      "strf": audio_strf(avi)}))
    sys.stdout.flush()
