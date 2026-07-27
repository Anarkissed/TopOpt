import sys, re, collections
path=sys.argv[1]; label=sys.argv[2]
feat=collections.Counter()          # extruded length per feature (mm of filament E)
widths=collections.Counter()        # count of extruding moves per rounded width
layer_minwidth={}                   # z -> min extruding width seen
z=0.0; cur_feat=None; cur_w=None
lastE=None; extrude_moves=0
bottom_widths=collections.defaultdict(list)  # first layers
with open(path,'r',errors='ignore') as f:
    for line in f:
        if line.startswith('; Z_HEIGHT:'):
            z=float(line.split(':')[1]); continue
        if line.startswith('; FEATURE:'):
            cur_feat=line.split(':',1)[1].strip(); continue
        if line.startswith('; LINE_WIDTH:'):
            cur_w=float(line.split(':')[1]); continue
        if line and line[0] in 'GgTt':
            # extruding move: G1 with positive E delta and X/Y
            if line[:2].upper()=='G1' and ' E' in line and (' X' in line or ' Y' in line):
                m=re.search(r' E([-0-9.]+)',line)
                if m and cur_w is not None:
                    e=float(m.group(1))
                    extrude_moves+=1
                    feat[cur_feat]+=1
                    wr=round(cur_w,3)
                    widths[wr]+=1
                    if z not in layer_minwidth or cur_w<layer_minwidth[z]:
                        layer_minwidth[z]=cur_w
                    if z<=1.6:
                        bottom_widths[round(z,2)].append(cur_w)
print(f"===== {label} =====")
print("total extruding moves:", extrude_moves)
print("\nFEATURE mix (count of extrude moves):")
for k,v in feat.most_common(): print(f"  {k:22s} {v:7d}")
print("\nLINE_WIDTH distribution (mm -> #moves):")
for w in sorted(widths): print(f"  {w:.3f}  {widths[w]:7d}")
print("\nmin extruding LINE_WIDTH overall: %.3f mm" % min(widths))
print("max extruding LINE_WIDTH overall: %.3f mm" % max(widths))
print("\nbottom layers (z<=1.6mm): z -> (min,max,mean) width, #moves:")
for zz in sorted(bottom_widths):
    ws=bottom_widths[zz]
    print(f"  z={zz:.2f}  min={min(ws):.3f} max={max(ws):.3f} n={len(ws)}")
