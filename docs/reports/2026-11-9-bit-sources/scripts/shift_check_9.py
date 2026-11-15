"""Is the decoder's 9 -> 10-bit conversion lossless?

    python3 shift_check_9.py <frame_9.raw> <frame_10.raw> <label>

Both files are the same frame decoded by ffmpeg as yuv444p9le and as
yuv444p10le. Prints how many samples are an exact `x << 1`, how many keep the
9-bit value in their top 9 bits (`y >> 1 == x`: the conversion loses
nothing), and the largest distance from the ideal full-range scaling
x * 1023 / 511, in 10-bit units.
"""
import struct
import sys

a = open(sys.argv[1], 'rb').read()
b = open(sys.argv[2], 'rb').read()
assert len(a) == len(b), (len(a), len(b))
n = len(a) // 2
v9 = struct.unpack(f'<{n}H', a)
v10 = struct.unpack(f'<{n}H', b)
shift = sum(1 for x, y in zip(v9, v10) if y == x << 1)
kept = sum(1 for x, y in zip(v9, v10) if y >> 1 == x)
err = max(abs(y - x * 1023 / 511) for x, y in zip(v9, v10))
print(f'{sys.argv[3]}: {n} samples (9-bit range {min(v9)}..{max(v9)}); '
      f'exact x<<1: {shift}; y>>1 == x: {kept}; '
      f'max distance from x*1023/511: {err:.2f}')
