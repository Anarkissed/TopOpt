#!/usr/bin/env python3
"""THE SHEET LAW ON THE OFF-GRIP ENVELOPE (the reviewer's ruling of 2026-11-26, item 3 (a)).

usage: python3 -I envelope.py <this folder>

Reads, per sheet type:
  ../2026-11-25-sheet-laws-thin-members/<type>/k_exact_w_all.csv   notes28's fixtures (0, 0.25, 0.5, 0.6, 0.75)
  <type>/k_exact_w_all.csv                                        this folder's sweep (gathered parts)
  ../2026-11-25-sheet-laws-thin-members/<type>/k_exact_bulk.csv    the bulk (finest pitch, 11-09's rule)
  ../2026-11-09-lattice-type-strut-laws/<type>/kfit.csv            today's law (from 10 / 9 cells)

THE POPULATIONS. The law's: the free surface (every placement) and THE OFF-GRIP CUT POPULATION
(`cut_off_grip`: the cut layer's cells off the two grip columns), and the bulk. 11-09's `cut_layer`
(which keeps the cut cells in the grip columns, where its peak sits) is carried for comparison only.

THE LAW PITCH (notes28's rule, unchanged): per fixture (rho, N, cut asked for) the coarsest pitch
the aliasing guard keeps (rho within 15 % of the library's and a free-surface population).

THE ENVELOPE per (rho, N): each coefficient (Kd, Kv, Kild, Kilv) on its own, the max over the bulk
and every law-population point of that width at its law pitch, across the whole cut sweep (the
weakest result: the highest K).
THE MONOTONE RULE: law(N) = max(today's row, max over N' >= N of envelope(N')): a narrower member
is never credited more than a wider one, and never more than any sweep point at its width or wider.

Writes <type>/kenv_sweep.csv (every point), <type>/kenv_widths.csv (the law rows),
<type>/kenv_table.txt (the sweep per row and width, off-grip Kd per cut), kenv_checks.csv (the
pass of (a), per type and check) and prints the verdict.
"""
import csv
import os
import sys

ev = os.path.abspath(sys.argv[1])
OLD = os.path.join(os.path.dirname(ev), "2026-11-25-sheet-laws-thin-members")
WIDE = os.path.join(os.path.dirname(ev), "2026-11-09-lattice-type-strut-laws")
TYPES = ("gyroid", "schwarz_d")
LAWPOPS = ("free_surface", "cut_off_grip")
Q = ("Kd", "Kv", "Kild", "Kilv")
COLS = ("K_dev_max", "K_vol", "K_il_dev", "K_il_vol")


def rows(p):
    if not os.path.exists(p):
        return []
    with open(p) as f:
        return list(csv.DictReader(f))


def layers_of(r):
    if r.get("cut_layers") not in (None, ""):
        return int(r["cut_layers"])
    cut, vpc, n = float(r["cut_frac"]), int(r["vpc"]), int(r["N"])
    return int(round((n + cut) * vpc + 1e-9)) - n * vpc if cut > 0 else 0


def aliased(r):
    lib, meas = float(r["rho_lib"]), float(r["rho_meas"])
    return lib <= 0 or abs(meas - lib) / lib > 0.15


checks = []
summary = {}
for t in TYPES:
    bulk = {}
    for r in rows(os.path.join(OLD, t, "k_exact_bulk.csv")):
        if aliased(r):
            continue
        rho, vpc = float(r["rho_lib"]), int(r["vpc"])
        if rho not in bulk or vpc >= bulk[rho][0]:
            bulk[rho] = (vpc, [float(r[c]) for c in COLS])
    wide = {}
    for r in rows(os.path.join(WIDE, t, "kfit.csv")):
        wide[float(r["rho_lib"])] = [float(r[k]) for k in ("Kd_cert", "Kv_cert", "Kild_cert", "Kilv_cert")]
    old_law = {}
    for r in rows(os.path.join(OLD, t, "kfit_widths.csv")):
        old_law[(float(r["rho_lib"]), int(r["N"]))] = float(r["Kd_law"])

    def key_rho(x, m):
        best = min(m, key=lambda k: abs(k - x)) if m else None
        return best if best is not None and abs(best - x) < 1e-4 else None

    # every exact row -> fixture (rho, N, cut asked, vpc)
    F = {}
    for src, path in (("11-25", os.path.join(OLD, t, "k_exact_w_all.csv")),
                      ("11-26", os.path.join(ev, t, "k_exact_w_all.csv"))):
        for r in rows(path):
            rho = key_rho(float(r["rho_lib"]), bulk)
            if rho is None:
                continue
            k = (rho, int(r["N"]), round(float(r["cut_frac"]), 4), int(r["vpc"]))
            fx = F.setdefault(k, {"pops": {}, "kept": False, "src": src})
            fx["layers"] = layers_of(r)
            fx["wall"] = float(r["wall_vox"])
            fx["wall_true"] = float(r["wall_true_vox"])
            fx["rho_meas"] = float(r["rho_meas"])
            if float(r["n_vox"]) > 0:
                fx["pops"][r["population"]] = [float(r[c]) for c in COLS]
            if r["population"] == "free_surface":
                fx["kept"] = (not aliased(r)) and float(r["K_dev_max"]) > 0
    law_vpc = {}
    for (rho, n, cut, vpc), fx in F.items():
        if fx["kept"] and ((rho, n, cut) not in law_vpc or vpc < law_vpc[(rho, n, cut)]):
            law_vpc[(rho, n, cut)] = vpc
    # the sweep points at the law pitch
    pts = []
    for (rho, n, cut, vpc), fx in sorted(F.items()):
        if law_vpc.get((rho, n, cut)) != vpc:
            continue
        for pop in LAWPOPS + ("cut_layer",):
            if pop in fx["pops"]:
                pts.append(dict(rho=rho, N=n, vpc=vpc, cut=cut, layers=fx["layers"], pop=pop,
                                K=fx["pops"][pop], law=pop in LAWPOPS, src=fx["src"], wall=fx["wall"],
                                wall_true=fx["wall_true"], rho_meas=fx["rho_meas"]))
    with open(os.path.join(ev, t, "kenv_sweep.csv"), "w") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["rho_lib", "N", "vpc", "cut_asked", "cut_layers", "cut_built", "population", "in_law",
                    "Kd", "Kv", "Kild", "Kilv", "rho_meas", "wall_vox", "wall_true_vox", "measured"])
        for p in pts:
            w.writerow([f"{p['rho']:.5f}", p["N"], p["vpc"], f"{p['cut']:.4f}", p["layers"],
                        f"{p['layers'] / p['vpc']:.4f}", p["pop"], int(p["law"])]
                       + [f"{x:.4f}" for x in p["K"]]
                       + [f"{p['rho_meas']:.5f}", f"{p['wall']:.1f}", f"{p['wall_true']:.2f}", p["src"]])
    # the envelope per (rho, N), then the monotone rule
    out, table = [], []
    ok_mono = ok_never = ok_today = ok_cuts = True
    rhos = sorted(bulk)
    for rho in rhos:
        ns = sorted({p["N"] for p in pts if p["rho"] == rho})
        if not ns:
            continue
        env, arg, meta = {}, {}, {}
        for n in ns:
            P = [p for p in pts if p["rho"] == rho and p["N"] == n and p["law"]]
            e = list(bulk[rho][1])
            a = "bulk"
            for p in P:
                for q in range(4):
                    if p["K"][q] > e[q]:
                        e[q] = p["K"][q]
                        if q == 0:
                            a = (f"{'sandwich' if p['cut'] == 0 else 'cut %d/%d' % (p['layers'], p['vpc'])} "
                                 f"{p['pop']}")
            env[n], arg[n] = e, a
            cuts = sorted({(p["layers"], p["vpc"]) for p in P if p["cut"] > 0})
            vp = sorted({p["vpc"] for p in P})
            meta[n] = dict(cuts=cuts, vpcs=vp, fixtures=len({(p["cut"]) for p in P}),
                           wall=min(p["wall"] for p in P), wall_true=min(p["wall_true"] for p in P))
            # the ruling's two cuts, measured and kept at this width
            have = {p["cut"] for p in P if p["pop"] == "cut_off_grip"}
            if not (0.5 in have and 0.6 in have):
                ok_cuts = False
                checks.append((t, rho, n, "cuts_0.5_0.6", "missing", False))
        w0 = wide.get(key_rho(rho, wide), [0.0] * 4) if wide else [0.0] * 4
        run = list(w0)
        law = {}
        for n in sorted(ns, reverse=True):
            run = [max(run[q], env[n][q]) for q in range(4)]
            law[n] = list(run)
        for n in ns:
            m = max((m for m in ns if m >= n), key=lambda m: env[m][0])
            src = "today's row" if w0[0] > env[m][0] else "N%d %s" % (m, arg[m])
            out.append(dict(rho=rho, N=n, meta=meta[n], bulk=bulk[rho][1], env=env[n], law=law[n], wide=w0,
                            arg=arg[n], src=src, old=old_law.get((rho, n), 0.0)))
        # checks: monotone; never above a sweep point (law >= every law point at N' >= N); never under today's
        for i, n in enumerate(ns):
            for m in ns[i + 1:]:
                if any(law[n][q] < law[m][q] - 1e-12 for q in range(4)):
                    ok_mono = False
                    checks.append((t, rho, n, "monotone", f"N{n} credited more than N{m}", False))
            for p in pts:
                if p["rho"] == rho and p["law"] and p["N"] >= n and any(law[n][q] < p["K"][q] - 1e-12 for q in range(4)):
                    ok_never = False
                    checks.append((t, rho, n, "never_above_a_point", f"under N{p['N']} cut {p['cut']} {p['pop']}", False))
            if any(law[n][q] < w0[q] - 1e-12 for q in range(4)):
                ok_today = False
                checks.append((t, rho, n, "never_under_today", "under today's row", False))
        # the sweep table: off-grip Kd per cut layer, per width
        lay = sorted({(p["layers"], p["vpc"]) for p in pts if p["rho"] == rho and p["pop"] == "cut_off_grip"})
        table.append(f"rho {rho:.5f} (bulk Kd {bulk[rho][1][0]:.2f}, today's {w0[0]:.2f}): off-grip Kd per cut "
                     f"(layers / vpc); free = the max free surface over the placements")
        table.append("   N  free  " + " ".join(f"{a:>2d}/{b:<2d}" for a, b in lay) + "   envelope  law")
        for n in ns:
            cells = []
            for a, b in lay:
                v = [p["K"][0] for p in pts if p["rho"] == rho and p["N"] == n and p["pop"] == "cut_off_grip"
                     and p["layers"] == a and p["vpc"] == b]
                cells.append(f"{max(v):5.1f}" if v else "    .")
            fr = max([p["K"][0] for p in pts if p["rho"] == rho and p["N"] == n and p["pop"] == "free_surface"] or [0])
            table.append(f"  {n:2d} {fr:5.1f}  " + " ".join(cells) + f"   {env[n][0]:7.2f}  {law[n][0]:6.2f}")
        table.append("")
    # the sweep is complete: every job of this folder's lists (screen, wide) is kept at its law pitch
    ok_sweep, listed = True, 0
    for jl in ("jobs_1_screen.txt", "jobs_2_wide.txt"):
        p = os.path.join(ev, jl)
        if not os.path.exists(p):
            ok_sweep = False
            checks.append((t, "", "", "sweep_complete", f"{jl} not written yet", False))
            continue
        for line in open(p):
            f_ = line.split()
            if not f_ or f_[0] != "w" or f_[1] != t:
                continue
            rho = key_rho(float(f_[2]), bulk)
            n, vpc = int(f_[3]), int(f_[4])
            for c in f_[5].split(","):
                listed += 1
                cut = round(float(c), 4)
                got = [p_ for p_ in pts if p_["rho"] == rho and p_["N"] == n and p_["pop"] == "cut_off_grip"
                       and p_["cut"] == cut]
                if not got:
                    ok_sweep = False
                    checks.append((t, rho, n, "sweep_complete", f"cut {c} at vpc {vpc} not kept at a law pitch", False))
    checks.append((t, "", "", "sweep_complete", f"every listed sweep fixture ({listed}) kept at its law pitch", ok_sweep))
    checks.append((t, "", "", "cuts_0.5_0.6", "every width of every row has 0.5 and 0.6 kept at its law pitch", ok_cuts))
    checks.append((t, "", "", "monotone", "every coefficient falls (or stays) as the member widens", ok_mono))
    checks.append((t, "", "", "never_above_a_point", "the law is at least every sweep point at its width or wider", ok_never))
    checks.append((t, "", "", "never_under_today", "never under today's row (from 10 / 9 cells)", ok_today))
    summary[t] = ok_sweep and ok_cuts and ok_mono and ok_never and ok_today
    with open(os.path.join(ev, t, "kenv_widths.csv"), "w") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["rho_lib", "N", "vpc_min", "vpc_max", "fixtures", "cut_layers", "wall_vox_min", "wall_true_vox_min"]
                   + [q + "_bulk" for q in Q] + [q + "_env" for q in Q] + [q + "_law" for q in Q]
                   + [q + "_wide" for q in Q] + ["Kd_law_over_wide", "Kd_law_notes28", "argmax_env", "law_from"])
        for o in out:
            m = o["meta"]
            w.writerow([f"{o['rho']:.5f}", o["N"], m["vpcs"][0], m["vpcs"][-1], m["fixtures"],
                        " ".join(f"{a}/{b}" for a, b in m["cuts"]), f"{m['wall']:.1f}", f"{m['wall_true']:.2f}"]
                       + [f"{x:.4f}" for x in o["bulk"]] + [f"{x:.4f}" for x in o["env"]]
                       + [f"{x:.4f}" for x in o["law"]] + [f"{x:.4f}" for x in o["wide"]]
                       + [f"{o['law'][0] / o['wide'][0]:.4f}" if o["wide"][0] > 0 else "0",
                          f"{o['old']:.4f}", o["arg"], o["src"]])
    with open(os.path.join(ev, t, "kenv_table.txt"), "w") as f:
        f.write("\n".join(table) + "\n")
    print(f"== {t}")
    print("\n".join(table))

with open(os.path.join(ev, "kenv_checks.csv"), "w") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["type", "rho", "N", "check", "detail", "pass"])
    for c in checks:
        w.writerow([c[0], f"{c[1]:.5f}" if c[1] != "" else "", c[2], c[3], c[4], int(bool(c[5]))])
for t, v in summary.items():
    print(f"{t}: the envelope law {'PASSES' if v else 'FAILS'} its checks (kenv_checks.csv)")
