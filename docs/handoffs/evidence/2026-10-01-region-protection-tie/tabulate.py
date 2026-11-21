import json,glob,os
R={}
for f in glob.glob('runs/*/out/lattice_forecast.json'):
    n=f.split('/')[1]; dn,cn=n.split('__',1)
    j=json.load(open(f))
    R.setdefault(cn,{})[dn]=(j['region_voxels'],j['include_region_void_voxels'],j['include_regions'],j['exclude_regions'])
missing=[os.path.basename(p)[:-5] for p in glob.glob('jobs/*.json') if not os.path.exists('runs/%s/out/lattice_forecast.json'%os.path.basename(p)[:-5])]
print('missing',missing)
ds=['part','v68','v52','v38','v26']
print('%-12s'%'set',''.join('%9s'%d for d in ds),'  | emptied (part - variant) per rung',' | include_void part/v26, incl/excl')
for cn in ['P101_6','P101_7','P15','P2','PAD','F6','F7','Le','Lu','Le20','Le_m101_6','Le_m101_7','Le_mF6','Le_mF7','Lu_m101_6','Lu_m101_7','Lu_mF6','Lu_mF7','K','K_m101_6','K_m101_7','K_mF6','K_mF7']:
    r=R[cn]; p=r['part'][0]
    print('%-12s'%cn,''.join('%9d'%r[d][0] for d in ds),'  |',' '.join('%5d'%(p-r[d][0]) for d in ds[1:]),' | %d/%d %d/%d'%(r['part'][1],r['v26'][1],r['part'][2],r['part'][3]))
json.dump(R,open('table.json','w'),indent=1)
