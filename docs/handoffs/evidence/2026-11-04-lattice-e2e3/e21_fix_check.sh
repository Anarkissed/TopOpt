#!/bin/zsh
cd /private/tmp/claude-501/-Users-nadim-dev-TopOpt-TopOpt--claude-worktrees-agent-comms-lattice-types-818eda/c7bc77f2-8120-406e-8dc6-57e4a7a57ea1/scratchpad/e2/scen
rm -rf fix_A fix_lv_A fix_an_A fix_lv_light
/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/agent-comms-lattice-types-818eda/core/build/topopt-cli run A_light_then_heavy.json --out fix_A > fix_A.log 2>&1; echo "run A exit $?"
grep -E '^LATTICE' fix_A.log | cut -c1-170
python3 -c "
import json
L=json.load(open('fix_A/variant_155_lattice.report.json'))
print({k:L.get(k) for k in ['solid_margin_worst_case','solid_margin_reproduced','solid_reconstruction_reproduces','lattice_margin_worst_case','lattice_accepted']})
print(json.dumps(L.get('scenarios')))"
/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/agent-comms-lattice-types-818eda/core/build/topopt-cli lattice-variant lv_A_light_then_heavy.json --out fix_lv_A > fix_lv_A.log 2>&1; echo "lattice-variant A exit $?"
grep -E 'LATTICE|NOT reproduce|refus' fix_lv_A.log | cut -c1-260 | head -3
ls fix_lv_A/*report.json 2>/dev/null | head -3
for f in fix_lv_A/*lattice.report.json(N); do python3 -c "
import json
L=json.load(open('$f')); print({k:L.get(k) for k in ['solid_margin_worst_case','solid_margin_reproduced','lattice_margin_worst_case','lattice_accepted']}); print(json.dumps(L.get('scenarios')))"; done
python3 -c "import json;j=json.load(open('lv_A_light_then_heavy.json'));j['lattice']['scenarios']=['light down'];json.dump(j,open('lv_A_light_only.json','w'),indent=1)"
/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/agent-comms-lattice-types-818eda/core/build/topopt-cli lattice-variant lv_A_light_only.json --out fix_lv_light > fix_lv_light.log 2>&1; echo "lattice-variant A light-only exit $?"
for f in fix_lv_light/*lattice.report.json(N); do python3 -c "
import json
L=json.load(open('$f')); print({k:L.get(k) for k in ['solid_margin_reproduced','lattice_margin_worst_case','lattice_accepted']}); print(json.dumps(L.get('scenarios')))"; done
/Users/nadim/dev/TopOpt/TopOpt/.claude/worktrees/agent-comms-lattice-types-818eda/core/build/topopt-cli analyze ans_A_light_then_heavy.json --out fix_an_A > fix_an_A.log 2>&1; echo "analyze A exit $?"
python3 -c "
import json
g=json.load(open('fix_an_A/run_info.json')).get('grading',{})
print({k:v for k,v in g.items() if 'recert' in k})"
