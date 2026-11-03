"""CPU reference for KNLMeansCL's maths (channels=Y, wmode=0, wref=1),
compared with a GPU build on 150 sampled pixels of frame 5.

    nlm_reference.py [PLUGIN]   # PLUGIN loaded as knlmalt; else the bundle's knlm

Weight of offset (dx,dy,dt): exp(-P * 255^2 / (h^2 (2s+1)^2)), P = sum of
squared differences over the (2s+1)^2 patch, pixels in [0,1] (nlmDistance's
3*d^2 for luma cancels NLM_LEGACY = 3). The centre pixel gets
wref * max(largest weight, FLT_EPSILON): the max-weight buffer U5 starts at
CL_FLT_EPSILON. Output = weighted mean. Prints, per h, the mean |GPU - reference|
and |input - reference| in 8-bit levels. The GPU's own float rounding and
8-bit output quantisation leave about 0.25 even when it is right.
"""
import math, random, sys, vapoursynth as vs
core = vs.core
ns = "knlm"
if len(sys.argv) > 1:
    core.std.LoadPlugin(sys.argv[1], forcens="knlmalt", forceid="probe.knlm.alt"); ns = "knlmalt"
A, S_, Dt, W, H = 2, 4, 1, 160, 120
FLT_EPSILON = 1.1920929e-07
clean = core.std.BlankClip(width=W, height=H, format=vs.YUV420P8, length=11, color=[128,128,128])
clean = core.akarin.Expr(clean, ["X 40 / floor 2 % 64 * 96 +", "", ""])
noisy = core.grain.Add(clean, var=40.0, uvar=0.0, seed=7)

def luma(clip, n):
    f = clip.get_frame(n); p = f[0]
    return [[p[y, x] / 255.0 for x in range(W)] for y in range(H)]  # 2-D index works

frames = {t: luma(noisy, 5 + t) for t in (-1, 0, 1)}
random.seed(1)
pts = [(random.randrange(A + S_ + 1, W - A - S_ - 1), random.randrange(A + S_ + 1, H - A - S_ - 1)) for _ in range(150)]

def ref(h, x, y):
    # luma distance is 3*d^2 (nlmDistance), over NLM_LEGACY=3: the 3s cancel
    k = 255.0 ** 2 / (h * h * (2 * S_ + 1) ** 2)
    c = frames[0]
    ws, acc = [], 0.0
    for dt in (-1, 0, 1):
        f = frames[dt]
        for dy in range(-A, A + 1):
            for dx in range(-A, A + 1):
                if dt == 0 and dx == 0 and dy == 0:
                    continue
                P = 0.0
                for j in range(-S_, S_ + 1):
                    rc, rf = c[y + j], f[y + dy + j]
                    for i in range(-S_, S_ + 1):
                        d = rc[x + i] - rf[x + dx + i]
                        P += d * d
                w = math.exp(-P * k)
                ws.append(w); acc += w * f[y + dy][x + dx]
    m = max(max(ws), FLT_EPSILON)   # the U5 buffer starts at CL_FLT_EPSILON
    return (acc + m * c[y][x]) / (sum(ws) + m)

for h in (1.2, 2.0, 3.0, 5.0):
    out = getattr(core, ns).KNLMeansCL(noisy, d=Dt, a=A, s=S_, h=h, channels="Y", device_type="gpu")
    g = luma(out, 5)
    e_gpu = e_in = 0.0
    for x, y in pts:
        r = ref(h, x, y)
        e_gpu += abs(g[y][x] - r); e_in += abs(frames[0][y][x] - r)
    print(f"h={h}: |gpu-ref|={e_gpu/len(pts)*255:.3f}  |input-ref|={e_in/len(pts)*255:.3f}", flush=True)
