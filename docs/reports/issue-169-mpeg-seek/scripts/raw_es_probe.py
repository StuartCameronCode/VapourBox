"""Raw elementary streams (no container timestamps): where a plain seek
lands. Out of scope for the fix; measured so the report can say so."""
from seeklib import sequential, decode, indices
import make_variants

v = make_variants.build()
for name in ('raw.m2v', 'raw.h264'):
    seq = sequential(v[name])
    cells = []
    for st in (1, 10, 40, 77):
        got = decode(v[name], st, 1, 'plain')
        cells.append(f"{st}->{indices(got, seq)[0] if got else 'none'}")
    print(f"== {name}: " + '  '.join(cells))
