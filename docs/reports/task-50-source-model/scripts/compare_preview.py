import json, subprocess, sys, hashlib, os, uuid
# Usage: compare_preview.py <new-worker> <old-worker> <TestResources dir> <scratch dir>
# old-worker: a build of the commit before task #50 (7c9de94^).
new, old, res, out = sys.argv[1:5]
fixtures = sorted(f for f in os.listdir(res) if f.rsplit('.',1)[-1] in ('mp4','mkv','mov','avi','ts','mpg','vob'))
bad = 0
for f in fixtures:
    path = os.path.join(res, f)
    m = json.loads(subprocess.run([new, '--probe-source', path], capture_output=True, text=True).stdout)
    if 'error' in m: print('PROBE ERROR', f, m); bad += 1; continue
    v = m['video']
    n = v['frameCount']
    frames = sorted({0, 1, 7, 40, max(0, n - 3)} & set(range(n)))
    for fr in frames:
        job = {"id": str(uuid.uuid4()), "inputPath": os.path.abspath(path), "outputPath": "/tmp/x.mkv",
               "qtgmcParameters": {"enabled": False}, "encodingSettings": {},
               "inputFrameRate": v['frameRate'], "inputWidth": v['width'], "inputHeight": v['height'],
               "inputPixelFormat": v['pixelFormat'], "totalFrames": n, "inputSar": v['sar'],
               "inputColorMatrix": v['colorMatrix'], "inputColorPrimaries": v['colorPrimaries'],
               "inputColorTransfer": v['colorTransfer'], "inputColorRange": v['colorRange']}
        cfg = os.path.join(out, 'job.json'); json.dump(job, open(cfg, 'w'))
        r = {}
        for name, exe in (('old', old), ('new', new)):
            p = subprocess.run([exe, '--preview', '--frame', str(fr), '--config', cfg], capture_output=True)
            err = p.stderr.decode('utf-8', 'replace')
            line = next((l for l in err.splitlines() if l.startswith('Preview: source frame') and 'window' in l), '')
            r[name] = (p.returncode, hashlib.md5(p.stdout).hexdigest(), line)
        same = r['old'] == r['new']
        if not same: bad += 1
        print(('OK  ' if same else 'DIFF'), f, fr, '' if same else f"\n   old={r['old']}\n   new={r['new']}")
print('differences:', bad)
