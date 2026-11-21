#!/usr/bin/env python3
"""Convert a COPY of a project folder to Aesthetic Stepped, for the any-step plan proof (reviewer,
2026-10-08: "The same proof for Aesthetic Stepped (any-step plans)"; converted copies are labelled
and never his originals). Sets lattice.algorithm = "stepped", lattice.gradeStepStyle = "stepped"
(what the wizard saves for Stepped) and lattice.stageMode = "aesthetic" (Structural Stepped is
blocked until core checks mixed cell sizes), and suffixes the name. Refuses the simulator store."""
import json, sys, os
d = sys.argv[1]
if 'CoreSimulator' in os.path.abspath(d):
    sys.exit('refusing: that is the live store')
p = os.path.join(d, 'project.json')
j = json.load(open(p))
lat = j.setdefault('lattice', {})
was = (lat.get('algorithm', ''), lat.get('stageMode'))
lat['algorithm'] = 'stepped'
lat['gradeStepStyle'] = 'stepped'
lat['stageMode'] = 'aesthetic'
j['name'] = j.get('name', '') + ' (converted: Aesthetic Stepped)'
json.dump(j, open(p, 'w'))
print(f"converted {os.path.basename(d)[:8]}: (algorithm, stage) {was!r} -> ('stepped', 'aesthetic'), gradeStepStyle 'stepped'")
