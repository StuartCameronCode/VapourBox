"""FlowFPS at 10/16-bit against 8-bit on the same clip (hypothesis 3)."""
from harness import *
src = load("small.yuv", 320, 240, vs.YUV420P8, 40, 30000, 1001)
def flow(c):
    sup=core.mv.Super(c,pel=2)
    bw=core.mv.Analyse(sup,isb=True,blksize=16,overlap=4); fw=core.mv.Analyse(sup,isb=False,blksize=16,overlap=4)
    return core.mv.FlowFPS(c,sup,bw,fw,num=60000,den=1001)
ref=flow(src)
for bits in (10,16):
    hi=core.resize.Point(src,format=src.format.replace(bits_per_sample=bits).id)
    out=core.resize.Point(flow(hi),format=vs.YUV420P8)
    d=core.std.PlaneStats(ref,out)
    worst=max(range(1,70,2),key=lambda i:d.get_frame(i).props.PlaneStatsDiff)
    vals=[d.get_frame(i).props.PlaneStatsDiff*255 for i in range(1,70,2)]
    print(f"{bits}-bit vs 8-bit FlowFPS: synthesized mean diff {sum(vals)/len(vals):.2f}/255, worst {max(vals):.2f} (frame {worst})")
