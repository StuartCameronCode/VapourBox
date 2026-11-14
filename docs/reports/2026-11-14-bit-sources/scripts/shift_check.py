"""Is the decoder's 14 -> 16-bit conversion lossless?

    python3 shift_check.py <frame_14.raw> <frame_16.raw> <label>

Both files are the same frame decoded by ffmpeg as yuv444p14le and as
yuv444p16le. Prints how many samples are an exact `x << 2`, how many keep the
14-bit value in their top 14 bits (`y >> 2 == x`: the conversion loses
nothing), and the largest distance from the ideal full-range scaling
x * 65535 / 16383, in 16-bit units.
"""
import struct
import sys

a = open(sys.argv[1], 'rb').read()
b = open(sys.argv[2], 'rb').read()
assert len(a) == len(b), (len(a), len(b))
n = len(a) // 2
v14 = struct.unpack(f'<{n}H', a)
v16 = struct.unpack(f'<{n}H', b)
shift = sum(1 for x, y in zip(v14, v16) if y == x << 2)
kept = sum(1 for x, y in zip(v14, v16) if y >> 2 == x)
err = max(abs(y - x * 65535 / 16383) for x, y in zip(v14, v16))
print(f'{sys.argv[3]}: {n} samples (14-bit range {min(v14)}..{max(v14)}); '
      f'exact x<<2: {shift}; y>>2 == x: {kept}; '
      f'max distance from x*65535/16383: {err:.2f}')
