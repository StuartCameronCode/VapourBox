"""Today's decoder start (worker/src/source_decode.rs at the commit this report
was written against), rebuilt in Python so the sweep can run it as the
control. Each function names its Rust original; behaviour is copied, not
re-derived. `check_today.py`-style cross-checks against the worker's own
preview live in sweep_probe.py (`--worker-check`).

Constants pinned to the Rust source (pktlib.pin_constants() asserts them).
"""
import math
from fractions import Fraction

GRID_LOOKBACK_SLOTS = 8
COUNT_SEEK_BELOW = 0.5
MAX_DECODER_DELAY = 4
SEEK_PREROLL_MARGIN = 0.5
SEEK_PREROLL_MIN = 1.0
SEEK_PROBE_SECONDS = 20
GRID_RATE_TOLERANCE = 0.001
TIMESTAMP_SEARCH_FORMATS = ('mpegts', 'mpeg')

VIDEO_START_PROBE_ARGS = ['-v', 'error', '-select_streams', 'v:0', '-show_entries',
                          'packet=pts_time:stream=start_time,r_frame_rate,avg_frame_rate:format=start_time',
                          '-read_intervals', '%+#64', '-of', 'json']
SEEK_PROBE_ARGS = ['-v', 'error', '-select_streams', 'v:0', '-show_entries',
                   'packet=pts_time,dts_time,flags:format=format_name,start_time',
                   '-read_intervals', '%+20', '-of', 'json']
DECODER_DELAY_PROBE_ARGS = ['-v', 'error', '-select_streams', 'v:0', '-show_entries',
                            'frame=best_effort_timestamp_time:stream=r_frame_rate:format=start_time',
                            '-read_intervals', '%+#16', '-of', 'json']


def _num(v):
    try:
        x = float(v)
        return x if math.isfinite(x) else None
    except (TypeError, ValueError):
        return None


def video_start_from_probe(j):
    """source_decode::video_start_from_probe"""
    container = _num((j.get('format') or {}).get('start_time'))
    streams = j.get('streams') or []
    stream = _num(streams[0].get('start_time')) if streams else None
    packets = j.get('packets')
    if packets is not None:
        first = stream if stream is not None else math.inf
        for p in packets:
            t = _num(p.get('pts_time'))
            if t is not None:
                first = min(first, t)
    else:
        first = stream
    if first is not None and not math.isfinite(first):
        first = None
    if container is not None and first is not None and first > container:
        return first - container
    return 0.0


def stores_decode_order(j):
    """source_decode::stores_decode_order"""
    return any('pts_time' not in p for p in (j.get('packets') or []))


def decoder_delay_from_probe(j, video_start):
    """source_decode::decoder_delay_from_probe"""
    streams = j.get('streams') or []
    rate = None
    if streams and '/' in str(streams[0].get('r_frame_rate', '')):
        n, d = streams[0]['r_frame_rate'].split('/')
        if float(n) > 0 and float(d) > 0:
            rate = float(n) / float(d)
    frames = j.get('frames') or []
    first = _num(frames[0].get('best_effort_timestamp_time')) if frames else None
    if rate is None or first is None:
        return 0
    container = _num((j.get('format') or {}).get('start_time')) or 0.0
    f = round_half_away((first - container - max(video_start, 0.0)) * rate)
    return int(f) if 1 <= f <= MAX_DECODER_DELAY else 0


def round_half_away(x):
    return math.floor(x + 0.5) if x >= 0 else -math.floor(-x + 0.5)


def seek_plan_from_probe(j):
    """source_decode::seek_plan_from_probe -> (preroll, container_start) or None"""
    fmt = j.get('format') or {}
    name = fmt.get('format_name')
    if not name or not any(n.strip() in TIMESTAMP_SEARCH_FORMATS for n in name.split(',')):
        return None
    cs = _num(fmt.get('start_time')) or 0.0
    keys, reorder = [], 0.0
    for p in j.get('packets') or []:
        pts, dts = _num(p.get('pts_time')), _num(p.get('dts_time'))
        if pts is not None and dts is not None:
            reorder = max(reorder, pts - dts)
        t = pts if pts is not None else dts
        if str(p.get('flags', '')).startswith('K') and t is not None:
            keys.append(t)
    gop = float(SEEK_PROBE_SECONDS) if len(keys) < 2 else max(b - a for a, b in zip(keys, keys[1:]))
    return dict(preroll=max(gop + reorder + SEEK_PREROLL_MARGIN, SEEK_PREROLL_MIN), container_start=cs)


def _rate(s):
    try:
        n, d = (int(x) for x in str(s).split('/'))
        return (n, d) if n > 0 and d > 0 else None
    except ValueError:
        return None


def fps_to_rational(fps):
    """models::fps_to_rational (used only when the stream's own rate is off)."""
    for rate, n, d in ((23.976, 24000, 1001), (24.0, 24, 1), (25.0, 25, 1), (29.97, 30000, 1001),
                       (30.0, 30, 1), (50.0, 50, 1), (59.94, 60000, 1001), (60.0, 60, 1)):
        if abs(fps - rate) < 0.01:
            return n, d
    return round_half_away(fps * 1000.0), 1000


def grid_from_probe(j, job_fps):
    """source_decode::grid_from_probe -> dict(num, den, origin) or None"""
    packets = j.get('packets')
    if not packets:
        return None
    first = math.inf
    for p in packets:
        t = _num(p.get('pts_time'))
        if t is None:
            return None
        first = min(first, t)
    streams = j.get('streams') or []
    st = streams[0] if streams else {}
    s = _num(st.get('start_time'))
    if s is not None:
        first = min(first, s)
    c = _num((j.get('format') or {}).get('start_time'))
    origin = max(first, c) if c is not None else first
    r, a = _rate(st.get('r_frame_rate')), _rate(st.get('avg_frame_rate'))
    if r and a:
        ratio = (r[0] * a[1]) / (r[1] * a[0])
        sr = a if 1.8 < ratio < 2.2 else r
    else:
        sr = r or a
    if sr and (job_fps <= 0 or abs((sr[0] / sr[1] - job_fps) / job_fps) <= GRID_RATE_TOLERANCE):
        num, den = sr
    elif job_fps > 0:
        num, den = fps_to_rational(job_fps)
    else:
        return None
    return dict(num=num, den=den, origin=origin)


def select_frame_rate(r, a):
    """FieldOrderDetector.selectFrameRate (the job's inputFrameRate)."""
    if not r or r <= 0:
        return a
    if not a or a <= 0:
        return r
    return a if 1.8 < r / a < 2.2 else r


def seek_time(frame, fps, video_start):
    """source_decode::seek_time"""
    if frame <= 0:
        return None
    fps = fps if fps > 0 else 29.97
    t = (frame - 0.5) / fps + max(video_start, 0.0)
    return t if t > 0 else None


def seek_arg(t):
    """source_decode::seek_arg: microseconds, rounded up (1 ns allowance)."""
    return f'{math.ceil(t * 1e6 - 1e-3) / 1e6:.6f}'


def grid_filters(g, first):
    """SourceGrid::filters"""
    return [f'setpts=PTS-{g["origin"]:.6f}/TB', f'fps={g["num"]}/{g["den"]}',
            f'trim=start_pts={max(first, 0)}', 'setpts=PTS-STARTPTS']


def source_seek(frame, fps, video_start, delay, plan):
    """source_decode::source_seek -> dict(ss, trim_from, trim_frames, rebase)"""
    d = 0 if plan else min(delay, MAX_DECODER_DELAY)
    out = dict(ss=None, trim_from=None, trim_frames=None, rebase=d > 0)
    if frame <= 0:
        return out
    t = seek_time(frame + d, fps, video_start)
    if d > 0 and t is not None and t < COUNT_SEEK_BELOW:
        out['trim_frames'] = frame
        return out
    if t is None or t <= 0:
        return out
    if plan is None:
        out['ss'] = t
    else:
        early = t - plan['preroll']
        out['ss'] = early if early > 0 else None
        out['trim_from'] = plan['container_start'] + t
    return out


def decode_start(frame, fps, video_start, delay, plan, grid):
    """source_decode::decode_start -> (input args, vf filters)"""
    frame = max(frame, 0)
    if grid is not None:
        if frame == 0 and plan is not None:
            f = grid_filters(grid, 0)
            f[0] = 'setpts=PTS-STARTPTS'
            return [], f
        target = seek_time(frame - GRID_LOOKBACK_SLOTS, grid['num'] / grid['den'], video_start)
        if target is not None and plan is not None:
            ss = target - plan['preroll']
            ss = ss if ss > 0 else None
        else:
            ss = target
        args = ['-copyts'] + (['-ss', seek_arg(ss)] if ss is not None else [])
        return args, grid_filters(grid, frame)
    s = source_seek(frame, fps, video_start, delay, plan)
    seeks = s['ss'] is not None or s['trim_from'] is not None or s['trim_frames'] is not None
    filters = []
    if s['trim_from'] is not None:
        filters.append(f'trim=start={seek_arg(s["trim_from"])}')
    elif s['trim_frames'] is not None:
        filters.append(f'trim=start_frame={s["trim_frames"]}')
    if seeks or s['rebase'] or video_start > 0 or filters:
        filters.append('setpts=PTS-STARTPTS')
    args = (['-copyts'] if s['trim_from'] is not None else []) + \
        (['-ss', seek_arg(s['ss'])] if s['ss'] is not None else [])
    return args, filters
