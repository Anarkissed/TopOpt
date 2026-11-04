import struct, numpy as np, sys
def read(path):
    b=open(path,'rb').read()
    off=0
    ver=b[0]; off=4
    nx,ny,nz=struct.unpack_from('<iii',b,off); off+=12
    ox,oy,oz,h=struct.unpack_from('<dddd',b,off); off+=32
    vc,_=struct.unpack_from('<ii',b,off); off+=8
    vs=[]
    for v in range(vc):
        req,ach,mw,me,vm=struct.unpack_from('<ddddd',b,off); off+=40
        acc,it=struct.unpack_from('<ii',b,off); off+=8
        bd=struct.unpack_from('<ddd',b,off); off+=24
        aa,eb=struct.unpack_from('<ii',b,off); off+=8
        fp,=struct.unpack_from('<Q',b,off); off+=8
        n,=struct.unpack_from('<q',b,off); off+=8
        d=np.frombuffer(b,dtype='<f8',count=n,offset=off).copy(); off+=8*n
        vs.append(dict(req=req,ach=ach,acc=acc,it=it,fp=fp,d=d))
    return dict(ver=ver,nx=nx,ny=ny,nz=nz,o=(ox,oy,oz),h=h,v=vs)
if __name__=='__main__':
    D=read(sys.argv[1])
    print(D['ver'],D['nx'],D['ny'],D['nz'],D['o'],D['h'],len(D['v']))
    for v in D['v']:
        d=v['d']
        print(v['req'],v['ach'],v['fp'],'n',len(d),'==0:',(d==0).sum(),'<1e-6:',(d<1e-6).sum(),'<0.5:',(d<0.5).sum(),'>=0.5:',(d>=0.5).sum(),'==1:',(d==1).sum(), 'min>0', d[d>0].min(), 'uniq small', np.unique(np.round(d[d<0.01],12))[:10])
