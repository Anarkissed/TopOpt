#!/usr/bin/env python3
"""R2 — the instruments are PR 299/306/307's, INCLUDED not retyped, so this
task's SIMP rows must equal PR 319's to the last printed digit.

Compares this task's `s2_reference_impl_vs_simp.csv` SIMP rows against PR 319's
committed `s2_semdot_vs_simp.csv` SIMP rows, on every column the two share.
Exits non-zero on any difference."""
import csv, sys, os
here = os.path.dirname(os.path.abspath(__file__))
mine = os.path.join(here, "s2_reference_impl_vs_simp.csv")
theirs = os.path.join(here, "baseline_pr319_s2_semdot_vs_simp.csv")
def rows(p, arm="SIMP"):
    with open(p) as f:
        return {r["rung"]: r for r in csv.DictReader(f) if r["arm"] == arm}
A, B = rows(mine), rows(theirs)
shared_rungs = sorted(set(A) & set(B))
if not shared_rungs:
    print("FAIL: no shared SIMP rungs"); sys.exit(1)
cols = sorted(set(next(iter(A.values()))) & set(next(iter(B.values()))) - {"arm", "rung"})
bad, n = [], 0
for rg in shared_rungs:
    for c in cols:
        n += 1
        a, b = A[rg][c], B[rg][c]
        try:
            same = abs(float(a) - float(b)) <= 1e-6 * max(1.0, abs(float(b)))
        except ValueError:
            same = a == b
        if not same:
            bad.append(f"  rung {rg} {c}: mine={a} PR319={b}")
print(f"SIMP rungs compared : {', '.join(shared_rungs)}")
print(f"shared columns      : {len(cols)}")
print(f"fields compared     : {n}")
print(f"fields differing    : {len(bad)}")
for b in bad: print(b)
print("PASS — this task's SIMP rows ARE PR 319's" if not bad else "FAIL")
sys.exit(1 if bad else 0)
