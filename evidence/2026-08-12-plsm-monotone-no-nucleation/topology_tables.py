#!/usr/bin/env python3
"""The topology curves — the task's headline.

Component count AND Euler characteristic, as the brief requires, because in 3D
a hole can be TUNNELLED through material without any new component appearing:
the void stays connected and b1 rises. Component monotonicity alone would call
that legal, so b1 is reported beside b0 and a rise in b1 with b0 flat is the
constraint being satisfied and evaded at once.
"""
import csv, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
arms = sys.argv[1:]

def load(a):
    p = os.path.join(HERE, "arms", a, "iterations.csv")
    if not os.path.exists(p): return []
    return list(csv.DictReader(open(p)))

def col(rows, k, cast=float):
    out = []
    for r in rows:
        v = r.get(k, "")
        try: out.append(cast(v))
        except (ValueError, TypeError): out.append(None)
    return out

data = {a: load(a) for a in arms}
data = {a: r for a, r in data.items() if r}

print("=" * 78)
print("M3 — THE TOPOLOGY CURVES")
print("=" * 78)

# ── the headline: does the constraint hold, and what was it fighting?
print("\n★ PER ARM — the whole run in one row\n")
hdr = (f"{'arm':14s} {'it':>3s} {'b0 first':>9s} {'b0 last':>8s} {'b0 max':>7s} "
       f"{'NEW tot':>8s} {'SPLIT tot':>10s} {'viol':>5s} {'revert':>7s} "
       f"{'chi last':>9s} {'b1 last':>8s} {'cav':>4s}")
print(hdr); print("-" * len(hdr))
for a, rows in data.items():
    b0 = [x for x in col(rows, "void_components") if x is not None]
    new = [x for x in col(rows, "new_components") if x is not None]
    spl = [x for x in col(rows, "split_delta") if x is not None]
    vio = col(rows, "mono_violations"); rev = col(rows, "mono_reverts")
    chi = col(rows, "euler_chi"); tun = col(rows, "tunnels"); cav = col(rows, "cavities")
    if not b0: continue
    print(f"{a:14s} {len(rows):3d} {b0[0]:9.0f} {b0[-1]:8.0f} {max(b0):7.0f} "
          f"{sum(new):8.0f} {sum(spl):10.0f} {vio[-1] or 0:5.0f} {rev[-1] or 0:7.0f} "
          f"{chi[-1] or 0:9.0f} {tun[-1] or 0:8.0f} {cav[-1] or 0:4.0f}")

print("\n★ b0 = void components. NEW = components sharing no voxel with any")
print("  previous void. SPLIT = the rest of the change in b0, i.e. existing void")
print("  fragmenting as solid bridges across it. b1 = tunnels = b0 + b2 - chi.")

# ── the per-iteration curves
for a, rows in data.items():
    print("\n" + "=" * 78)
    print(f"{a} — per iteration")
    print("=" * 78)
    print(f"{'it':>3s} {'b0':>6s} {'d(b0)':>6s} {'NEW':>5s} {'SPLIT':>6s} "
          f"{'chi':>7s} {'b1':>6s} {'cav':>4s} {'viol':>5s} {'rev':>4s} {'compliance':>13s}")
    prev = None
    for r in rows:
        try: b = int(float(r["void_components"]))
        except (ValueError, TypeError, KeyError): continue
        d = "" if prev is None else f"{b - prev:+d}"
        prev = b
        def g(k, f="{:.0f}"):
            try: return f.format(float(r[k]))
            except (ValueError, TypeError, KeyError): return "-"
        print(f"{g('iteration'):>3s} {b:6d} {d:>6s} {g('new_components'):>5s} "
              f"{g('split_delta'):>6s} {g('euler_chi'):>7s} {g('tunnels'):>6s} "
              f"{g('cavities'):>4s} {g('mono_violations'):>5s} {g('mono_reverts'):>4s} "
              f"{g('compliance','{:.10f}'):>13s}")

# ── ★ the 3D evasion check the brief demands
print("\n" + "=" * 78)
print("★ THE 3D CAVEAT — is the constraint being satisfied AND evaded?")
print("=" * 78)
print("A hole tunnelled through material raises b1 without raising b0. If a")
print("monotone arm holds b0 flat while b1 climbs, the constraint is not doing")
print("what it was asked to do.\n")
for a, rows in data.items():
    b0 = [x for x in col(rows, "void_components") if x is not None]
    b1 = [x for x in col(rows, "tunnels") if x is not None]
    if len(b0) < 2 or len(b1) < 2: continue
    db0, db1 = b0[-1] - b0[0], b1[-1] - b1[0]
    verdict = ("★ EVADED — b0 held, b1 climbed" if db0 <= 0 < db1
               else "b0 rose too" if db0 > 0
               else "clean — neither rose")
    print(f"  {a:14s} d(b0) {db0:+7.0f}   d(b1) {db1:+7.0f}   {verdict}")
