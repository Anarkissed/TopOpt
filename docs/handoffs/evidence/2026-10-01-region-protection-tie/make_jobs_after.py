# Same probes against the AFTER run's design.bin (region 101 frozen at 24.15 mm).
exec(open('make_jobs.py').read().split("CFG={")[0])
CFG={'P101_7':[reg(101,24.15,'include')],'F7':F7('include'),'Le':LE('include'),'Lu':LU('include'),
     'K':LE('include')+LU('exclude'),'Band':LE('include')+LE('exclude',20),
     'Le_m101_7':LE('include')+[reg(101,24.15,'exclude')],'Le_mF7':LE('include')+F7('exclude'),
     'P7_mLe':[reg(101,24.15,'include')]+LE('exclude')}
A='/private/tmp/claude-501/-Users-nadim-dev-TopOpt-TopOpt--claude-worktrees-lattice-stage-frontend-37bee1/18143e8f-32fa-4c68-b7a1-dff8f191152c/scratchpad/agentwork/band101/opt_after/run/design.bin'
D=read(A)
for p in base['loads']['face_protections']:
    if p.get('region_id')==101: p['depth_mm']=24.15
designs={}
for v in D['v']: designs['A%02d'%round(v['req']*100)]=v
for dn,v in designs.items():
    for cn,regs in CFG.items():
        j=copy.deepcopy(base)
        j['loads']['face_regions']=base['loads']['face_regions']+[
            {'id':102,'name':'probe p15','add':[15]},{'id':103,'name':'probe p2','add':[2]},
            {'id':104,'name':'probe pad','add':[18]+base['loads']['groups'][0]['face_ids']}]
        j['lattice']['regions']=regs
        j['variant']={'design':'design_after.bin','fingerprint':str(v['fp']),'achieved_volume_fraction':v['ach']}
        json.dump(j,open('jobs/%s__%s.json'%(dn,cn),'w'),indent=1)
print(len(designs)*len(CFG),'after jobs', [(dn,v['fp'],v['acc']) for dn,v in designs.items()])
