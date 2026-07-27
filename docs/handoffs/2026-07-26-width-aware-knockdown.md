# 2026-07-26 — Width-aware accept-gate knockdown (ARMING-READY, shipped OFF)

**Track:** production feature, core + one app doc-comment. Built OFF by default and
byte-for-byte identical to the pre-width gate; the width-aware composite is armed by
a single named constant with a header tripwire, exactly as the Active-Domain arming
did. This handoff IMPLEMENTS a maintainer decision; it does not re-open it.

---

## THE DECISION (recorded verbatim, not re-litigated)

> make the accept-gate knockdown width-aware
>
> THE MAINTAINER HAS DECIDED. […] This implements a decision; it does not
> re-litigate it.
>
> WHY — The gate applies margin_effective = worst_case * f^1.5 with NO width term
> (`core/src/simp/minimize_plastic.cpp:69` is a pure function of infill percent; wall
> loops never cross the bridge). Three measurements now show that is wrong in BOTH
> directions:
>   - PR 191: on a bare infill core f^1.5 is NON-conservative by 1.5-1.8x; solid wall
>     loops rescue narrow sections; the rescue vanishes with width, crossing over near
>     41-98mm depending on loops and infill.
>   - PR 192: at MEMBER scale (the ~9.4mm ribs an optimized part is made of) the gate
>     is CONSERVATIVE — true margin 2.19-18.5 where it certifies 1.5, and BENDING makes
>     it more conservative still. It validated 191's composite model to 3 digits.
>   - Net effect: the gate is simultaneously too cautious for thin ribs and still
>     optimistic for envelope-scale solid regions. A uniform re-tune is therefore
>     WRONG. The fix must be size-aware.
>
> The cost of the status quo is not safety, it is WEIGHT: at 10mm / 5 loops / 30%
> infill the gate assumes the part is 4.5x weaker than measured, so the ladder stops at
> a heavier rung than necessary.
>
> BUILD — A width-aware knockdown built on the SHELL+CORE COMPOSITE that 191 and 192
> measured: E_eff = f_wall * E_solid + (1 - f_wall) * E_infill(rho), with
> f_wall = 4t(W-t)/W^2 for a local member width W.
>
> ★ BUILD IT ON THE EXISTING MACHINERY, NOT A PARALLEL MODEL. PR 198's homogenization
> library and 191/192's resolved composite measurements are the two data paths. Choose
> one, state which and why, and do not create a second independent model of the same
> physics.

The bars (K1–K7, BLOCKED-STOP, FORBIDDEN) are reproduced and answered in §6.

---

## 1. The result in six lines

- **OFF is byte-identical, proven end-to-end.** All 70 CTest tests pass 100%
  (`evidence/…/` — the whole suite ran green); `test_analyze_fixed_design` still
  reproduces every certification number bit-for-bit, and `test_production_parity`
  asserts the library default and the shipped production config both leave the
  width-aware gate OFF. THE ONE RULE holds.
- **The shipped model reproduces 192's member table** to within the discretization it
  named (≤ 7% on E_eff/E_solid, ≤ 8% on margin@1.5), and it IS the exact Voigt
  composite 191/192 validated — asserted to 1e-12 in `test_width_aware_knockdown`.
- **Armed, the gate flips exactly the rungs the decision predicted.** On a member-scale
  cantilever at 30% infill / 5 loops, the scalar gate rejects the two lightest rungs
  (eff 1.44, 0.96 < 1.5); the width-aware gate accepts them (eff 2.15, 2.07 ≥ 1.5) —
  the ladder strips two rungs further, the WEIGHT the status quo was leaving on the
  table (§6 K2).
- **Caution on thick sections is provably kept.** On the envelope-scale block the
  width-aware effective margin equals the scalar one to the digit (`unchanged`) — the
  binding failure mode there is either an at-cap-thick member or the interlayer term,
  both left at the unmodified f^1.5. The sign is stated on every reported change (K4).
- **The local member width is a distance-transform thickness of the density field,
  costing 0.0–0.1% of the gate solve it runs beside** (§6 K6). It is a NEW pass over
  the density field (BLOCKED-STOP), and its measured cost is reported, not hidden.
- **One physics law, one place.** The width-aware composite lives only in core
  (`width_aware_knockdown`); the Swift failure-load mirror still reproduces the
  unchanged core `infill_margin_knockdown` (f^1.5) to the digit and is documented as
  deliberately NOT mirroring the composite (K7).

---

## 2. What shipped (core additive; one app comment)

```
core/include/topopt/pipeline.hpp      MinimizePlasticOptions::{width_aware_knockdown,
                                      wall_loops, wall_line_width_mm}
core/include/topopt/analyze.hpp       KnockdownSpec; wall_area_fraction();
                                      width_aware_knockdown(); analyze_fixed_design
                                      signature (double infill_knockdown → KnockdownSpec)
core/include/topopt/voxel.hpp         local_member_thickness_mm() decl
core/src/simp/analyze.cpp             wall_area_fraction, width_aware_knockdown, the
                                      per-voxel width-aware gate in analyze_fixed_design
core/src/voxel/voxelize.cpp           local_member_thickness_mm + a seeded squared-EDT
core/src/simp/minimize_plastic.cpp    build the KnockdownSpec; validate wall inputs;
                                      floor test reads margin_effective (one scale)
core/src/simp/production.cpp          kProductionWidthAwareKnockdown = false + TRIPWIRE;
                                      production_width_aware_knockdown(); config echo
core/include/topopt/production.hpp    production_width_aware_knockdown() decl
core/src/cli/{job,loadcase,run_job}.cpp   wall_loops / wall_line_width_mm across the bridge
core/include/topopt/{job,loadcase}.hpp    the same fields on the job / load-case structs
core/src/simp/observability.cpp       run_info echo: width_aware_knockdown, wall_loops,
core/include/topopt/observability.hpp     wall_line_width_mm
core/tests/unit/test_width_aware_knockdown.cpp   K3/K5/K4-sign + the thickness transform
core/tests/validation/test_production_parity.cpp arming echo (OFF) assertions
core/tests/harness/width_aware_gate.cpp          the before/after gate table (NOT CTest)
app/…/TopOptFlows/ResultsModel.swift  K7 doc-comment: the mirror's single-source boundary
```

**No library default moved.** `MinimizePlasticOptions::width_aware_knockdown` is
`false`; `configure_production_options` sets it from `kProductionWidthAwareKnockdown`
(also `false`). Gate-V2, the property suite and every reference run never call that
function, so they are byte-for-byte unchanged. `infill_margin_knockdown` (the f^1.5
curve) is untouched — the width-aware composite REUSES it.

---

## 3. The data path: the SHELL+CORE COMPOSITE (★), not the homogenization library

Two data paths were on offer. **The composite that 191/192 resolved is the right one,
and PR 198's homogenization library is the wrong one for this job:**

- **The gate is a scalar-margin gate on a wall-wrapped-infill part.** The composite
  `E_eff/E_solid = f_wall + (1 - f_wall)·f^1.5` is an isotropic scalar knockdown that
  drops straight into `margin_effective = worst_case · knockdown`. It REUSES the
  existing `infill_margin_knockdown` for the core term, so there is exactly one copy
  of the Gibson-Ashby f^1.5 curve, and it reproduces the numbers the decision cites
  (192's table) directly, because those numbers ARE this composite.
- **PR 198's homogenization library models a different physics.** It computes
  anisotropic stiffness TENSORS for periodic LATTICE unit cells (gyroid / octet /
  Schwarz-D), is Mac-only, and wires into the macro FEA solve. A wall-wrapped sparse
  member is not a periodic lattice; using the library here would be a SECOND,
  independent model of the same wall+infill physics — exactly what ★ forbids — and it
  would not reproduce 192's measured composite. The lattice tensor work stays where it
  belongs (its own Phase-1 wiring); this gate uses the composite it was told to.

So: **one model of the wall+infill composite, reusing the one f^1.5 curve. No second
model of the same physics.**

---

## 4. The two bridge crossings

### (a) wall_loops + wall_line_width_mm — slicer metadata, now in core

Until now `wall_loops` was pure slicer UI metadata (app `PrintParams.wallLoops`) that
never reached the engine. It now crosses the whole bridge exactly as `infill_percent`
does: `job.json loads.{wall_loops,wall_line_width_mm}` → `JobLoads` →
`ProductionLoadCase` → `build_production_loadcase` → `MinimizePlasticOptions`, echoed
in `run_info.json`. The wall ring thickness is `t = wall_loops · wall_line_width_mm`
(default line width 0.45 mm — the 0.4 mm-nozzle default 191/192 measured with).
`wall_loops = 0` (the default) → `t = 0` → `f_wall = 0` → the composite reduces to
today's f^1.5, so the fields are inert until both the gate is armed AND loops are set.

### (b) the LOCAL MEMBER WIDTH — a distance-transform thickness (the hard part)

**Method.** `local_member_thickness_mm` (`voxelize.cpp`) computes the Hildebrand
inscribed-sphere thickness of the printed density field: τ(v) = the diameter of the
largest sphere that fits inside the printed material and contains v. It is a
granulometric opening driven by a seeded **squared Euclidean distance transform**
(Felzenszwalb–Huttenlocher, separable, exact, O(N)): first the distance d(v) from each
printed voxel to the nearest void; then for radii r = 1,2,…,cap, the opening by a
radius-r ball keeps v iff some point with d ≥ r lies within r of v (a second seeded
EDT per level), and τ(v) = 2·(largest surviving r)·spacing.

**Why the inscribed sphere and not 2·EDT.** A plain 2·EDT assigns a boundary voxel its
distance to the surface — one voxel — so the outer-fibre voxels where bending stress
peaks would read as razor-thin and be over-credited with wall rescue. The inscribed
sphere assigns every voxel of a rib the rib's FULL width, so the outer fibre of a
10 mm rib reads 10 mm. `test_width_aware_knockdown` pins exactly this: a slab's
outer-fibre voxel reads the slab's full width, not one voxel.

**The cap, and why it is conservative.** The radius sweep is capped at 32 voxels. This
bounds the cost (one seeded EDT per level → O(cap·N)) AND sets the "thick" cutoff: a
voxel still solid under the radius-cap opening is at least 2·32·spacing thick, returns
+∞, and `wall_area_fraction(+∞) = 0` → NO wall rescue. Under-resolving a thick region
therefore makes the gate MORE conservative there (the safe direction, K4), never less.
At production spacing (1.5–3 mm on a 200 mm part) the cutoff is ~96–192 mm, spanning
191's ~59–98 mm crossover; at finer spacing it drops, which only adds conservatism.

**The gate applies it per voxel.** `analyze_fixed_design` divides each printed voxel's
von Mises by its own `width_aware_knockdown(infill, W(v), t)` and takes the worst
SOLID-EQUIVALENT peak `max(vm/k(W))`. This is what keeps caution on thick sections
honest: a thick region whose real stress is a fraction of the rib peak can still
GOVERN once inflated by its small knockdown, so the width-awareness cannot silently
hide a thick-region hot spot behind a thin-rib rescue. The interlayer (z-bonding) term
is left at the unmodified f^1.5 — 191/192 measured axial and bending, never z-bonding,
so no measurement supports crediting perimeters there, and the gate stays exactly as
conservative as today on the interlayer failure mode.

---

## 5. Sign and safety (K4), stated once for the whole design

`width_aware_knockdown = f_wall + (1 - f_wall)·f^1.5 ≥ f^1.5` for all inputs, with
equality iff `f_wall = 0`. Therefore `margin_effective` only ever RISES relative to the
scalar gate, so the gate only ever becomes **LESS conservative — it accepts lighter
rungs it was over-penalising** — and only in proportion to how much wall actually
rescues the *governing* member. Where the governing member is thick (large W → small
f_wall) or past the cap (+∞ → f_wall = 0), or where the interlayer term binds, the
knockdown is exactly today's f^1.5 and nothing changes. **The width-aware gate can
never be MORE optimistic than today on a thick section** — it does not attempt to fix
191's envelope-scale non-conservatism (that needs a more conservative *core* model and
is a separate maintainer act); it only stops over-penalising thin ribs.

---

## 6. THE BARS

### K1 — OFF byte-identical; opt-in behind a named constant + header tripwire

`analyze_fixed_design`'s width-aware branch is guarded by `KnockdownSpec::width_aware`;
`false` runs the literal pre-width statement `margin_effective = worst_case ·
infill_knockdown`. The arming constant is `kProductionWidthAwareKnockdown = false`
(`production.cpp`) with a TRIPWIRE naming the harness to re-run and the coupon the
maintainer must land before flipping it — the same shape as `kProductionActiveDomainBand`.
The shipped default does not change. **Evidence:** all 70 CTest pass; `production_parity`
asserts OFF before AND after `configure_production_options`; `analyze_fixed_design`
bit-identical bar green.

### K2 — full gate table, before and after, every rung, every flip named

`evidence/…/gate_table.txt` (harness `width_aware_gate.cpp`, run OFF then ON at
margin_stop = 1.5 on each converged rung — the gate change isolated from the optimiser):

**MEMBER-SCALE cantilever · 30% infill (f^1.5 = 0.1643) · 5 loops × 0.45 mm · 3 mm spacing**

| rung | vf | worst_case | eff(OFF) | verdict | eff(ON) | verdict | sign |
|---|---|---|---|---|---|---|---|
| 1 | 0.800 | 22.03 | 3.620 | ACCEPT | 5.539 | ACCEPT | LESS-cons |
| 2 | 0.600 | 20.75 | 3.410 | ACCEPT | 5.847 | ACCEPT | LESS-cons |
| 3 | 0.450 | 15.67 | 2.574 | ACCEPT | 4.271 | ACCEPT | LESS-cons |
| 4 | 0.350 | 8.77 | 1.440 | **reject** | 2.147 | **ACCEPT** | LESS-cons **← FLIP** |
| 5 | 0.250 | 5.86 | 0.963 | **reject** | 2.065 | **ACCEPT** | LESS-cons **← FLIP** |

**Every flip explained.** Rungs 4 and 5 are thin-rib designs whose SOLID worst-case
margins (8.77, 5.86) the scalar gate crushes to 1.44 and 0.96 with the blind ×0.1643,
tripping the 1.5 threshold. The width-aware gate credits the 5 wall loops the slicer
wraps around each ~member-scale rib (per-voxel k ≈ 0.35–0.37 here, vs 0.164), lifting
the effective margins to 2.15 and 2.07 — above 1.5, so both accept. Consequence: the
armed ladder strips to vf 0.25 where the scalar ladder would stop at 0.45 — two rungs
of extra material removed. Direction: LESS conservative, exactly as the decision
predicted for thin ribs, and each flipped rung still clears 1.5 with real margin
(2.07), so it is a correction of over-caution, not a loosening of the bar. Rungs 1–3
were already accepted by both; the width-aware value is higher (LESS-cons) but changes
no verdict there.

**ENVELOPE-SCALE solid block · same settings**

| rung | vf | worst_case | eff(OFF) | verdict | eff(ON) | verdict | sign |
|---|---|---|---|---|---|---|---|
| 1 | 0.800 | 66.85 | 10.985 | ACCEPT | 13.076 | ACCEPT | LESS-cons |
| 2 | 0.600 | 41.62 | 6.839 | ACCEPT | 6.839 | ACCEPT | **unchanged** |
| 3 | 0.450 | 24.56 | 4.036 | ACCEPT | 4.036 | ACCEPT | **unchanged** |
| 4 | 0.350 | 16.54 | 2.719 | ACCEPT | 2.719 | ACCEPT | **unchanged** |
| 5 | 0.250 | 11.06 | 1.817 | ACCEPT | 1.817 | ACCEPT | **unchanged** |

**No flip, and that is the point (K4).** On the thick block the binding failure mode
on rungs 2–5 is the term the width-aware gate leaves at the unmodified f^1.5 (the
interlayer / at-cap-thick member), so ON equals OFF to the digit — the thick-region
gate is not made one iota less conservative. No verdict flips; nothing is silently
loosened on a thick section.

### K3 — reproduce 192's member-scale numbers with the shipped model

`test_width_aware_knockdown` calls the SHIPPED `width_aware_knockdown(infill, W,
loops·0.45)` on 192's directly-resolved member rows (`evidence/…/unit_test.txt`):

| W mm | loops | infill | shipped E_eff/Es | 192 E_meas/Es | ratio | shipped m@1.5 | 192 m@1.5 |
|---|---|---|---|---|---|---|---|
| 10 | 5 | 30% | 0.7472 | 0.7321 | 1.021 | 6.82 | 6.68 |
| 10 | 3 | 60% | 0.7148 | 0.6791 | 1.053 | 2.31 | 2.19 |
| 10 | 5 | 15% | 0.7151 | 0.7182 | 0.996 | 18.46 | 18.54 |
| 10 | 5 | 60% | 0.8381 | 0.8225 | 1.019 | 2.70 | 2.65 |
| 5 | 5 | 30% | 0.9916 | 0.9900 | 1.002 | 9.05 | 9.04 |
| 5 | 3 | 60% | 0.8867 | 0.8850 | 1.002 | 2.86 | 2.86 |
| 10 | 3 | 30% | 0.5547 | 0.5210 | 1.065 | 5.06 | 4.76 |

The test asserts (a) shipped == exact Voigt composite to 1e-12 — the production model
IS the model 191/192 validated, not a re-derivation; (b) within 7% of the measured
E_meas/Es; (c) margin@1.5 within 8% of 192. The residual (≤ 6.5%, worst at 10 mm/3
loops) is the two gaps 192 already named: the specimen's discretised φ_wall (vpc16)
differs from the nominal 4t(W-t)/W² by up to ~5%, and a real resolved part is ~2–3%
softer than the rule of mixtures. The production model does NOT disagree with the
harness that motivated it.

### K4 — the sign is stated everywhere

The gate table's `sign` column labels every reported change LESS-cons / unchanged /
MORE-cons; §5 states the invariant (`k ≥ f^1.5` always → never MORE conservative than
today anywhere, and unchanged wherever walls do not rescue the governing member). The
unit test pins the monotonicity (`k` decreases with width toward f^1.5), the floor
(`k ≥ f^1.5`), and the cap (`+∞` thickness → `k = f^1.5`).

### K5 — degenerate cases (each tested)

`test_width_aware_knockdown`: solid infill (≥ 100%) → **exactly 1.0** for any wall
geometry; wall-less member (t = 0) or unbounded width → exactly `infill_margin_knockdown`;
a member thinner than 2t (ring exceeds the half-width) → clamped to f_wall = 1 → 1.0
(all wall = solid); very thin / single-voxel / NaN-width members stay finite and in
(0, 1] with no division by zero. The single-voxel member reads thickness = 2·spacing.

### K6 — cost: once per gate, measured

`evidence/…/cost.txt` — the local-thickness pass in ISOLATION vs one gate FEA solve:

| grid | voxels | thickness pass | one gate solve | thickness / solve |
|---|---|---|---|---|
| 24³ | 13 824 | 1.0 ms | 1.6 s | 0.1% |
| 40³ | 64 000 | 5.2 ms | 11.6 s | 0.0% |
| 56³ | 175 616 | 17.5 ms | 59.6 s | 0.0% |

It runs ONCE per gate evaluation (once per rung inside `analyze_fixed_design`, not per
CG iteration), scales linearly in voxel count (O(cap·N)), and is 0.0–0.1% of the solve
it accompanies. Negligible.

### K7 — the Swift mirror agrees, and the composite is core-only

`ResultsModel.swift FailureLoad.infillKnockdown` mirrors ONE core law —
`infill_margin_knockdown` (f^1.5), which this PR did NOT change — so it still agrees
with the shipped gate to the digit (`ResultsModelTests` pins `pow(f,1.5)`). Its
doc-comment now states the boundary: the width-aware composite is CORE-ONLY (it needs
a per-element member width only core measures, at the gate), so it is deliberately NOT
mirrored, and the app must consume core's computed `margin_effective` rather than
recompute it. There is exactly one width-aware law, in core — the drift K7 forbids
cannot happen.

### BLOCKED-STOP — the width DOES need a new pass; here is what it costs

A local member width cannot be had from the scalars the gate already holds — it
requires a pass over the density field (the distance transform). Per the brief, this
is reported rather than silently absorbed: the pass is O(cap·N), runs once per gate,
and measures 0.0–0.1% of the gate solve (K6). It is not on the per-iteration path. A
slower gate is the correct call here and the cost is trivially within budget; the
maintainer is free to disagree, but there is no cheaper correct option — the wall
rescue is intrinsically a function of local width.

### FORBIDDEN — clean

No `fixtures/`, benchmark, `materials.json`, `ARCHITECTURE.md`, `DECISIONS.md`, or
ROADMAP checkbox was touched. The synthetic yield in the harness is an in-code test
material (as `test_minimize_plastic` uses), not a `materials.json` edit.

---

## 7. Honesty caveats (what would change these numbers)

1. **Stiffness proxy on a strength margin** (191/192's own caveat). The composite is a
   measured STIFFNESS knockdown; the gate applies it to a STRENGTH margin. The sign is
   robust (in a wall+core section the solid walls carry a disproportionate share of
   both stiffness and peak stress, and in bending the outer-fibre walls are solid), but
   arming is gated on a physical-coupon calibration only the maintainer can generate —
   that is why the TRIPWIRE requires a coupon, not just a code flip.
2. **Thickness quantisation.** The opening resolves the inscribed thickness in 2-voxel
   steps (τ = 2r·spacing), consistent with the voxel resolution the FEA itself runs at.
   Sub-voxel member widths are not distinguished; this is at the same fidelity as every
   other voxel quantity.
3. **Interlayer is left at f^1.5.** Walls are credited only in-plane. If a coupon later
   shows perimeters also stiffen z-bonding, the interlayer term could be relieved too;
   until then it stays fully conservative.
4. **Which width the slicer wraps is still asserted, not sliced** (192's caveat 2).
   TopOpt does not slice; the local member width is the density field's own inscribed
   thickness, which is the right input IF the slicer wraps each member's cross-section.
   A G-code trace of an exported part remains the primary evidence and is out of scope.
5. **Past-cap thick regions get exactly today's f^1.5**, which 191 showed is itself
   non-conservative at envelope scale. This PR does not fix that (it needs a more
   conservative CORE term); it only stops over-penalising ribs and is careful never to
   make the thick regions worse than today.

---

## 8. Reproduce

```
# core library + tests
cd core && cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j8
ctest --test-dir build -R "width_aware_knockdown|analyze_fixed_design|production_parity"

# the before/after gate table (NOT a CTest target)
c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
  -DSETTINGS_RULES_PATH="\"$(pwd)/src/settings/rules.json\"" \
  tests/harness/width_aware_gate.cpp build/libtopopt.a -o build/width_aware_gate
./build/width_aware_gate                 # gate tables (member + envelope)
TOPOPT_WA_ONLY=cost ./build/width_aware_gate   # K6 cost probe (minutes; JacobiCG)
# knobs: TOPOPT_WA_INFILL, TOPOPT_WA_LOOPS, TOPOPT_WA_YIELD, TOPOPT_WA_GRAVITY
```

Every number in this handoff is first-hand in `evidence/2026-07-26-width-aware-knockdown/`.
