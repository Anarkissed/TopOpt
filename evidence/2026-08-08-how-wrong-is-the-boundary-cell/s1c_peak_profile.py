import struct, sys
import numpy as np
fp, dp = sys.argv[1], sys.argv[2]
raw=open(fp,'rb').read(); o=0
ver,=struct.unpack_from('<B',raw,o); o+=4
nx,ny,nz=struct.unpack_from('<iii',raw,o); o+=12
o+=24; sp,=struct.unpack_from('<d',raw,o); o+=8; o+=8
nv,_=struct.unpack_from('<ii',raw,o); o+=8
draw=open(dp,'rb').read(); q=56
D={}
for v in range(4):
    rq,=struct.unpack_from('<d',draw,q); q+=40+8+24+8+8
    n,=struct.unpack_from('<q',draw,q); q+=8
    D[round(rq,2)]=np.frombuffer(draw,dtype='<f8',count=n,offset=q).reshape((nz,ny,nx)); q+=8*n
for v in range(nv):
    rq,mass=struct.unpack_from('<dd',raw,o); o+=16; o+=8
    nvm,nst,nd=struct.unpack_from('<qqq',raw,o); o+=24
    vm=np.frombuffer(raw,dtype='<f4',count=nvm,offset=o).reshape((nz,ny,nx)); o+=4*nvm+4*nst+4*nd
    f=D[round(rq,2)]; pr=f>0.5
    k,j,i=np.unravel_index(np.argmax(vm),vm.shape)
    print(f"--- rung {rq:.2f}: peak {vm[k,j,i]:.6g} MPa at (i={i},j={j},k={k})")
    # which face-neighbours are void -> the local outward directions
    dirs={'+x':(0,0,1),'-x':(0,0,-1),'+y':(0,1,0),'-y':(0,-1,0),'+z':(1,0,0),'-z':(-1,0,0)}
    for name,(dk,dj,di) in dirs.items():
        kk,jj,ii=k+dk,j+dj,i+di
        out = not (0<=ii<nx and 0<=jj<ny and 0<=kk<nz) or not pr[kk,jj,ii]
        if not out: continue
        # walk INWARD (opposite) and print the vM profile through the member
        prof=[]
        for s in range(0,14):
            kk,jj,ii=k-dk*s,j-dj*s,i-di*s
            if not (0<=ii<nx and 0<=jj<ny and 0<=kk<nz) or not pr[kk,jj,ii]: break
            prof.append(vm[kk,jj,ii])
        print(f"    outward {name}: member is {len(prof)} voxels deep; vM inward: "
              + ", ".join(f"{x:.5f}" for x in prof))
        if len(prof)>1:
            print(f"      -> drops {100*(1-prof[-1]/prof[0]):.1f}% across the member; "
                  f"per-voxel first step {100*(1-prof[1]/prof[0]):.1f}%")
