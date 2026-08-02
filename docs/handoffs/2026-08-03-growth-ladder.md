# "Minimize plastic" OFF becomes a GROWTH LADDER, not a single 0.9 shot

**Slug:** `growth-ladder`
**Evidence:** `evidence/2026-08-03-growth-ladder/`
**Scope:** `core/` (ladder + report + builder) + CLI + the app surface that presents
the recommendation.
**Status:** SHIPPED. Core ctest 102/102. App suite 1145 tests, green except the 3
pre-existing lib3mf 3MF-import failures this worktree already had.

---

## 1. What it did, and what was wrong with it

`loadcase.cpp:313`, before:

```cpp
opts.volume_fraction_ladder =
    lc.minimize_plastic ? production_reduction_ladder()
                        : std::vector<double>{0.9};
```

**ON** walked the four-rung reduction ladder `[0.68, 0.52, 0.38, 0.26]` and
recommended the lightest rung that passed. **OFF** ran ONE variant at 0.9 of the
part. No search, no recommendation — the code's own comment called it "the single
conservative variant".

That answered a question nobody asked. A user who unticks "minimize plastic" is
not asking for 90% of their part. In the maintainer's words:

> "by NOT checking minimize plastic you are basically saying that you can grow
> MORE plastic to achieve the strengths I want to achieve — however, it should be
> as little as possible (i.e. +10% / +25% / +55% and a recommendation for which)"

And a second thing was wrong, quieter. `loadcase.cpp:331`:

```cpp
const bool want_pad = lc.minimize_plastic;
```

A structural PAD — frozen behind every anchor and retained load face after a real
failure (diagnosis 064: an unpadded boss is carved to a film, then isolated and
discarded) — was **silently dropped** by the same checkbox, on the reasoning that
"the {0.9} conservative variant keeps material anyway". That is a safety feature
attached to a control that reads as an objective toggle, and its premise does not
survive contact with a design box several times the part's volume.

---

## 2. What was built

### 2.1 The growth ladder is the reduction ladder, read in the mirror

`production_growth_ladder()` returns **`{1.55, 1.25, 1.10}`** — DESCENDING, and
that ordering is the whole trick. `minimize_plastic`'s existing walk is:

> evaluate rungs in ladder order → stop at the first rung under `margin_stop` →
> the LAST ACCEPTED rung is the recommendation.

On a descending ladder above 1.0 that already reads **"the smallest addition that
passes"**. So the walk, the stop rule, the recommendation rule, the streaming, the
warm start, the ladder floor and the report assembly are all UNCHANGED. There is no
second optimizer, no parallel search, and no new stopping logic.

This answers the task's first BLOCKED-STOP directly: **growth IS expressible in the
existing `volume_fraction_ladder` machinery.** The reason is in
`minimize_plastic.cpp`'s handoff-080 whole-domain block: on a design-box run that
does not freeze the part, a rung's target is already normalised to
`vf × part_solid`, i.e. "vf of the PART's worth of material". Nothing in that
expression cares whether `vf` is below or above 1 — the only thing that stopped it
was the `vf ∈ (0, 1]` validation. Above 1.0 the target simply exceeds the part, and
the Active envelope outside the part is where the difference goes.

**Why these rungs.** The maintainer proposed +10/+25/+55 and it is adopted as
proposed, because the spacing is right for this direction and measurably NOT the
reduction ladder's:

| ladder | rungs | ln(ratio to 1.0) | steps |
|---|---|---|---|
| reduction | 0.68, 0.52, 0.38, 0.26 | 0.386, 0.654, 0.968, 1.347 | 0.386, 0.268, 0.313, 0.379 |
| growth | 1.10, 1.25, 1.55 | 0.095, 0.223, 0.438 | 0.095, 0.128, 0.215 |

The reduction ladder is near-UNIFORM in log space (~0.33/rung). That is right for
reduction, where every rung down is a win in itself and the ladder wants a wide
span. Growth has the opposite objective — not "how light can this go" but "what is
the SMALLEST addition that clears the gate" — so the cost of a coarse rung is paid
directly in plastic the user did not need. The rungs must therefore be FINEST just
above 1.0 and may coarsen as the ask grows, which is exactly what +10/+25/+55 does
(each log step ~1.4–1.7× the previous). Applying the reduction ladder's spacing here
would put the FIRST rung at +39% — a step four times coarser than the feature is for.

Three rungs, not four: a part needing more than +55% is not a growth problem, and a
fourth rung at, say, +100% would spend a full production solve saying so less
usefully than the gate diagnosis already does.

### 2.2 The design box is a prerequisite — required in core, derived in the builder

Growth needs somewhere to go. Without a design box the ladder target degenerates to
simp's own fraction of the part, the run prints at most the part, and the receipt
would announce growth that never happened.

* **`minimize_plastic` REFUSES** a `> 1.0` ladder that is not part-relative, naming
  which of the two conditions is missing (no design box / `freeze_imported_part`),
  and ending with *"Refusing to redistribute and call it growth."*
* **`build_production_loadcase` DERIVES a minimal box** when the user drew none, via
  `minimal_growth_design_box` — the part's own bounding box inflated by the smallest
  whole number of voxels that supplies `kGrowthBoxHeadroom × (top_rung − 1) ×
  part_solid` of add-region — **and SAYS SO**: `ProductionRunSetup::
  growth_box_auto_derived` + `growth_box`, a `[loadcase]` log line, and a
  `growth_design_box_auto_derived` / `growth_design_box_mm` block in the loadcase
  receipt. Material grown into a domain the user never drew is exactly the fact that
  must not be silent.

The headroom is 2.0 because the optimizer must ROUTE the added material (a strut
that reaches an anchor is longer than the volume it displaces), not merely store it.
An over-large box costs solve time; an under-large one silently saturates the ladder,
and only the second is a wrong ANSWER.

**Saturation is reported, not hidden.** If the box (the user's or the derived one)
cannot hold a rung's ask, the `min(1.0, …)` clamp binds and the rung runs at "fill
the box". That is not a strength verdict and does not stop the ladder, but
`VariantReport::growth_target_saturated` records it and every surface prints it.

### 2.3 The validation, tightened rather than loosened

The pre-growth rule was `vf ∈ (0, 1]`. It is **unchanged for every ladder at or
below 1.0**. Above it, three further conditions hold, each closing a way the feature
could lie:

1. **All-or-nothing.** Every rung ≤ 1.0 (reduction) or every rung > 1.0 (growth). A
   mixed ladder is refused — it would ask one run to both remove and add against the
   same reference, and there is no honest name for its recommendation.
2. **Bounded** by `kMaxLadderVolumeFraction = 2.0`, so a mistyped rung (2.5 for 0.25)
   is a refusal, not an expensive silent success.
3. **A design box**, per §2.2.

The report schema validator gained the matching rule, and it is **additive**: a
growth document is exactly one carrying an `added_material` block, and every
document without that block is validated by the identical `[0, 1]` rule it always
was. A growth document's fractions are read on the `[0, 2]` scale — still BOUNDED,
so an out-of-range number is still caught, on the right scale. The load-bearing
consistency check (`volume_saved == 1 − printed`) is unconditional in both.

> Note: this also fixes a latent inconsistency. `report.hpp` has said since handoff
> 104 that `printed_fraction` "can exceed 1 on the box add-material path", while the
> validator capped it at 1 — so a design-box run that netted material added would
> have failed its own schema. It could not happen before because no ladder targeted
> above the part.

### 2.4 The added-material accounting is the headline

PR 285 already computed the printed / inside-part / outside-part split — but only
inside the CLI's **lattice** export path, so a solid growth run had no accounting at
all. It is now a first-class core report field, `VariantReport::added_material`,
computed from `original_part_voxels` (THE one definition of "this voxel was in the
imported part", the same one PR 285 uses, so a solid growth run and a latticed one
cannot disagree about what counts as added):

```
printed_voxels · inside_part · outside_part · part_solid_voxels
outside_fraction · outside_volume_mm3 · net_added_volume_mm3
outside_mass_grams · net_added_mass_grams · growth_target_saturated
```

`evaluated == false` on every reduction run, and then the block is omitted from
`report.json` entirely — those documents keep their exact bytes. PR 285's
`kept_solid` is NOT duplicated here: it exists only when a lattice ran, and its
policy is untouched (see §7).

It surfaces as: `report.json` per variant · the CLI's per-rung stdout line and a
`recommended:` line · the bridge's `OptimizeVariant` · `ResultsModel`'s
`addedMaterialLine` · a caption above the results tabs.

### 2.5 The pad is built on the growth path — measured, not argued

`kGrowthPathAnchorPad = true` (`loadcase.hpp`). See §5 for the measurement that
decided it. The constant exists so the pad's coupling to the mode has a name and a
number instead of being an inherited side effect: flipping it re-prices the decision.

### 2.6 No silent mode switch

One line each, from ONE source of truth (`LadderMode`, `app/TopOptKit/Sources/
TopOptFlows/LadderMode.swift`):

> **Minimize plastic** — Remove as much plastic as possible while still meeting your
> safety margin.
> **Add to strengthen** — Add as little plastic as possible to meet your safety
> margin.

Wired to: the workspace chip (which now shows the MODE, not just the setting's
name), the import sheet's subtitle (which used to say "Turn off to just handle your
forces" — describing neither what off did nor what it does), the Optimize
sub-label (which with the box OFF used to name only the load case and say nothing
about the mode at all), and a caption above the results tabs. Core says it too:
`MinimizePlasticResult::growth_ladder`, `run_info.json`'s `ladder_mode`, the
loadcase receipt's `ladder_mode`, a `[loadcase] ladder=GROWTH …` log line, and the
CLI's `ladder:` line before any number.

The results tab headline flips sign with the mode: a growth variant reads
**"+48%"** added, not "−(−48)%" saved — which is what the savings scale would have
rendered, and it is both broken and backwards about the one thing the user asked for.

**One path is deliberately NOT growth-enabled:** the bridge's self-weight entry
(`run_minimize_plastic`, `bridge.cpp`) keeps the reduction ladder unconditionally.
It cannot be reached with the box unticked — `ForceModel.canOptimize` already
requires a full load case (≥1 anchor + ≥1 load) when `minimizePlastic` is false, and
that routes through `run_minimize_plastic_loadcase` →
`build_production_loadcase`. "Grow this part under its own weight" is not a request
anyone can make today, and inventing a ladder for it would be building a mode with
no door.

---

## 3. G2 — the maintainer's failing bracket

`evidence/2026-08-03-growth-ladder/growth_ladder_gate.txt`.

The WallMount geometry is not in the repo (it was a device job), so what is
reproduced is the **condition**, and the load is **calibrated** to it rather than
typed in: the margin of a fixed design is inversely proportional to the load, so one
probe solve fixes the force that lands the imported part on the motivating run's
exact rejection point.

```
fixture      L-bracket 8x3x8 @ 2.0 mm, 84 solid voxels, 0.833 g
material     PLA (yield 55 MPa, z_knockdown 0.55)
condition    infill 35%, margin_required 1.50
knockdown    f^1.5 = 0.207063
calibration  probe at 120 N -> effective 0.1177; the load landing on 0.5759 is 24.5190 N

BASELINE (the part as imported, no growth)
  in_plane 5.3195   interlayer 2.7813   worst_case 2.7813
  EFFECTIVE 0.5759  required 1.50  -> REJECTED
  binding term: the INFILL KNOCKDOWN
```

The reproduction is faithful where it counts: `worst_case 2.7813` against the real
run's `2.7814`, `margin_effective 0.5759` against `0.5759`, and the same binding
term — the f^1.5 infill knockdown at 35%, not the stress margin.

To be exact about what is NOT reproduced: the in-plane margin is 5.32 here against
the real run's 3.8038. It does not enter, because `worst_case = min(in_plane,
interlayer)` and the INTERLAYER term binds in both — 2.7813 here, 2.7814 there. The
fixture is a different bracket carrying a calibrated load, not the WallMount; what
is reproduced is its rejection CONDITION, and the numbers that decide the verdict
are the ones that match.

**The growth ladder (pad ON, the shipped posture):**

| rung | request | achieved | mass g | added g | outside % | in-plane | interlayer | worst | effective | req | verdict |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 | 1.55 | 1.4762 | 1.230 | +0.397 | 67.7 | 11.6917 | 7.9494 | 7.9494 | **1.6460** | 1.50 | **ACCEPTED** |
| 1 | 1.25 | 1.1905 | 0.992 | +0.159 | 63.0 | 6.1772 | 4.6934 | 4.6934 | 0.9718 | 1.50 | REJECTED — margin below required |

> **RECOMMENDED: +55% — added +0.397 g, effective margin 1.6460 ≥ 1.50.**

**The +10% rung was never evaluated, and that is correct.** Strength is monotone in
the ladder direction: a SMALLER growth rung cannot pass where a larger one failed,
so the walk stops — the same rule that stops the reduction ladder, for the same
reason. Reporting a rung the run deliberately did not solve would be reporting a
number nobody measured.

**So: the growth ladder rescues the run the app could only shrug at.** Before this
task the honest answers available were "raise infill to 67%" or "use a stronger
material". Now there is a third, and it is the one the maintainer asked for: *add
55% here and it passes.*

### 3.1 …and the case the ladder exists for

The run above lands on the TOP rung, which does not exercise "as little as possible".
At 0.45× the load — a part only slightly under the gate — the same ladder walks all
three rungs:

| rung | request | achieved | mass g | added g | effective | req | verdict |
|---|---|---|---|---|---|---|---|
| 0 | 1.55 | 1.4881 | 1.240 | +0.407 | 2.5035 | 1.50 | ACCEPTED |
| 1 | 1.25 | 1.2024 | 1.002 | +0.169 | 2.1669 | 1.50 | ACCEPTED |
| 2 | 1.10 | 1.0833 | 0.903 | +0.069 | 1.7202 | 1.50 | ACCEPTED |

> **RECOMMENDED: +10% — added +0.069 g.** Not +55%, which also passes and would cost
> **5.9× the plastic**.

---

## 4. G4 — growth is REAL growth

Asserted per rung in `test_growth_ladder` (H3) and reported in the evidence:

| rung | printed | vs part (0.833 g) | outside the part |
|---|---|---|---|
| 1.55 | 1.230 g | **+0.397 g (+47.6%)** | 84 of 124 printed voxels (67.7%), 672.0 mm³ |
| 1.25 | 0.992 g | **+0.159 g (+19.0%)** | 63 of 100 printed voxels (63.0%), 504.0 mm³ |

Every rung grew. The test asserts, on every rung, that the printed mass exceeds the
part's, that material is printed OUTSIDE the part envelope, that
`inside + outside == printed` exactly, that `net added == printed − part` to the bit,
and that the reported printed fraction exceeds 1 and is NOT clamped.

**A fact worth stating plainly:** the outside share is ~65–78%, i.e. most of what
prints is new material. That is the whole-domain-optimize path (handoff 080) doing
what it does — with the part left as a design region, the optimizer is free to
remove part material while it adds elsewhere, so "+47.6% net" is the net of a larger
gross add and a real subtraction. The accounting says so directly, which is the
point of surfacing it: "net added" and "outside the part" are different numbers and
the user needs both.

---

## 5. G5 — the pad decision, MEASURED

The SAME growth ladder, same fixture, same load, same rungs, once with the
anchor/load pad and once without
(`evidence/2026-08-03-growth-ladder/pad_on_off.txt`):

| | pad ON | pad OFF |
|---|---|---|
| rungs evaluated | 2 | 1 |
| rungs ACCEPTED | **1** | **0** |
| rung 1.55 — effective margin | **1.6460** | 1.1266 (−0.5195) |
| rung 1.55 — interlayer margin | 7.9494 | 5.4407 |
| rung 1.55 — printed mass | 1.230 g | 1.240 g |
| rung 1.55 — outside the part | 67.7% | 78.4% |
| rung 1.55 — verdict | **ACCEPTED** | **REJECTED** |

**The pad changes the verdict.** Without it the top rung of the growth ladder fails
by 0.37 and the run has nothing to recommend at all; with it, the run's answer is
"+55% and it passes".

And the mechanism is visible in the numbers. Pad OFF prints **more** mass (1.240 vs
1.230 g) and is **weaker**. It spends 78.4% of its material outside the part instead
of 67.7% — it grows out into the box while carving away the boss it is anchored by.
That is diagnosis 064's failure, reproduced on the growth path, where the old
justification ("the conservative variant keeps material anyway") is at its very
weakest: a growth run is BY DEFINITION a run whose structure is under-strength, its
anchors most of all.

**Decision: `kGrowthPathAnchorPad = true`.** The pad is built in both modes. The
checkbox now changes the ladder and nothing else.

---

## 6. G6 — the gate is unchanged

Nothing in this task touches the verdict logic or the tolerance. `analyze_fixed_
design`, `gate_margin_effective`, `knockdown_spec_for` and `margin_stop` are
untouched; a growth rung is gated by exactly the same expression, on exactly the
same scale. The full gate table across the ladder is in §3 and §3.1 — every rung's
in-plane, interlayer, worst-case and effective margin against its requirement.

The only way a growth rung passes where the part failed is **by having more
material**, and the table shows precisely that: the worst-case margin rises from
2.7813 (the part) to 7.9494 (at +55%), and the knockdown factor applied to it is
identical (0.207063) at every rung.

**Negative control, PR 248's discipline** (1e-9 is the floor a real difference has
to clear; identity is what a re-run must produce):

```
G6 NEGATIVE CONTROL: the same growth run, twice
  fields compared: 14   shape match: yes   WORST |difference|: 0
  floor: 1e-9. EXACTLY ZERO — bit-identical, as a re-run must be.
```

`test_growth_ladder` H7 repeats this in-suite over 42 gate fields, also exactly 0.

---

## 6.1 …and it runs end to end through the front door

`evidence/2026-08-03-growth-ladder/cli_growth_run.txt` — a real `topopt-cli run` with
`loads.minimize_plastic: false` and **no design box in the job**:

```
[loadcase] ladder=GROWTH rungs=[1.55,1.25,1.10] anchor_pad=1 — add as little
           plastic as possible to reach the required margin
[loadcase] growth design box AUTO-DERIVED (none drawn):
           min=(-32.5,-22.5,-2.5) max=(32.5,22.5,62.5) mm spacing=2.5

ladder: GROWTH [1.55, 1.25, 1.10 x the part]
variants: 3 evaluated, 3 accepted
  vf 1.55: +22.82 g added (1178 of 3320 printed voxels outside the part = 35.5%)
  vf 1.25: +10.11 g added ( 522 of 2664 printed voxels outside the part = 19.6%)
  vf 1.10:  +3.80 g added ( 196 of 2338 printed voxels outside the part =  8.4%)
recommended: +10% (vf 1.10) — the SMALLEST addition that passes: +3.797 g
```

`inside_part` is 2142 on every rung — the part's ENTIRE solid count — because the
anchor pad and the retained load faces pin it. So on this run the growth is purely
additive and `outside_part` and `net_added` agree exactly. `report.json` carries
`volume_saved_fraction −0.55 / −0.24 / −0.09`, negative because this run adds, and
the document validates: the schema reads it on the growth scale precisely because it
carries the `added_material` block.

**And the grown variant RE-CERTIFIES.** This was the one thing an auto-derived box
could plausibly have broken: a box the job never declared, needed again later to
re-analyse the design that grew into it. It does not break, because the derivation is
PURE and lives inside `build_production_loadcase`, which the analyze path calls too —
so it is reconstructed bit-identically rather than remembered:

```
topopt-cli analyze … --mesh variant_110.stl
  peak stress 0.7434 MPa   worst-case margin 73.99 (required 1.5)
  load case: declared external load        verdict: ACCEPTED
  voxel mass 47.55 g   mesh mass 44.29 g
```

(The margin differs from the run's 60.03 because analyze certifies the exported FILE
— re-voxelized from STL — not the run's density field. That is the documented
mesh-round-trip behaviour of the analyze path, unchanged by this task.)

---

## 7. BLOCKED-STOP #2 — the PR 285 interaction, reported not changed

The task asks for the interaction to be reported if a growth rung cannot be
certified because added material sits outside the part and PR 285's policy keeps it
solid. **It does not block certification, and PR 285's policy is untouched.**

`kDesignBoxAddedMaterialKeptSolid = true` governs the LATTICE export path only: on a
latticed design-box run, cells containing added material are dropped from the lattice
mask and printed solid. A growth run is not inherently latticed — the runs above are
solid — and on a solid run the policy is inert. The two do meet on a
growth-plus-lattice run, and there the interaction is now *legible rather than
implicit*: PR 285's receipt reports `kept_solid_voxels` and `outside_kept_solid`, and
this task's `added_material` block reports `outside_part` from the same
`original_part_voxels` definition. With 65–78% of a growth variant's voxels outside
the part, a latticed growth run would be mostly solid by that policy — which is an
honest consequence of the policy, priced by two receipts that agree, and a decision
for a future task rather than a silent change here.

---

## 8. G1 — minimize_plastic ON is byte-identical

**The load-bearing bar.** `evidence/2026-08-03-growth-ladder/g1_byte_identity.txt`.

Stash-rebuild checksum: the same two jobs, run by a `topopt-cli` built from the tree
WITHOUT this task's changes (`git stash`) and WITH them. The compared artifacts are
**the product** — `report.json` and every exported variant mesh.

| job | what it exercises | result |
|---|---|---|
| A — self-weight, l-bracket @ res 32, ladder [0.7, 0.5, 0.3] | never enters `loadcase.cpp`; 3 variants | **BYTE-IDENTICAL** |
| B — LOADCASE, `minimize_plastic: true`, l-bracket @ res 24 | the reduction ladder through the shared builder; 4 rungs, 4 accepted | **BYTE-IDENTICAL** |

```
job A  c32cef89…  report.json      job B  501450a1…  report.json
       70e2c604…  variant_070.stl         15e821c6…  variant_068.stl
       3795583f…  variant_050.stl         15e821c6…  variant_052.stl
       f1b3ed01…  variant_030.stl         15e821c6…  variant_038.stl
                                          15e821c6…  variant_026.stl
```

**The ONLY differences anywhere in the output tree** are two additions of the same
single key, both deliberate:

```
run_info.json    + "ladder_mode": "reduction"
loadcase.json    + "ladder_mode": "reduction"
```

Those are provenance documents, not the product, and **naming the mode IS bar G7** —
emitting it only when the mode is unusual would be exactly the silence the bar
closes. Everything the user prints or certifies is unchanged to the byte.

The in-suite standing guard is `test_growth_ladder` H1 (the reduction ladder literal
and the pre-growth `(0, 1]` rule are still enforced) plus the existing
`test_production_parity`, which asserts the builder still hands
`production_reduction_ladder()` verbatim on the ON path.

---

## 9. G8 — determinism + the suites

**Determinism.** Three independent checks, all EXACTLY zero:

* the harness's negative control — 14 gate fields, worst |difference| **0**;
* `test_growth_ladder` H7 — 42 gate fields across the whole ladder, worst
  |difference| **0**;
* `minimal_growth_design_box` — the derived box is bit-identical on repeat (H5).

1e-9 is PR 248's *floor*; identity is what a re-run must produce, and it does.

**Core ctest: 102/102 passed** (100 before this task + `growth_ladder`; count rose
from 101 to 102).

**App suite: 1145 tests, 13 skipped, 8 failing assertions across exactly THREE
tests — the pre-existing lib3mf 3MF-import failures** this worktree already had
(`testThreeMFImportNormalisesToStlWorkingCopyAndKeepsProvenance`,
`testThreeMFImportOptimisesOnDeviceEndToEnd`,
`testReopenedThreeMFProjectReimportsTheStlWorkingCopy`) — the macOS slice is built
3MF-free here (`build_core.sh` prints `no vendor/lib3mf-ios`), exactly as the
gate-diagnosis handoff recorded. `GrowthLadderTests` contributes 9 of the 1145, all
passing.

One test DID break on this task and was fixed rather than excused:
`testMinimizePlasticLoadCaseUsesDeclaredForces` asserted `variants.count == 1` on the
OFF path — see below.

**Four existing tests were REWRITTEN, and no assertion was weakened.** All four used
`minimize_plastic = false` as a PROXY for something else — "one fast rung", "no
anchor pad", "no design box" — and this task gave that flag a meaning of its own.
That is exactly the coupling the task set out to remove, so each test now says what
it actually means:

* `test_loadcase_analyze` (L2/L3/L4) used `minimize_plastic = false` purely to get
  ONE fast rung. That flag now means the growth ladder, which expands onto a derived
  box — a different seam from the one this test is about. It now uses the reduction
  mode and pins `volume_fraction_ladder = {0.9}` directly. Every assertion is
  unchanged; only the vehicle for "one rung" moved.
* `test_face_protection_parity` isolated a Face protection from the anchor pad by
  setting `minimize_plastic = false`, then asserted "the overlay's FrozenSolid count
  IS the protection". Since the pad is now built in both modes (§5), that
  coincidence is gone — so the check became **stronger**: an exact voxel-by-voxel SET
  equality, `design_mask == (anchor pad) ∪ (the reported frozen skin)`, with the
  skin rebuilt through the same `mask_step_face` primitive the builder uses. The
  test also now REPORTS a fact it used to hide: on this fixture the protected face is
  also a retained LOAD face, so the pad's 3-voxel depth already subsumes the 2-voxel
  skin and the overlay grows by zero. Check count 14 → 17.
* `TopOptKitTests.testMinimizePlasticLoadCaseUsesDeclaredForces` used it for "one
  conservative variant => fast" and asserted `variants.count == 1`. It KEEPS the OFF
  path — which makes it the end-to-end proof that the app's OFF path produces a
  growth ladder through the bridge — and now asserts the growth contract instead:
  `growthLadder` is true, every rung requests > 1.0, and every rung carries
  added-material accounting with `inside + outside == printed` and `outside > 0`.
  Resolution 20 → 12, because a growth run solves on the derived box's expanded grid
  across up to three rungs (9.5 s, down from 108 s).
* `TopOptKitTests.testMinimizePlasticLoadCaseDesignBoxExpandsTheGrid` used it to get
  a NO-BOX baseline — which OFF can no longer provide, since it now derives one. It
  moved to `minimizePlastic: true`, so "no box" genuinely means no box again. Its
  subject ("a user-declared box reaches the core and expands the grid") is
  mode-independent and unchanged. It had been silently passing on a broken baseline.

---

## 10. Files touched

**core — the ladder**
* `include/topopt/production.hpp`, `src/simp/production.cpp` —
  `production_growth_ladder()`, `minimal_growth_design_box()`,
  `kGrowthBoxHeadroom`, `kGrowthBoxMaxInflationVoxels`.
* `include/topopt/report.hpp`, `src/settings/report.cpp` —
  `AddedMaterialReport`, `VariantReport::growth_target_saturated`,
  `kMaxLadderVolumeFraction`, the `added_material` emission, and the
  growth-scale branch of the schema validator.
* `include/topopt/pipeline.hpp`, `src/simp/minimize_plastic.cpp` —
  the growth validation rules, the design-box refusal, the saturation flag, the
  added-material measurement, the un-clamped growth fraction,
  `MinimizePlasticResult::growth_ladder`.
* `include/topopt/loadcase.hpp`, `src/cli/loadcase.cpp` — the ladder switch,
  `kGrowthPathAnchorPad`, the derived box, the growth fields on
  `ProductionRunSetup`, two new log lines.
* `include/topopt/observability.hpp`, `src/simp/observability.cpp` —
  `RunInfo::ladder_mode`.

**CLI**
* `src/cli/run_job.cpp` — `ladder_mode` + the growth block in the loadcase receipt,
  the run_info echo, the setup-echo carry.
* `src/cli/main.cpp` — the `ladder:` line, the per-rung added-material line, the
  `recommended:` line (including the honest "NONE" form).

**tests**
* NEW `tests/validation/test_growth_ladder.cpp` (ctest `growth_ladder`, 77 checks).
* NEW `tests/harness/growth_ladder_gate.cpp` (harness, writes the evidence).
* `tests/validation/test_loadcase_analyze.cpp`, `test_face_protection_parity.cpp` —
  see §9.
* `CMakeLists.txt` — both registrations.

**app**
* `TopOptBridge/include/TopOptBridge.hpp`, `TopOptBridge/bridge.cpp` — the growth
  accounting and the ladder flag across the bridge.
* `TopOptKit/TopOptKit.swift` — `AddedMaterial`, `OptimizeVariant.addedMaterial`,
  `OptimizeOutcome.growthLadder`, the decode.
* NEW `TopOptFlows/LadderMode.swift` — the ONE source for both modes' copy.
* `TopOptFlows/ResultsModel.swift`, `ResultsScreen.swift` — the growth headline, the
  mode caption, the added-material caption, the export filename.
* `TopOptFlows/WorkspacePlaceholder.swift`, `ImportSheet.swift` — the chip and the
  Optimize sub-label now name the mode.
* `TopOptFlows/RemoteRunner.swift` — decode `added_material` from a LAN
  `report.json`; derive the mode from it.
* `TopOptFlows/OutcomeStore.swift` — both facts survive the persist/restore round
  trip (the DTO-mirrors-the-outcome rule).
* NEW `Tests/TopOptFlowsTests/GrowthLadderTests.swift` (9 tests).
* `Tests/TopOptKitTests/TopOptKitTests.swift` — the two rewritten tests (see §9).

**Untouched, as required:** fixtures, `materials.json`, `ARCHITECTURE.md`,
`DECISIONS.md`, the gate's verdict logic and tolerance, PR 285's
`kDesignBoxAddedMaterialKeptSolid`.

---

## 11. In plain language

**What the checkbox used to do.** "Minimize plastic" ticked meant: try four
progressively lighter versions of your part and recommend the lightest one that is
still strong enough. Unticked meant: make one version at 90% of your part and hand
it over. No search, no recommendation, no choice. And — without saying so anywhere —
unticking it also switched off a small safety feature that welds the mounting bosses
into the body, so the optimizer can't carve them away.

**What it does now.** Unticking the box means the opposite of the ticked box, done
just as carefully. The app tries your part at **+55%, +25% and +10%** more material,
and recommends **the smallest addition that is strong enough**. If +10% is enough,
that is what you get — not +55%, which would also work and would cost you nearly six
times the plastic.

**Where the extra material goes.** Growth needs room. If you drew a design box, it
grows into that. If you didn't, the app works out the smallest box it needs, uses
that, and **tells you** — in the run log, in the receipt and on the results screen.
It will never quietly move material around inside your part and call that growth.

**What you now see.** Every version tells you how much plastic it adds, and how much
of the object you are about to print was never in your model. The results tab reads
**"+10%"** added instead of a nonsensical negative saving, and both modes are named
in one line each so you can never be in the wrong one without knowing:

> **Minimize plastic** — Remove as much plastic as possible while still meeting your
> safety margin.
> **Add to strengthen** — Add as little plastic as possible to meet your safety
> margin.

**The safety feature stays on in both modes.** We measured it rather than argued
about it: on a growth run, the version WITH the boss reinforcement passes the safety
gate and the version without it fails — while actually printing slightly MORE
plastic, because it spends it in the wrong place. So it is on. Always.

**And the bracket that started this.** The maintainer's run failed at a safety margin
of 0.58 where 1.5 was required, and the app could only say "raise your infill or buy
a stronger plastic". Reproduced here on the same numbers, the growth ladder answers:
**add 55% and it passes** (margin 1.65). That answer did not exist before.

**If nothing works, it says so.** A run where even +55% is not enough reports that
plainly, with every rung's numbers, rather than handing back the biggest version as
though it were a recommendation.

**Nothing about the ticked box changed.** We rebuilt the app from before these
changes, ran the same jobs, and compared the results file-by-file: identical, to the
byte.
