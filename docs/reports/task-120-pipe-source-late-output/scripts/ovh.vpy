import os, sys
import vapoursynth as vs
core = vs.core
sys.path.insert(0, os.environ['VB_TEMPLATES'])
import pipe_source
clip = pipe_source.create_pipe_clip(1920, 1080, 300, 25, 1, 'yuv420p', cache_frames=40)
if os.environ.get('VB_TRACK') == '1':
    clip = pipe_source.track_output(clip)
clip.set_output()
