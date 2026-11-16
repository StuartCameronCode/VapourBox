"""The control is today's code: check today_args against the vector files the
Rust and Dart unit tests already pin to source_decode.rs
(seek_arg_cases.json, source_grid_vectors.json), and its constants and probe
arguments against the Rust source itself (pktlib.pin_constants)."""
import json

import pktlib as L
import today_args as today

L.pin_constants()
n = 0
for c in json.load(open(L.resource('seek_arg_cases.json')))['cases']:
    fps = c['fpsNum'] / c['fpsDen']
    s = today.source_seek(c['frame'], fps, c['videoStart'], c['delay'], None)
    got_ss = today.seek_arg(s['ss']) if s['ss'] is not None else None
    assert got_ss == c['ss'] and s['trim_frames'] == c['trimFrames'], (c, s)
    n += 1
for c in json.load(open(L.resource('source_grid_vectors.json')))['cases']:
    g = today.grid_from_probe(c['probe'], c['jobFps'])
    want = c['grid']
    if want is None:
        assert g is None, (c['name'], g)
    else:
        assert (g['num'], g['den']) == (want['rateNum'], want['rateDen']) and abs(g['origin'] - want['origin']) < 1e-9, (c['name'], g)
    for s in c.get('starts', []):
        p = s.get('plan')
        plan = dict(preroll=p['preroll'], container_start=p['containerStart']) if p else None
        args, filters = today.decode_start(s['frame'], c['jobFps'], s['videoStart'], 0, plan, g)
        ss = args[args.index('-ss') + 1] if '-ss' in args else None
        assert ss == s['ss'] and filters == s['filters'], (c['name'], s, args, filters)
        if 'copyts' in s:
            assert ('-copyts' in args) == s['copyts'], (c['name'], s)
        n += 1
print(f'today_args agrees with source_decode.rs: {n} vector cases, constants and probe arguments pinned')
