#!/usr/bin/env python3
"""Promote a tested deps release candidate to its final version.

A deps release is published as the exact bundles CI and the nightly tested
on the release candidate, with only the version changed: each file name, each
zip's version.json, each v2 delta's baseSha256 (re-pointed at the re-stamped
bundle, since the app checks it against the bundle zip it downloaded) and the
.sha256.json sidecars. Every other entry is copied with the same name,
contents (CRC), size, permissions, timestamp and compression method, and that
is verified afterwards, along with each candidate sidecar against its zip and
each candidate delta against its candidate bundle.

    gh release download deps-vX.Y.Z-rcN -D rc
    python3 -I Scripts/promote-deps-rc.py rc final X.Y.Z-rcN X.Y.Z
    gh release create deps-vX.Y.Z --latest=false ...   # never Latest
    gh release upload deps-vX.Y.Z final/*

The zips come out a little smaller than the candidate's (Python recompresses
each entry); the files inside are identical.
"""
import hashlib
import json
import os
import sys
import zipfile

src, out, old, new = sys.argv[1:5]
os.makedirs(out, exist_ok=True)


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for b in iter(lambda: f.read(1 << 22), b''):
            h.update(b)
    return h.hexdigest()


def restamp(name, base_sha=None):
    old_zip = os.path.join(src, name)
    new_name = name.replace(f'-{old}-', f'-{new}-')
    new_zip = os.path.join(out, new_name)
    with zipfile.ZipFile(old_zip) as zin, zipfile.ZipFile(new_zip, 'w', allowZip64=True) as zout:
        seen = 0
        for info in zin.infolist():
            data = zin.read(info)
            if info.filename == 'version.json':
                seen += 1
                v = json.loads(data)
                assert v['version'] == old, v
                v['version'] = new
                if base_sha is not None:
                    assert 'baseSha256' in v, v
                    v['baseSha256'] = base_sha
                else:
                    assert 'baseSha256' not in v, v
                data = (json.dumps(v, indent=2) + '\n').encode()
            out_info = zipfile.ZipInfo(info.filename, info.date_time)
            for attr in ('compress_type', 'external_attr', 'create_system', 'create_version',
                         'extract_version', 'internal_attr', 'comment', 'extra'):
                setattr(out_info, attr, getattr(info, attr))
            with zout.open(out_info, 'w', force_zip64=len(data) > 0x7fffffff) as w:
                w.write(data)
            # zipfile gives a 0 attribute 0600 when writing the local header;
            # the central directory (written at close) is what readers use, so
            # put the original back there.
            out_info.external_attr = info.external_attr
        assert seen == 1, f'{name}: {seen} version.json entries'

    # Verify: same entries, same contents/attributes, except version.json.
    with zipfile.ZipFile(old_zip) as a, zipfile.ZipFile(new_zip) as b:
        ia, ib = a.infolist(), b.infolist()
        assert [i.filename for i in ia] == [i.filename for i in ib], name
        for x, y in zip(ia, ib):
            if x.filename == 'version.json':
                continue
            for attr in ('CRC', 'file_size', 'external_attr', 'date_time', 'compress_type', 'create_system'):
                assert getattr(x, attr) == getattr(y, attr), (name, x.filename, attr)
        assert b.testzip() is None, name

    digest = sha256(new_zip)
    side = json.load(open(old_zip + '.sha256.json'))
    assert side['filename'] == name and side['version'] == old, side
    assert side['sha256'] == sha256(old_zip), f'{name}: rc sidecar does not match its zip'
    side.update(filename=new_name, sha256=digest, size=os.path.getsize(new_zip), version=new)
    if base_sha is not None:
        side['baseSha256'] = base_sha
    with open(new_zip + '.sha256.json', 'w') as f:
        f.write(json.dumps(side, indent=2) + '\n')
    print(f'{new_name}  {digest}  {side["size"]}')
    return digest


zips = sorted(n for n in os.listdir(src) if n.endswith('.zip'))
bundles = [n for n in zips if not n.endswith('-v2-delta.zip')]
deltas = [n for n in zips if n.endswith('-v2-delta.zip')]
assert len(bundles) == 5 and len(deltas) == 3, zips

new_sha = {}
for n in bundles:
    new_sha[n] = restamp(n)
for d in deltas:
    base = d.replace('-v2-delta.zip', '.zip')
    old_side = json.load(open(os.path.join(src, d + '.sha256.json')))
    assert old_side['baseSha256'] == sha256(os.path.join(src, base)), f'{d}: rc delta was not cut against {base}'
    restamp(d, base_sha=new_sha[base])
print('ok: 5 bundles, 3 deltas')
