# Sheets: the wall (core's tpms.hpp: |f|/|grad f| <= t/2, period L = 1) at which the
# channels CLOSE -- walls facing across a channel meet at its narrowest throat, so the
# void on that side stops running through the part. Bisected on the void's percolation
# (a component spanning a 3x3x3 tiling along x). Then the TRUE normal wall at that t,
# the way core's tables measure it (march along the normal from the zero set).
import numpy as np, math, sys
from scipy import ndimage
def field(kind, x, y, z):
  a=2*np.pi; sx,cx=np.sin(a*x),np.cos(a*x); sy,cy=np.sin(a*y),np.cos(a*y); sz,cz=np.sin(a*z),np.cos(a*z)
  if kind=='gyroid':
    f=sx*cy+sy*cz+sz*cx
    gx=a*(cx*cy-sz*sx); gy=a*(-sx*sy+cy*cz); gz=a*(-sy*sz+cz*cx)
  else:
    f=sx*sy*sz+sx*cy*cz+cx*sy*cz+cx*cy*sz
    gx=a*(cx*sy*sz+cx*cy*cz-sx*sy*cz-sx*cy*sz)
    gy=a*(sx*cy*sz-sx*sy*cz+cx*cy*cz-cx*sy*sz)
    gz=a*(sx*sy*cz-sx*cy*sz-cx*sy*sz+cx*cy*cz)
  return f,gx,gy,gz
def grid(kind,N,T):
  u=(np.arange(N*T)+0.5)/N
  X,Y,Z=np.meshgrid(u,u,u,indexing='ij')
  f,gx,gy,gz=field(kind,X,Y,Z)
  g=np.abs(f)/np.maximum(np.sqrt(gx*gx+gy*gy+gz*gz),1e-12)
  return f,g
def spans(mask):
  lab,n=ndimage.label(mask)
  a=set(np.unique(lab[0]))-{0}; b=set(np.unique(lab[-1]))-{0}
  return len(a&b)>0
def critical(kind,N,T=3):
  f,g=grid(kind,N,T)
  lo,hi=0.0,1.0     # t in L units; t=0 -> open
  for side in (1,):
    pos=f>0
    for _ in range(30):
      mid=0.5*(lo+hi)
      if spans(pos & (g>mid/2)): lo=mid
      else: hi=mid
  # solid fraction at t (one cell)
  f1,g1=grid(kind,N,1)
  rho=float(np.mean(g1<=0.5*lo))
  return lo,hi,rho
def true_wall(kind,t,n=4000,seed=1):
  rng=np.random.default_rng(seed); out=[]
  def ev(p):
    f,gx,gy,gz=field(kind,p[0],p[1],p[2]); g=np.array([gx,gy,gz]); return f,g
  while len(out)<n:
    p=rng.random(3)
    for _ in range(30):
      f,g=ev(p); gg=g@g
      if gg<1e-9: break
      p=p-f*g/gg
      if abs(f)<1e-12: break
    f,g=ev(p)
    if abs(f)>1e-9 or g@g<1e-6: continue
    nrm=g/np.linalg.norm(g); tot=0.0; ok=True
    for s in (1,-1):
      # march until |f|/|grad f| = t/2 (bisection on the first crossing)
      d=0.0; step=t/200; prev=0.0
      while True:
        d+=step
        if d>1.0: ok=False; break
        fq,gq=ev(p+s*d*nrm); val=abs(fq)/max(np.linalg.norm(gq),1e-12)-t/2
        if val>=0: break
      if not ok: break
      a_,b_=d-step,d
      for _ in range(40):
        m=0.5*(a_+b_); fq,gq=ev(p+s*m*nrm)
        if abs(fq)/max(np.linalg.norm(gq),1e-12)-t/2>=0: b_=m
        else: a_=m
      tot+=0.5*(a_+b_)
    if ok: out.append(tot)
  out=np.array(out); return float(np.median(out)),float(out.min()),float(out.max())
for kind in ('gyroid','schwarzd'):
  for N in (48,64):
    lo,hi,rho=critical(kind,N)
    print(f"{kind} N{N}: channels close at field t {lo:.5f}..{hi:.5f} L (solid fraction {rho:.4f})",flush=True)
  tc=0.5*(lo+hi)
  med,mn,mx=true_wall(kind,tc,1500)
  print(f"{kind}: true normal wall at that t: median {med:.5f} L (min {mn:.5f}, max {mx:.5f})",flush=True)
  # check the march against core's table: rho 0.20 row, gyroid param 0.26453/4, true 0.26028/4
  chk={'gyroid':(0.26453/4,0.26028/4),'schwarzd':(0.21297/4,0.20978/4)}[kind]
  m2,_,_=true_wall(kind,chk[0],800)
  print(f"{kind}: control, core's rho 0.20 row: param {chk[0]:.5f} -> true {m2:.5f} L (core's table {chk[1]:.5f})",flush=True)
