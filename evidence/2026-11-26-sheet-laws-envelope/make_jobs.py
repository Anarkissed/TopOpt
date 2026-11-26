#!/usr/bin/env python3
"""The 11-26 cut sweep's job lists (the reviewer's ruling, item 3 (a)). usage:

  python3 -I make_jobs.py screen <this folder>        -> jobs_1_screen.txt
  python3 -I make_jobs.py wide <this folder>          -> jobs_2_wide.txt (reads the screen's parts)

THE SWEEP. Every voxel layer of the law pitch from half a cell up: k / vpc for k = vpc/2 .. vpc-1
(vpc 16: 8..15 layers, 0.5000 .. 0.9375; vpc 24: 12..23, 0.5000 .. 0.9583). The notes28 record
(evidence/2026-11-25-sheet-laws-thin-members) already holds 0.25, 0.5, 0.6 and 0.75 at every width
and row (0.6 is 10 / 16 layers at vpc 16 and 14 / 24 at vpc 24); this folder measures the layers it
does not have.

  SCREEN  every new layer at N = 2, 3, 4 (every row, both sheets).
  WIDE    N = 5, 6, 8 at the screen's worst new layers per row: the TWO with the highest off-grip
          Kd at N = 4 (ties: N = 3) at the vpc 16 rows, the ONE at the two vpc 24 rows (their 8-cell
          blocks are 1.6-1.9 h each). The old layers (0.5, 0.6, 0.75) are already measured at
          every width.

Job line: w <type> <rho> <N> <vpc> <cuts, comma separated, six decimals>.
"""
import csv
import glob
import os
import sys

# (type, rho as the notes28 job lists wrote it, law pitch)
ROWS = [("gyroid", "0.15010", 24), ("gyroid", "0.2", 16), ("gyroid", "0.313", 16),
        ("gyroid", "0.45", 16), ("gyroid", "0.60069", 16),
        ("schwarz_d", "0.20038", 24), ("schwarz_d", "0.313", 16), ("schwarz_d", "0.45", 16),
        ("schwarz_d", "0.60012", 16)]
OLD_CUTS = [0.25, 0.5, 0.6, 0.75]


def layers_of(cut, vpc, n=2):
    """The voxel layers the probe builds for a cut fraction (solve_finite: lround((N + cut) vpc))."""
    return int(round((n + cut) * vpc + 1e-9)) - n * vpc if cut > 0 else 0


def new_layers(vpc):
    old = {layers_of(c, vpc) for c in OLD_CUTS}
    return [k for k in range(vpc // 2, vpc) if k not in old]


def frac(k, vpc):
    return f"{k / vpc:.6f}"


def screen(ev):
    L = ["# 11-26 SWEEP, SCREEN: every new voxel layer from half a cell up, N = 2, 3, 4, every row.",
         "# The vpc 24 rows first (their wide jobs wait on this screen and are the longest)."]
    rows24 = [r for r in ROWS if r[2] == 24]
    rows16 = [r for r in ROWS if r[2] == 16]
    for t, rho, vpc in rows24 + rows16:
        ks = new_layers(vpc)
        for n in (4, 3, 2):
            # a job is at most ~25 min single-threaded: N4 at vpc 24 is ~7 min a cut, split in threes
            chunk = 3 if (vpc == 24 and n == 4) else len(ks)
            for i in range(0, len(ks), chunk):
                L.append(f"w {t} {rho} {n} {vpc} " + ",".join(frac(k, vpc) for k in ks[i:i + chunk]))
    with open(os.path.join(ev, "jobs_1_screen.txt"), "w") as f:
        f.write("\n".join(L) + "\n")
    print(f"jobs_1_screen.txt: {len(L) - 2} jobs")


def read_parts(ev, t):
    out = []
    for p in glob.glob(os.path.join(ev, t, "parts", "k_exact_w_*.csv")):
        with open(p) as f:
            out += list(csv.DictReader(f))
    return out


def wide(ev):
    L = ["# 11-26 SWEEP, WIDE: N = 8, 6, 5 at the screen's worst new layers (make_jobs.py wide);",
         "# longest first (the vpc 24 8-cell blocks, ~2.2-2.8 GB each)."]
    sel_lines = []
    jobs8, jobs6, jobs5 = [], [], []
    for t, rho, vpc in ROWS:
        rows = [r for r in read_parts(ev, t) if abs(float(r["rho_target"]) - float(rho)) < 1e-4
                and int(r["vpc"]) == vpc and r["population"] == "cut_off_grip"
                and abs(float(r["rho_meas"]) - float(r["rho_lib"])) <= 0.15 * float(r["rho_lib"])]
        ks = new_layers(vpc)
        score = {}
        for k in ks:
            def kd(n):
                v = [float(r["K_dev_max"]) for r in rows if int(r["N"]) == n and int(r["cut_layers"]) == k]
                return max(v) if v else -1.0
            score[k] = (kd(4), kd(3))
        missing = [k for k in ks if score[k][0] < 0]
        if missing:
            sys.exit(f"{t} {rho}: the screen has no N=4 off-grip row at layers {missing}: not selecting")
        top = sorted(ks, key=lambda k: score[k], reverse=True)[: (2 if vpc == 16 else 1)]
        sel_lines.append(f"{t} {rho} vpc{vpc}: " + ", ".join(
            f"{k}/{vpc} ({score[k][0]:.3f} at N4, {score[k][1]:.3f} at N3)" for k in top)
            + " | others: " + ", ".join(f"{k}/{vpc} {score[k][0]:.3f}" for k in ks if k not in top))
        cuts = ",".join(frac(k, vpc) for k in top)
        for k in top:
            jobs8.append((vpc, f"w {t} {rho} 8 {vpc} {frac(k, vpc)}"))
            jobs6.append((vpc, f"w {t} {rho} 6 {vpc} {frac(k, vpc)}"))
        jobs5.append((vpc, f"w {t} {rho} 5 {vpc} {cuts}"))
    for group in (jobs8, jobs6, jobs5):
        group.sort(key=lambda x: -x[0])
        L += [j for _, j in group]
    with open(os.path.join(ev, "jobs_2_wide.txt"), "w") as f:
        f.write("\n".join(L) + "\n")
    with open(os.path.join(ev, "wide_selection.txt"), "w") as f:
        f.write("The screen's worst new layers per row (off-grip Kd at N = 4, then N = 3):\n")
        f.write("\n".join(sel_lines) + "\n")
    print("\n".join(sel_lines))
    print(f"jobs_2_wide.txt: {len(L) - 2} jobs")


if __name__ == "__main__":
    {"screen": screen, "wide": wide}[sys.argv[1]](sys.argv[2])
