#!/usr/bin/env python3
"""How far the first audio stream runs ahead of the picture in a file's byte
order: the largest audio DTS less the DTS of the last video packet stored
before it (issue #266). Usage: lead.py <ffprobe> <file>"""
import json
import subprocess
import sys

ffprobe, path = sys.argv[1], sys.argv[2]
j = json.loads(subprocess.check_output([
    ffprobe, '-v', 'error',
    '-show_entries', 'packet=stream_index,pts_time,dts_time,pos',
    '-show_entries', 'stream=index,codec_type', '-of', 'json', path]))
types = {s['index']: s['codec_type'] for s in j['streams']}
packets = sorted((p for p in j['packets'] if 'pos' in p), key=lambda p: int(p['pos']))
last_video, lead = None, float('-inf')
for p in packets:
    t = float(p.get('dts_time') or p.get('pts_time'))
    kind = types[p['stream_index']]
    if kind == 'video':
        last_video = t
    elif kind == 'audio' and last_video is not None:
        lead = max(lead, t - last_video)
print(f'{lead:.2f}')
