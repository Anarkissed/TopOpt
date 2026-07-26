import struct, sys, math
from collections import defaultdict

def read_binary_stl(path):
    with open(path,'rb') as f:
        f.read(80)
        n=struct.unpack('<I',f.read(4))[0]
        tris=[]; norms=[]
        for _ in range(n):
            data=f.read(50)
            nx,ny,nz,ax,ay,az,bx,by,bz,cx,cy,cz=struct.unpack('<12f',data[:48])
            tris.append(((ax,ay,az),(bx,by,bz),(cx,cy,cz)))
            norms.append((nx,ny,nz))
    return tris,norms

def facet_normal(t):
    (ax,ay,az),(bx,by,bz),(cx,cy,cz)=t
    ux,uy,uz=bx-ax,by-ay,bz-az
    vx,vy,vz=cx-ax,cy-ay,cz-az
    nx,ny,nz=uy*vz-uz*vy,uz*vx-ux*vz,ux*vy-uy*vx
    l=math.sqrt(nx*nx+ny*ny+nz*nz)
    if l==0: return None
    return (nx/l,ny/l,nz/l)

def quant(v,s=1e-5):
    return (round(v[0]/s),round(v[1]/s),round(v[2]/s))

def analyze(path):
    tris,_=read_binary_stl(path)
    normals=[facet_normal(t) for t in tris]
    # build edge -> list of facet indices, using quantized vertices
    edge_map=defaultdict(list)
    vid={}
    def getv(v):
        q=quant(v)
        if q not in vid: vid[q]=len(vid)
        return vid[q]
    for fi,t in enumerate(tris):
        ids=[getv(v) for v in t]
        for a,b in ((0,1),(1,2),(2,0)):
            e=tuple(sorted((ids[a],ids[b])))
            edge_map[e].append(fi)
    dihedrals=[]
    for e,fs in edge_map.items():
        if len(fs)!=2: continue
        n1,n2=normals[fs[0]],normals[fs[1]]
        if n1 is None or n2 is None: continue
        d=max(-1.0,min(1.0,n1[0]*n2[0]+n1[1]*n2[1]+n1[2]*n2[2]))
        dihedrals.append(math.degrees(math.acos(d)))
    dihedrals.sort()
    n=len(dihedrals)
    def pct(p): return dihedrals[min(n-1,int(p*n))]
    mean=sum(dihedrals)/n
    sharp30=sum(1 for x in dihedrals if x>30)/n
    sharp45=sum(1 for x in dihedrals if x>45)/n
    return dict(tris=len(tris),edges=n,mean=mean,median=pct(0.5),p90=pct(0.9),
                p99=pct(0.99),max=dihedrals[-1],sharp30=sharp30,sharp45=sharp45)

for path in sys.argv[1:]:
    r=analyze(path)
    name=path.split('/')[-3]+'/'+path.split('/')[-1]
    print(f"{name:28s} tris={r['tris']:6d} edges={r['edges']:6d} | dihedral(deg) "
          f"mean={r['mean']:5.1f} med={r['median']:5.1f} p90={r['p90']:5.1f} "
          f"p99={r['p99']:5.1f} max={r['max']:5.1f} | frac>30={r['sharp30']*100:4.1f}% "
          f">45={r['sharp45']*100:4.1f}%")
