import sys,glob
ooo=0; runs=0; again=0; maxlag=0
for f in glob.glob(sys.argv[1]+'/*.log'):
    runs+=1; seen=-1
    for l in open(f):
        p=l.split()
        if len(p)>2 and p[1]=='REQOUT':
            n=int(p[2])
            if n<seen: ooo+=1
            seen=max(seen,n)
        elif len(p)>3 and p[2]=='again':
            again+=1; maxlag=max(maxlag,int(p[3].split('=')[1])-int(p[1]))
print(f"runs {runs}, output requests out of order {ooo}, re-requests {again}, max lag {maxlag}")
