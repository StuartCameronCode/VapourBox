import json, sys
d = sys.argv[1]
v3 = [json.load(open('%s/v3_%d.json' % (d, r))) for r in (1, 2, 3)]
v4 = [json.load(open('%s/v4_%d.json' % (d, r))) for r in (1, 2, 3)]
print('%-24s %-22s %-22s %-14s %s' % ('case', 'v3 distinct full/blk', 'v4 distinct full/blk', 'v3==v4 blocks', 'v4 acts'))
for k in v3[0]:
    def dist(runs, part):
        if 'error' in runs[0]:
            return runs[0]['error'][:40]
        return len({tuple(r[k][part]) for r in runs})
    if 'error' in v3[0][k] or 'error' in v4[0][k]:
        print('%-24s v3: %s | v4: %s' % (k, v3[0][k].get('error', 'ok'), v4[0][k].get('error', 'ok')))
        continue
    same = all(v3[0][k]['blocks'][i] == v4[0][k]['blocks'][i] for i in range(12))
    nb = sum(1 for i in range(12) if v3[0][k]['blocks'][i] != v4[0][k]['blocks'][i])
    acts = sum(v4[0][k]['changed'])
    print('%-24s %-22s %-22s %-14s %d/12' % (k, '%s/%s' % (dist(v3, 'full'), dist(v3, 'blocks')), '%s/%s' % (dist(v4, 'full'), dist(v4, 'blocks')), 'yes' if same else 'NO (%d fr)' % nb, acts))
