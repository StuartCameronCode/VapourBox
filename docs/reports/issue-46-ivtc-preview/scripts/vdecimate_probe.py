"""What the bundled vivtc.VDecimate decides from (task #46).

Runs itself under the deps bundle's Python (VapourSynth R78 is a Python
package there) on a synthetic clip of flat grey frames, with dryrun=True,
which stamps VDecimateDrop / VDecimateTotalDiff on every frame:

  1. a clip's frame 0 gets a fixed large metric (it is never dropped);
  2. each frame's metric is its difference from the frame before, so a
     cycle's decision reads the frame before the cycle;
  3. cycles count from the clip's first frame, and a short last cycle still
     drops one frame;
  4. a frame property set before VDecimate survives on the frames it keeps
     (the preview tags each frame with its index to read the drop).

  python3 vdecimate_probe.py     (macOS / Linux deps layout)
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

if os.environ.get('_VB_PROBE_INNER') != '1':
    from measure import DEPS
    env = dict(os.environ, _VB_PROBE_INNER='1',
               PYTHONHOME=os.path.join(DEPS, 'python'),
               PYTHONPATH=os.pathsep.join([DEPS, os.path.join(DEPS, 'python-packages')]),
               XDG_CONFIG_HOME=os.path.join(DEPS, 'config'))
    py = os.path.join(DEPS, 'python', 'bin', 'python3')
    sys.exit(subprocess.run([py, __file__], env=env).returncode)

import vapoursynth as vs  # noqa: E402

core = vs.core
LEVELS = [16, 60, 100, 100, 140, 180, 200, 220, 230, 235]


def clip_of(levels):
    return core.std.Splice([core.std.BlankClip(format=vs.YUV420P8, width=64, height=64, length=1,
                                               color=[y, 128, 128]) for y in levels])


def drops(c):
    d = core.vivtc.VDecimate(c, dryrun=True)
    return [(d.get_frame(i).props['VDecimateDrop'], d.get_frame(i).props['VDecimateTotalDiff'])
            for i in range(len(c))]


c = clip_of(LEVELS)
print('levels      ', LEVELS)
print('drop/metric ', drops(c))
print('1. frame 0 metric', drops(c)[0][1], 'is the same for another first frame:', drops(c[3:])[0][1])
# 2: small steps (no scene change); the second cycle [5..9] reads frame 4.
steps = [16, 30, 44, 58, 72, 86, 88, 102, 116, 130]
steps_alt = steps[:4] + [86] + steps[5:]
for name, lv in (('frame 4 = 72', steps), ('frame 4 = 86 (= frame 5)', steps_alt)):
    print(f'2. {name}: second cycle drops', [i for i, (d, _) in enumerate(drops(clip_of(lv))) if d and i >= 5])
# 3: the same frames from index 3: cycles [3..7], [8..9].
print('3. from frame 3: drops at', [i + 3 for i, (d, _) in enumerate(drops(c[3:])) if d],
      '(cycles 3..7 and the short 8..9)')
# 4: a property survives.


def tag(n, f):
    fout = f.copy()
    fout.props['_PreviewSlot'] = n
    return fout


t = core.vivtc.VDecimate(core.std.ModifyFrame(c, c, tag))
print('4. kept frames carry their tag:', [t.get_frame(i).props['_PreviewSlot'] for i in range(len(t))])
