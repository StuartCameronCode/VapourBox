#!/usr/bin/env python3
"""Decode a clip's luma to a (frames, h, w) uint8 .npy (ffmpeg on PATH), for
flicker.py's reference rows.

    python luma_npy.py <clip> <out.npy>
"""
import json
import subprocess
import sys

import numpy as np


def main():
    clip, out = sys.argv[1], sys.argv[2]
    info = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                                               "stream=width,height", "-of", "json", clip]))["streams"][0]
    w, h = info["width"], info["height"]
    raw = subprocess.check_output(["ffmpeg", "-v", "error", "-i", clip, "-f", "rawvideo", "-pix_fmt", "gray", "-"])
    np.save(out, np.frombuffer(raw, np.uint8).reshape(-1, h, w))


if __name__ == "__main__":
    main()
