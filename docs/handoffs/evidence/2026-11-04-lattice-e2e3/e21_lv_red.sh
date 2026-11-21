#!/bin/zsh
# E2.1 red-first, the other two paths, on the bar with minimize_plastic on (a ladder below 1).
cd /private/tmp/claude-501/-Users-nadim-dev-TopOpt-TopOpt--claude-worktrees-agent-comms-lattice-types-818eda/c7bc77f2-8120-406e-8dc6-57e4a7a57ea1/scratchpad/e2/scen
python3 - <<'PY'
import json
for run in ["A_light_then_heavy","C_heavy_alone"]:
    j=json.load(open(run+".json")); j["loads"]["minimize_plastic"]=True
    json.dump(j,open("mp_"+run+".json","w"),indent=1)
    a=json.load(open(run+".json")); a["mode"]="analyze"; a.pop("output",None); a["output"]={"report":"report.json","mesh_format":"stl","mesh_prefix":"variant"}
    json.dump(a,open("an_"+run+".json","w"),indent=1)
PY
for r in A_light_then_heavy C_heavy_alone; do
  /Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/agent-comms-lattice-types-818eda/core/build/topopt-cli run mp_$r.json --out mpout_$r > mpout_$r.log 2>&1; echo "run $r exit $?"
  vf=$(python3 -c "import json;r=json.load(open('mpout_$r/report.json'));print(r['variants'][0]['volume_fraction'] if r['variants'] else '')")
  echo "first accepted vf $vf"; grep -E '^LATTICE' mpout_$r.log | cut -c1-200 | head -2
  [ -n "$vf" ] || continue
  python3 -c "import json;j=json.load(open('mp_$r.json'));j['mode']='lattice_variant';j['variant']={'design':'mpout_$r/design.bin','volume_fraction':round($vf,2)};json.dump(j,open('lv_$r.json','w'),indent=1)"
  /Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/agent-comms-lattice-types-818eda/core/build/topopt-cli lattice-variant lv_$r.json --out lvout_$r > lvout_$r.log 2>&1; echo "lattice-variant $r exit $?"; grep -E 'LATTICE|NOT reproduce|must|refus' lvout_$r.log | cut -c1-400 | head -3
  /Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/agent-comms-lattice-types-818eda/core/build/topopt-cli analyze an_$r.json --out anout_$r > anout_$r.log 2>&1; echo "analyze $r exit $?"; grep -i -E 'recertif|LATTICE|governs|scenario' anout_$r.log | cut -c1-250 | head -4
done
