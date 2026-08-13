#!/usr/bin/env python3
"""R1's AFTER side: his job document plus a plsm block naming the OLD defaults.

★ THE BASE BINARY NEEDS NO SUCH BLOCK — those ARE its defaults. Writing them
explicitly on the new binary is what makes the comparison mean "the new
machinery, configured as the old machinery, reproduces it exactly", which is the
only byte-identity claim available now that the CLI has no SIMP route.
"""
import json, sys
j = json.load(open(sys.argv[1]))
j["plsm"] = {"enabled": True, "ersatz": "heaviside", "sens_weight": "continuum",
             "eta_voxels": 2.0, "max_iterations": 60, "margin_probe_every": 0}
json.dump(j, open(sys.argv[2], "w"), indent=1)
