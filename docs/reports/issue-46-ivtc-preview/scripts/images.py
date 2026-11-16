"""The report's images, from the two measure.py runs' scratch directories
(each keeps its previews as <case>_<target>_<sub>.png and its encodes as
<case>.mkv).

  python3 images.py --before-work DIR --after-work DIR

Each image is four panels at half size, left to right: the source slot (an
independent decode), the old preview, the new preview, and the encode's frame
for that slot. Written to ../img/.
"""
import os
import sys

from measure import FF, RES, ff

HERE = os.path.dirname(os.path.abspath(__file__))
IMG = os.path.join(HERE, '..', 'img')

SHOTS = [
    # name, fixture, case, target, sub, encode frame
    ('01-ivtc-radius12-source45.png', 'hard_telecine_test.avi', 'ivtc_r12', 45, 0, 36),
    ('02-soft-telecine-source62.png', 'soft_telecine_dvd.vob', 'soft_vob_r5', 62, 0, 50),
    ('03-ivtc-5994-source44-output1.png', 'hard_telecine_test.avi', 'ivtc_fps5994', 44, 1, 89),
]


def main():
    a = sys.argv[1:]
    before, after = a[a.index('--before-work') + 1], a[a.index('--after-work') + 1]
    os.makedirs(IMG, exist_ok=True)
    for name, fixture, case, t, k, enc in SHOTS:
        src = os.path.join(RES, fixture)
        slot_vf = 'setpts=PTS-STARTPTS,fps=30000/1001,' if fixture.endswith('.vob') else ''
        inputs = ['-i', src,
                  '-i', os.path.join(before, f'{case}_{t}_{k}.png'),
                  '-i', os.path.join(after, f'{case}_{t}_{k}.png'),
                  '-i', os.path.join(after, f'{case}.mkv')]
        half = 'scale=iw/2:ih/2:flags=area,format=rgb24'
        graph = (f'[0:v]{slot_vf}select=eq(n\\,{t}),{half}[s];'
                 f'[1:v]{half}[b];[2:v]{half}[a];'
                 f'[3:v]select=eq(n\\,{enc}),{half}[e];'
                 '[s][b][a][e]hstack=inputs=4')
        ff([*inputs, '-filter_complex', graph, '-frames:v', '1', os.path.join(IMG, name)])
        print('wrote', name)


if __name__ == '__main__':
    main()
