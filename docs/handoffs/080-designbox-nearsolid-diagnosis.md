# 080 — Design-box near-solid: diagnosis + fix

Status: **DIAGNOSED and FIXED (Option 2, maintainer-chosen).** The decisive comparison
+ root causes are the primary deliverable; the fix makes "minimize plastic + design
box" a true whole-domain optimize (removes plastic against the part). No-box path is
byte-identical; the shipped add-material feature is preserved behind a flag. See §6.

Territory: `/core/` (read `/app/` for how savings %/mass are displayed). Worktree:
`geometric-multigrid-preconditioner-ee2ac2` (core-only; app read from main checkout).

---

## STEP 1 — The decisive comparison (the deliverable)

Same L-bracket (thin corner bracket, top-mounted, downward tip load), run through
`minimize_plastic` twice — **no box** vs **small box drawn snug to the part bbox** —
under the exact production options (ladder `{0.68,0.52,0.38,0.26}`, `margin_stop=1.5`,
`margin_floor_multiple=2.0`, MMA updater, infill 100). Harness reproduces the device
signature. Load is swept because the ladder's stopping rung is load-dependent; two
regimes bracket the device.

**Part (honest reference): 84 solid voxels.** Small box → expanded grid 8×3×8 = 192
voxels = **84 FrozenSolid (the part) + 108 Active (add-region)**. A fully-filled
expanded domain is 192/84 = **2.29× the part** (device saw ~3.6× — larger drawn box).

### Regime A — device's reported signature (load = 30)

| path | rung | target vf | achieved vf | domain vf normalised against | savings shown | mass (kg) | vs part | margin | accept | why it stopped |
|------|------|-----------|-------------|------------------------------|---------------|-----------|---------|--------|--------|----------------|
| NO BOX | 0 | 0.680 | 0.680 | **part** (n_active = whole part) | −32% | 0.0006 | 0.75× | 1.646 | yes | — |
| NO BOX | 1 | 0.520 | 0.518 | part | −48% | 0.0005 | 0.60× | 1.060 | **NO** | margin < margin_stop |
| SMALL BOX | 0 | 0.680 | 0.680 | **add-region only** (n_active = 108) | −32% | 0.0016 | **1.88×** | 5.301 | yes | **FLOOR** (margin ≥ 3.0) |

No-box walks the ladder and stops on margin; box **stops after one rung on the floor**
and its single rung is **1.88× the part mass** — heavier than the original, labelled
"−32% saved". Ladder collapsed to one rung. Both failures, one table.

### Regime B — full 4-rung box ladder (load = 60), to show every rung

| path | rung | target vf | achieved vf | savings shown | mass (kg) | vs part | margin | accept |
|------|------|-----------|-------------|---------------|-----------|---------|--------|--------|
| NO BOX | 0 | 0.680 | 0.680 | −32% | 0.0006 | 0.75× | 0.823 | **NO** (part too weak) |
| SMALL BOX | 0 | 0.680 | 0.680 | −32% | 0.0016 | 1.88× | 2.650 | yes |
| SMALL BOX | 1 | 0.520 | 0.520 | −48% | 0.0014 | 1.67× | 2.688 | yes |
| SMALL BOX | 2 | 0.380 | 0.380 | −62% | 0.0012 | 1.45× | 2.596 | yes |
| SMALL BOX | 3 | 0.260 | 0.260 | −74% | 0.0011 | **1.31×** | 1.233 | NO |

Every "savings" rung on the box path is **heavier than the part** (1.31×–1.88×). The
achieved vf that becomes `savings = 1 − vf` is the **fill fraction of the add-region**,
which is blind to the part. The lightest rung the ladder can physically reach (0.26)
is still 1.31× the part, because the whole part is frozen solid underneath it.

Baseline the app implies = `mass / achieved_vf` = 0.0016/0.68 = **0.0024 kg = the filled
expanded domain**, not the part (0.0008 kg). Same shape as the device's 2.51 kg /
0.68 → 3.69 kg baseline balloon.

---

## STEP 2 — The baseline (failure 2)

- **a. Baseline domain:** the app never receives a baseline; it back-derives one from
  `mass_grams` and `achieved_volume_fraction`. On the box path `achieved_volume_fraction`
  = `active_volfrac` = (Active physical volume)/`n_active` — the **add-region** fill
  fraction (`simp.cpp:1354`, `simp.cpp:1229`). It **excludes the frozen part entirely**.
  `mass_grams` counts frozen part + Active fill (`minimize_plastic.cpp:343-383`). So the
  implied baseline `mass/vf` is the **filled expanded domain**, not the part.
- **b. SIMP target normalisation:** `target = volume_fraction * n_active`
  (`simp.cpp:928`, `:1225`). `n_active` = Active add-region voxels only. **This is the
  prime suspect and it is confirmed** — see STEP 4: MMA drives the add-region to exactly
  `0.68 * 108 = 73.4` voxels, then the 84 frozen part voxels are added on top → near-solid.
- **c. Padding / grown region:** the align-8 / bbox padding voxels outside the box stay
  `Empty` and are **not** counted (they are neither FrozenSolid nor Active); keep-out is
  FrozenVoid, also not counted. Padding is **not** the balloon. The balloon is the
  frozen part + add-region fill, both legitimately "solid" but wrongly used as the
  reference.
- **d. Correct definition:** the honest baseline is **the imported part's mass** (user
  intent: "how much plastic vs my original part"). Savings must be measured as
  `printed_mass` against `part_mass`. On the current frozen-part design the box path can
  only *add*, so honest savings would be **negative** — the report is not just
  mis-scaled, the sign is wrong. Ownership: the **core** must expose the part-relative
  quantity (it is the only side that knows `n_active` vs part voxel count); the app's
  `1 − achievedVolumeFraction` is correct *given* an honestly part-normalised fraction
  (it is exactly right on the no-box path).

---

## STEP 3 — The ladder (failure 1)

- **a. Rungs attempted:** no-box walks until a rung's margin < `margin_stop` (2 rungs at
  load 30, up to 4 at lighter loads). Box **stops after rung 0** on the floor at the
  device's load.
- **b. Rejected vs never attempted:** never rejected on the box path — rung 0 is
  *accepted*, then the **anchor-integrity FLOOR** halts the walk (`stopped_on_floor=1`,
  `minimize_plastic.cpp:451-455`). Not a budget/time bail, not cancellation.
- **c. Is the floor computed against the expanded domain?** **No.** The floor test is
  `margin.worst_case * infill_knockdown >= margin_floor_multiple * margin_stop`
  → RHS `2.0 * 1.5 = 3.0`, a stress-margin threshold with **no voxel-count term**. It is
  domain-independent. It trips because the *near-solid box geometry* (root cause B) is
  far stiffer than any carved no-box design, so its margin (5.30 at load 30) sails past
  3.0 on the first accepted rung. **Failure 1 is downstream of failure 2/B.**
- **d. Time/iteration budget:** not the cause — the ladder stops on the floor, not a
  budget. (Cost per rung is ~14× on the expanded grid, but the walk halts at rung 1 for
  a correctness reason, not exhaustion.)

---

## STEP 4 — MMA sanity (exonerated, as the maintainer expected)

Driving `simp_optimize` directly on the expanded box domain, per MMA iteration:

```
EXPANDED domain: n_active(add-region)=108  n_frozen(part)=84  budget=vf*n_active=73.4
part solid voxels=84  ==> a HONEST budget would be vf*part=57.1
  MMA iter 1  compliance=1.506e+01  max|drho|=0.1998
  MMA iter 2  compliance=1.212e+01  max|drho|=0.1998
  MMA iter 3  compliance=1.047e+01  max|drho|=0.1998
  MMA iter 4  compliance=1.014e+01  max|drho|=0.1253
CONVERGED: achieved active_volfrac=0.6800 (target 0.68)  iters=25
printed voxels=158  (part=84)  ==> printed/part=1.88x
```

Compliance decreases monotonically, `max|drho|` is nonzero (the design **is** changing),
and it converges to the active-volume constraint **exactly** (0.6800 = target). **MMA is
correctly solving a badly-posed problem.** The problem is badly posed because the volume
constraint is `vf * n_active` over the add-region while the part is frozen solid — MMA
filling the box to 68% is the *correct* answer to the *wrong* question. MMA is not the bug.

---

## STEP 5 — Named root causes

**RC-B (mechanism, the near-solid result):** `expand_design_domain` freezes every
imported-part voxel `FrozenSolid` (unremovable) and the ladder's volume budget +
achieved fraction are normalised to the **Active add-region** (`n_active`), not the part.
So "minimize plastic + design box" does not minimise the part at all — it holds the part
100% solid and *adds* a `vf`-fraction of new material into the box. Even the lightest
ladder rung (0.26) is ≥ the full part (1.31× measured). The rendered result is the design
box lightly trimmed. `voxelize.cpp:120-148`, `simp.cpp:928/1225`.

**RC-A (reporting, the baseline balloon):** the core reports `achieved_volume_fraction =
active_volfrac` = add-region fill fraction on the box path, but = part-retention fraction
on the no-box path — **same field, two different denominators, no signal to the app.**
The app's `savings = 1 − vf` and implied `baseline = mass/vf` therefore measure against
the filled expanded domain instead of the part. `simp.cpp:1354`, `bridge.cpp:208`,
`ResultsModel.swift:1440`.

**RC-C (ladder collapse, derived from RC-B):** the near-solid box geometry's margin is
far above the anchor-integrity floor (`2.0 × margin_stop = 3.0`), so the floor halts the
walk at rung 1. The floor logic is correct and domain-independent; it collapses only
because RC-B feeds it a near-solid part. Fix RC-B and the ladder walks again.

RC-A and RC-B are independent defects; RC-C is a symptom of RC-B.

---

## STEP 6bis — What was implemented (Option 2, chosen by the maintainer)

The maintainer chose **Option 2 — true whole-domain optimize**. Implemented, all in
`/core/`:

- **`expand_design_domain` gains `bool freeze_part = true`** (`voxel.hpp`,
  `voxelize.cpp`). `true` (default) = the shipped add-material feature (part
  FrozenSolid); `false` = part solid voxels become **Active** (removable), keeping
  their Load/Fixture tags so the mask-aware simp path still pins the BC skin.
- **`MinimizePlasticOptions::freeze_imported_part = false`** (new, `pipeline.hpp`),
  the DEFAULT — so `minimize_plastic` + a box now does whole-domain optimize. The
  driver passes it to `expand_design_domain`.
- **RC-B fix (budget):** on the box path the ladder rung `vf` is rescaled from
  "fraction of the Active envelope" to "fraction of the part":
  `simp_vf = (vf * part_solid − frozen_skin) / active_effective`, clamped to (0, 1]
  (`minimize_plastic.cpp`). So rung `vf` means "keep `vf` of the part's worth of
  material", distributed over part + box.
- **RC-A fix (reporting):** the achieved fraction handed to the app is overwritten to
  `printed_voxels / part_solid` on the box path, so `savings = 1 − achieved` and the
  implied baseline `mass / achieved` resolve to the **part's mass** exactly.
- All four changes are gated on `expanded && !freeze_imported_part`, so the **no-box
  path is byte-identical** and Gate-V2 is untouched.

**Result (harness + gate):** the snug-box L-bracket now prints **less** than the part
(0.516 g vs 0.833 g, +38% honest savings), the implied baseline equals the part's mass
exactly (0.83328 g), and the box ladder walks the **same rung count** as no-box
(2 == 2 at the device load; 1 == 1 at heavier/lighter loads). Pre-fix the same rung was
1.88× the part, reported as "+32% saved".

**Regression gate added:** `tests/validation/test_designbox_reduction.cpp` (CMake
`designbox_reduction`) — (a) box removes material (achieved < 0.9 AND mass < part), the
hard guard against a silent near-solid return; (b) baseline == part mass; (c) box rung
count == no-box rung count.

### Deferred (honest)
- **Anchor pad under a box.** With the part now removable, the deeper N-voxel anchor
  pad the no-box path applies (diagnosis 064, `bridge.cpp:706` currently SKIPS it under
  a box on the now-false assumption "the whole import is frozen") is **not** applied on
  the box path. Only the 1-voxel Load/Fixture BC skin is pinned (via `effective_mask`),
  which keeps the solve correct but could let the optimizer carve a boss thin. Fixing
  it fully needs an app-side change (build the pad, pass it through the box path) plus
  relaxing the `design_box` + `design_mask` incompatibility in the driver. Flagged for a
  follow-up; out of this core-track pass.
- **App/bridge.** `bridge.cpp:706` comment ("anchor pad unnecessary under a design box")
  is now stale under Option 2 and should be revisited with the pad fix above. No app
  change was required for the baseline/savings fix — the core now hands up a
  part-relative `achieved_volume_fraction`, which the app already turns into honest
  savings via `1 − achievedVolumeFraction`.
- **Add-material feature re-scope.** `test_design_domain` now opts into
  `freeze_imported_part = true` to keep testing the shipped add-material contract; a
  broader product decision about when the app should use add-material vs whole-domain is
  the maintainer's, in its own handoff.

---

## STEP 6 — Fix scope (the decision that was taken)

The task's requested regression tests define the intended behaviour:
(a) box run **removes** removable material (vf upper-bound vs the **part**);
(b) box-path baseline **equals the part's mass**;
(c) box path yields the **same rung count** as no-box on an equivalent case.

All three require the box path to **optimise the part+box domain against the part as
reference and be able to remove part material** — i.e. the imported part must become part
of the optimisable set, not `FrozenSolid`, and the budget/achieved-fraction must
normalise to the part (or whole domain), not the add-region.

**This directly conflicts with a shipped feature.** `expand_design_domain` is the
M7.dom-core "add material" feature; its acceptance test `test_design_domain.cpp` asserts
*"the imported part is NEVER removed (every FrozenSolid voxel density ≥ 0.9)"*. Making
minimize_plastic+box remove part material breaks that contract and that test. Un-freezing
the part also un-freezes the anchor/load bosses the freeze was protecting
(diagnosis 064 — anchor integrity).

So the correct fix is a **semantic choice about what "minimize plastic + a design box"
means**, and either choice changes product behaviour:

- **Option 1 — keep add-material semantics, fix only the report.** Part stays frozen; the
  box genuinely adds material. Fix RC-A so the app shows this honestly (baseline = part,
  savings **negative** when material is added), and suppress/relabel the reduction ladder
  when a box is present (it cannot reduce a frozen part). No conflict with the shipped
  feature. Does **not** satisfy regression (a)/(c) — because on this semantics the box
  path *should not* remove or produce a reduction ladder.
- **Option 2 — make minimize_plastic+box a true whole-domain optimise.** Part (minus the
  anchor/load pad) becomes Active/removable; budget + achieved-fraction normalise to the
  part; the box merely extends the design region. Satisfies regression (a)/(b)/(c). **Breaks**
  `test_design_domain`'s "part never removed" contract — that test/feature must be
  re-scoped (its own handoff), and the anchor pad must be re-applied under a box (currently
  skipped, `bridge.cpp:706` — "unnecessary under a design box" because the whole import is
  frozen; that assumption goes away).

I did **not** guess between these — both are hard-to-reverse (one silently breaks a
shipped feature) and the choice is the maintainer's. The no-box path is untouched and
must stay byte-identical either way; Gate-V2 unaffected either way.

### What is done vs deferred
- **Done:** full diagnosis, decisive comparison table, root causes named, MMA exonerated.
- **Deferred pending the Option 1/2 decision:** the code fix + the three regression tests.
  Once chosen, the fix is small and localised (RC-A: one part-relative fraction exposed
  from `minimize_plastic`/bridge; RC-B under Option 2: mask construction in
  `expand_design_domain` + budget normalisation). No ROADMAP box checked.

### Evidence
Harnesses (scratch, not committed): decisive comparison + per-MMA-iteration log. Core
built via cmake (Eigen from brew); `/core/` change when the fix lands → run
`build_core.sh` before app tests.
