# Exact channel throat: the critical points of f inside a channel (f>0) are its skeleton's
# nodes (maxima) and edge midpoints (saddles). The true distance from each to the zero set
# is the minimum, over directions, of the first f=0 crossing along a ray (the nearest
# surface point is reached by the straight ray). The throat is the smallest such distance
# among the saddles; the wall closes the channel when its half-thickness reaches it.
import numpy as np
from scipy import optimize
exec(open('sheet.py').read().split('def grid')[0])
def grad(kind,p):
  _,gx,gy,gz=field(kind,p[0],p[1],p[2]); return np.array([gx,gy,gz])
def hess(kind,p,h=1e-6):
  H=np.zeros((3,3))
  for i in range(3):
    e=np.zeros(3); e[i]=h; H[:,i]=(grad(kind,p+e)-grad(kind,p-e))/(2*h)
  return H
def crit(kind,n=4000,seed=3):
  rng=np.random.default_rng(seed); pts=[]
  for _ in range(n):
    p=rng.random(3)
    s=optimize.root(lambda q:grad(kind,q),p,jac=lambda q:hess(kind,q),tol=1e-13)
    if not s.success: continue
    q=np.mod(s.x,1.0); f=field(kind,*q)[0]
    if f<=1e-6: continue
    ev=np.linalg.eigvalsh(hess(kind,q)); idx=int(np.sum(ev<0))
    if not any(np.linalg.norm(((q-r[0]+0.5)%1)-0.5)<1e-6 for r in pts): pts.append((q,f,idx))
  return pts
def fib(n):
  i=np.arange(n)+0.5; phi=np.arccos(1-2*i/n); th=np.pi*(1+5**0.5)*i
  return np.stack([np.cos(th)*np.sin(phi),np.sin(th)*np.sin(phi),np.cos(phi)],1)
def ray(kind,p,d,smax=0.6):
  f0=field(kind,*p)[0]; s=0.0; ds=0.002
  while s<smax:
    s2=s+ds; f2=field(kind,*(p+s2*d))[0]
    if np.sign(f2)!=np.sign(f0):
      return optimize.brentq(lambda t:field(kind,*(p+t*d))[0],s,s2,xtol=1e-14)
    s=s2
  return smax
def dist(kind,p):
  D=fib(6000); r=np.array([ray(kind,p,d) for d in D]); k=int(np.argmin(r))
  def g(a):
    th,ph=a; d=np.array([np.sin(th)*np.cos(ph),np.sin(th)*np.sin(ph),np.cos(th)]); return ray(kind,p,d)
  d0=D[k]; a0=[np.arccos(np.clip(d0[2],-1,1)),np.arctan2(d0[1],d0[0])]
  s=optimize.minimize(g,a0,method='Nelder-Mead',options={'xatol':1e-10,'fatol':1e-13,'maxiter':400})
  return min(s.fun,r[k])
for kind in ('gyroid','schwarzd'):
  pts=crit(kind,1500)
  byf={}
  for q,f,idx in pts: byf.setdefault((round(f,6),idx),q)
  for (f,idx),q in sorted(byf.items()):
    d=dist(kind,q)
    print(f"{kind}: critical point f={f:.6f} ({'max' if idx==3 else 'saddle' if idx==2 else 'idx'+str(idx)}) at {np.round(q,5)}: distance to the surface {d:.6f} L -> wall {2*d:.6f} L",flush=True)
