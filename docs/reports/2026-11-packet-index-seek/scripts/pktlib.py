"""Shared helpers for the packet-index seek probe (task #51).

Paths come from the repo (found from this file's location) or the
environment, never a personal path:

  VAPOURBOX_DEPS_DIR  deps/<platform> to take ffmpeg/ffprobe from
                      (default: <repo>/deps/<platform>)
  PKTIDX_WORK         scratch directory (default: a fresh temporary one)

Pictures are named by the MD5 of their luma plane (`-pix_fmt gray`), so
"which stored picture came out" is exact. That says nothing about colour.
"""
import hashlib
import json
import math
import os
import platform
import re
import subprocess
import tempfile
from fractions import Fraction

import today_args as today

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..', '..', '..'))
RES = os.path.join(REPO, 'Tests', 'TestResources')
DATA = os.path.join(HERE, '..', 'data')


def _platform_id():
    machine = platform.machine().lower()
    arch = 'arm64' if machine in ('arm64', 'aarch64') else 'x64'
    system = platform.system()
    if system == 'Darwin':
        return f'macos-{arch}'
    if system == 'Windows':
        return 'windows-x64'
    return f'linux-{arch}'


DEPS = os.environ.get('VAPOURBOX_DEPS_DIR') or os.path.join(REPO, 'deps', _platform_id())
EXE = '.exe' if platform.system() == 'Windows' else ''
FF = os.path.join(DEPS, 'ffmpeg', 'ffmpeg' + EXE)
FP = os.path.join(DEPS, 'ffmpeg', 'ffprobe' + EXE)
WORK = os.environ.get('PKTIDX_WORK') or tempfile.mkdtemp(prefix='pktidx_')
os.makedirs(WORK, exist_ok=True)

# Every fixture of the two heavy suites the task names.
SEEK_SUITE = [
    'small_clip.mp4', 'seek_timebase_2997.mov', 'face_restore_test.mp4',
    'seek_dvd_pal.mpg', 'seek_gop_late_video.ts', 'pal-dvbt-fieldcoded-25i.ts',
    'hard_telecine_test.avi', 'avi_h264_bframes.avi', 'avi_ntsc_intra.avi',
    'seek_reset_dvd_pal.mpg', 'seek_reset_h264.ts',
]
GRID_SUITE = [
    'interlaced_test.avi', 'null_frames_mid.avi', 'soft_telecine_test.mkv',
    'soft_telecine_dvd.vob', 'soft_telecine_dvd.mkv',
]
RESET_FIXTURES = ('seek_reset_dvd_pal.mpg', 'seek_reset_h264.ts')


def resource(name):
    return os.path.join(RES, name)


def run(args, **kw):
    return subprocess.run(args, capture_output=True, **kw)


def probe_json(args, path):
    r = run([FP, *args, path], text=True)
    return json.loads(r.stdout) if r.returncode == 0 and r.stdout.strip() else None


def pin_constants():
    """Fail loudly if today_args no longer matches the Rust it copies."""
    src = open(os.path.join(REPO, 'worker', 'src', 'source_decode.rs')).read()
    for name, val in [('GRID_LOOKBACK_SLOTS', today.GRID_LOOKBACK_SLOTS),
                      ('COUNT_SEEK_BELOW', today.COUNT_SEEK_BELOW),
                      ('MAX_DECODER_DELAY', today.MAX_DECODER_DELAY),
                      ('SEEK_PREROLL_MARGIN', today.SEEK_PREROLL_MARGIN),
                      ('SEEK_PREROLL_MIN', today.SEEK_PREROLL_MIN),
                      ('SEEK_PROBE_SECONDS', today.SEEK_PROBE_SECONDS),
                      ('GRID_RATE_TOLERANCE', today.GRID_RATE_TOLERANCE)]:
        m = re.search(rf'pub const {name}: \w+ = ([0-9.]+);', src)
        assert m and float(m.group(1)) == float(val), f'{name} moved: {m and m.group(1)} != {val}'
    for name in ('VIDEO_START_PROBE_ARGS', 'SEEK_PROBE_ARGS', 'DECODER_DELAY_PROBE_ARGS'):
        m = re.search(rf'pub const {name}: \[&str; \d+\] = \[(.*?)\];', src, re.S)
        rust = re.findall(r'"([^"]*)"', m.group(1))
        assert rust == getattr(today, name), f'{name} moved: {rust}'
    assert 'format!("{:.6}", (t * 1e6 - 1e-3).ceil() / 1e6)' in src, 'seek_arg moved'


# ---------------------------------------------------------------- today's info

def source_info(path):
    """What the worker learns about a source before it decodes (main.rs's
    fill_video_start / fill_seek_plan / fill_source_grid), via today_args."""
    s = probe_json(['-v', 'error', '-select_streams', 'v:0', '-show_entries',
                    'stream=width,height,r_frame_rate,avg_frame_rate,has_b_frames,time_base:'
                    'format=format_name,start_time', '-of', 'json'], path)
    st, fmt = s['streams'][0], s['format']
    fr = lambda x: float(Fraction(x)) if x and x != '0/0' else 0.0
    fps = today.select_frame_rate(fr(st['r_frame_rate']), fr(st['avg_frame_rate']))
    vs = probe_json(today.VIDEO_START_PROBE_ARGS, path)
    offset = today.video_start_from_probe(vs)
    delay = 0
    if today.stores_decode_order(vs):
        delay = today.decoder_delay_from_probe(probe_json(today.DECODER_DELAY_PROBE_ARGS, path), offset)
    plan = today.seek_plan_from_probe(probe_json(today.SEEK_PROBE_ARGS, path))
    grid = today.grid_from_probe(vs, fps)
    return dict(path=path, w=st['width'], h=st['height'], fps=fps, offset=offset, delay=delay,
                plan=plan, grid=grid, tb=Fraction(st['time_base']),
                cs=float(fmt.get('start_time') or 0), fmt=fmt['format_name'],
                has_b=int(st.get('has_b_frames') or 0),
                ts=any(n in ('mpegts', 'mpeg') for n in fmt['format_name'].split(',')))


def today_args(info, frame):
    return today.decode_start(frame, info['fps'], info['offset'], info['delay'], info['plan'], info['grid'])


# ---------------------------------------------------------------- pictures

def hashes(args, w, h):
    """Luma MD5 per output frame of `ffmpeg <args>`, written as `rawvideo`
    like the worker's decoders (ffmpeg's constant-rate output timing applies
    exactly as it does there)."""
    r = run([FF, '-v', 'error', *args, '-f', 'rawvideo', '-pix_fmt', 'gray', '-'])
    n = w * h
    data = r.stdout
    return [hashlib.md5(data[i:i + n]).hexdigest() for i in range(0, len(data) - n + 1, n)], \
        r.stderr.decode(errors='replace')[-400:]


def decode(info, inargs, filters, count=None, src=None):
    args = list(inargs) + ['-apply_cropping', 'codec', '-i', src or info['path'], '-map', '0:v:0']
    if filters:
        args += ['-vf', ','.join(filters)]
    if count:
        args += ['-frames:v', str(count)]
    return hashes(args, info['w'], info['h'])


def reference(info):
    """Frame N as the app numbers it: the untrimmed decode (today's frame-0
    arguments, which every heavy test checks against an independent decode),
    and, on a grid source, issue #174's independent placement of every stored
    frame by its timestamp (gridlib.timeline), as a cross-check."""
    a, f = today_args(info, 0)
    seq, _ = decode(info, a, f)
    out = dict(seq=seq, placed=None)
    if info['grid']:
        stored, _ = hashes(['-apply_cropping', 'codec', '-i', info['path'], '-map', '0:v:0',
                            '-fps_mode', 'passthrough'], info['w'], info['h'])
        r = run([FP, '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                 'frame=pts_time,best_effort_timestamp_time', '-of', 'csv=p=0', info['path']], text=True)
        times = []
        for line in r.stdout.split():
            vals = [x for x in line.split(',') if x and x != 'N/A']
            times.append(float(vals[0]) if vals else None)
        if times and None not in times and len(times) == len(stored):
            g = info['grid']
            rate = g['num'] / g['den']
            t0 = g['origin']
            slot = [round((t - t0) * rate) for t in times]
            placed = []
            order = sorted(range(len(times)), key=lambda i: times[i])
            for i in range(max(slot) + 1):
                cand = [j for j in order if slot[j] <= i]
                placed.append(stored[cand[-1]] if cand else None)
            out['placed'] = placed
    return out


# ---------------------------------------------------------------- the index

PACKET_ENTRIES = 'packet=pts,dts,flags,pos'


def packet_index(path, entries=PACKET_ENTRIES, extra=()):
    """I-full: every video packet in decode order (pts/dts in the stream's
    time base, None where the container stores none)."""
    r = run([FP, '-v', 'error', *extra, '-select_streams', 'v:0', '-show_entries',
             entries + ':stream=time_base', '-of', 'json', path], text=True)
    j = json.loads(r.stdout)
    i = lambda v: int(v) if v not in (None, 'N/A') else None
    pk = [dict(pts=i(p.get('pts')), dts=i(p.get('dts')), pos=i(p.get('pos')),
               key=str(p.get('flags', '')).startswith('K')) for p in j.get('packets', [])]
    return pk, Fraction(j['streams'][0]['time_base'])


def fps_slot(pts, tb, g):
    """The grid slot the `fps` filter gives a picture: `setpts=PTS-<origin>/TB`
    (vf_setpts truncates the double to int64) then rescale to 1/rate rounding
    to nearest, half away from zero (AV_ROUND_NEAR_INF)."""
    origin = float(f'{g["origin"]:.6f}')
    p = int(pts - origin / float(tb))
    x = Fraction(p) * tb * Fraction(g['num'], g['den'])
    return math.floor(x + Fraction(1, 2)) if x >= 0 else -math.floor(-x + Fraction(1, 2))


def key_for_slot(index, tb, g, n):
    """K for grid slot n: the last key packet (decode order) whose own slot is
    <= n. Slot n shows the latest picture whose slot is <= n, so its PTS is at
    least K's: decoding from K reaches it. Uses key packets' PTS only (I-key)."""
    best = None
    for i, p in enumerate(index):
        if p['key'] and p['pts'] is not None and fps_slot(p['pts'], tb, g) <= n:
            best = i
    return best


def first_key(index):
    return next(i for i, p in enumerate(index) if p['key'])


def floor_us(t):
    return f'{math.floor(t * 1e6) / 1e6:.6f}'


def m1_grid(info, index, tb, n):
    """M1: -copyts, a time seek to key packet K's PTS (floored to the
    microsecond, so the accurate-seek drop never takes K), the grid filters to
    slot n. M0 (no seek) when K is the first key packet."""
    k = key_for_slot(index, tb, info['grid'], n)
    if k is None or k == first_key(index):
        return ['-copyts'], today.grid_filters(info['grid'], n), k
    t = float(index[k]['pts'] * tb) - info['cs']
    return ['-copyts', '-ss', floor_us(t)], today.grid_filters(info['grid'], n), k


def m2_grid(info, index, tb, n):
    """M2 (TS/PS): -copyts and a byte start at K's packet position, the grid
    filters to slot n. M0 when K is the first key packet."""
    k = key_for_slot(index, tb, info['grid'], n)
    if k is None or k == first_key(index):
        return ['-copyts'], today.grid_filters(info['grid'], n), k
    return ['-copyts', '-skip_initial_bytes', str(index[k]['pos'])], today.grid_filters(info['grid'], n), k


def key_for_count(index, n):
    """Decode-order sources (AVI): K = the last key packet at or before
    picture n in decode order. In a closed GOP the first picture out of a
    decode from K is display picture k (its decode index)."""
    return max(i for i, p in enumerate(index[:n + 1]) if p['key'])


def count_from_key(info, index, n, compensate=True):
    """AVI with decode-order timestamps: seek to K by its DTS (whole ticks,
    one tick = one frame), drop n - k pictures by count. ffmpeg starts any
    seek of a file with a delayed stream 3/23 s early (ffmpeg_demux.c's
    dts_heuristic), which lands on the key before K, so `compensate` adds
    3/23 s and turns off the accurate-seek drop. M0 when K is the first."""
    k = key_for_count(index, n)
    filters = []
    if n - k > 0:
        filters.append(f'trim=start_frame={n - k}')
    filters.append('setpts=PTS-STARTPTS')
    if k == first_key(index):
        return [], filters, k
    t = float(index[k]['dts'] * info['tb']) - info['cs']
    if compensate and info['has_b'] > 0:
        return ['-noaccurate_seek', '-ss', f'{t + 3 / 23:.6f}'], filters, k
    return ['-noaccurate_seek', '-ss', f'{t:.6f}'], filters, k


def name(got, ref):
    first = {}
    for i, h in enumerate(ref):
        first.setdefault(h, i)
    return [first.get(h, '?') for h in got]
