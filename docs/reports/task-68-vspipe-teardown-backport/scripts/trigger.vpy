# Task #68: the cheapest trigger for vspipe R78's teardown race. One frame,
# computed while the script is evaluated, so it is already in the cache when
# vspipe asks for it: the frame callback can run (and count the frame done)
# before vspipe's main thread checks whether every frame is done. Task #46's
# IVTC preview did the same by accident (task #65).
import vapoursynth as vs
core = vs.core
c = core.std.BlankClip(width=64, height=48, format=vs.YUV420P8, length=1)
c.get_frame(0)
c.set_output()
