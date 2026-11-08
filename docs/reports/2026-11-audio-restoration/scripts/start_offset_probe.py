"""Does rendering audio to a separate WAV keep a container's audio start offset?

The encode used to map the source's audio straight into the output, where
the muxer keeps an audio stream that starts later than the video (common in
captures) at its real position. Rendering the restored audio to a WAV loses
timestamps, so the render has to pad that gap itself. This checks which
aresample settings do so, with and without an input seek.
"""
import os
import subprocess

import numpy as np

from common import WORK, FFMPEG, ff, decode

FFPROBE = os.environ.get("FFPROBE", os.path.join(os.path.dirname(FFMPEG), "ffprobe"))


def first_sound(path):
    x = decode(path, 48000)[:, 0]
    idx = np.argmax(np.abs(x) > 0.05)
    return idx / 48000.0, len(x) / 48000.0


def main():
    src = os.path.join(WORK, "late_audio.mkv")
    ff("-f", "lavfi", "-i", "testsrc2=s=320x240:r=25:d=10",
       "-itsoffset", "0.5", "-f", "lavfi", "-i", "sine=f=1000:d=9.5:r=48000",
       "-map", "0", "-map", "1", "-c:v", "libx264", "-c:a", "flac", src)
    print(subprocess.run([FFPROBE, "-v", "error", "-show_entries",
                          "stream=codec_type,start_time:format=start_time",
                          "-of", "compact", src], capture_output=True, text=True).stdout)
    for seek in (None, "2"):
        for af in ("anull", "aresample=first_pts=0", "aresample=async=1:first_pts=0"):
            out = os.path.join(WORK, "late_out.wav")
            args = (["-ss", seek] if seek else []) + ["-i", src, "-map", "0:a",
                                                      "-af", af, "-c:a", "pcm_f32le", out]
            ff(*args)
            onset, dur = first_sound(out)
            print(f"seek={seek!s:4s} af={af:32s} first sound at {onset:.3f}s, length {dur:.3f}s")


if __name__ == "__main__":
    main()
