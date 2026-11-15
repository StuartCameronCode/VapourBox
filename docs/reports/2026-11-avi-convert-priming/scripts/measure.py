"""Measure an output: video stream facts, flash times, beep times, sync."""
import array, json, os, subprocess, sys
DEPS = os.environ['VAPOURBOX_DEPS_DIR']
FF = os.path.join(DEPS, 'ffmpeg', 'ffmpeg'); FP = os.path.join(DEPS, 'ffmpeg', 'ffprobe')

def run(a):
    return subprocess.run(a, capture_output=True, text=True, check=True).stdout

def streams(path):
    j = json.loads(run([FP, '-v', 'error', '-count_frames', '-show_entries',
        'stream=index,codec_type,codec_name,time_base,r_frame_rate,avg_frame_rate,nb_frames,nb_read_frames,start_time,duration,sample_rate',
        '-of', 'json', path]))
    return j['streams']

def frames(path):
    """(pts_time, yavg) of every decoded video frame, as a player gets them."""
    out = run([FP, '-v', 'error', '-f', 'lavfi', '-i',
        "movie='%s',signalstats" % path.replace("'", "\\'"),
        '-show_entries', 'frame=pts_time:frame_tags=lavfi.signalstats.YAVG', '-of', 'json'])
    fr = json.loads(out)['frames']
    return [(float(f['pts_time']), float(f['tags']['lavfi.signalstats.YAVG'])) for f in fr]

def beeps(path, rate=48000):
    raw = subprocess.run([FF, '-v', 'error', '-i', path, '-map', '0:a:0', '-ac', '1', '-ar', str(rate),
        '-f', 's16le', '-'], capture_output=True, check=True).stdout
    s = array.array('h'); s.frombytes(raw[:len(raw)//2*2])
    st = float(next(x for x in streams(path) if x['codec_type']=='audio').get('start_time') or 0)
    out = []; last = -9; quiet = rate//100
    for i in range(quiet, len(s)):
        if abs(s[i]) > 0.3*32768 and all(abs(s[j]) <= 0.3*32768 for j in range(i-quiet, i)):
            t = st + i/rate
            if t - last > 0.5: out.append(t)
            last = t
    return out, len(s)/rate

def report(path):
    ss = streams(path)
    fr = frames(path)
    flashes = [t for t, y in fr if y > 200]
    b, adur = beeps(path)
    v = next(x for x in ss if x['codec_type']=='video')
    lags = []
    for f in flashes:
        near = [x for x in b if -0.5 <= x - f <= 1.5]
        lags.append(round((near[0]-f)*1000, 2) if near else None)
    return dict(file=os.path.basename(path), v_tb=v['time_base'], v_avg=v['avg_frame_rate'], v_r=v['r_frame_rate'],
        nb_frames=v.get('nb_frames'), decoded=len(fr), first_pts=[round(t,4) for t,_ in fr[:3]],
        v_start=v.get('start_time'), flashes=[round(x,4) for x in flashes], beeps=[round(x,4) for x in b],
        lag_ms=lags, audio_codec=[x['codec_name'] for x in ss if x['codec_type']=='audio'], audio_secs=round(adur,4))

if __name__ == '__main__':
    for p in sys.argv[1:]:
        print(json.dumps(report(p)))
