#!/usr/bin/env python3
"""s0_table.py — ★ THE §0 TABLE (task 2026-08-12-lattice-page-redesign).

Reads the three arms' receipts and prints the comparison R1 asks for, against
the maintainer's last run: 13,034 latticed voxels, 12% of the part, 507 g
(solid 543.7 g).

Every number here is READ from a receipt. Nothing is computed from an assumption
about the grid, the material or the ladder — where a receipt does not carry a
figure, the cell says so rather than filling it in.

    python3 evidence/2026-08-12-lattice-page-redesign/s0_table.py
"""
import json, os, re, sys, glob

E = os.path.dirname(os.path.abspath(__file__))
ARMS = [
    ("A  his run (5 mm protect / 7 mm lattice)", "mismatch"),
    ("B  depths matched (7 mm / 7 mm)", "matched"),
    ("C  matched + Auto per-region cell", "auto"),
]
HIS = {"latticed_voxels": 13034, "share": 0.12, "mass_g": 507.0, "solid_g": 543.7}


def loadcase(arm):
    p = os.path.join(E, "s0_depth", f"out_{arm}", "loadcase.json")
    return json.load(open(p)) if os.path.exists(p) else None


def log_text(arm):
    p = os.path.join(E, "s0_depth", f"{arm}.log")
    return open(p, encoding="utf-8", errors="ignore").read() if os.path.exists(p) else ""


def lattice_reports(arm):
    """Every rung's lattice receipt, newest rung last."""
    out = []
    for p in sorted(glob.glob(os.path.join(E, "s0_depth", f"out_{arm}", "*_lattice.report.json"))):
        try:
            out.append((os.path.basename(p), json.load(open(p))))
        except Exception:
            pass
    return out


def report(arm):
    p = os.path.join(E, "s0_depth", f"out_{arm}", "report.json")
    return json.load(open(p)) if os.path.exists(p) else None


def fmt(v, spec="{:,.0f}"):
    return "—" if v is None else spec.format(v)


def main():
    print("§0 — THE THREE ARMS, on the maintainer's own job")
    print("task 2026-08-12-lattice-page-redesign · M2_verticalStand.step · res 128")
    print("binary: s0_depth/topopt-cli.snapshot\n")

    # ── THE BARRIER (loadcase stage: available the moment a run starts) ──────
    print("THE BARRIER — what the protection holds against TO")
    print(f"{'arm':<44}{'asked':>8}{'reaches':>10}{'layers':>8}{'voxels held':>14}")
    for label, arm in ARMS:
        lc = loadcase(arm)
        fp = (lc or {}).get("face_protections") or []
        f = fp[0] if fp else {}
        print(f"{label:<44}"
              f"{fmt(f.get('depth_requested_mm'), '{:.3g} mm'):>8}"
              f"{fmt(f.get('depth_effective_mm'), '{:.4g} mm'):>10}"
              f"{fmt(f.get('depth_voxels')):>8}"
              f"{fmt(f.get('voxels_frozen')):>14}")
    print()

    # ── THE PAD, counted apart (§1f) ────────────────────────────────────────
    print("THE ANCHOR PAD, counted apart (§1f) — NOT a face protection")
    lc = loadcase("mismatch")
    ap = (lc or {}).get("anchor_pad") or {}
    line = re.search(r"anchor-pad depth=(\d+) anchor_faces=(\d+) load_faces=(\d+) "
                     r"voxels_frozen=(\d+)", log_text("mismatch"))
    if ap.get("voxels_frozen"):
        print(f"  depth {ap['depth_voxels']} voxels · {ap['anchor_faces']} anchor "
              f"+ {ap['load_faces']} load faces · {ap['voxels_frozen']:,} voxels frozen"
              "   [from the receipt]")
    elif line:
        d, a_, l_, v = (int(x) for x in line.groups())
        print(f"  depth {d} voxels · {a_} anchor + {l_} load faces · {v:,} voxels frozen"
              "   [from the LOG]")
        print("  (these arms ran the snapshot binary, built before the echo carried")
        print("   the pad into loadcase.json — fixed and verified separately in")
        print("   r7/receipt_matches_log.txt)")
    else:
        print("  (no anchor-pad line yet)")
    print()

    # ── THE LATTICE (per rung, once a rung's lattice receipt exists) ─────────
    print("THE LATTICE — per rung, from that rung's own receipt")
    print(f"{'arm':<32}{'rung':>6}{'latticed':>10}{'region vox':>12}"
          f"{'solid fallback':>16}{'mass g':>9}{'cell mm':>9}")
    any_rows = False
    for label, arm in ARMS:
        rows = lattice_reports(arm)
        if not rows:
            print(f"{label[:30]:<32}{'(still running — no rung yet)':>62}")
            continue
        # ★ A RUNG CORE REFUSED HAS NO RECEIPT, and omitting it would read as
        # "not run yet" rather than "emitted nothing" — the difference that
        # matters most in this table. Refusals are read from the log and shown.
        refused = {}
        for m in re.finditer(
                r"vf=([\d.]+) NO LATTICE EMITTED — the grading law could lattice "
                r"NONE of this variant's (\d+) candidate voxels", log_text(arm)):
            refused[f"{float(m.group(1)):.2f}"] = int(m.group(2))
        by_rung = {}
        for name, r in rows:
            m = re.search(r"_(\d+)_lattice", name)
            by_rung[f"{int(m.group(1)) / 100:.2f}" if m else "?"] = r
        for rung in sorted(set(by_rung) | set(refused)):
            any_rows = True
            if rung in refused:
                n = refused[rung]
                print(f"{label[:30]:<32}{rung:>6}{0:>10}{n:>12,}{n:>16,}"
                      f"{'REFUSED':>9}{'—':>9}")
                continue
            r = by_rung[rung]
            g = r.get("grading") or {}
            print(f"{label[:30]:<32}{rung:>6}"
                  f"{fmt(r.get('lattice_voxels')):>10}"
                  f"{fmt(g.get('region_voxels')):>12}"
                  f"{fmt(g.get('solid_fallback_voxels')):>16}"
                  f"{fmt(r.get('lattice_mass_grams'), '{:,.1f}'):>9}"
                  f"{fmt(g.get('cell_size_mm'), '{:.4g}'):>9}")
    print()

    # ── the include-on-void count, the other half of the maintainer's diagnosis
    print("INCLUDE REGIONS OVER VOID — 'a lattice cannot conjure material there'")
    for label, arm in ARMS:
        rows = lattice_reports(arm)
        if not rows:
            continue
        name, r = rows[-1]
        reg = r.get("regions") or {}
        if isinstance(reg, dict):
            print(f"  {label[:44]:<46}"
                  f"include_void_by_optimizer = {fmt(reg.get('include_void_by_optimizer')):>9}")
    print()

    if any_rows:
        print("AGAINST HIS LAST RUN: 13,034 latticed voxels · 12% of the part · "
              "507 g (solid 543.7 g)")
        print("(his include_void_by_optimizer was 120,821)")
    else:
        print("AGAINST HIS LAST RUN (13,034 / 12% / 507 g): no arm has produced a")
        print("lattice receipt yet — the ladder is still running. The barrier table")
        print("above is complete and is what §0(a)/§0(b) ask for.")
    print()

    # ── §0(c): core's own pre-flight, quoted, not paraphrased ───────────────
    t = log_text("mismatch")
    m = re.search(r"\[lattice\] Why: .*", t)
    if m:
        print("§0(c) — CORE'S OWN PRE-FLIGHT ON ARM A (quoted):")
        print("  " + m.group(0)[len("[lattice] "):])


if __name__ == "__main__":
    main()
