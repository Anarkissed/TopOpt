#!/usr/bin/env python3
"""Convert a COPY of a project folder to Default Grade (ruling 4: converted copies are fine for
coverage, never his originals, labelled "converted"). Sets lattice.algorithm = "doubled" and
lattice.gradeStepStyle = "dyadic" (what the wizard saves for Default Grade) and suffixes the name.
Refuses to touch anything under the simulator container."""
import json, sys, os
d = sys.argv[1]
if 'CoreSimulator' in os.path.abspath(d):
    sys.exit('refusing: that is the live store')
p = os.path.join(d, 'project.json')
j = json.load(open(p))
lat = j.setdefault('lattice', {})
was = lat.get('algorithm', '')
lat['algorithm'] = 'doubled'
lat['gradeStepStyle'] = 'dyadic'
j['name'] = j.get('name', '') + ' (converted: Default Grade)'
json.dump(j, open(p, 'w'))
print(f"converted {os.path.basename(d)[:8]}: algorithm {was!r} -> 'doubled', gradeStepStyle 'dyadic'")
