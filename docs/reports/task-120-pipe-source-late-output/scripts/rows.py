import json,os,sys
root=sys.argv[1]
for d in sorted(os.listdir(root)):
    for f in os.listdir(os.path.join(root,d)):
        rows=json.load(open(os.path.join(root,d,f)))
        st=[r for r in rows if r['variant'].startswith('stabilize') and r['row'].startswith('720x480')]
        print('==',d)
        for r in sorted(st,key=lambda r:(r['variant'],-r['secs']))[:]:
            if 'yuv444p16' in r['row'] or 'yuv420p/' in r['row'] or not r['ok']:
                print(f"  {r['variant']:<28} {r['row']:<26} {r['secs']:7.1f} {r['ok']} {r.get('error','')[:60]}")
        # top 5 slowest overall
        s=sorted(rows,key=lambda r:-r['secs'])[:6]
        print('  slowest:',[(r['variant'],r['row'],r['secs']) for r in s])
