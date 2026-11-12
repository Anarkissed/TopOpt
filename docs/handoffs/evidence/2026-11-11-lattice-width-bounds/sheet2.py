# Sheets, by the TRUE distance to the zero set (EDT of the sign, -0.5 voxel): the channels
# close when the true wall reaches the throat, i.e. {f>0, dist > w/2} stops spanning a
# 3x3x3 tiling. w is a true normal wall thickness, the unit core's sheet "diameter" is in.
import numpy as np
from scipy import ndimage
exec(open('sheet.py').read().split('def grid')[0])   # field() only
def run(kind,N):
  u=(np.arange(3*N)+0.5)/N
  X,Y,Z=np.meshgrid(u,u,u,indexing='ij')
  f,_,_,_=field(kind,X,Y,Z); del X,Y,Z
  out=[]
  for sgn in (1,-1):
    pos=(sgn*f)>0
    d=(ndimage.distance_transform_edt(pos)-0.5)/N
    lo,hi=0.0,1.0
    for _ in range(22):
      mid=0.5*(lo+hi)
      lab,n=ndimage.label(pos&(d>mid/2))
      a=set(np.unique(lab[0]))-{0}; b=set(np.unique(lab[-1]))-{0}
      if a&b: lo=mid
      else: hi=mid
    c=N; core_=pos[c:2*c,c:2*c,c:2*c]; dd=d[c:2*c,c:2*c,c:2*c]
    out.append((lo, float(1-np.mean(core_&(dd>lo/2))-np.mean((~pos[c:2*c,c:2*c,c:2*c])&False))))
  return out
for kind in ('gyroid','schwarzd'):
  for N in (64,96):
    r=run(kind,N)
    print(kind,N,' '.join(f"side{'+' if i==0 else '-'}: closes at true wall {w:.4f} L" for i,(w,_) in enumerate(r)),flush=True)
