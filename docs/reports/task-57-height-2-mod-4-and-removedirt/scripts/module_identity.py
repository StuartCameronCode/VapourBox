"""srestore and stabilize.weave are fixed inside their modules (task #57):
srestore takes the luma before its 8-bit conversion, weave makes its 16-bit
measurement copy without _FieldBased. Both must give the samples they gave
before wherever they ran before. This hashes srestore's per-frame
measurements (every frame property of stats_clip) and weave's measurement copy
with the modules before (OLD_TEMPLATES) and after, at heights that ran before.

weave's own output is not compared: Depan's estimate on a picture without
global motion is a near-tie that varies with threading (CLAUDE.md, Stabilize),
so its output differs between two runs of the same module.
"""
import hashlib
import importlib.util
import json
import os

import vapoursynth as vs

from common import TEMPLATES, clip

core = vs.core
OLD = os.environ['OLD_TEMPLATES']


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(path, name.split('_', 1)[1] + '.py'))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def props_hash(c):
    m = hashlib.md5()
    for f in c.frames():
        m.update(json.dumps({k: v for k, v in sorted(f.props.items()) if not k.startswith('_')},
                            default=str).encode())
    return m.hexdigest()[:12]


def frames_hash(c):
    m = hashlib.md5()
    for f in c.frames():
        for p in range(f.format.num_planes):
            m.update(bytes(f[p]))
    return m.hexdigest()[:12]


def weave_copy(mod_path, c):
    """The 16-bit copy weave() measures on, cut out of the module's source."""
    src = open(os.path.join(mod_path, 'stabilize.py')).read()
    i = src.index('        deep = ')
    j = src.index('        measured = ', i)
    body = '\n'.join(l[8:] for l in src[i:j].splitlines())
    scope = {'core': core, 'vs': vs, 'clip': c, 'fmt': c.format}
    exec(body, scope)  # noqa: S102 -- the module's own lines
    return scope['deep']


rows = []
for ss in ('420', '422', '444'):
    for bits in (8, 10, 16):
        for field in (0, 2):
            for (w, h) in ((352, 240), (720, 480), (720, 486)):
                c = clip(ss, bits, field, w, h)
                row = {'cell': '%sp%d/f%d/%dx%d' % (ss, bits, field, w, h)}
                for side, path in (('old', OLD), ('new', TEMPLATES)):
                    try:
                        row['srestore_' + side] = props_hash(load(path, side + '_srestore').stats_clip(c))
                    except Exception as e:  # noqa: BLE001
                        row['srestore_' + side] = 'refused: ' + str(e).splitlines()[0][:60]
                    if bits != 16:
                        try:
                            row['weave_' + side] = frames_hash(weave_copy(path, c))
                        except Exception as e:  # noqa: BLE001
                            row['weave_' + side] = 'refused: ' + str(e).splitlines()[0][:60]
                rows.append(row)
                print(row, flush=True)
print(json.dumps(rows))
