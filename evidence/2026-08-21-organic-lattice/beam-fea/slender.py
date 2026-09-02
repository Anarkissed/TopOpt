#!/usr/bin/env python3
"""Junction-to-junction strut slenderness for a dumped beam model.

L/r decides whether beam theory applies at all. Segments are NOT struts: a long
beam finely subdivided is still a beam. What matters is the distance between
JUNCTIONS, after welding struts that physically touch.
"""
import sys, numpy as np, collections
from scipy.spatial import cKDTree

def analyse(path):
    segs=[]
    for ln in open(path):
        t=ln.split()
        if t and t[0]=='SEG': segs.append([float(x) for x in t[1:8]])
    if not segs: return None
    S=np.array(segs)
    key={}
    def nid(p):
        k=(round(p[0]/1e-6),round(p[1]/1e-6),round(p[2]/1e-6))
        if k not in key: key[k]=len(key)
        return key[k]
    E=[(nid(s[0:3]),nid(s[3:6]),s[6]) for s in S]
    N=len(key); pts=np.zeros((N,3))
    for s in S: pts[nid(s[0:3])]=s[0:3]; pts[nid(s[3:6])]=s[3:6]
    ch=list(range(N))
    def f(x):
        while ch[x]!=x: ch[x]=ch[ch[x]]; x=ch[x]
        return x
    for a,b,r in E:
        ra,rb=f(a),f(b)
        if ra!=rb: ch[max(ra,rb)]=min(ra,rb)
    cid=np.array([f(i) for i in range(N)])
    rad=np.zeros(N)
    for a,b,r in E: rad[a]=max(rad[a],r); rad[b]=max(rad[b],r)
    mg=list(range(N))
    def fm(x):
        while mg[x]!=x: mg[x]=mg[mg[x]]; x=mg[x]
        return x
    for i,j in cKDTree(pts).query_pairs(r=float(rad.max()*2), output_type='ndarray'):
        if cid[i]==cid[j]: continue
        if np.linalg.norm(pts[i]-pts[j])>rad[i]+rad[j]: continue
        a,b=fm(i),fm(j)
        if a!=b: mg[max(a,b)]=min(a,b)
    new=np.array([fm(i) for i in range(N)])
    adj=collections.defaultdict(set); seglen={}
    for a,b,r in E:
        na,nb=new[a],new[b]
        if na!=nb:
            adj[na].add(nb); adj[nb].add(na)
            seglen[(na,nb)]=seglen[(nb,na)]=np.linalg.norm(pts[a]-pts[b])
    junc={k for k,v in adj.items() if len(v)!=2}
    L=[]; seen=set()
    for j in junc:
        for nb in adj[j]:
            if (j,nb) in seen: continue
            prev,cur,tot=j,nb,seglen[(j,nb)]; seen.add((j,nb))
            while cur not in junc:
                nx=[x for x in adj[cur] if x!=prev]
                if not nx: break
                seen.add((cur,nx[0])); tot+=seglen[(cur,nx[0])]; prev,cur=cur,nx[0]
            seen.add((cur,prev)); L.append(tot)
    if not L: return None
    L=np.array(L); r=float(np.median(rad[rad>0]))
    return dict(n=len(L), r=r, med=np.median(L), p05=np.percentile(L,5),
                sl=np.median(L)/r, lt5=100*np.mean(L/r<5), lt10=100*np.mean(L/r<10),
                nodes=len(adj), junc=len(junc))

if __name__=='__main__':
    print(f"{'cell':>5} {'struts':>8} {'r_mm':>6} {'L_med':>7} {'L/r':>6} {'<5':>7} {'<10':>7} {'junctions':>10}")
    for p in sys.argv[1:]:
        c=p.split('/c')[-1].split('/')[0]
        d=analyse(p)
        if d is None: print(f"{c:>5}   (no data)"); continue
        print(f"{c:>5} {d['n']:8,} {d['r']:6.2f} {d['med']:7.2f} {d['sl']:6.1f} "
              f"{d['lt5']:6.1f}% {d['lt10']:6.1f}% {d['junc']:10,}")
