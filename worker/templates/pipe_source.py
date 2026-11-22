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
    # No 9-bit: CTMF has no 9-bit format, and havsfunc's MinBlur(r>=2) calls
    # it, so pixel_format.rs decodes 9-bit sources as 10 (task #31).
    'yuv420p10le': vs.YUV420P10,
    'yuv422p10le': vs.YUV422P10,
    'yuv444p10le': vs.YUV444P10,
    'yuv420p12le': vs.YUV420P12,
    'yuv422p12le': vs.YUV422P12,
    'yuv444p12le': vs.YUV444P12,
    # No 14-bit: fmtconv can't write it, and havsfunc's Bob/Resize/Deblock_QED
    # need to, so pixel_format.rs decodes 14-bit sources as 16 (task #23).
    'yuv420p16le': vs.YUV420P16,
    'yuv422p16le': vs.YUV422P16,
    'yuv444p16le': vs.YUV444P16,
    # Common aliases
    'yuvj420p':    vs.YUV420P8,   # MJPEG full-range
    'yuvj422p':    vs.YUV422P8,
    'yuvj444p':    vs.YUV444P8,
}


# Frames read but not yet served are kept beyond the temporal window, up to
# this much memory (at least _MIN_EXTRA_FRAMES of them). Only frames the
# script never asks for (a decimation, a preview's single frame) fill it.
_EXTRA_BYTES = 512 * 1024 * 1024
_MIN_EXTRA_FRAMES = 16


class _PipeReader:
    """Reads raw video frames from stdin, keeping the frames the script may
    still ask for.

    A pipe can only be read forward, and VapourSynth does not ask for frames
    in order: vspipe requests a new frame whenever any frame completes, so one
    early frame whose callback is late (a busy machine) lets the rest of the
    clip be read past it -- measured: frames 6 and 7 served after frame 99 was
    read (task #58). So a frame is kept until it has been served and is more
    than the temporal window behind the oldest frame not yet served (`_low`),
    not merely the window behind the last frame read. Frames that are never
    asked for pin `_low`; past a memory cap the oldest are dropped anyway.

    A frame asked for after it was dropped raises: it can no longer be read,
    and serving any other picture in its place silently writes the wrong frame
    into the output (which this reader used to do).
    """

    def __init__(self, width, height, vs_format, cache_frames=40,
                 pad_right=0, pad_bottom=0, pad_fields=False):
        self.width = width
        self.height = height

        fmt = core.get_video_format(vs_format)
        bps = fmt.bytes_per_sample  # 1 for 8-bit, 2 for 9..16-bit
        self.bps = bps
        ss_h = 1 << fmt.subsampling_w
        ss_v = 1 << fmt.subsampling_h
        # FFmpeg's rawvideo rounds a chroma plane UP (av_image_get_buffer_size:
        # AV_CEIL_RSHIFT), so a 63x33 4:2:0 frame carries 32x17 chroma samples
        # (task #97). On a frame on its chroma grid this is the plain quotient.
        cw = -(-width // ss_h)
        ch = -(-height // ss_v)
        self.plane_sizes = [
            width * height * bps,                            # Y
            cw * ch * bps,                                   # U
            cw * ch * bps,                                   # V
        ]
        self.plane_dims = [
            (width, height),
            (cw, ch),
            (cw, ch),
        ]
        # A frame off its chroma grid (task #97): VapourSynth can't hold
        # it, so the clip is pad_right / pad_bottom larger. Its chroma is
        # already that size (rounded up, above); luma repeats its last column
        # into the new columns and, for the new rows, its last row, or on an
        # interlaced clip (pad_fields) each field's own last row, the period-2
        # repeat plugin_formats.pad_around uses.
        self.pad_right = int(pad_right)
        self.pad_bottom = int(pad_bottom)
        self.pad_fields = bool(pad_fields)
        if (width + self.pad_right) % ss_h or (height + self.pad_bottom) % ss_v \
                or cw != (width + self.pad_right) // ss_h or ch != (height + self.pad_bottom) // ss_v:
            raise vs.Error(
                f"pipe_source: a {width}x{height} {fmt.name} frame padded by "
                f"{self.pad_right}x{self.pad_bottom} is not on its chroma grid. "
                "This is a VapourBox fault (VideoJob::source_grid_pad).")
        self.frame_size = sum(self.plane_sizes)

        self._pipe = sys.stdin.buffer
        self._cache = OrderedDict()  # frame -> bytes, in frame (= read) order
        self._window = max(40, int(cache_frames))  # >= QTGMC TR2 + margin
        self._cap = self._window + max(
            _MIN_EXTRA_FRAMES, _EXTRA_BYTES // max(1, self.frame_size))
        self._next = 0          # the next frame the pipe will deliver
        self._low = 0           # the lowest frame not yet served
        self._served = set()    # frames >= _low already served
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

    def _advance_low(self):
        while self._low in self._served:
            self._served.discard(self._low)
            self._low += 1

    def _evict(self):
        """Drop served frames behind the window, and the oldest past the cap."""
        while self._cache:
            k = next(iter(self._cache))
            if k < self._low - self._window:
                self._cache.popitem(last=False)
            elif len(self._cache) > self._cap:
                # Never asked for while the reader went this far ahead: given
                # up. Asking for it later raises.
                self._cache.popitem(last=False)
                if k >= self._low:
                    self._low = k + 1
                    self._served = {s for s in self._served if s > k}
                    self._advance_low()
            else:
                break

    def _ensure(self, n):
        """Read stdin forward until frame n is cached (or the pipe ends)."""
        while self._next <= n and not self._eof:
            data = self._read_one()
            if data is None:
                return
            self._last_frame = data
            self._cache[self._next] = data
            self._next += 1
            self._evict()

    def _frame_data(self, n):
        """Frame n's bytes, under the lock. Raises if it was read and dropped."""
        self._ensure(n)
        data = self._cache.get(n)
        if data is None:
            if n < self._next:
                raise vs.Error(
                    f"pipe_source: frame {n} was asked for after it left the "
                    f"cache (read up to frame {self._next - 1}, oldest frame "
                    f"not yet served {self._low}, window {self._window}, cap "
                    f"{self._cap} frames). This is a VapourBox fault: a pass "
                    "reads further back than its declared radius."
                )
            # Past the end of the stream: repeat the last real frame so
            # VDecimate can identify it as a duplicate and drop it (blank
            # frames would be kept, extending the video duration when
            # TOTAL_FRAMES overshoots the actual count).
            data = self._last_frame
        if n >= self._low:
            self._served.add(n)
            self._advance_low()
        return data

    def fill_frame(self, n, f):
        """VapourSynth ModifyFrame callback."""
        fout = f.copy()
        with self._lock:
            data = self._frame_data(n)
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
            if p == 0 and (self.pad_right or self.pad_bottom):
                self._pad_luma(dst, stride, pw, ph)
        return fout

    def _pad_luma(self, dst, stride, pw, ph):
        """Fill the luma pad of a frame off its chroma grid (task #97)."""
        bps = self.bps
        if self.pad_right:
            tail = self.pad_right * bps
            for row in range(ph):
                at = dst + row * stride
                last = ctypes.string_at(at + (pw - 1) * bps, bps)
                ctypes.memmove(at + pw * bps, last * self.pad_right, tail)
        row_bytes = (pw + self.pad_right) * bps
        for row in range(ph, ph + self.pad_bottom):
            src = row - 2 if self.pad_fields and ph >= 2 else ph - 1
            ctypes.memmove(dst + row * stride, dst + src * stride, row_bytes)


def create_pipe_clip(width, height, num_frames, fps_num, fps_den, pix_fmt,
                     cache_frames=40, pad_right=0, pad_bottom=0, pad_fields=False):
    """
    Create a VapourSynth clip that reads raw frames from stdin.

    Args:
        width: Frame width in pixels
        height: Frame height in pixels
        num_frames: Total number of frames
        fps_num: FPS numerator
        fps_den: FPS denominator
        pix_fmt: FFmpeg pixel format string (e.g. 'yuv420p')
        cache_frames: The temporal window: frames kept behind the oldest
            frame not yet served, for passes that read back. Frames read ahead
            and not yet served are kept as well (see _PipeReader). A frame
            asked for after it was dropped raises rather than coming back as
            another picture. The worker sizes it from the pipeline's total
            radius.
        pad_right, pad_bottom: columns and rows that bring a frame stored
            off its chroma grid (a 4:2:0 frame with an odd width or height)
            onto it, since VapourSynth can't hold it at its own size (task
            #97). The clip is that much larger; every stored sample is
            copied as it is, and the pad repeats the last column / row
            (each field's own last row with pad_fields). 0 for every other
            frame. The worker decides (VideoJob::source_grid_pad) and crops
            the pad back in the encoder where it can (VideoJob::grid_output).

    Returns:
        vs.VideoNode backed by stdin pipe
    """
    if pix_fmt not in _FORMAT_MAP:
        raise ValueError(f"Unsupported pixel format: {pix_fmt}. "
                         f"Supported: {', '.join(_FORMAT_MAP.keys())}")

    vs_format = _FORMAT_MAP[pix_fmt]
    reader = _PipeReader(width, height, vs_format, cache_frames,
                         pad_right, pad_bottom, pad_fields)

    blank = core.std.BlankClip(
        width=width + reader.pad_right, height=height + reader.pad_bottom,
        format=vs_format, length=num_frames,
        fpsnum=fps_num, fpsden=fps_den,
    )

    return core.std.ModifyFrame(clip=blank, clips=[blank], selector=reader.fill_frame)
