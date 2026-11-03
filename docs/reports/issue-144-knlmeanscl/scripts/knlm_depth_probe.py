"""Run ONE KNLMeansCL build across bit depths, layouts and channel modes,
and dump every output frame for knlm_compare.py.

One build per process, so a fault in one cannot be blamed on the other.

Run with the deps bundle's Python (see run.sh):

    knlm_depth_probe.py --out DIR                 # the bundle's own knlm
    knlm_depth_probe.py --out DIR --alt PLUGIN    # another build, as knlmalt

Writes DIR/<case>.raw (frame FRAME, planes concatenated) for the source and
each case that runs, and DIR/status.txt: one line per case, "ok" or the error.
"""
import argparse
import os
import vapoursynth as vs

core = vs.core

ap = argparse.ArgumentParser()
ap.add_argument("--out", required=True)
ap.add_argument("--alt", help="KNLMeansCL build to use instead, loaded as knlmalt")
ap.add_argument("--devices", default="gpu,auto")
args = ap.parse_args()

ns = "knlm"
if args.alt:
    core.std.LoadPlugin(args.alt, forcens="knlmalt", forceid="probe.knlm.alt")
    ns = "knlmalt"
os.makedirs(args.out, exist_ok=True)

W, H, FRAMES, FRAME = 320, 240, 11, 5
DEPTHS = [8, 9, 10, 12, 14, 16]
LAYOUTS = {"420": (1, 1), "444": (0, 0)}


def source(fmt):
    """A deterministic noisy picture: gradient + coloured blocks + grain, made
    at 16-bit and truncated so every depth sees the same content."""
    base = core.std.BlankClip(width=W, height=H, format=vs.YUV444P16,
                              length=FRAMES, color=[32768, 32768, 32768])
    grad = core.akarin.Expr(base, ["X 128 * Y 64 * + 8192 +",
                                    "X 32 / floor 2 % 16384 * 24576 +",
                                    "Y 24 / floor 2 % 16384 * 24576 +"])
    noisy = core.grain.Add(grad, var=40.0, uvar=20.0, seed=7)
    return core.resize.Point(noisy, format=fmt, dither_type="none")


def dump(clip, name):
    f = clip.get_frame(FRAME)
    with open(os.path.join(args.out, name + ".raw"), "wb") as fh:
        for p in range(f.format.num_planes):
            fh.write(bytes(f[p]))


status = []
for depth in DEPTHS:
    for lname, (sw, sh) in LAYOUTS.items():
        fmt = core.query_video_format(vs.YUV, vs.INTEGER, depth, sw, sh)
        src = source(fmt.id)
        dump(src, f"src_{depth}_{lname}")
        for device in args.devices.split(","):
            for channels in ["Y", "UV"] + (["YUV"] if lname == "444" else []):
                case = f"{depth}_{lname}_{channels}_{device}"
                try:
                    out = getattr(core, ns).KNLMeansCL(
                        src, d=1, a=2, s=4, h=1.2, channels=channels, device_type=device)
                    dump(out, case)
                    status.append(f"{case} ok")
                except vs.Error as e:
                    status.append(f"{case} ERROR {str(e).splitlines()[0]}")
                print(status[-1], flush=True)

with open(os.path.join(args.out, "status.txt"), "w") as fh:
    fh.write("\n".join(status) + "\n")
