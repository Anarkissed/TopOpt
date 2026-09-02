#!/usr/bin/env python3
"""HYBRID FE: solid hex elements for the part, beam elements for the lattice.

Why this and not the submodel: the submodel had to be DRIVEN by a global field taken
from a solve where the lattice region was still solid (too stiff), and its cut-boundary
rotations had to be clamped (also too stiff). Both are modelling errors that do not
shrink with refinement. The hybrid has neither -- the real supports and the real loads
are applied, the solid carries what it carries, and the lattice carries the rest.

It also avoids homogenisation entirely, which matters: De Biasi et al. (Mater. Des. 255,
2025) measured homogenised lattice models at >15% error in the BEST case and >50% in
many, and blind to topology-induced stress concentration.

COUPLING. Hex nodes have 3 dof (translation); beam nodes have 6 (translation +
rotation). A beam node inside a solid element has its 3 TRANSLATIONS tied to the
trilinear interpolation of that element's 8 corners, and its rotations left FREE. That
is a pinned embedment: it transmits force, not moment. It is the SOFT choice -- a real
strut embedded in plastic does carry some moment -- so it errs toward more lattice
deflection and more lattice stress, i.e. conservative for a margin.
"""
import sys, math, os, collections
import numpy as np, scipy.sparse as sp, scipy.sparse.linalg as spl
from scipy.spatial import cKDTree

SHEAR_K=0.9
def frame_k(L,E,G,A,Iy,Iz,J,eb=False):
    k=np.zeros((12,12))
    a=E*A/L; k[0,0]=k[6,6]=a; k[0,6]=k[6,0]=-a
    t=G*J/L;  k[3,3]=k[9,9]=t; k[3,9]=k[9,3]=-t
    for (I,i1,i2,i3,i4,sg) in ((Iz,1,5,7,11,1.0),(Iy,2,4,8,10,-1.0)):
        phi=0.0 if eb else 12.0*E*I/(G*SHEAR_K*A*L*L)
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

def hex8_K(h,E,nu):
    """24x24 trilinear hex stiffness, 2x2x2 Gauss."""
    c=E/((1+nu)*(1-2*nu))
    D=np.array([[c*(1-nu),c*nu,c*nu,0,0,0],[c*nu,c*(1-nu),c*nu,0,0,0],
                [c*nu,c*nu,c*(1-nu),0,0,0],[0,0,0,E/(2*(1+nu)),0,0],
                [0,0,0,0,E/(2*(1+nu)),0],[0,0,0,0,0,E/(2*(1+nu))]])
    g=1/math.sqrt(3); N=[(-1,-1,-1),(1,-1,-1),(1,1,-1),(-1,1,-1),
                         (-1,-1,1),(1,-1,1),(1,1,1),(-1,1,1)]
    K=np.zeros((24,24))
    for gx in (-g,g):
        for gy in (-g,g):
            for gz in (-g,g):
                dN=np.zeros((3,8))
                for a,(xi,et,ze) in enumerate(N):
                    dN[0,a]=xi*(1+et*gy)*(1+ze*gz)/8
                    dN[1,a]=et*(1+xi*gx)*(1+ze*gz)/8
                    dN[2,a]=ze*(1+xi*gx)*(1+et*gy)/8
                dN=dN*(2.0/h)                       # J = h/2 * I
                B=np.zeros((6,24))
                for a in range(8):
                    B[0,3*a]=dN[0,a]; B[1,3*a+1]=dN[1,a]; B[2,3*a+2]=dN[2,a]
                    B[3,3*a]=dN[1,a]; B[3,3*a+1]=dN[0,a]
                    B[4,3*a+1]=dN[2,a]; B[4,3*a+2]=dN[1,a]
                    B[5,3*a]=dN[2,a];  B[5,3*a+2]=dN[0,a]
                K+=B.T@D@B*(h/2)**3
    return K

def main():
    beam=sys.argv[1]; E=float(sys.argv[2]); nu=float(sys.argv[3]); G=E/(2*(1+nu))
    segs=[]; bcs=[]; loads=[]; grid=None
    for ln in open(beam):
        t=ln.split()
        if not t: continue
        if t[0]=='SEG':
            v=[float(x) for x in t[1:8]]; segs.append(v)
        elif t[0]=='BC':  bcs.append((float(t[1]),float(t[2]),float(t[3]),int(t[4]),float(t[5])))
        elif t[0]=='LOAD':loads.append((float(t[1]),float(t[2]),float(t[3]),int(t[4]),float(t[5])))
        elif t[0]=='GRID':grid=tuple(float(x) for x in t[1:5])+tuple(int(x) for x in t[5:8])
    ox,oy,oz,h,nx,ny,nz=grid; NX,NY,NZ=nx+1,ny+1,nz+1
    mk=np.fromfile(beam+'.mask',dtype=np.uint8)
    if mk.size!=nx*ny*nz: print(f"REFUSING: mask {mk.size} != {nx*ny*nz}"); return 2
    mk=mk.reshape(nz,ny,nx)
    solid=(mk&1).astype(bool); inreg=(mk&2).astype(bool)
    hexmask=solid&~inreg                       # hex where solid AND outside the region
    print(f"grid {nx}x{ny}x{nz}  solid {solid.sum():,}  in-region {(solid&inreg).sum():,}  "
          f"HEX elements {hexmask.sum():,}")

    # ── solid nodes: number only those a hex element touches ────────────────
    nid=-np.ones((NZ,NY,NX),dtype=np.int64)
    kk,jj,ii=np.nonzero(hexmask)
    for dk in (0,1):
        for dj in (0,1):
            for di in (0,1): nid[kk+dk,jj+dj,ii+di]=0
    used=np.nonzero(nid.ravel()==0)[0]
    nid.ravel()[used]=np.arange(len(used))
    NS=len(used)
    print(f"solid nodes {NS:,}  ({3*NS:,} dof)")

    # ── beam nodes, contact-welded ──────────────────────────────────────────
    key={}; pts=[]
    def gid(p):
        k=(round(p[0]/1e-6),round(p[1]/1e-6),round(p[2]/1e-6))
        if k not in key: key[k]=len(pts); pts.append(p)
        return key[k]
    el=[]
    for v in segs:
        a,b=gid(tuple(v[0:3])),gid(tuple(v[3:6]))
        if a!=b: el.append((a,b,v[6]))
    pts=np.array(pts)
    ch=list(range(len(pts)))
    def f(x):
        while ch[x]!=x: ch[x]=ch[ch[x]]; x=ch[x]
        return x
    for a,b,r in el:
        ra,rb=f(a),f(b)
        if ra!=rb: ch[max(ra,rb)]=min(ra,rb)
    cid=np.array([f(i) for i in range(len(pts))])
    rad=np.zeros(len(pts))
    for a,b,r in el: rad[a]=max(rad[a],r); rad[b]=max(rad[b],r)
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
    NB=len(remap); P=np.zeros((NB,3)); C=np.zeros(NB)
    for i in range(len(pts)): P[new[i]]+=pts[i]; C[new[i]]+=1
    P/=C[:,None]
    el=[(new[a],new[b],r) for (a,b,r) in el if new[a]!=new[b]]
    el=[(a,b,r) for (a,b,r) in el if np.linalg.norm(P[a]-P[b])>1e-9]
    print(f"beam nodes {NB:,}  elements {len(el):,}  ({6*NB:,} dof)")

    # dof layout: [solid 3*NS][beam 6*NB]
    SB=3*NS; ND=SB+6*NB
    I_,J_,V_=[],[],[]
    Kh=hex8_K(h,E,nu)
    for (k0,j0,i0) in zip(kk,jj,ii):
        n8=[nid[k0+dk,j0+dj,i0+di] for dk in (0,1) for dj in (0,1) for di in (0,1)]
        # trilinear corner order must match hex8_K's N ordering
        order=[0,1,3,2,4,5,7,6]
        n8=[n8[o] for o in order]
        dofs=[3*n+c for n in n8 for c in range(3)]
        for a,da in enumerate(dofs):
            row=Kh[a]
            for b,db in enumerate(dofs):
                if row[b]!=0.0: I_.append(da); J_.append(db); V_.append(row[b])
    print(f"  hex assembled: {len(V_):,} entries")
    for (a,b,r) in el:
        A=math.pi*r*r; Ii=math.pi*r**4/4.0; Jj=2*Ii
        T,L=transform(P[a],P[b])
        ke=T.T@frame_k(L,E,G,A,Ii,Ii,Jj)@T
        dofs=[SB+6*a+c for c in range(6)]+[SB+6*b+c for c in range(6)]
        for x,dx in enumerate(dofs):
            for y,dy in enumerate(dofs):
                if ke[x,y]!=0.0: I_.append(dx); J_.append(dy); V_.append(ke[x,y])
    K=sp.coo_matrix((V_,(I_,J_)),shape=(ND,ND)).tocsr()
    print(f"  total {K.nnz:,} nnz, {ND:,} dof")
    # ── COUPLING: tie each beam node's TRANSLATIONS to the hex it sits in ────
    # Rotations stay free (a pinned embedment: force, not moment). That is the SOFT
    # choice and therefore conservative for a stress margin.
    rows=[];cols=[];vals=[];tied=0
    Nord=[(-1,-1,-1),(1,-1,-1),(1,1,-1),(-1,1,-1),(-1,-1,1),(1,-1,1),(1,1,1),(-1,1,1)]
    slave=np.zeros(ND,bool)
    # The lattice sits in a REGION with no hex elements, so "strictly inside a hex"
    # coupled only 0.75% of nodes -- the lattice hung off 166 points, which is both
    # physically wrong (it is bonded all round its boundary, including to the solid
    # rim) and a near-mechanism the solver could not resolve. A strut is bonded to the
    # solid wherever it TOUCHES it, so search the 3x3x3 neighbourhood and tie to the
    # nearest hex element, clamping the local coordinates onto that element.
    hk,hj,hi=np.nonzero(hexmask)
    hcen=np.stack([ox+(hi+0.5)*h, oy+(hj+0.5)*h, oz+(hk+0.5)*h],1)
    htree=cKDTree(hcen)
    for b in range(NB):
        d0,hidx=htree.query(P[b])
        if d0 > 1.5*h: continue                 # too far from any solid to be bonded
        k0,j0,i0=int(hk[hidx]),int(hj[hidx]),int(hi[hidx])
        gx=(P[b,0]-ox)/h; gy=(P[b,1]-oy)/h; gz=(P[b,2]-oz)/h
        fx=min(1.0,max(0.0,gx-i0)); fy=min(1.0,max(0.0,gy-j0)); fz=min(1.0,max(0.0,gz-k0))
        n8=[nid[k0+dk,j0+dj,i0+di] for dk in (0,1) for dj in (0,1) for di in (0,1)]
        n8=[n8[o] for o in [0,1,3,2,4,5,7,6]]
        if min(n8)<0: continue
        w=[]
        for (xi,et,ze) in Nord:
            w.append(((fx if xi>0 else 1-fx)*(fy if et>0 else 1-fy)*(fz if ze>0 else 1-fz)))
        for c in range(3):
            sd=SB+6*b+c
            slave[sd]=True
            for a in range(8):
                if w[a]!=0.0: rows.append(sd); cols.append(3*n8[a]+c); vals.append(w[a])
        tied+=1
    print(f"COUPLING: {tied:,} of {NB:,} beam nodes embedded in solid elements "
          f"({100.0*tied/NB:.2f}%)")
    # T maps master dof -> all dof
    master=~slave
    midx=np.flatnonzero(master); mpos=-np.ones(ND,np.int64); mpos[midx]=np.arange(len(midx))
    Ti=list(midx); Tj=list(range(len(midx))); Tv=[1.0]*len(midx)
    for r,c,v in zip(rows,cols,vals):
        if mpos[c]<0: continue
        Ti.append(r); Tj.append(mpos[c]); Tv.append(v)
    T=sp.coo_matrix((Tv,(Ti,Tj)),shape=(ND,len(midx))).tocsr()
    Kr=(T.T@K@T).tocsr()
    print(f"  reduced: {Kr.shape[0]:,} dof, {Kr.nnz:,} nnz")

    # ── BCs and loads on the SOLID nodes ────────────────────────────────────
    fixed=np.zeros(len(midx),bool); F=np.zeros(len(midx))
    nbc=0
    for (x,y,z,c,v) in bcs:
        i=int(round((x-ox)/h)); j=int(round((y-oy)/h)); k=int(round((z-oz)/h))
        if not (0<=i<NX and 0<=j<NY and 0<=k<NZ): continue
        n=nid[k,j,i]
        if n<0: continue
        d=mpos[3*n+c]
        if d>=0: fixed[d]=True; nbc+=1
    nld=0; ftot=0.0
    for (x,y,z,c,v) in loads:
        i=int(round((x-ox)/h)); j=int(round((y-oy)/h)); k=int(round((z-oz)/h))
        if not (0<=i<NX and 0<=j<NY and 0<=k<NZ): continue
        n=nid[k,j,i]
        if n<0: continue
        d=mpos[3*n+c]
        if d>=0: F[d]+=v; nld+=1; ftot+=abs(v)
    print(f"BCs applied {nbc:,} dof   loads applied {nld:,} dof, |F| = {ftot:.4g} N")
    if nbc==0 or nld==0:
        print("REFUSING: supports or loads did not land on the solid mesh."); return 3
    # ── DROP WHAT CANNOT REACH GROUND ───────────────────────────────────────
    # 85.9% of beam nodes tie to no solid. Any lattice not connected THROUGH a tied
    # node is free-floating: a rigid-body mode, and the matrix comes back exactly
    # singular. Keep only the beam nodes with a path to a coupled node; the rest carry
    # no load by definition, exactly as the submodel's connectivity pass established.
    adj=collections.defaultdict(list)
    for (a,b,r) in el: adj[a].append(b); adj[b].append(a)
    seedb=[b for b in range(NB) if slave[SB+6*b]]
    seen=set(seedb); stack=list(seedb)
    while stack:
        n=stack.pop()
        for m in adj[n]:
            if m not in seen: seen.add(m); stack.append(m)
    print(f"LATTICE CONNECTIVITY: {len(seen):,} of {NB:,} beam nodes reach the solid "
          f"({100.0*len(seen)/NB:.2f}%)  -- {NB-len(seen):,} orphaned, carry NO load")
    # ── AND THE SAME FOR THE SOLID ──────────────────────────────────────────
    # The part can contain hex islands with no path to a support (the STL is one body
    # only after the lattice is added; the solid alone need not be). Those are rigid
    # bodies too, and they keep the matrix singular however well the lattice is filtered.
    sp_par=list(range(NS))
    def sf(x):
        while sp_par[x]!=x: sp_par[x]=sp_par[sp_par[x]]; x=sp_par[x]
        return x
    for (k0,j0,i0) in zip(kk,jj,ii):
        n8=[nid[k0+dk,j0+dj,i0+di] for dk in (0,1) for dj in (0,1) for di in (0,1)]
        r0=sf(int(n8[0]))
        for n in n8[1:]:
            rn=sf(int(n))
            if rn!=r0:
                sp_par[max(rn,r0)]=min(rn,r0); r0=sf(r0)
    bcnodes=set()
    for (x,y,z,c,v) in bcs:
        i=int(round((x-ox)/h)); j=int(round((y-oy)/h)); k=int(round((z-oz)/h))
        if 0<=i<NX and 0<=j<NY and 0<=k<NZ and nid[k,j,i]>=0: bcnodes.add(int(nid[k,j,i]))
    grounded_roots={sf(n) for n in bcnodes}
    solid_live=np.array([sf(n) in grounded_roots for n in range(NS)])
    print(f"SOLID CONNECTIVITY: {int(solid_live.sum()):,} of {NS:,} solid nodes reach a "
          f"support ({100.0*solid_live.sum()/NS:.2f}%)")
    live=np.ones(ND,bool)
    for b in range(NB):
        if b not in seen: live[SB+6*b:SB+6*b+6]=False
    for n in range(NS):
        if not solid_live[n]: live[3*n:3*n+3]=False
    livem=live[midx]
    # a master dof with no stiffness at all cannot be solved for either
    free=(~fixed)&livem
    Kf0=Kr[free][:,free].tocsr()
    d0=Kf0.diagonal()
    if (d0<=0).any():
        rel=np.flatnonzero(free)[d0<=0]
        print(f"  releasing {len(rel):,} master dof with zero diagonal stiffness")
        free[rel]=False
    print(f"  solving {int(free.sum()):,} dof")
    Kff=Kr[free][:,free].tocsr()
    # ── WHERE IS THE SINGULARITY? Stop guessing: components of the free-dof graph.
    # Every component must contain a constrained dof or it is a free-floating body.
    from scipy.sparse.csgraph import connected_components as _cc
    ncomp,lab=_cc(Kff,directed=False)
    print(f"  DOF-GRAPH: {ncomp} connected component(s) among the free dof")
    if ncomp>1:
        import collections as _c
        sz=_c.Counter(lab.tolist())
        big=sz.most_common(1)[0]
        print(f"    largest {big[1]:,} dof; {ncomp-1} others totalling "
              f"{int(free.sum())-big[1]:,} dof  -> these float")
        fi=np.flatnonzero(free)
        # which kind of dof are the floaters?
        others=np.flatnonzero(lab!=big[0])
        gl=fi[others]                      # indices into the master vector
        gfull=midx[gl]                     # indices into the FULL dof vector
        nb=int((gfull>=SB).sum()); ns_=int((gfull<SB).sum())
        print(f"    floaters: {ns_:,} SOLID dof, {nb:,} BEAM dof")
        if nb:
            rot=int(((gfull>=SB)&(((gfull-SB)%6)>=3)).sum())
            print(f"      of the beam floaters, {rot:,} are ROTATIONAL dof")
        print(f"    -> restricting the solve to the largest component")
        keepc=np.zeros(len(free),bool); keepc[fi[lab==big[0]]]=True
        free=keepc
        Kff=Kr[free][:,free].tocsr()
        print(f"  solving {int(free.sum()):,} dof after restriction")
    dg=Kff.diagonal().copy(); dg[dg<=0]=1.0
    sol,info=spl.cg(Kff,F[free],rtol=1e-10,maxiter=20000,M=sp.diags(1.0/dg))
    if info!=0:
        # A mixed solid+beam system is badly conditioned: hex stiffness scales as E*h
        # (thousands) while beam bending goes as EI/L^3 with I ~ 0.05 mm^4. Jacobi only
        # normalises the diagonal and leaves that coupling. Incomplete LU captures it.
        print(f"  Jacobi-CG stalled (info={info}); trying ILU-preconditioned CG")
        try:
            ilu=spl.spilu(Kff.tocsc(),drop_tol=1e-5,fill_factor=20)
            M2=spl.LinearOperator(Kff.shape,ilu.solve)
            sol,info=spl.cg(Kff,F[free],rtol=1e-10,maxiter=5000,M=M2)
            print(f"  ILU-CG info={info}")
        except Exception as ex:
            print(f"  ILU failed ({ex}); trying sparse direct")
            info=1
        if info!=0:
            try:
                sol=spl.spsolve(Kff.tocsc(),F[free]); info=0
                print("  sparse direct completed")
            except Exception as ex:
                print(f"REFUSING: no solver converged ({ex})."); return 3
    res=np.linalg.norm(Kff@sol-F[free])/max(1e-30,np.linalg.norm(F[free]))
    print(f"relative residual {res:.3e}")
    if not np.isfinite(res) or res>1e-6:
        print("REFUSING: unusable residual."); return 3
    um=np.zeros(len(midx)); um[free]=sol
    u=T@um
    ub=u[SB:].reshape(-1,6)
    print(f"max |solid displacement| {np.abs(u[:SB]).max():.6g} mm")
    if os.environ.get('TOPOPT_HYBRID_DIAG'):
        # the axial extension of the TOP face -- the quantity PL/(AE) predicts
        us=u[:SB].reshape(-1,3)
        top=[]; 
        for kz in range(NZ-1,-1,-1):
            idx=[nid[kz,jy,ix] for jy in range(NY) for ix in range(NX) if nid[kz,jy,ix]>=0]
            if idx: top=idx; break
        uz=np.array([us[n,2] for n in top])
        ux=np.array([us[n,0] for n in top])
        print(f"  DIAG top face: {len(top)} nodes  mean uz {uz.mean():.6e}  "
              f"min {uz.min():.6e}  max {uz.max():.6e}")
        print(f"  DIAG top face: mean |ux| {np.abs(ux).mean():.6e} (Poisson contraction)")
    print(f"max |lattice displacement| {np.linalg.norm(ub[:,:3],axis=1).max():.6g} mm")
    worst=0.0; wa=None
    for (a,b,r) in el:
        A=math.pi*r*r; Ii=math.pi*r**4/4.0; Jj=2*Ii
        Tm,L=transform(P[a],P[b])
        fl=frame_k(L,E,G,A,Ii,Ii,Jj)@(Tm@np.concatenate([u[SB+6*a:SB+6*a+6],u[SB+6*b:SB+6*b+6]]))
        for (ni,my,mz) in ((0,4,5),(6,10,11)):
            sg=abs(fl[ni])/A+math.sqrt(fl[my]**2+fl[mz]**2)*r/Ii
            if sg>worst: worst,wa=sg,(P[a],P[b],r,L)
    print(f"PEAK LATTICE STRESS: {worst:.6g} MPa")
    if wa: print(f"  worst strut L={wa[3]:.3f} mm r={wa[2]:.3f} (L/r={wa[3]/wa[2]:.2f}, "
                 f"chi={2.25*(wa[2]/wa[3])**2:.3f})")
    return 0

if __name__=='__main__':
    r=main()
    print("assembly complete" if not isinstance(r,int) else f"exit {r}")
