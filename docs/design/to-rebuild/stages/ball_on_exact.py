# Where does the plate's 3.6 mm reading lose 7 to 10 %? Take the EXACT Kirsch field (no solve), sample it on the
# test's voxels, and apply the reading's own ball (stress_measure.cpp's rules), against the reference's ball.
import numpy as np, math, sys
A=6.0; TILT=math.radians(30.0); SUB=8
def vm_exact(x,y):                      # pull along the tilted axis; x,y in mm from the hole centre
    c,s=math.cos(TILT),math.sin(TILT); u=x*c+y*s; v=-x*s+y*c
    r=np.maximum(np.hypot(u,v),A); th=np.arctan2(v,u); q=A*A/(r*r)
    c2=np.cos(2*th); s2=np.sin(2*th)
    srr=0.5*(1-q)+0.5*(1-4*q+3*q*q)*c2; stt=0.5*(1+q)-0.5*(1+3*q*q)*c2; srt=-0.5*(1+2*q-3*q*q)*s2
    return np.sqrt(srr*srr+stt*stt-srr*stt+3*srt*srt)*(3.03/3.0)
def reference(D,T):                      # to_reference_reading.hpp, hot point (0,A) in the pull frame
    R=0.5*D; n=61; best=0
    xs=np.linspace(-R,R,n); X,Y=np.meshgrid(xs,xs); rho2=X*X+Y*Y; m=rho2<=R*R
    W=np.minimum(T,2*np.sqrt(np.maximum(R*R-rho2,0)))
    c,s=math.cos(TILT),math.sin(TILT)
    for k in range(25):
        e=D*k/24; cu,cv=0.0,A+e
        U=cu+X; V=cv+Y; inside=(np.hypot(U,V)>=A)&m
        x=U*c-V*s; y=U*s+V*c
        f=vm_exact(x,y); den=(W*inside).sum()
        if den>0: best=max(best,(W*inside*f).sum()/den)
    return best
def stencil(rad,off_z=0.0):
    reach=int(math.ceil(rad+0.5)); taps=[]
    g=(np.arange(6)+0.5)/6-0.5
    for dk in range(-reach,reach+1):
        for dj in range(-reach,reach+1):
            for di in range(-reach,reach+1):
                X,Y,Z=np.meshgrid(di+g,dj+g,dk+g+off_z,indexing='ij'); inn=(X*X+Y*Y+Z*Z<=rad*rad).mean()
                if inn>0: taps.append((di,dj,dk,inn))
    return taps
def measured(rv,D,mode):
    h=A/rv; w=20*rv; cx=0.5*w+0.29; cy=0.5*w-0.41
    sub=(np.arange(SUB)+0.5)/SUB
    I,J=np.meshgrid(np.arange(w),np.arange(w),indexing='ij')
    fill=np.zeros((w,w)); 
    for a in sub:
        for b in sub: fill+= (np.hypot(I+a-cx,J+b-cy)>rv)
    fill/=SUB*SUB
    # the exact stress of the MATERIAL in each voxel: mean over its solid sub-points
    f=np.zeros((w,w)); cnt=np.zeros((w,w))
    for a in sub:
        for b in sub:
            sol=np.hypot(I+a-cx,J+b-cy)>rv
            f+=sol*vm_exact((I+a-cx)*h,(J+b-cy)*h); cnt+=sol
    f=np.where(cnt>0,f/np.maximum(cnt,1),0)
    if mode=='ersatz': f=f*fill       # a cut voxel reports stress scaled by its fill
    rad=0.5*D/h
    if rad<=0.5: return float((f*(fill>=0.5)).max())
    nz=2; best=0
    lo=int(cx-rv-rad-3); hi=int(cx+rv+rad+3)
    for kc in range(nz):
        taps=stencil(rad)
        for i in range(lo,hi):
            for j in range(lo,hi):
                if fill[i,j]<0.5: continue
                s=0; wt=0
                for di,dj,dk,sh in taps:
                    k=kc+dk
                    if k<0 or k>=nz: continue
                    u=fill[i+di,j+dj]
                    if mode=='all':
                        if u<=0: continue
                    elif u<0.5: continue
                    s+=sh*u*f[i+di,j+dj]; wt+=sh*u
                if wt>0: best=max(best,s/wt)
    return best
D=float(sys.argv[1]) if len(sys.argv)>1 else 3.6
print(f"reading over {D} mm; exact Kirsch field on the test's voxels; percent against the reference's ball")
for rv in (3,4,5,6):
    T=2*A/rv; ref=reference(D,T)
    row=[]
    for mode in ('rules','all','ersatz'):
        row.append(100*(measured(rv,D,mode)/ref-1))
    print(f"hole radius {rv} voxels (thickness {T:.1f} mm): reference {ref:.3f}; today's ball rules {row[0]:+.1f} %; counting cut voxels under half too {row[1]:+.1f} %; cut voxels' stress scaled by fill {row[2]:+.1f} %")
