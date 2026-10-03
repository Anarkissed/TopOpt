# Build forecast-only jobs that make CORE count voxels in set combinations on the stand.
# Every set is a lattice role region core resolves itself:
#   Le   = face 23's three facet prisms EXACTLY as the stage/variant job emits them (depth 24.15, expanded outline)
#   Lu   = the same prisms with the unexpanded outline (outline_u.py), depth 24.15
#   R101@d = kind "region", region 101 at depth d -> region_lattice_mask = mask_step_region's voxels (the protection)
#   R102@12 (face 15), R103@13 (face 2), R104@10 (anchor 18 + the 20 load faces, 3 layers = the pad)
# region_voxels = |cand| = solid-in-design & in an include & not in an exclude.
import json, copy, sys, os
sys.path.insert(0,'.')
from readdesign import read
S='/private/tmp/claude-501/-Users-nadim-dev-TopOpt-TopOpt--claude-worktrees-lattice-stage-frontend-37bee1/18143e8f-32fa-4c68-b7a1-dff8f191152c/scratchpad'
base=json.load(open(S+'/vprobe/c1/saved/variant_forecast.json'))
assert base['lattice']['regions']==json.load(open(S+'/dump/sync-68BF7B74-3C2A-4ED6-A46D-AC040A9CA649.json'))['lattice']['regions']
Le=[r for r in base['lattice']['regions'] if r.get('face_id')==23]
U=json.load(open('outline_unexpanded.json'))
def face(rs,role,depth=None,outline=None):
    out=[]
    for k,r in enumerate(rs):
        r=copy.deepcopy(r); r['role']=role
        if role=='exclude': r.pop('face_id',None)
        if depth is not None: r['geometry']['depth_mm']=depth
        if outline is not None: r['geometry']['outline_uv']=[outline[k]]
        out.append(r)
    return out
def reg(rid,d,role): return {'role':role,'kind':'region','region_id':rid,'geometry':{'depth_mm':d}}
LE=lambda role,d=None: face(Le,role,d)
LU=lambda role,d=None: face(Le,role,d,U)
F6=lambda role: [reg(101,20,role),reg(102,12,role),reg(103,13,role),reg(104,10,role)]
F7=lambda role: [reg(101,24.15,role),reg(102,12,role),reg(103,13,role),reg(104,10,role)]
CFG={
 # positive controls vs the run's loadcase receipt
 'P101_6':[reg(101,20,'include')], 'P101_7':[reg(101,24.15,'include')],
 'P15':[reg(102,12,'include')], 'P2':[reg(103,13,'include')], 'PAD':[reg(104,10,'include')],
 'F6':F6('include'), 'F7':F7('include'),
 # the slab and its parts
 'Le':LE('include'), 'Lu':LU('include'), 'Le20':LE('include',20),
 'Le_m101_6':LE('include')+[reg(101,20,'exclude')],
 'Le_m101_7':LE('include')+[reg(101,24.15,'exclude')],
 'Le_mF6':LE('include')+F6('exclude'), 'Le_mF7':LE('include')+F7('exclude'),
 'Lu_m101_6':LU('include')+[reg(101,20,'exclude')], 'Lu_m101_7':LU('include')+[reg(101,24.15,'exclude')],
 'Lu_mF6':LU('include')+F6('exclude'), 'Lu_mF7':LU('include')+F7('exclude'),
 'K':LE('include')+LU('exclude'),
 'K_m101_6':LE('include')+LU('exclude')+[reg(101,20,'exclude')],
 'K_m101_7':LE('include')+LU('exclude')+[reg(101,24.15,'exclude')],
 'K_mF6':LE('include')+LU('exclude')+F6('exclude'), 'K_mF7':LE('include')+LU('exclude')+F7('exclude'),
}
D=read(S+'/standvar/run/design.bin')
designs={'part':None}
for v in D['v']: designs['v%02d'%round(v['req']*100)]=v
os.makedirs('jobs',exist_ok=True)
for dn,v in designs.items():
    for cn,regs in CFG.items():
        j=copy.deepcopy(base)
        j['loads']['face_regions']=base['loads']['face_regions']+[
            {'id':102,'name':'probe p15','add':[15]},{'id':103,'name':'probe p2','add':[2]},
            {'id':104,'name':'probe pad','add':[18]+base['loads']['groups'][0]['face_ids']}]
        j['lattice']['regions']=regs
        if v is None:
            j['mode']='lattice_part'; j.pop('variant',None)
        else:
            j['variant']={'design':'design.bin','fingerprint':str(v['fp']),'achieved_volume_fraction':v['ach']}
        json.dump(j,open('jobs/%s__%s.json'%(dn,cn),'w'),indent=1)
print(len(designs)*len(CFG),'jobs')
