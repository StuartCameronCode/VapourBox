"""Sound offset of an AVI output against its source by cross-correlation, and the
head of the decoded sound (what the copied first packet sounds like).
    VAPOURBOX_DEPS_DIR=... python3 xcorr.py <source> <out.avi>...
Positive offset = the output's sound plays later than the source's."""
import array, os, subprocess, sys, math
D = os.environ['VAPOURBOX_DEPS_DIR']; FF = os.path.join(D, 'ffmpeg', 'ffmpeg')
def pcm(p, n=None):
    raw = subprocess.run([FF, '-v', 'error', '-i', p, '-map', '0:a:0', '-ac', '1', '-ar', '48000', '-f', 'f32le', '-'],
                         capture_output=True, check=True).stdout
    a = array.array('f'); a.frombytes(raw); return a
def lag(ref, out, lo=24000, n=48000, maxlag=2400):
    best = None
    seg = ref[lo:lo+n]; e0 = math.sqrt(sum(x*x for x in seg))
    for d in range(-maxlag, maxlag+1):
        o = out[lo+d:lo+d+n]
        if len(o) < n: continue
        c = sum(a*b for a, b in zip(seg, o)) / (e0 * math.sqrt(sum(x*x for x in o)) + 1e-12)
        if best is None or c > best[1]: best = (d, c)
    return best
def rms(a): return math.sqrt(sum(x*x for x in a)/max(1,len(a)))
ref = pcm(sys.argv[1])
print('source head rms 0-10ms %.4f 10-21ms %.4f 21-43ms %.4f' % (rms(ref[:480]), rms(ref[480:1024]), rms(ref[1024:2048])))
for p in sys.argv[2:]:
    out = pcm(p)
    d, c = lag(ref, out)
    print('%-40s offset %+.2f ms (corr %.4f)  head rms 0-10ms %.4f 10-21ms %.4f 21-43ms %.4f' % (
        os.path.basename(p), d/48, c, rms(out[:480]), rms(out[480:1024]), rms(out[1024:2048])))
