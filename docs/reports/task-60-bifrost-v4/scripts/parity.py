import array, sys, os
d = sys.argv[1]; W, H, NF = 720, 480, 8
def load(name, bits):
    a = array.array('B' if bits == 8 else 'H')
    with open(os.path.join(d, name), 'rb') as f: a.frombytes(f.read())
    return a
def planes(ss):
    cw, ch = (W // 2, H // 2) if ss == '420' else (W // 2, H)
    return W * H, cw * ch
for ss in ('420', '422'):
    ly, lc = planes(ss); fs = ly + 2 * lc
    def chroma_idx():
        for n in range(NF):
            b = n * fs
            yield from range(b + ly, b + fs)
    def luma_idx():
        for n in range(NF):
            b = n * fs
            yield from range(b, b + ly)
    i8, o8 = load('%s_b8_in.raw' % ss, 8), load('%s_b8_out.raw' % ss, 8)
    ch = list(chroma_idx())
    changed8 = sum(1 for i in ch if o8[i] != i8[i])
    print('== %s: 8-bit Bifrost changed %.1f%% of chroma samples' % (ss, 100 * changed8 / len(ch)))
    for tag, bits in (('b16z', 16), ('b16', 16), ('b10', 10)):
        i, o = load('%s_%s_in.raw' % (ss, tag), bits), load('%s_%s_out.raw' % (ss, tag), bits)
        sc = 1 << (bits - 8)
        luma_exact = all(o[k] == i[k] for k in luma_idx())
        # decision parity: changed at depth vs changed at 8-bit
        mism = 0; dsum = 0.0; dmax = 0.0; rw_sum = 0.0; rw_max = 0.0; chg = 0
        for k in ch:
            dd = (o[k] - i[k]) / sc
            d8 = o8[k] - i8[k]
            if (o[k] != i[k]): chg += 1
            if (o[k] != i[k]) != (o8[k] != i8[k]): mism += 1
            e = abs(dd - d8); dsum += e; dmax = max(dmax, e)
            # run_within (task #48): 8-bit copy of the deep input (round), delta scaled back
            # approximated with the 8-bit run's delta (its input is this rounded copy for b16z only)
        print('  %-5s luma bit-exact=%s  changed %.1f%%  decision mismatch vs 8-bit %.2f%%  |delta-delta8| mean %.3f max %.1f (8-bit levels)'
              % (tag, luma_exact, 100 * chg / len(ch), 100 * mism / len(ch), dsum / len(ch), dmax))
