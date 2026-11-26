import sys,glob,collections
lead=collections.Counter(); depth=collections.Counter()
for f in glob.glob(sys.argv[1]+'/*.log'):
    seen=-1
    for l in open(f):
        p=l.split()
        if len(p)>2 and p[1]=='REQOUT':
            n=int(p[2]); low=int(p[3].split('=')[1])
            lead[low-n]+=1
            if n<seen: depth[seen-n]+=1
            seen=max(seen,n)
print("low - n at request:", sorted(lead.items())[-8:], "max", max(lead))
print("out-of-order depth:", sorted(depth.items()))
