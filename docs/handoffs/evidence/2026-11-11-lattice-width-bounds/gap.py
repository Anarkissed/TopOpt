# The smallest distance between two struts that share no node, over a cell and its 26
# neighbours, for core's canonical strut cells (re-stated from core/src/fea/strut_cell.cpp).
import itertools, math
def d2(a,b): return sum((x-y)**2 for x,y in zip(a,b))
def fcc(S): h=S//2; return [(0,0,0),(h,h,0),(h,0,h),(0,h,h)]
def bcc(S): return [(0,0,0),(S//2,)*3]
def dia(S): q=S//4;h=S//2; return [(0,0,0),(h,h,0),(h,0,h),(0,h,h),(q,q,q),(q,3*q,3*q),(3*q,q,3*q),(3*q,3*q,q)]
def corner(p,S): return all(c%S==0 for c in p)
def pts(basis,S,R=1): return [tuple(n[i]+d[i]*S for i in range(3)) for d in itertools.product(range(-R,R+1),repeat=3) for n in basis]
def midin(a,b,S): return all(0<=a[i]+b[i]<2*S for i in range(3))
def from_pairs(basis,S,bond):
  P=pts(basis,S); out=set()
  for i in range(len(P)):
    for j in range(i+1,len(P)):
      if bond(P[i],P[j]) and midin(P[i],P[j],S): out.add(tuple(sorted((P[i],P[j]))))
  return sorted(out)
def trunc_oct():
  s=set()
  for perm in itertools.permutations((0,1,2)):
    for s1 in (-1,1):
      for s2 in (-1,1):
        s.add(tuple(0 if v==0 else (s1 if v==1 else 2*s2) for v in perm))
  return sorted(s)
def rhomb():
  v=[]
  for s in (-2,2): v+= [(s,0,0),(0,s,0),(0,0,s)]
  v+= list(itertools.product((-1,1),repeat=3)); return v
def from_poly(centres,S,verts,e2):
  out=set()
  for c in pts(centres,S):
    V=[tuple(c[i]+r[i] for i in range(3)) for r in verts]
    for i in range(len(V)):
      for j in range(i+1,len(V)):
        if d2(V[i],V[j])==e2 and midin(V[i],V[j],S): out.add(tuple(sorted((V[i],V[j]))))
  return sorted(out)
cells={
 'octet':(2,from_pairs(fcc(2),2,lambda a,b:d2(a,b)==2)),
 'sc':(2,from_pairs([(0,0,0)],2,lambda a,b:d2(a,b)==4)),
 'bcc':(2,from_pairs(bcc(2),2,lambda a,b:d2(a,b)==3)),
 'fcc':(2,from_pairs(fcc(2),2,lambda a,b:d2(a,b)==2 and corner(a,2)!=corner(b,2))),
 'diamond':(4,from_pairs(dia(4),4,lambda a,b:d2(a,b)==3)),
 'kelvin':(4,from_poly([(0,0,0),(2,2,2)],4,trunc_oct(),2)),
 'rhombic':(4,from_poly(fcc(4),4,rhomb(),3)),
}
def segdist(p0,p1,q0,q1):
  # exact: min over the unit square of a convex quadratic; check interior + 4 edges
  u=[p1[i]-p0[i] for i in range(3)]; v=[q1[i]-q0[i] for i in range(3)]; w=[p0[i]-q0[i] for i in range(3)]
  dot=lambda x,y:sum(a*b for a,b in zip(x,y))
  a,b,c,d,e=dot(u,u),dot(u,v),dot(v,v),dot(u,w),dot(v,w)
  def f(s,t): return math.sqrt(max(0.0,sum((w[i]+s*u[i]-t*v[i])**2 for i in range(3))))
  cand=[]
  den=a*c-b*b
  if den>1e-12:
    s=(b*e-c*d)/den; t=(a*e-b*d)/den
    if 0<=s<=1 and 0<=t<=1: cand.append(f(s,t))
  cl=lambda x:min(1,max(0,x))
  for s in (0,1):
    t=cl((b*s+e)/c); cand.append(f(s,t))
  for t in (0,1):
    s=cl((b*t-d)/a); cand.append(f(s,t))
  return min(cand)
for name,(S,st) in cells.items():
  base=[(tuple(x/S for x in a),tuple(x/S for x in b)) for a,b in st]
  best=1e9; pair=None
  for off in itertools.product((-1,0,1),repeat=3):
    for i,(a0,a1) in enumerate(base):
      for j,(b0,b1) in enumerate(base):
        if off==(0,0,0) and j<=i: continue
        B0=tuple(b0[k]+off[k] for k in range(3)); B1=tuple(b1[k]+off[k] for k in range(3))
        if any(d2(p,q)<1e-18 for p in (a0,a1) for q in (B0,B1)): continue
        g=segdist(a0,a1,B0,B1)
        if g>1e-9 and g<best-1e-12: best=g; pair=((a0,a1),(B0,B1))
  L=math.sqrt(d2(*base[0]))
  print(f"{name:8s} struts/cell {len(st):3d} strut length {L:.6f} L  touch gap {best:.6f} L  pair {pair}")

# ── F: the FACE VIEW. Seen square-on to a cell face, the smallest gap between two
# neighbouring PARALLEL struts of the front cell layer (depth 0..1), struts that run along
# the view axis being points there. Octet's ruled quilt, 1/(2 sqrt 2), is this number.
def face_view(S, st):
  base=[(tuple(x/S for x in a),tuple(x/S for x in b)) for a,b in st]
  best=(9,None)
  for ax in range(3):
    o=[k for k in range(3) if k!=ax]
    segs=[]
    for off in itertools.product((-1,0,1,2),repeat=3):
      for a,b in base:
        A=tuple(a[k]+off[k] for k in range(3)); B=tuple(b[k]+off[k] for k in range(3))
        if min(A[ax],B[ax])<-1e-9 or max(A[ax],B[ax])>1+1e-9: continue
        p=(A[o[0]],A[o[1]]); q=(B[o[0]],B[o[1]])
        if abs(p[0]-q[0])<1e-12 and abs(p[1]-q[1])<1e-12: continue   # along the view: a point
        if max(p[0],q[0])<-1 or min(p[0],q[0])>2 or max(p[1],q[1])<-1 or min(p[1],q[1])>2: continue
        segs.append((p,q))
    for i in range(len(segs)):
      (p0,p1)=segs[i]; u=(p1[0]-p0[0],p1[1]-p0[1]); lu=math.hypot(*u); u=(u[0]/lu,u[1]/lu)
      if not (0<=min(p0[0],p1[0])<=1 and 0<=min(p0[1],p1[1])<=1): continue
      for j in range(len(segs)):
        if i==j: continue
        (q0,q1)=segs[j]; v=(q1[0]-q0[0],q1[1]-q0[1]); lv=math.hypot(*v); v=(v[0]/lv,v[1]/lv)
        if abs(u[0]*v[1]-u[1]*v[0])>1e-9: continue                  # parallel only
        n=(-u[1],u[0]); g=abs((q0[0]-p0[0])*n[0]+(q0[1]-p0[1])*n[1])
        if g<1e-9: continue                                          # collinear
        s0=(q0[0]-p0[0])*u[0]+(q0[1]-p0[1])*u[1]; s1=(q1[0]-p0[0])*u[0]+(q1[1]-p0[1])*u[1]
        if max(s0,s1)<=1e-9 or min(s0,s1)>=lu-1e-9: continue         # must run alongside
        if g<best[0]-1e-12: best=(g,(ax,segs[i],segs[j]))
  return best
# W: the smallest WINDOW (a face of the cell's polyhedra: a closed loop of struts in one
# plane, no strut across it) closes when the strut reaches twice its inradius.
print()
for name,(S,st) in cells.items():
  f,why=face_view(S,st)
  print(f"{name:8s} face view {f:.6f} L   view axis {why[0]}  {why[1]} | {why[2]}")
