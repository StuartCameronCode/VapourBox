# The r31 fingerprint, the same check vapoursynth_integration_test.dart's
# "fmtconv version pin" test makes. U and V are the same vertical ramp, so any
# U-V difference after a field-aware vertical resample is chroma placement
# alone. Prints the 16-bit U, V and U-V averages per field to the last argument.
import sys, vapoursynth as vs
core = vs.core
rows = [core.std.BlankClip(format=vs.GRAY8, width=32, height=1, length=2, color=[40 + 5 * i]) for i in range(32)]
ch = core.std.StackVertical(rows)
y = core.std.BlankClip(format=vs.GRAY8, width=64, height=64, length=2, color=[128])
c = core.std.ShufflePlanes([y, ch, ch], [0, 0, 0], vs.YUV)
fields = core.std.SeparateFields(core.std.SetFieldBased(c, 2), tff=True)
lines = []
for cp in ("dv", "mpeg2"):
    o = core.fmtc.resample(fields, scalev=2, interlaced=1, interlacedd=0, cplace=cp)
    for n in range(2):
        u = core.std.PlaneStats(o, plane=1).get_frame(n).props["PlaneStatsAverage"]
        v = core.std.PlaneStats(o, plane=2).get_frame(n).props["PlaneStatsAverage"]
        lines.append(f"{cp} field{n} U={u*65535:.2f} V={v*65535:.2f} U-V={(u-v)*65535:+.2f}")
open(sys.argv[-1], "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
