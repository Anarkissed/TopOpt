exec(open('make_jobs.py').read().split("CFG={")[0])
CFG={
 'Band_m101_6':LE('include')+LE('exclude',20)+[reg(101,20,'exclude')],
 'Le20_m101_6':LE('include',20)+[reg(101,20,'exclude')],
 'Le20_mF6':LE('include',20)+F6('exclude'),
 'P7_mLe':[reg(101,24.15,'include')]+LE('exclude'),
 'P6_mLe20':[reg(101,20,'include')]+LE('exclude',20),
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
