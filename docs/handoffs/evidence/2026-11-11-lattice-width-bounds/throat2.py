import numpy as np
from scipy import optimize
exec(open('throat.py').read().split('for kind in')[0])
def fast_dist(kind,p,n=1500):
  D=fib(n); r=np.array([ray(kind,p,d,0.4) for d in D]); k=int(np.argmin(r))
  def g(a):
    th,ph=a; d=np.array([np.sin(th)*np.cos(ph),np.sin(th)*np.sin(ph),np.cos(th)]); return ray(kind,p,d,0.4)
  d0=D[k]; a0=[np.arccos(np.clip(d0[2],-1,1)),np.arctan2(d0[1],d0[0])]
  return optimize.minimize(g,a0,method='Nelder-Mead',options={'xatol':1e-9,'fatol':1e-12}).fun
for kind,q in (('schwarzd',np.array([0.5,0.25,0.5])),('gyroid',np.array([0.375,0.125,0.875]))):
  H=hess(kind,q); w,V=np.linalg.eigh(H)
  print(kind,'hessian eigenvalues',np.round(w,3))
  if kind=='schwarzd':
    along=V[:,2]; P=V[:,:2]           # one positive: along the channel
    # max over the cross-section through the saddle, then min of that along the channel
    def cs(s):
      c=q+s*along
      m=optimize.minimize(lambda a:-fast_dist(kind,c+P@a),[0,0],method='Nelder-Mead',options={'xatol':1e-6,'fatol':1e-9})
      return -m.fun,m.x
    for s in (-0.06,-0.03,0.0,0.03,0.06):
      v,x=cs(s); print(f"  along {s:+.2f}: best clearance in the cross-section {v:.6f} L (offset {np.round(x,4)}) -> wall {2*v:.6f}",flush=True)
  else:
    # the node: max clearance near it
    m=optimize.minimize(lambda a:-fast_dist(kind,q+a),[0,0,0],method='Nelder-Mead',options={'xatol':1e-6,'fatol':1e-9})
    print(f"  node: max clearance nearby {-m.fun:.6f} at offset {np.round(m.x,4)} (at the node itself {fast_dist(kind,q):.6f})",flush=True)
