import time, sys, vapoursynth as vs
core = vs.core
bits = int(sys.argv[1])
c = core.std.BlankClip(width=720, height=480, format=vs.YUV422P8, length=600, color=[128, 120, 136])
c = core.grain.Add(c, var=20, uvar=20, constant=False)
if bits != 8:
    c = core.resize.Point(c, format=vs.YUV422P16 if bits == 16 else vs.YUV422P10)
base = c
o = core.bifrost.Bifrost(c, interlaced=True)
for name, clip in (('source', base), ('bifrost', o)):
    t = time.perf_counter()
    for f in clip.frames(): pass
    print('%s %d-bit: %.0f fps' % (name, bits, 600 / (time.perf_counter() - t)))
