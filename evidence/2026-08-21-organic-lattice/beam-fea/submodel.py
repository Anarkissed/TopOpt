#!/usr/bin/env python3
"""SUBMODEL beam FEA of the organic lattice.

The lattice alone is a lace: solved in isolation it deflects 100 mm under 9.8 N,
because the solid walls that carry the load are not in the model. So we do not apply
the job's loads here at all. Instead the lattice is DRIVEN at its cut boundary --
the nodes lying outside the declared lattice region, i.e. embedded in the solid rim --
by the displacement field of the full-part solve, trilinearly interpolated.

KNOWN BIAS, and it does not shrink with refinement: the driving field comes from a
solve where the lattice region is still SOLID, hence too stiff, so the margin this
reports is OPTIMISTIC. Softening that region in the global solve is the correction.
"""
import sys, math, numpy as np, collections
import scipy.sparse as sp, scipy.sparse.linalg as spl
from scipy.spatial import cKDTree

import os
# TIMOSHENKO by default. Euler-Bernoulli ignores shear deformation and so OVERSTATES
# stiffness in stubby members -- the regime this lattice lives in (median L/r 5.1 at
# 3 mm cells). Published comparisons put Euler-Bernoulli ~27% high at w/L = 0.5 and up
# to 108% high on the deepest specimens, while Timoshenko-Ehrenfest stays inside 5%
# across the whole slenderness range. Set TOPOPT_BEAM=EB to get the old behaviour and
# measure the gap on THIS geometry rather than inheriting theirs.
SHEAR_K = 0.9   # Timoshenko shear coefficient for a circular section
def frame_k(L,E,G,A,Iy,Iz,J):
    k=np.zeros((12,12))
    a=E*A/L; k[0,0]=k[6,6]=a; k[0,6]=k[6,0]=-a
    t=G*J/L;  k[3,3]=k[9,9]=t; k[3,9]=k[9,3]=-t
    eb = os.environ.get('TOPOPT_BEAM','') == 'EB'
    for (I,i1,i2,i3,i4,sg) in ((Iz,1,5,7,11,1.0),(Iy,2,4,8,10,-1.0)):
        phi = 0.0 if eb else 12.0*E*I/(G*SHEAR_K*A*L*L)
        c1=12*E*I/(L**3*(1+phi)); c2=6*E*I/(L**2*(1+phi))
        c3=(4+phi)*E*I/(L*(1+phi)); c4=(2-phi)*E*I/(L*(1+phi))
        k[i1,i1]=k[i3,i3]=c1; k[i1,i3]=k[i3,i1]=-c1
        k[i2,i2]=k[i4,i4]=c3; k[i2,i4]=k[i4,i2]=c4
        s=sg*c2
        k[i1,i2]=k[i2,i1]=s;  k[i1,i4]=k[i4,i1]=s
        k[i3,i2]=k[i2,i3]=-s; k[i3,i4]=k[i4,i3]=-s
    return k

def transform(p0,p1):
    d=np.asarray(p1)-np.asarray(p0); L=np.linalg.norm(d); ex=d/L
    up=np.array([0.,0.,1.])
    if abs(ex@up)>0.999: up=np.array([0.,1.,0.])
    ez=np.cross(ex,up); ez/=np.linalg.norm(ez); ey=np.cross(ez,ex)
    R=np.vstack([ex,ey,ez]); T=np.zeros((12,12))
    for b in range(4): T[3*b:3*b+3,3*b:3*b+3]=R
    return T,L

def main():
    beam=sys.argv[1]; E=float(sys.argv[2]); nu=float(sys.argv[3]); G=E/(2*(1+nu))
    segs=[]; grid=None
    for ln in open(beam):
        t=ln.split()
        if not t: continue
        if t[0]=='SEG':
            v=[float(x) for x in t[1:8]]
            v+= [int(t[8]),int(t[9])] if len(t)>=10 else [1,1]
            segs.append(v)
        elif t[0]=='GRID':
            grid=tuple(float(x) for x in t[1:5])+tuple(int(x) for x in t[5:8])
    if grid is None: print("REFUSING: no GRID header."); return 2
    ox,oy,oz,h,nx,ny,nz=grid
    NX,NY,NZ=nx+1,ny+1,nz+1
    import os
    # SCALE the driving field. The submodel is LINEAR, so peak stress must scale
    # exactly with it -- which turns "how optimistic is the too-stiff driving field?"
    # into a single multiplier instead of a homogenisation project.
    scale=float(os.environ.get('TOPOPT_DRIVE_SCALE','1'))
    U=np.fromfile(beam+'.disp',dtype=np.float64)*scale
    if scale!=1.0: print(f"  DRIVING FIELD SCALED x{scale}")
    if U.size != 3*NX*NY*NZ:
        print(f"REFUSING: disp has {U.size} doubles, expected {3*NX*NY*NZ}."); return 2
    U=U.reshape(NZ,NY,NX,3)
    print(f"segments {len(segs):,}   global grid {NX}x{NY}x{NZ} @ {h:.4f} mm")

    key={}; pts=[]
    def nid(p):
        k=(round(p[0]/1e-6),round(p[1]/1e-6),round(p[2]/1e-6))
        if k not in key: key[k]=len(pts); pts.append(p)
        return key[k]
    elems=[]; inside={}
    for v in segs:
        a,b=nid(tuple(v[0:3])),nid(tuple(v[3:6]))
        inside[a]=inside.get(a,1) and v[7]; inside[b]=inside.get(b,1) and v[8]
        if a!=b: elems.append((a,b,v[6]))
    pts=np.array(pts)
    # contact weld across different chains (struts that physically overlap are fused)
    ch=list(range(len(pts)))
    def f(x):
        while ch[x]!=x: ch[x]=ch[ch[x]]; x=ch[x]
        return x
    for a,b,r in elems:
        ra,rb=f(a),f(b)
        if ra!=rb: ch[max(ra,rb)]=min(ra,rb)
    cid=np.array([f(i) for i in range(len(pts))])
    rad=np.zeros(len(pts))
    for a,b,r in elems: rad[a]=max(rad[a],r); rad[b]=max(rad[b],r)
    mg=list(range(len(pts)))
    def fm(x):
        while mg[x]!=x: mg[x]=mg[mg[x]]; x=mg[x]
        return x
    for i,j in cKDTree(pts).query_pairs(r=float(rad.max()*2),output_type='ndarray'):
        if cid[i]==cid[j]: continue
        if np.linalg.norm(pts[i]-pts[j])>rad[i]+rad[j]: continue
        a,b=fm(i),fm(j)
        if a!=b: mg[max(a,b)]=min(a,b)
    remap={}
    for i in range(len(pts)):
        r0=fm(i)
        if r0 not in remap: remap[r0]=len(remap)
    new=np.array([remap[fm(i)] for i in range(len(pts))])
    M=len(remap); P=np.zeros((M,3)); C=np.zeros(M); drive=np.zeros(M,bool)
    for i in range(len(pts)):
        P[new[i]]+=pts[i]; C[new[i]]+=1
        if not inside.get(i,1): drive[new[i]]=True
    P/=C[:,None]
    elems=[(new[a],new[b],r) for (a,b,r) in elems if new[a]!=new[b]]
    n0=len(elems)
    elems=[(a,b,r) for (a,b,r) in elems if np.linalg.norm(P[a]-P[b])>1e-9]
    if n0!=len(elems):
        print(f"  dropped {n0-len(elems):,} zero-length elements (weld centroids coincided)")
    ND=6*M
    print(f"nodes {M:,}   elements {len(elems):,}   DOF {ND:,}")
    print(f"CUT BOUNDARY: {drive.sum():,} nodes lie outside the lattice region "
          f"({100.0*drive.sum()/M:.2f}%) -- driven by the global field")
    if drive.sum()==0:
        print("REFUSING: no cut-boundary nodes; nothing drives this submodel."); return 3

    # trilinear sample of the global displacement at a point
    def sample(p):
        gx=(p[0]-ox)/h; gy=(p[1]-oy)/h; gz=(p[2]-oz)/h
        i=int(np.clip(np.floor(gx),0,NX-2)); j=int(np.clip(np.floor(gy),0,NY-2)); k=int(np.clip(np.floor(gz),0,NZ-2))
        fx,fy,fz=np.clip(gx-i,0,1),np.clip(gy-j,0,1),np.clip(gz-k,0,1)
        out=np.zeros(3)
        for dk in (0,1):
            for dj in (0,1):
                for di in (0,1):
                    w=(fx if di else 1-fx)*(fy if dj else 1-fy)*(fz if dk else 1-fz)
                    out+=w*U[k+dk,j+dj,i+di]
        return out

    I_,J_,V_=[],[],[]
    for (a,b,r) in elems:
        A=math.pi*r*r; Ii=math.pi*r**4/4.0; Jj=2*Ii
        T,L=transform(P[a],P[b])
        ke=T.T@frame_k(L,E,G,A,Ii,Ii,Jj)@T
        dofs=[6*a+i for i in range(6)]+[6*b+i for i in range(6)]
        for ii,di in enumerate(dofs):
            for jj,dj in enumerate(dofs):
                if ke[ii,jj]!=0.0: I_.append(di); J_.append(dj); V_.append(ke[ii,jj])
    K=sp.coo_matrix((V_,(I_,J_)),shape=(ND,ND)).tocsr()

    # only the part CONNECTED to the cut boundary can be solved; the rest is orphaned
    adj=collections.defaultdict(list)
    for a,b,r in elems: adj[a].append(b); adj[b].append(a)
    seen=set(np.flatnonzero(drive).tolist()); stack=list(seen)
    while stack:
        n=stack.pop()
        for m in adj[n]:
            if m not in seen: seen.add(m); stack.append(m)
    keep=np.zeros(M,bool); keep[list(seen)]=True
    print(f"CONNECTIVITY: {keep.sum():,} of {M:,} nodes reach the cut boundary "
          f"({100.0*keep.sum()/M:.2f}%)  -- {M-keep.sum():,} orphaned, carry NO load")

    # prescribed displacements on the cut boundary (translations; rotations left free)
    ud=np.zeros(ND); fixed=np.zeros(ND,bool)
    for i in np.flatnonzero(drive):
        d=sample(P[i])
        for c in range(3): ud[6*i+c]=d[c]; fixed[6*i+c]=True
        for c in range(3,6): ud[6*i+c]=0.0; fixed[6*i+c]=True
    print(f"  driving displacement magnitude: max {np.abs(ud).max():.6g} mm")
    if not np.isfinite(K.data).all():
        print("REFUSING: stiffness matrix contains non-finite entries."); return 3
    free=np.repeat(keep,6)&~fixed
    rhs=-(K@ud)[free]
    Kff=K[free][:,free].tocsr()
    d0=Kff.diagonal()
    nz=int((d0<=0).sum())
    if nz:
        print(f"  {nz:,} free DOF have ZERO diagonal stiffness -- releasing them")
        rel=np.flatnonzero(free)[d0<=0]
        free[rel]=False
        rhs=-(K@ud)[free]
        Kff=K[free][:,free].tocsr()
    print(f"  free DOF {int(free.sum()):,}")
    dg=Kff.diagonal().copy(); dg[dg<=0]=1.0
    sol,info=spl.cg(Kff,rhs,rtol=1e-10,maxiter=50000,M=sp.diags(1.0/dg))
    if info!=0:
        print(f"Jacobi-CG did not converge (info={info}); sparse direct fallback")
        sol=spl.spsolve(Kff,rhs)
    res=np.linalg.norm(Kff@sol-rhs)/max(1e-30,np.linalg.norm(rhs))
    print(f"relative residual {res:.3e}")
    if not np.isfinite(res) or res>1e-6:
        print("REFUSING: solve did not produce a usable residual."); return 3
    u=ud.copy(); u[free]=sol
    disp=np.linalg.norm(u.reshape(-1,6)[:,:3],axis=1)
    print(f"max |displacement| {disp[keep].max():.6g} mm   "
          f"(driven boundary max {np.abs(ud).max():.6g} mm)")
    worst=0.0; wa=None
    for (a,b,r) in elems:
        if not (keep[a] and keep[b]): continue
        T,L=transform(P[a],P[b])
        A=math.pi*r*r; Ii=math.pi*r**4/4.0; Jj=2*Ii
        fl=frame_k(L,E,G,A,Ii,Ii,Jj)@(T@np.concatenate([u[6*a:6*a+6],u[6*b:6*b+6]]))
        for (n_i,my,mz) in ((0,4,5),(6,10,11)):
            sgm=abs(fl[n_i])/A+math.sqrt(fl[my]**2+fl[mz]**2)*r/Ii
            if sgm>worst: worst,wa=sgm,(P[a],P[b],r)
    print(f"PEAK stress (axial+bending, beam theory): {worst:.6g} MPa")
    if wa: print(f"  worst strut: ({wa[0][0]:.1f},{wa[0][1]:.1f},{wa[0][2]:.1f}) -> "
                 f"({wa[1][0]:.1f},{wa[1][1]:.1f},{wa[1][2]:.1f})  r={wa[2]:.3f}")
    return 0

sys.exit(main())
