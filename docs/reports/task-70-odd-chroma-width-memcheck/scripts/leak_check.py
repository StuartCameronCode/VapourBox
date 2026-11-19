"""Negative control for poison.py (task #70): QTGMC followed by a deliberate read
of one padding sample per chroma row into the picture. poison.py must report
two different hashes for two seeds here.  python leak_check.py [preset WxH format]"""
import ctypes, sys
import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import poison, havsfunc as haf
real_q = haf.QTGMC
def leaky(c, **k):
    out = real_q(c, **k)
    # read 1 sample of padding (poisoned upstream by the proxy) into column 0
    pad = haf.core.std.Merge(out, out, 0.0)   # proxied: its padding is poisoned
    def leak(n, f):
        fo = f.copy(); bps = f.format.bytes_per_sample
        for p in range(1, 3):
            pw = f.width >> f.format.subsampling_w
            src = ctypes.cast(f.get_read_ptr(p), ctypes.c_void_p).value
            dst = ctypes.cast(fo.get_write_ptr(p), ctypes.c_void_p).value
            ctypes.memmove(dst, src + pw * bps, bps)
        return fo
    return poison.REAL.std.ModifyFrame(pad, pad, leak)
haf.QTGMC = leaky
sys.argv = ['poison.py'] + (sys.argv[1:4] or ['Draft', '98x96', 'YUV420P12']) + ['1', '2']
poison.main()
