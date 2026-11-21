#!/usr/bin/env python3
"""flip_f.py GATE_DIR [TYPES...] (flip.py with the triangle count; the stand's before = 262b731f,
step (c)'s gate; the 21 binaries' base stays eede708a): the stand flip table (after = the gate's
commit) per type and rung, and the 21 identity binaries' before/after, from gate.sh's output.
"""
import json, os, re, sys

gate = sys.argv[1]
types = sys.argv[2:] or ["octet", "fcc", "kelvin", "rhombic", "diamond", "bcc", "sc", "gyroid", "schwarz_d"]


def rungs(d, t):
    log = os.path.join(d, "out_run_struct_%s.log" % t)
    out = {}
    if not os.path.exists(log):
        return out
    for line in open(log, errors="replace"):
        m = re.search(r"LATTICE vf=([0-9.]+) .*cell_mm=([0-9.]+).*rho_min=([0-9.]+) rho_max=([0-9.]+) cells=(\d+) tris=(\d+) lattice_margin=([0-9.e+-]+) lattice_accepted=(\d)", line)
        if m and line.startswith("LATTICE"):
            vf = float(m.group(1))
            out.setdefault(vf, {}).update(
                state="lattice", cell=float(m.group(2)), rho=(float(m.group(3)), float(m.group(4))),
                cells=int(m.group(5)), tris=int(m.group(6)), margin=float(m.group(7)),
                accepted=m.group(8) == "1")
        m = re.search(r"\[lattice\] vf=([0-9.]+) NO LATTICE EMITTED — (.*)", line)
        if m:
            vf = round(float(m.group(1)), 2)
            why = m.group(2)
            short = ("sealed cavity" if "SEALED" in why else
                     "volume check (light)" if "certificate counts" in why else why[:60])
            out.setdefault(vf, {}).update(state="refused: " + short)
    for vf, r in out.items():
        rp = os.path.join(d, "out_run_struct_%s" % t, "variant_%03d_lattice.report.json" % round(vf * 100))
        if os.path.exists(rp):
            j = json.load(open(rp))
            r["mass"] = j.get("lattice_mass_grams")
            vc = j.get("volume_check")
            if vc:
                r["gap"] = vc.get("gap")
                r["worst"] = vc.get("worst_gap")
                r["high"] = vc.get("highest_gap")
    return out


def fmt(r):
    if not r:
        return "(no rung)"
    if r.get("state") != "lattice":
        return r.get("state", "?")
    s = "%d cells, %d triangles, rho %.3f-%.3f, %s g, margin %.1f, %s" % (
        r["cells"], r["tris"], r["rho"][0], r["rho"][1],
        "%.1f" % r["mass"] if r.get("mass") is not None else "?", r["margin"],
        "ACCEPTED" if r["accepted"] else "REJECTED")
    if r.get("gap") is not None:
        s += ", gap %+.1f %% (lightest pocket %+.1f %%, heaviest %+.1f %%)" % (
            100 * r["gap"], 100 * r["worst"], 100 * r["high"])
    return s


print("STAND (M2, Structural ladder; before = 262b731f, after = this gate)")
for t in types:
    b = rungs(os.path.join(gate, "stand", "before", t), t)
    a = rungs(os.path.join(gate, "stand", "after", t), t)
    print("\n%s" % t)
    for vf in sorted(set(b) | set(a), reverse=True):
        rb, ra = b.get(vf), a.get(vf)
        flip = ""
        sb = (rb or {}).get("state") == "lattice" and (rb or {}).get("accepted")
        sa = (ra or {}).get("state") == "lattice" and (ra or {}).get("accepted")
        if sb != sa:
            flip = "   <-- FLIP: " + ("now accepted" if sa else "now not latticed/accepted")
        print("  rung %.2f before: %s" % (vf, fmt(rb)))
        print("            after:  %s%s" % (fmt(ra), flip))

ident = os.path.join(gate, "ident.txt")
if os.path.exists(ident):
    print("\nTHE 21 BINARIES (base eede708a vs this gate; outputs filtered as pipe.sh does)")
    for line in open(ident):
        st, t = line.split()
        base = os.path.join(gate, "ident", "base", t + ".out")
        head = os.path.join(gate, "ident", "head", t + ".out")
        def tail(p):
            try:
                ls = open(p, errors="replace").read().strip().splitlines()
            except OSError:
                return "?"
            ex = [l for l in ls if l.startswith("exit ")]
            res = [l for l in ls if re.search(r"(PASS|FAIL)\b.*checks|checks, \d+ failures", l)]
            return (ex[-1] if ex else "?") + ("; " + res[-1].strip()[:60] if res else "")
        print("  %-9s %-32s before: %s | after: %s" % (st, t, tail(base), tail(head)))
