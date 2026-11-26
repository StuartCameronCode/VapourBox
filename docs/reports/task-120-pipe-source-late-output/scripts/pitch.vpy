import sys, os
import vapoursynth as vs
core = vs.core
sys.path.insert(0, os.environ['VB_TEMPLATES'])
import pipe_source as ps
from stabilize import weave, correct_pitch
clip = ps.create_pipe_clip(720, 480, 50, 30000, 1001, 'yuv444p16le', cache_frames=66)
clip = weave(clip, dxmax=4, dymax=4, mirror=0)
clip = correct_pitch(clip, mode='auto', radius=10)
clip = clip[25]
clip.set_output()
