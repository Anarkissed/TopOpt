exec(open('make_jobs.py').read().split("CFG={")[0])
W15=[r for r in base['lattice']['regions'] if r.get('face_id')==15]
W2=[r for r in base['lattice']['regions'] if r.get('face_id')==2]
CFG={'W15':face(W15,'include'),'W15_mP15':face(W15,'include')+[reg(102,12,'exclude')],'W15_mF6':face(W15,'include')+F6('exclude'),
     'W2':face(W2,'include'),'W2_mP2':face(W2,'include')+[reg(103,13,'exclude')],'W2_mF6':face(W2,'include')+F6('exclude')}
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
