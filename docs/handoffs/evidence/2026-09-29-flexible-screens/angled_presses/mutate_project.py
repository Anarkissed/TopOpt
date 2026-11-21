# Copy a project.json with ONE setting changed (the stage-hash controls).
#   depth  : lattice.groupDepthMM of group 92E96F3A (his "Top" include) 4 -> 5 mm   (the stage job READS it)
#   flex   : lattice.flexible.faces[first loaded].weightKg + 1                       (the stage job never reads it)
import json, sys
src, dst, what = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(src))
lat = d['lattice']
if what == 'depth':
    g = lat['groupDepthMM']
    i = g.index('92E96F3A-D8F7-4FB0-AF8D-56230DFB6BC0')
    print(f"groupDepthMM {g[i]}: {g[i+1]} -> {g[i+1] + 1}")
    g[i + 1] = g[i + 1] + 1
elif what == 'flex':
    f = next(x for x in lat['flexible']['faces'] if x['role'] == 'loaded')
    print(f"flexible face {f['faceRegionID']} weightKg {f['weightKg']} -> {f['weightKg'] + 1}")
    f['weightKg'] = f['weightKg'] + 1
else:
    sys.exit(f"unknown mutation {what}")
json.dump(d, open(dst, 'w'), sort_keys=True)
