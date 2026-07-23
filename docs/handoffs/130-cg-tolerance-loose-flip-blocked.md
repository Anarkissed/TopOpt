# 130 — `cg_tolerance_loose` production flip: BLOCKED-STOP (the table is the deliverable)

**Lane:** B (core-only). **Builds on:** 128/PR#158 (the adaptive early CG
tolerance `SimpOptions::cg_tolerance_loose`, opt-in, default 0 = disabled →
byte-identical), 114 (warm-start production flip + `production_parity`), 123
(conditional-projection production-config precedent), the **141 house rule**
(no production flip without design-difference evidence, bar stated BEFORE
measuring). **110** measurement-table template (`warm_start_probe.cpp`).

## TL;DR

**BLOCKED-STOP. No production flip.** The adaptive early CG tolerance was
measured against a design-difference bar stated up front. On the **design-box
whole-domain fixture — the exact regime this flip most targets (125 stagnation
= design-box + clearance)** — arming the loose trajectory tolerance changes the
**shipped** part by `mean|Δρ| ≈ 0.055` and shifts accepted-rung safety margins
by up to **4.65%**, exceeding the bar (`mean|Δρ| ≤ 0.03`, `margin_delta ≤ 3%`).
Crucially the perturbation is a **basin-flip threshold, not a graceful scaling**:
it is already `≈0.055` at the *mildest* loose endpoint tested (`1e-6`, one order
above the tight `1e-8`) and does not shrink toward the tight baseline. A gentler
schedule does not rescue it. Per 141 → the evidence is the deliverable; the
production seam (`configure_production_options`, `run_info`, `production_parity`,
CLI echo) is **left untouched**. The library default `cg_tolerance_loose = 0`
stays dark in production, exactly as it shipped in 128.

## The bar (stated BEFORE measuring)

Within the envelope the warmA flip already signed for (141: `|Δρ|≈0.023`, ~2%):

- terminal / shipped **and** worst-accepted-rung `mean|Δρ| ≤ ~0.03` (loose vs tight),
- per-rung **margin delta ≤ ~3%**,
- **every gate verdict (accept/REJECT) IDENTICAL** loose-vs-tight.

If exceeded → BLOCKED-STOP with the table as the record.

## Method

Harness `core/tests/harness/cg_tol_probe.cpp` (110 template, forked from
`warm_start_probe.cpp`; standalone, **not** wired into CTest). It drives
`minimize_plastic` under the **actual production configuration**
(`configure_production_options` — matrix-free MG + Galerkin cache + conditional
projection + physical min-feature + the production ladder `{0.68,0.52,0.38,0.26}`),
toggling **only** `simp.cg_tolerance_loose`, so the table measures the literal
flip: production-with-loose vs production-without.

- **Fixture 1 — L-BRACKET LOADCASE:** the 080/082/ladder-gate thin L-bracket
  (8×3×8, 84 solid voxels), external tip load −30 N.
- **Fixture 2 — DESIGN-BOX (whole-domain):** the same L-bracket part inside a
  snug whole-domain design box (`test_designbox_reduction`'s device repro), tip
  load. This is the whole-domain regime where trajectory solves cold-grind and
  the loose-CG payoff is claimed.

**Loose-endpoint sweep** `{1e-6, 1e-5, 1e-4, 1e-3}` vs the tight baseline
(`cg_tolerance_loose = 0`), so the table also answers the maintainer's first
question — "does a gentler schedule stay within the bar?" (`1e-3` is the 128 §B
production value; tight `cg_tolerance = 1e-8`).

**Thermal protocol (113):** iteration counts, CG-iter totals, margins, achieved
fractions, gate verdicts and `|Δρ|` are **deterministic** — the harness asserts
it (`repeat_max|Δρ| = 0.00e+00` on a re-run of every mode; see the tables) — so
they are captured once, exact, thermal-free. Wall-clock is thermally
contaminated (±~30% on this box), reported as the **median of 3** interleaved
repeats with the band; treat the **CG-iter ratio, not the wall ratio**, as the
cost figure.

## The table (verbatim)

### Fixture 1 — L-BRACKET LOADCASE (grid 8×3×8, 84 solid voxels)

```
[tight ] rungs=2 total_iters=357 total_cg=60809  wall=0.45s  repeat_max|drho|=0.00e+00
    vf=0.68  iters=159  cg=21223  achieved=0.6800  margin=1.612  C=29.1945  accept
    vf=0.52  iters=198  cg=39586  achieved=0.5200  margin=1.471  C=39.4733  REJECT
[1e-6]  total_cg=59897   vf0.68 margin=1.612 C=29.1945 accept | vf0.52 margin=1.471 C=39.4733 REJECT
[1e-5]  total_cg=55854   vf0.68 margin=1.612 C=29.1945 accept | vf0.52 margin=1.471 C=39.4733 REJECT
[1e-4]  total_cg=54703   vf0.68 margin=1.612 C=29.1945 accept | vf0.52 margin=1.471 C=39.4733 REJECT
[1e-3]  total_cg=57388   vf0.68 margin=1.612 C=29.1945 accept | vf0.52 margin=1.471 C=39.4733 REJECT

design difference vs tight (bar: mean|drho|<=0.03, margin_delta<=3%, gate OK):
  1e-6  cg_ratio=1.02x gate=OK | SHIPPED vf=0.68 mean|drho|=0.00000 max=0.000 | worst-accepted mean|drho|=0.00000 margin_delta=0.00% C_delta=0.00%
  1e-5  cg_ratio=1.09x gate=OK | SHIPPED vf=0.68 mean|drho|=0.00000 max=0.000 | worst-accepted mean|drho|=0.00000 margin_delta=0.00% C_delta=0.00%
  1e-4  cg_ratio=1.11x gate=OK | SHIPPED vf=0.68 mean|drho|=0.00000 max=0.000 | worst-accepted mean|drho|=0.00000 margin_delta=0.00% C_delta=0.00%
  1e-3  cg_ratio=1.06x gate=OK | SHIPPED vf=0.68 mean|drho|=0.00000 max=0.000 | worst-accepted mean|drho|=0.00000 margin_delta=0.00% C_delta=0.00%
```

**Within bar at every loose endpoint.** The shipped part (accepted heaviest rung
vf=0.68) is byte-identical (`mean|Δρ|=0.00000`). The only motion is on the
**REJECTED** light rung (vf=0.52), which at 1e-3 shows `mean|Δρ|=0.247`,
`max|Δρ|=1.0` at **identical compliance (39.4733)** — a degenerate-basin flip on
a rung that never ships. Gate verdicts identical.

### Fixture 2 — DESIGN-BOX whole-domain (grid 8×3×8, 84 solid voxels, snug box)

```
[tight ] rungs=4 total_iters=1130 total_cg=223426  wall=8.6s  repeat_max|drho|=0.00e+00
    vf=0.68  iters=191  cg=20990   achieved=0.6786  margin=4.170  C=4.70347  accept
    vf=0.52  iters=271  cg=32855   achieved=0.5238  margin=3.147  C=6.54262  accept
    vf=0.38  iters=299  cg=40546   achieved=0.3810  margin=2.163  C=13.3872  accept
    vf=0.26  iters=369  cg=129035  achieved=0.2738  margin=0.786  C=57.3042  REJECT
[1e-6]  total_cg=194831  vf0.68 m=4.033 C=4.663 acc | vf0.52 m=3.145 C=6.785 acc | vf0.38 m=2.163 C=13.386 acc | vf0.26 m=0.753 C=56.71 REJECT
[1e-5]  total_cg=196025  vf0.68 m=4.033 C=4.663 acc | vf0.52 m=3.150 C=6.640 acc | vf0.38 m=2.163 C=13.392 acc | vf0.26 m=0.411 C=614.3 REJECT
[1e-4]  total_cg=185228  vf0.68 m=4.033 C=4.663 acc | vf0.52 m=3.144 C=6.785 acc | vf0.38 m=2.163 C=13.387 acc | vf0.26 m=0.719 C=70.33 REJECT
[1e-3]  total_cg=186429  vf0.68 m=4.093 C=4.464 acc | vf0.52 m=3.293 C=6.659 acc | vf0.38 m=2.163 C=13.396 acc | vf0.26 m=0.772 C=57.22 REJECT

design difference vs tight (bar: mean|drho|<=0.03, margin_delta<=3%, gate OK):
  1e-6  cg_ratio=1.15x gate=OK | SHIPPED vf=0.38 mean|drho|=0.05483 max=1.000 | worst-accepted mean|drho|=0.10371 margin_delta=3.28% C_delta=3.70%
  1e-5  cg_ratio=1.14x gate=OK | SHIPPED vf=0.38 mean|drho|=0.05483 max=1.000 | worst-accepted mean|drho|=0.05483 margin_delta=3.28% C_delta=1.48%
  1e-4  cg_ratio=1.21x gate=OK | SHIPPED vf=0.38 mean|drho|=0.05482 max=1.000 | worst-accepted mean|drho|=0.05482 margin_delta=3.28% C_delta=3.71%
  1e-3  cg_ratio=1.20x gate=OK | SHIPPED vf=0.38 mean|drho|=0.05485 max=1.000 | worst-accepted mean|drho|=0.08470 margin_delta=4.65% C_delta=5.09%
```

**Exceeds the bar at EVERY loose endpoint.** The shipped part (last accepted rung
vf=0.38) changes by `mean|Δρ| ≈ 0.055` with full voxel flips (`max|Δρ|=1.0`);
worst-accepted margin delta 3.28–4.65% (> 3%); accepted-rung compliance shifts up
to 5.09%. It does not decay toward the tight baseline as the loose endpoint
tightens (basin-flip threshold). Two rejected light rungs are wildly unstable
under any looseness — at 1e-5 rung vf=0.26 blows up to `C=614` (compliance ×10.7,
`C_delta ≈ 972%`); rejected, never shipped, but it shows the light end of the
whole-domain ladder sits on a knife-edge that trajectory looseness tips.

## Verdict

Gate verdicts stayed identical on both fixtures — good — and Fixture 1's shipped
part is byte-identical. But **Fixture 2 (the design-box regime this flip exists to
accelerate) fails the bar on both the `mean|Δρ|` and `margin_delta` criteria, at
every loose endpoint down to 1e-6.** By the 141 rule the flip is BLOCKED. The
determinism self-check (`repeat_max|Δρ|=0` throughout) rules out measurement noise:
these are real, reproducible different optima.

## Honest claim calibration (the cost side)

The 128 headline **2.1× fewer Jacobi CG iters is per-solve, in the pure
Jacobi-stagnation regime** (a stagnating 32³ checker, MG latched off, cold-Jacobi
grind, tol 1e-8→1e-3: 440→207 iters). **These fixtures do not reproduce that
regime** (small grids; MG carries or the fallback is not a latched grind), so the
**end-to-end** saving here is only **cg_ratio 1.06–1.21×** — a 6–21% reduction in
total trajectory CG iters, not 2.1×. That is exactly the calibration the task
demanded: 2.1× is a per-solve, regime-specific number; the measured end-to-end
gain on production-shaped MMA ladders is far smaller. So the trade on offer is
**~15% fewer CG iters in exchange for a shipped-part design change that exceeds the
safety envelope** — a bad trade, independent of any speedup argument.

## What would unblock a future revisit (NOT done here)

Out of scope for this task (the discipline is to stop at the bar), noted for the
maintainer:

1. **A design-difference-bounded schedule.** The current schedule keys tolerance
   to `max|Δρ|` only. A schedule that also *never loosens once the design-region
   `Mnd`/motion says the topology is committing* might keep the whole-domain
   basin from flipping. Would need its own 110-template re-measure against this
   same bar.
2. **Larger-fixture confirmation.** These are deliberately the tiny fixtures the
   141/warmA envelope was itself calibrated on (apples-to-apples), where basins
   are most degenerate. A 48³/64³ design-box confirmation could show whether the
   basin-flip is tininess-amplified or real at production scale — but the bar is
   the bar, and on the calibrated yardstick it is exceeded.
3. **Restricting arming to the confirmed-stagnation path only** (where MG has
   latched off and the 2.1× actually applies), rather than all trajectory solves —
   couples the design-risk to the regime that pays for it.

None of these are attempted here; each is a separate measured task.

## Gates / provenance

- **No production code changed.** `git diff main -- core/src core/include` is
  **empty**; the only additions are the harness `core/tests/harness/cg_tol_probe.cpp`
  and this handoff + evidence. `cg_tolerance_loose` remains at its library default
  `0` (disabled), so production is **byte-identical to main / pre-128**. Byte-identity
  with the option disabled is therefore trivially preserved (nothing to flip).
- **Full ctest: 100% passed, 60/60** (761 s) — raw in
  `docs/handoffs/evidence/129/ctest_raw.txt`. Includes `production_parity` (#57,
  the seam a flip would have extended) green on the untouched config, and
  `cli_demo` (#56). Expected, since no production code changed.

## Evidence (cited)

- `docs/handoffs/evidence/129/cg_tol_probe_stdout.txt` — full harness stdout (both
  fixtures, five modes, per-rung, wall band, determinism check).
- `docs/handoffs/evidence/129/fixture1_l_bracket_loadcase.csv` — Fixture 1 ladder,
  machine-readable (mode×rung, iters, cg_iters, margin, compliance, `Δρ` vs tight).
- `docs/handoffs/evidence/129/fixture2_design_box.csv` — Fixture 2 ladder (same
  columns) — the CSV that carries the BLOCKED evidence.
- Reproduce:
  ```
  cmake --build core/build --target topopt -j8
  c++ -std=c++17 -O2 -I core/include -I /opt/homebrew/include/eigen3 \
    -DSETTINGS_RULES_PATH="\"$PWD/core/src/settings/rules.json\"" \
    core/tests/harness/cg_tol_probe.cpp core/build/libtopopt.a -o /tmp/cg_tol_probe
  TOPOPT_CG_PROBE_CSV_DIR=docs/handoffs/evidence/129 /tmp/cg_tol_probe
  ```
