"""
VapourBox Pipe Source - reads raw video frames from stdin.

FFmpeg decodes the input file and pipes raw frames here, eliminating
the need for FFMS2 indexing (which blocks on large/NAS files).

Usage in .vpy template:
    from pipe_source import create_pipe_clip
    clip = create_pipe_clip(width, height, num_frames, fps_num, fps_den, pix_fmt)
"""

import vapoursynth as vs
import sys
import os
import ctypes
import threading
from collections import OrderedDict

core = vs.core

# Ensure binary mode on Windows
if sys.platform == 'win32':
    import msvcrt
    msvcrt.setmode(sys.stdin.fileno(), os.O_BINARY)

# FFmpeg pixel format name -> VapourSynth format. Only formats readable
# *directly* off the pipe belong here; anything else is converted by the decoder
# ffmpeg to the nearest format in this map (see `pixel_format.rs`, which is the
# single producer of the name passed to create_pipe_clip and must stay in sync
# with these keys — `test_native_formats_match_pipe_source` asserts that).
#
# Plane geometry and bytes-per-sample are derived from the VapourSynth format
# itself rather than duplicated here, so adding a format is a one-line change.
_FORMAT_MAP = {
    'yuv411p':     vs.YUV411P8,   # NTSC DV / DVCPRO
    'yuv420p':     vs.YUV420P8,
    'yuv422p':     vs.YUV422P8,
    'yuv444p':     vs.YUV444P8,
    'yuv420p9le':  vs.YUV420P9,
    'yuv422p9le':  vs.YUV422P9,
    'yuv444p9le':  vs.YUV444P9,
    'yuv420p10le': vs.YUV420P10,
    'yuv422p10le': vs.YUV422P10,
    'yuv444p10le': vs.YUV444P10,
    'yuv420p12le': vs.YUV420P12,
    'yuv422p12le': vs.YUV422P12,
    'yuv444p12le': vs.YUV444P12,
    'yuv420p14le': vs.YUV420P14,
    'yuv422p14le': vs.YUV422P14,
    'yuv444p14le': vs.YUV444P14,
    'yuv420p16le': vs.YUV420P16,
    'yuv422p16le': vs.YUV422P16,
    'yuv444p16le': vs.YUV444P16,
    # Common aliases
    'yuvj420p':    vs.YUV420P8,   # MJPEG full-range
    'yuvj422p':    vs.YUV422P8,
    'yuvj444p':    vs.YUV444P8,
}


class _PipeReader:
    """Reads raw video frames from stdin with a small cache for temporal filters."""

    def __init__(self, width, height, vs_format):
        self.width = width
        self.height = height

        fmt = core.get_video_format(vs_format)
        bps = fmt.bytes_per_sample  # 1 for 8-bit, 2 for 9..16-bit
        self.bps = bps
        ss_h = 1 << fmt.subsampling_w
        ss_v = 1 << fmt.subsampling_h
        self.plane_sizes = [
            width * height * bps,                            # Y
            (width // ss_h) * (height // ss_v) * bps,       # U
            (width // ss_h) * (height // ss_v) * bps,       # V
        ]
        self.plane_dims = [
            (width, height),
            (width // ss_h, height // ss_v),
            (width // ss_h, height // ss_v),
        ]
        self.frame_size = sum(self.plane_sizes)

        self._pipe = sys.stdin.buffer
        self._cache = OrderedDict()
        self._cache_limit = 40  # enough for QTGMC TR2 + margin
        self._next = 0
        self._lock = threading.Lock()
        self._eof = False
        self._last_frame = None  # last successfully read frame data

    def _read_one(self):
        """Read one frame from stdin. Returns bytes or None on EOF."""
        data = b''
        remaining = self.frame_size
        while remaining > 0:
            chunk = self._pipe.read(remaining)
            if not chunk:
                self._eof = True
                return None
            data += chunk
            remaining -= len(chunk)
        return data

    def _ensure(self, n):
        """Read stdin forward until frame n is cached."""
        if self._eof and n not in self._cache:
            return
        while self._next <= n:
            data = self._read_one()
            if data is None:
                return
            self._last_frame = data
            self._cache[self._next] = data
            self._next += 1
            # Evict old frames
            while len(self._cache) > self._cache_limit:
                self._cache.popitem(last=False)

    def fill_frame(self, n, f):
        """VapourSynth ModifyFrame callback."""
        fout = f.copy()
        with self._lock:
            self._ensure(n)
            data = self._cache.get(n)

        if data is None:
            # EOF: repeat last real frame so VDecimate can identify it as a
            # duplicate and drop it (blank frames would be kept, extending the
            # video duration when TOTAL_FRAMES overshoots the actual count).
            data = self._last_frame
        if data is None:
            return fout  # no frames read at all: return blank

        offset = 0
        for p in range(fout.format.num_planes):
            plane_data = data[offset:offset + self.plane_sizes[p]]
            offset += self.plane_sizes[p]

            pw, ph = self.plane_dims[p]
            row_bytes = pw * self.bps
            stride = fout.get_stride(p)
            # get_write_ptr returns c_void_p (newer VS) or raw bytes (VS R73/Py3.8)
            raw_ptr = fout.get_write_ptr(p)
            if isinstance(raw_ptr, bytes):
                dst = int.from_bytes(raw_ptr, byteorder='little')
            elif isinstance(raw_ptr, int):
                dst = raw_ptr
            else:
                dst = raw_ptr.value if raw_ptr.value is not None else 0

            if stride == row_bytes:
                # No padding — bulk copy
                ctypes.memmove(dst, plane_data, self.plane_sizes[p])
            else:
                # Row-by-row copy to handle stride padding
                for row in range(ph):
                    ctypes.memmove(
                        dst + row * stride,
                        (ctypes.c_char * row_bytes).from_buffer_copy(
                            plane_data, row * row_bytes),
                        row_bytes
                    )
        return fout


def create_pipe_clip(width, height, num_frames, fps_num, fps_den, pix_fmt):
    """
    Create a VapourSynth clip that reads raw frames from stdin.

    Args:
        width: Frame width in pixels
        height: Frame height in pixels
        num_frames: Total number of frames
        fps_num: FPS numerator
        fps_den: FPS denominator
        pix_fmt: FFmpeg pixel format string (e.g. 'yuv420p')

    Returns:
        vs.VideoNode backed by stdin pipe
    """
    if pix_fmt not in _FORMAT_MAP:
        raise ValueError(f"Unsupported pixel format: {pix_fmt}. "
                         f"Supported: {', '.join(_FORMAT_MAP.keys())}")

    vs_format = _FORMAT_MAP[pix_fmt]
    reader = _PipeReader(width, height, vs_format)

    blank = core.std.BlankClip(
        width=width, height=height,
        format=vs_format, length=num_frames,
        fpsnum=fps_num, fpsden=fps_den,
    )

    return core.std.ModifyFrame(clip=blank, clips=[blank], selector=reader.fill_frame)
