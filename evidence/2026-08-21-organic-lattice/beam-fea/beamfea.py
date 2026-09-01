#!/usr/bin/env python3
"""Beam FEA on the organic lattice.

Every polyline segment is one 3D frame element (12 DOF: 3 translation + 3 rotation
per node). This is the standard fast path for lattice FEA -- ~340x fewer DOF than
resolving the struts as solid voxels -- and it detects DISCONNECTION natively: a
component with no path to ground has a rigid-body mode, so the stiffness matrix is
singular there. That is the structural gate, done by the physics rather than by a
separate geometric check.
"""
import sys, math, numpy as np
from collections import defaultdict
import scipy.sparse as sp
import scipy.sparse.linalg as spl

WELD = 1e-6   # nodes closer than this are the same node

def load(path):
    segs, bcs, loads, grid = [], [], [], None
    with open(path) as f:
        for ln in f:
            t = ln.split()
            if not t: continue
            if t[0] == 'SEG':
                segs.append(tuple(float(x) for x in t[1:8]))
            elif t[0] == 'BC':
                bcs.append((float(t[1]),float(t[2]),float(t[3]),int(t[4]),float(t[5])))
            elif t[0] == 'LOAD':
                loads.append((float(t[1]),float(t[2]),float(t[3]),int(t[4]),float(t[5])))
            elif t[0] == 'GRID':
                grid = tuple(float(x) for x in t[1:5]) + tuple(int(x) for x in t[5:8])
    return segs, bcs, loads, grid

SHEAR_K = 0.9   # Timoshenko shear coefficient, circular section
def frame_k(L, E, G, A, Iy, Iz, J):
    """12x12 local stiffness of a 3D frame element (Timoshenko; EB via TOPOPT_BEAM=EB)."""
    import os
    k = np.zeros((12,12))
    a = E*A/L; k[0,0]=k[6,6]=a; k[0,6]=k[6,0]=-a
    t = G*J/L;  k[3,3]=k[9,9]=t; k[3,9]=k[9,3]=-t
    eb = os.environ.get('TOPOPT_BEAM','') == 'EB'
    for (I, i1, i2, i3, i4, sgn) in ((Iz,1,5,7,11,1.0), (Iy,2,4,8,10,-1.0)):
        phi = 0.0 if eb else 12.0*E*I/(G*SHEAR_K*A*L*L)
        c1 = 12*E*I/(L**3*(1+phi)); c2 = 6*E*I/(L**2*(1+phi))
        c3 = (4+phi)*E*I/(L*(1+phi)); c4 = (2-phi)*E*I/(L*(1+phi))
        k[i1,i1]=k[i3,i3]=c1;  k[i1,i3]=k[i3,i1]=-c1
        k[i2,i2]=k[i4,i4]=c3;  k[i2,i4]=k[i4,i2]=c4
        s = sgn*c2
        k[i1,i2]=k[i2,i1]=s;  k[i1,i4]=k[i4,i1]=s
        k[i3,i2]=k[i2,i3]=-s; k[i3,i4]=k[i4,i3]=-s
    return k

def transform(p0, p1):
    d = np.array(p1)-np.array(p0); L = np.linalg.norm(d)
    ex = d/L
    up = np.array([0.,0.,1.])
    if abs(ex@up) > 0.999: up = np.array([0.,1.,0.])
    ez = np.cross(ex, up); ez /= np.linalg.norm(ez)
    ey = np.cross(ez, ex)
    R = np.vstack([ex, ey, ez])
    T = np.zeros((12,12))
    for b in range(4): T[3*b:3*b+3, 3*b:3*b+3] = R
    return T, L

def main():
    path = sys.argv[1]
    E    = float(sys.argv[2]) if len(sys.argv)>2 else 2300.0   # MPa
    nu   = float(sys.argv[3]) if len(sys.argv)>3 else 0.35
    segs, bcs, loads, grid = load(path)
    G = E/(2*(1+nu))
    print(f"segments {len(segs):,}   BCs {len(bcs):,}   loads {len(loads):,}")

    # ── weld coincident endpoints into shared nodes ─────────────────────────
    key = lambda p: (round(p[0]/WELD), round(p[1]/WELD), round(p[2]/WELD))
    nid, pts = {}, []
    def node(p):
        k = key(p)
        if k not in nid:
            nid[k] = len(pts); pts.append(p)
        return nid[k]
    elems = []
    for (x1,y1,z1,x2,y2,z2,r) in segs:
        a, b = node((x1,y1,z1)), node((x2,y2,z2))
        if a != b: elems.append((a,b,r))
    pts = np.array(pts)
    # ── CONTACT WELD ────────────────────────────────────────────────────────
    # Welding on exact coincidence leaves the lattice as loose threads that pass
    # THROUGH each other: two curves that cross in space essentially never share a
    # polyline vertex. Measured on the 3 mm lattice: 454 of 111,909 nodes had degree
    # > 2, i.e. 5,445 disconnected chains, while 157,313 node pairs sat within r+r.
    # In the printed part those struts overlap and are fused, so they must share a
    # node here. Consecutive nodes on ONE curve are closer than r+r, so the merge is
    # restricted to nodes from DIFFERENT chains or a naive merge collapses the curves.
    from scipy.spatial import cKDTree as _KD
    import collections as _c
    chain = list(range(len(pts)))
    def _f(x):
        while chain[x] != x: chain[x] = chain[chain[x]]; x = chain[x]
        return x
    for (a,b,r) in elems:
        ra, rb = _f(a), _f(b)
        if ra != rb: chain[max(ra,rb)] = min(ra,rb)
    chain_of = np.array([_f(i) for i in range(len(pts))])
    nchain = len(set(chain_of.tolist()))
    rad = np.zeros(len(pts))
    for (a,b,r) in elems: rad[a]=max(rad[a],r); rad[b]=max(rad[b],r)
    merge = list(range(len(pts)))
    def _fm(x):
        while merge[x] != x: merge[x] = merge[merge[x]]; x = merge[x]
        return x
    tree0 = _KD(pts)
    welded = 0
    for (i,j) in tree0.query_pairs(r=float(rad.max()*2.0), output_type='ndarray'):
        if chain_of[i] == chain_of[j]: continue          # same curve: never merge
        if np.linalg.norm(pts[i]-pts[j]) > rad[i]+rad[j]: continue
        a, b = _fm(i), _fm(j)
        if a != b: merge[max(a,b)] = min(a,b); welded += 1
    remap = {}
    for i in range(len(pts)):
        r0 = _fm(i)
        if r0 not in remap: remap[r0] = len(remap)
    newid = np.array([remap[_fm(i)] for i in range(len(pts))])
    newpts = np.zeros((len(remap),3)); cnt = np.zeros(len(remap))
    for i in range(len(pts)):
        newpts[newid[i]] += pts[i]; cnt[newid[i]] += 1
    newpts /= cnt[:,None]
    elems = [(newid[a], newid[b], r) for (a,b,r) in elems if newid[a] != newid[b]]
    print(f"contact weld: {nchain:,} chains -> merged {welded:,} touching pairs; "
          f"nodes {len(pts):,} -> {len(remap):,}")
    pts = newpts
    N = len(pts); ND = 6*N
    print(f"nodes {N:,}   elements {len(elems):,}   DOF {ND:,}")

    # ── assemble ────────────────────────────────────────────────────────────
    I_, J_, V_ = [], [], []
    for (a,b,r) in elems:
        A = math.pi*r*r; Ii = math.pi*r**4/4.0; Jj = 2*Ii
        T, L = transform(pts[a], pts[b])
        ke = T.T @ frame_k(L,E,G,A,Ii,Ii,Jj) @ T
        dofs = [6*a+i for i in range(6)] + [6*b+i for i in range(6)]
        for ii,di in enumerate(dofs):
            for jj,dj in enumerate(dofs):
                if ke[ii,jj] != 0.0:
                    I_.append(di); J_.append(dj); V_.append(ke[ii,jj])
    K = sp.coo_matrix((V_,(I_,J_)), shape=(ND,ND)).tocsr()

    # ── connectivity: which nodes reach a support? ──────────────────────────
    adj = defaultdict(list)
    for (a,b,r) in elems: adj[a].append(b); adj[b].append(a)
    # snap BCs / loads to the nearest lattice node within one grid spacing
    spacing = grid[3] if grid else 1.0
    from scipy.spatial import cKDTree
    tree = cKDTree(pts)
    def snap(items):
        out = defaultdict(list)
        for (x,y,z,c,v) in items:
            dist, i = tree.query([x,y,z])
            if dist <= spacing: out[i].append((c,v))
        return out
    bc_n, ld_n = snap(bcs), snap(loads)
    print(f"BC nodes matched {len(bc_n):,}   load nodes matched {len(ld_n):,}")
    if not bc_n or not ld_n:
        print("REFUSING: supports or loads did not land on the lattice."); return 2

    seen=set(); stack=list(bc_n)
    seen.update(stack)
    while stack:
        n=stack.pop()
        for m in adj[n]:
            if m not in seen: seen.add(m); stack.append(m)
    grounded = len(seen)
    print(f"CONNECTIVITY: {grounded:,} of {N:,} nodes reach a support "
          f"({100.0*grounded/N:.2f}%)  -- {N-grounded:,} nodes carry NO load")
    loaded_ok = sum(1 for i in ld_n if i in seen)
    print(f"  load nodes with a path to ground: {loaded_ok} of {len(ld_n)}")

    # ── solve on the GROUNDED set only (the rest is provably load-free) ─────
    keep = np.zeros(N, bool); keep[list(seen)] = True
    dof_keep = np.repeat(keep, 6)
    fixed = np.zeros(ND, bool)
    for i,cv in bc_n.items():
        for (c,v) in cv: fixed[6*i+c] = True
        for c in range(3,6): fixed[6*i+c] = True      # clamp rotations at supports
    free = dof_keep & ~fixed
    f = np.zeros(ND)
    for i,cv in ld_n.items():
        for (c,v) in cv: f[6*i+c] += v
    print(f"free DOF {int(free.sum()):,}   applied load {np.abs(f).sum():.4g} N")
    Kff = K[free][:,free].tocsr()
    rhs = f[free]
    u = np.zeros(ND)
    # ── CONDITIONING ────────────────────────────────────────────────────────
    # A frame system mixes translational and ROTATIONAL dof, whose diagonal entries
    # differ by orders of magnitude (EA/L vs EI/L), so unpreconditioned CG stalls:
    # measured info=20000 (iteration cap) on 415k dof. Jacobi normalises exactly that
    # scale difference. A sparse DIRECT factorisation is the fallback -- at this size
    # it is affordable, and it either returns the answer or fails loudly.
    dg = Kff.diagonal().copy()
    dg[dg <= 0] = 1.0
    Minv = sp.diags(1.0/dg)
    sol, info = spl.cg(Kff, rhs, rtol=1e-10, maxiter=200000, M=Minv)
    if info != 0:
        print(f"Jacobi-CG did NOT converge (info={info}) -- falling back to sparse direct")
        try:
            sol = spl.spsolve(Kff, rhs)
            res = np.linalg.norm(Kff @ sol - rhs)/max(1e-30, np.linalg.norm(rhs))
            print(f"sparse direct: relative residual {res:.3e}")
            if not np.isfinite(res) or res > 1e-6:
                print("REFUSING: direct solve did not produce a usable residual."); return 3
            info = 0
        except Exception as ex:
            print(f"REFUSING: direct solve failed ({ex})."); return 3
    else:
        res = np.linalg.norm(Kff @ sol - rhs)/max(1e-30, np.linalg.norm(rhs))
        print(f"Jacobi-CG converged; relative residual {res:.3e}")
    u[free] = sol
    disp = np.linalg.norm(u.reshape(-1,6)[:,:3], axis=1)
    d_on = disp[keep]
    print(f"max |displacement| {disp.max():.6g} mm")
    print("  displacement distribution over grounded nodes (mm): "
          f"median {np.median(d_on):.4g}  p90 {np.percentile(d_on,90):.4g}  "
          f"p99 {np.percentile(d_on,99):.4g}  max {d_on.max():.4g}")
    # a MECHANISM shows as a few nodes far above the bulk; a floppy STRUCTURE moves
    # together. Degree-1 nodes are free ends and can flap without carrying anything.
    import collections as _cc
    dg = _cc.Counter()
    for (a,b,r) in elems: dg[a]+=1; dg[b]+=1
    top = np.argsort(-disp)[:20]
    n_deg1 = sum(1 for i in top if dg[i] <= 1)
    print(f"  of the 20 most-displaced nodes, {n_deg1} are FREE ENDS (degree <= 1)")
    frac = float((d_on > 0.1*d_on.max()).sum())/max(1,len(d_on))
    print(f"  fraction of grounded nodes above 10% of the max: {100*frac:.2f}%"
          f"   ({'MECHANISM: a few nodes flapping' if frac < 0.02 else 'the structure moves as a whole'})")

    # ── axial + bending stress per element ─────────────────────────────────
    # END FORCES from the element's OWN stiffness -- f_local = k_local @ u_local.
    # Deriving the moment from end ROTATIONS alone drops the transverse-displacement
    # terms and overstates the stress by orders of magnitude (measured: 150x on a
    # cantilever whose DISPLACEMENT was exact -- which is why the control matters).
    worst = 0.0; worst_at = None
    for (a,b,r) in elems:
        if not (keep[a] and keep[b]): continue
        T, L = transform(pts[a], pts[b])
        A = math.pi*r*r; Ii = math.pi*r**4/4.0; Jj = 2*Ii
        ue = np.concatenate([u[6*a:6*a+6], u[6*b:6*b+6]])
        fl = frame_k(L,E,G,A,Ii,Ii,Jj) @ (T @ ue)
        for (n_i, my_i, mz_i) in ((0,4,5), (6,10,11)):
            axial = abs(fl[n_i])/A
            bend  = math.sqrt(fl[my_i]**2 + fl[mz_i]**2)*r/Ii
            sigma = axial + bend
            if sigma > worst: worst, worst_at = sigma, (pts[a], pts[b], r)
    print(f"PEAK stress (axial+bending, beam theory): {worst:.6g} MPa")
    if worst_at is not None:
        p0,p1,r = worst_at
        print(f"  worst strut: ({p0[0]:.1f},{p0[1]:.1f},{p0[2]:.1f}) -> "
              f"({p1[0]:.1f},{p1[1]:.1f},{p1[2]:.1f})  r={r:.3f} mm")
    return 0

if __name__ == '__main__':
    sys.exit(main())
