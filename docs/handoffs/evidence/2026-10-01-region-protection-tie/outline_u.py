# Recover the UNEXPANDED (expand = 0) outline of face 23's three facet prisms from the
# wire outline, by inverting the app's LatticeOutlineRibbon.offsetRing (line offset +
# intersection; a parallel pair takes the start of the second offset line). Seam edges
# (facet-to-facet) keep their wire position (the bisector flare is not the collar);
# every other edge moves INWARD by the expand (4.15 mm).
import json, numpy as np, sys
S='/private/tmp/claude-501/-Users-nadim-dev-TopOpt-TopOpt--claude-worktrees-lattice-stage-frontend-37bee1/18143e8f-32fa-4c68-b7a1-dff8f191152c/scratchpad'
E=4.15
SEAMS={0:{8},1:{9,20},2:{5}}   # edge i = loop[i] -> loop[i+1]; identified from the 3D print
def inward_normals(L):
    m=len(L); area=sum(L[i][0]*L[(i+1)%m][1]-L[(i+1)%m][0]*L[i][1] for i in range(m))
    ccw=area>0; out=[]
    for i in range(m):
        e=L[(i+1)%m]-L[i]; l=np.linalg.norm(e); left=np.array([-e[1],e[0]])/l
        out.append(left if ccw else -left)
    return out
def offset(L,offs):
    L=np.array(L,float); m=len(L); n=inward_normals(L)
    P=[L[i]+n[i]*offs[i] for i in range(m)]; D=[L[(i+1)%m]-L[i] for i in range(m)]
    def meet(a,b):
        p1,d1,p2,d2=P[a],D[a],P[b],D[b]; cr=d1[0]*d2[1]-d1[1]*d2[0]
        if abs(cr)<1e-9*max(np.linalg.norm(d1)*np.linalg.norm(d2),1e-9): return p2
        t=((p2[0]-p1[0])*d2[1]-(p2[1]-p1[1])*d2[0])/cr; return p1+d1*t
    R=[meet((i-1)%m,i) for i in range(m)]
    # eaten-edge check (the app's rule): an edge whose offset copy runs backwards
    for i in range(m):
        if np.dot(R[(i+1)%m]-R[i],D[i])<=1e-9: print('WARNING eaten edge',i,file=sys.stderr)
    return np.array(R)
def area(L):
    L=np.array(L); x,y=L[:,0],L[:,1]; return 0.5*abs(np.dot(x,np.roll(y,-1))-np.dot(y,np.roll(x,-1)))
j=json.load(open(S+'/dump/sync-68BF7B74-3C2A-4ED6-A46D-AC040A9CA649.json'))
fac=[r for r in j['lattice']['regions'] if r.get('face_id')==23]
out=[]
tot_u=0
for k,r in enumerate(fac):
    W=np.array(r['geometry']['outline_uv'][0])
    offs=[0.0 if i in SEAMS[k] else +E for i in range(len(W))]        # inward
    U=offset(W,offs)
    back=offset(U,[0.0 if i in SEAMS[k] else -E for i in range(len(W))])  # the app's forward pass
    err=np.abs(back-W).max()
    print('facet',k,'n',len(W),'area wire %.1f  area unexpanded %.1f  round-trip max err %.2e'%(area(W),area(U),err))
    out.append(U.tolist())
json.dump(out,open('outline_unexpanded.json','w'))
