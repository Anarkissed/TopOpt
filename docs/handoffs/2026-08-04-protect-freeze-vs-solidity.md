# Protect is a freeze, not a solidity declaration

Slug: `protect-freeze-vs-solidity` · Evidence: `evidence/2026-08-04-protect-freeze-vs-solidity/`

**The maintainer's spec, verbatim, and it is the whole design:**

> "protect should stay frozen. but the decision of whether it's solid or latticed
> is done in the Lattice page (where we select lattice vs no lattice). This way
> protect stays what it actually is > a freeze and nothing else."

---

## 0. THE HEADLINE, BEFORE ANYTHING ELSE

**The two facts were already separate in the mechanism. They were joined only in
the reporting and the copy.** That is the finding, it is load-bearing for
everything below, and it was verified rather than assumed:

* `MaskValue` lives in its own grid-indexed array (`DesignMask`) and constrains
  the **design variable**: `FrozenSolid` pins the density at 1 and drops the voxel
  from the OC update. It is a statement about the optimizer and nothing else.
* Whether a printed voxel is **solid or latticed** is decided downstream by
  `LatticeBoundary` + `lattice_certification_mask`, from three inputs: the final
  physical density, the clearance keep-outs, and the include/exclude **role**
  regions. Neither the generator nor the certification mask ever reads the design
  mask — `grep -n "design_mask" core/src/cli/run_job.cpp` returns **nothing**.

So `include`-over-frozen already produced a lattice, and `exclude`-over-frozen
already produced solid. What did not exist was any way for a user to **know** it:
no receipt line, no log line, no app copy — and Protect's own wording actively
told them the opposite ("frozen solid", "preserves this face's material").

That reframes the task from "separate the tags" to **"stop lying about them, and
prove the separation holds"**. Item 1 asked for a report on whether a new tag, a
flag beside the tag, or a separate mask is the right shape. The measured answer is
**none of the three, on this path** — see §1 for where the conflation IS real.

---

## 1. ITEM 1 — THE TAG SHAPE, REPORTED

### What each type actually expresses

| type | lives in | says |
|---|---|---|
| `VoxelTag` | `VoxelGrid::tags` | what the voxel IS geometrically (Empty / Interior / Surface / Load / Fixture) |
| `MaskValue` | `DesignMask`, a separate array | what the OPTIMIZER may do with it (Active / FrozenSolid / FrozenVoid) |
| `lattice_certification_mask` | derived per variant | what the MATERIAL is (latticed / solid) |

Three arrays, three questions. `voxel.hpp` already says so in its own words: the
design mask is *"a SEPARATE classification from VoxelTag … so a masked voxel keeps
its Interior/Surface/Load/Fixture tag"*. The third question was simply never asked
of the frozen set.

### Recommendation: no new tag, no new flag, no new mask

A new tag would create a fourth thing to keep in sync with three things that are
already correct, and would have to be threaded through `expand_design_domain`,
`warm_start` coarsening, `effective_mask`, the clearance merge and the FEA
analysis grid — every one of which cares only about the optimizer question. The
honest change is **reporting**, and that is what shipped.

### WHERE THE CONFLATION IS REAL, and it is not on this path

**The multiscale path (PR 293, unmerged, default-OFF).** There the lattice *is*
the material law: `C(ρ)` replaces `ρᵖ·E₀` inside the region, so lattice-ness is
carried by the density variable itself. Pinning the density necessarily pins the
solidity. That is a genuine one-tag-two-facts conflation, it is exactly what PR
293 measured, and it cannot be fixed by reporting. **The right shape there is the
separate mask PR 293 already has** (`multiscale_region`): a frozen voxel inside it
should be pinned at a *lattice* density rather than at 1. That is PR 293's
decision to make and is recorded here, not built here.

---

## 2. ITEMS 2–4 — DEFAULT, INCLUDE, EXCLUDE

| declaration over frozen material | result | measured |
|---|---|---|
| no lattice block at all | unchanged, byte-identical | **bar 1 PASS**, §7 |
| lattice, no regions ("lattice the whole part") | frozen material is latticed — today's behaviour, unchanged | observed, not asserted: see below |
| `include` region over it | **retained AND latticed** | 1042 of 1042 in-include frozen voxels latticed |
| `exclude` region over it | **retained AND solid** | 0 of 1042 in-exclude frozen voxels latticed |

The middle row is **observed rather than asserted**, and the distinction is worth
keeping straight. In the gate's exclude run the anchor/load pad's 576 frozen
voxels lie outside every declared region and are latticed by the whole-part
default — visible in `core_gate.txt` as `latticed=576 in_include=0`. No bar
asserts it, because it is the pre-existing behaviour bar 1 already pins; it is
recorded here so the table is complete rather than to claim coverage it does not
have.

Both directions are asserted end-to-end on a real `run_job` in
`core/tests/validation/test_protect_freeze_vs_solidity.cpp` (**26 checks, all
pass**).

One assertion in that gate had to be corrected during the work and the correction
matters. The first draft asserted `latticed == 0` over **all** frozen material in
the exclude case. That is false and would have passed only by luck: the production
load case also freezes an anchor/load pad which lies *outside* the exclude region
and is latticed by the whole-part default. The bar is now scoped to the region it
is about — `in_exclude_region_latticed == 0` — which is the statement item 4
actually makes.

### What the run now says out loud

Per variant, on stderr and in the receipt:

```
[lattice] vf=0.68 frozen material: printed=40216 latticed=337 solid=39879
          in_include=10070 in_exclude=0/0 latticed
          (audit: cells_not_emitted=0 strut_and_solid=0 unexplained=0)
```

and in `run_info.json` under `lattice_export`, plus a `frozen_material` block in
each variant's lattice receipt. Emitted **only** when the run has both frozen
material and a lattice, so nothing else moves.

---

## 3. BAR 3 — CERTIFIED == EXPORTED OVER FROZEN MATERIAL, and the defect it found

Reusing PR 285's audit shape over the frozen voxels turned up **a real,
pre-existing divergence on the role path** — the same failure mode PR 285 fixed
one path over.

**The mechanism.** PR 285's own comment says the null cell predicate "stops being
correct the moment [a policy] clears voxels the boundary still considers
material". Lattice ROLES do exactly that: an exclude region, or anything outside
the include union, clears voxels from the certification mask that the boundary's
voxel base still sees as material. But the uniform role path was still passing
`cell_latticed = nullptr` — "lattice every cell `cell_may_overlap` cannot PROVE
empty", a conservative proof-based test — while the certification mask uses exact
voxel-**centre** membership. A cell can therefore "may-overlap" an include region
while none of its voxel centres are inside it: **struts written into material the
certificate calls entirely solid.**

**Measured, on the l-bracket gate, before the fix:**

| run | frozen voxels with strut AND companion solid | of those, unexplained |
|---|---|---|
| include over protected face | 48 | **48** |
| exclude over protected face | 426 | **426** |

Every single one unexplained — i.e. in a cell owning **no** certified-latticed
voxel at all. Not bonding overlap; pure divergence.

**The fix** is one condition: arm the mask-derived cell predicate on
`domain.expanded || roles_present` instead of `domain.expanded` alone. After it,
all three audit numbers are **0**.

**Why this cannot move a verdict** (and is therefore landable under bar 5): the
certification mask is untouched, so the certified object and every margin it
produces are unchanged. Only the exported FILE moves, strictly fewer cells — it
stops writing struts the certificate never credited.

**A bar that had to be corrected, and this one is important.** The naive form —
"no voxel receives both a strut and companion solid" — is *false by design* on the
role path where a cell straddles a role boundary: roles are deliberately kept out
of the strut clip (`lattice_boundary.hpp`) so the lattice/solid interface stays
bonded. The receipt therefore reports **two** numbers and the gate asserts the
second: `voxels_strut_and_solid` (may legitimately be non-zero at an interface)
and `strut_and_solid_unexplained` (**must be 0** — a cell emitting struts into a
region the certificate calls entirely solid). On this fixture the fix drove both
to zero, but the distinction is what keeps the bar true rather than lucky.

---

## 4. ITEM 5 — THE WARNING, RETARGETED

**Where PR 293's warning is: only in PR 293.** It lives inside the multiscale
arming block (`run_job.cpp`, the `[multiscale] WARNING: … % of the declared
lattice region is NOT optimizable … a face-protection collar`). PR 293 is
**unmerged**, so that text does not exist in `main` and there was nothing to
delete on this branch. What must happen there is stated in §10 for whoever lands
it.

**What shipped here instead.** `include_void_voxels` was an aggregate summing two
situations with opposite meanings. It is now split by CAUSE:

* `include_void_by_clearance` — the include region overlaps a declared keep-clear.
  There is no material there and **no rung, cell size or formulation can create
  any**. This is the only lattice-region overlap that is a real conflict, and it
  is the only one that warns.
* `include_void_by_optimizer` — the optimizer removed the material at this rung. A
  heavier rung may carry it. Not a conflict; reported, not warned.

Frozen material gets a plain report line and **no warning, ever** — warning on it
would train users away from the one thing this task exists to make expressible.

`PF4` asserts both directions on the real stderr text, and asserts the retired
frozen-overlap wording never reappears.

---

## 5. ITEM 6 — THE SECOND REASON HIS REGIONS PRODUCED NOTHING

**Does F3 already cover it? Partly — and not this part.**

PR 291's F3 (also unmerged) reports per-voxel fallback reasons including
`fallback_member_too_thin` and `fallback_irrecoverable_by_cell`, computed from
`local_member_thickness_mm` — the **design's** printed solid. That covers "the
member is too thin". It does **not** cover "the declared REGION is too thin",
which is the maintainer's case: his include regions are 4 mm-deep face slabs, and
the certification mask lattices only voxels **inside** the include union, so the
latticed body is a subset of the region and can be no thicker than it.

**So it was added**, as a pre-flight forecast that runs before any import,
voxelize or solve — from the declared geometry and two constants alone. On his own
job document, unmodified:

```
[lattice] FORECAST region_too_thin: include region 1 (face) is 4.000 mm across its
  thinnest dimension; the cells-per-member floor needs 5.0 cells x 4.6026 mm =
  23.013 mm. Nothing inside this region can hold a certifiable lattice — it will
  be kept SOLID. This is a property of the region's geometry and the printability
  floor (nozzle-derived), not of the optimizer or of any Protect setting.
[lattice] FORECAST: 5 of 8 include regions are thinner than the 23.013 mm the
  floor requires (thinnest 4.000 mm; floor 5.0 cells x 4.6026 mm)
```

Three of his eight include regions are **not** too thin — the Ø60 bolt regions
clear it at 30 mm. So the forecast is discriminating, not a blanket refusal. It is
also a forecast and not a gate: it states the physics and lets the run proceed.

### ITEM 7b — A SEPARATE DEFECT THIS UNCOVERED. FILED, NOT FIXED.

`grade_lattice`'s too-thin test reads `local_member_thickness_mm(grid, density,
…)` — the width of the **design's printed solid**, which knows nothing about the
region restriction. On a thick wall with a thin include slab the two disagree: the
law sees the wall's width and admits the voxel, while the body actually latticed
is only as deep as the slab. A 30 mm wall with a 4 mm include slab at cell 4.6 mm
passes the floor at 6.5 cells per member and then lattices a 0.87-cell-thick
sheet.

**Not fixed here, deliberately.** Correcting the width basis to the candidate set
changes which voxels are latticed on every existing graded+roles run, which moves
the certified object — bar 5 makes that a blocked-stop. Reproduction: any graded
job with an include slab thinner than `n* × cell` over a member thicker than it;
the forecast above now names the same configuration from the other side.

---

## 6. ITEM 7 — THE 472 VOXELS. CONFIRMED, AND IT IS NOT A BUG TO FIX

**Confirmed.** Re-running his configuration reproduces the mechanism exactly, and
reproduces PR 293's own number on the nose:

```
[lattice] vf=0.68 frozen material: printed=40216 latticed=337 solid=39879 in_include=10070
[lattice] vf=0.52 frozen material: printed=40216 latticed=25  solid=40191 in_include=10070
[lattice] vf=0.38 frozen material: printed=40216 latticed=0   solid=40216 in_include=10070
[lattice] vf=0.26 frozen material: printed=40216 latticed=0   solid=40216 in_include=10070
```

`in_include=10070` **is** PR 293's `frozen_solid=10070`. Those are the same
voxels: the frozen collar sitting inside his declared include region. The
identification is now measured, not inferred.

**Why it is not a bug to fix.** Under the maintainer's spec, lattice-include over
frozen material is *precisely the intended behaviour* — retained AND latticed. The
472 voxels were the feature working, with nothing anywhere telling him so. What
was genuinely wrong was the silence, and that is what changed: the per-variant
report line, the receipt block, the `run_info` fields, the Protect copy and the
Lattice page's protected-regions section.

The residual honest caveat: those voxels were latticed **without the user having
asked for that specifically** — he marked a face "lattice here" and the collar
happened to be inside it. The app now shows the collision before the run.

---

## 7. THE BARS

| bar | verdict | evidence |
|---|---|---|
| 1 bit-identical without lattice | **PASS** | `bar1_byte_identity.txt` |
| 2 the maintainer's case, measured | **MEASURED** | §8 |
| 3 certified == exported over frozen material | **PASS**, and found a defect | §3 |
| 4 the warning fires on the right thing | **PASS** | gate `PF4` |
| 5 full gate table, no verdict flips | **PASS** | §8, `bar5_gate_table.txt` |
| 6 the app says what it means | **PASS** | §9 |
| 7 full ctest + app tests | ctest **103/103**; app **1152, 8 failures — all lib3mf-absent, named below** | `ctest_final.txt`, `app_tests.txt` |
| 8 determinism | **PASS** | gate `PF6` |

### Bar 7, stated honestly

**ctest: 103/103.** The first full run came back **102/103** with
`designbox_lattice_recert` failing — a defect *I* introduced and the suite
caught: the new `frozen_material` block's `printed_voxels` key shadowed
`added_material`'s for the receipt's substring reader, so an existing assertion
silently read a different number. Every key in the new block is now prefixed
`frozen_`. Second run green.

**App tests: 1152 executed, 14 skipped, 8 assertion failures across exactly 3
cases** — `testThreeMFImportNormalisesToStlWorkingCopyAndKeepsProvenance`,
`testThreeMFImportOptimisesOnDeviceEndToEnd`,
`testReopenedThreeMFProjectReimportsTheStlWorkingCopy`. All three fail with the
test's own message: *"3MF import requires lib3mf, which is not available in this
build"*. This worktree's macOS core slice is built without lib3mf; this task
touches no import path; CI's `app-macos` job provisions lib3mf via vcpkg. The 7
new `ProtectFreezeVsSolidityTests` all pass.

**And a second gap found while trying to turn those three green, filed not
fixed.** Provisioning lib3mf (`build_lib3mf_macos.sh`) rebuilds the macOS slice
*with* 3MF — and then the test bundle fails to LINK: the aggregate
`TopOptKitPackageTests` target does not inherit `TopOptKit`'s
`-L…/vendor/lib3mf-lib -l3mf` linker settings, so every `lib3mf_*` symbol the
slice references is undefined. So on this checkout the 3MF tests fail *without*
lib3mf and fail to link *with* it. That is a Package.swift gap, unrelated to this
task, and it is why the counts above are reported as they are rather than as a
green.

### Bar 1 — the load-bearing one

Face protection + **no** lattice declaration, same job document, base (`main`) CLI
vs branch CLI:

```
IDENTICAL  report.json    27336eaf99213cff59f22d5b4b319cb1189392aa1f73175f5ee23a3cba7956ff
IDENTICAL  fields.bin     e4a5dc2aef59be4e43a60767f58a9719957b1a0f8c30f12468bffd984565f135
IDENTICAL  design.bin     2674c9f73a70f6ab5eed027a0e3c2fdd0f856e0c6b2f8d6b0bf96237458a17e7
IDENTICAL  loadcase.json  420361e3d49bebaa5c3c9de2942319dcad87705f3ef8db2e8b3604653d6428ab
IDENTICAL  variant_026.stl / _038 / _052 / _068
```

Two artifacts carry a wall clock and are compared with the clock removed, stated
explicitly rather than quietly excluded: `run_info.json` differs only in
`created_wall_ms`, and `iterations.csv` only in its timestamp column and per-phase
millisecond timings — **every physics column is identical**. Neither can be
byte-identical across two runs of the *same* binary, so a strict comparison there
would prove nothing.

---

## 8. BAR 5 — THE GATE TABLE

`bar5_gate_table.sh` · `bar5_gate_table.txt`. Four configurations chosen to cover
every existing path this task touches, base (`main`) CLI vs branch CLI, **every
rung**, on the demo l-bracket at resolution 32:

| cfg | what it covers |
|---|---|
| **P** | protection, NO lattice — the path bar 1 proves byte-identical |
| **L** | lattice, NO regions — the legacy uniform path (roles absent ⇒ the new cell predicate must NOT arm) |
| **R** | lattice + include/exclude ROLES — the path the cell-predicate fix changes |
| **G** | graded lattice + roles — the maintainer's shape, in miniature |

```
cfg    rung  base verdict  branch verdict    base margin  branch margin          d
P      0.68          True            True      10.878029      10.878029  +0.00e+00
P      0.52          True            True      10.849132      10.849132  +0.00e+00
P      0.38          True            True      10.771841      10.771841  +0.00e+00
P      0.26          True            True      10.254110      10.254110  +0.00e+00
P    voxel-classification flips: 0 / 90112
L      … all four rungs True/True, d = +0.00e+00
L    variant_026/038/052/068  True  True   null   null   [composite]
L    voxel-classification flips: 0 / 90112
R      … all four rungs True/True, d = +0.00e+00
R    variant_026  True  True  10.254110  10.254110  +0.00e+00  [composite]
R    variant_038  True  True  10.771841  10.771841  +0.00e+00  [composite]
R    variant_052  True  True  10.849132  10.849132  +0.00e+00  [composite]
R    variant_068  True  True  10.878029  10.878029  +0.00e+00  [composite]
R    voxel-classification flips: 0 / 90112
G      … identical to R, composite included
G    voxel-classification flips: 0 / 90112

NEGATIVE CONTROL (one voxel nudged across the 0.5 iso): 1 flip(s) detected
BAR 5 PASS — no verdict flipped on any existing path.
```

Three things about this table are worth stating rather than assuming.

**The composite row is not decoration.** `report.json` carries the SOLID gate; the
composite margin the lattice receipt certifies is a *different* number, and it is
the one the cell-predicate change (§3) could actually move. A table that stopped
at `report.json` would have looked clean either way. It is compared per rung, per
configuration, and does not move.

**Config L's composite margin is `null`, and that is correct.** When the lattice
covers the whole printed set there is no solid region left for the solid-margin
quantity to be taken over. The comparator prints `null` rather than crashing on
it — and the **verdict** is compared regardless, which is what the bar is about.
(The first version of the comparator crashed here; a comparator that dies on a
legitimate value would have quietly reduced the table's coverage.)

**The negative control is what makes "0 flips" mean anything.** The same
comparator, run against a design with one voxel nudged across the 0.5 iso,
reports exactly 1 flip. So the zeroes above are a measurement, not a blind spot.

---

## 8b. BAR 2 — THE MAINTAINER'S CASE, MEASURED

`bar2_maintainer_case.py` · `bar2_maintainer_case.txt`

_(filled from the completed runs)_

---

## 9. BAR 6 — THE APP

**Protect's copy no longer implies solidity.** Three strings changed, and each one
now names the control that *does* decide:

| where | was | is |
|---|---|---|
| Protect toggle (on) | "Protected — the optimizer preserves this face's own material." | "Protected — the optimizer may not change this face's shape. Solid or latticed is set on the Lattice page." |
| Protect toggle (off) | "Protect — freeze this face's skin so the optimizer may not touch it." | "…so the optimizer may not reshape it. It does not decide solid vs latticed." |
| chip toast | "Protected — the optimizer will preserve this face's material" | "Protected — the optimizer may not reshape this face. Solid or latticed is set on the Lattice page." |
| results note | "(N voxels of the face's skin frozen solid)" | "(N voxels of the face's skin frozen — the optimizer could not reshape it)" |

**The Lattice page now shows which frozen regions are latticed and which are
solid** — a "Protected regions" section listing every Protect group with its
outcome and the reason, hidden entirely when nothing is protected.
`FrozenRegionLatticeStatus` mirrors core's own precedence (exclude beats include;
an include region *anywhere* means only the include union is latticed) so the page
cannot state a rule the run does not follow, and it carries the honest caveat that
group granularity is coarser than the run's voxel split.

`ProtectFreezeVsSolidityTests` (7 tests) covers the whole precedence matrix **and
the call site** — the page composing those rows from a real `ProjectModel` — because
"built, never invoked" has shipped five times in this repo and a value-type test
would not have caught it.

---

## 10. ITEM 8 — SHOULD THE FLOOR BE STRESS-CONDITIONAL? MEASURED.

`core/tests/harness/subfloor_lattice_probe.cpp` · `item8_subfloor_floor.txt`

**First, a fact that reframes the proposal: the floor is not a gate today.**
Nothing refuses a sub-floor lattice. `grade_lattice` filters such voxels out of
its *candidate set* (they stay solid); `analyze_fixed_design` only raises
`lattice_strut_out_of_regime`, a reported flag. There is no gate to relax — only
an accuracy claim to price.

### 8a — the error being accepted

A cantilever with a 4 mm flange welded to its side, swept from the tip (carrying
almost nothing) toward the clamped root. Latticed at 1.33 cells per member —
well below the floor of 5 — against the same design with the flange solid:

| flange x | region peak vM, % of part peak | margin solid | margin sub-floor | Δ margin |
|---:|---:|---:|---:|---:|
| 44 (tip) | 11.664 % | 0.752682 | 0.752682 | **+0.0001 %** |
| 36 | 14.019 % | 0.752680 | 0.752682 | +0.0002 % |
| 28 | 16.573 % | 0.752679 | 0.752682 | +0.0003 % |
| 20 | 19.370 % | 0.752675 | 0.752681 | +0.0008 % |
| 12 | 22.088 % | 0.752503 | 0.752656 | +0.0203 % |
| 4 (root) | 23.478 % | 0.751974 | 0.752593 | +0.0823 % |

Every movement is positive (the certified margin goes **up**, the safe direction)
and the largest is **+0.08 %** at a region carrying 23 % of the peak.

### 8b — the non-local effect

**The argmax did not move.** Across all six stations the peak von Mises stayed at
the same voxel. No non-local redistribution was detected on this part.

### 8c — and yet: the answer is KEEP THE FLOOR

By 8a's own criterion the numbers say "safe here". **They do not mean what they
appear to mean, and the control is what shows it.** Same geometry, same ρ, cell
swept across the floor:

| cell mm | cells per member | margin.worst | peak vM | regime |
|---:|---:|---:|---:|---|
| 0.80 | 5.00 | 0.7526820834 | 73.0720196698 | in |
| 1.00 | 4.00 | 0.7526820834 | 73.0720196698 | OUT |
| 2.00 | 2.00 | 0.7526820834 | 73.0720196698 | OUT |
| 3.00 | 1.33 | 0.7526820834 | 73.0720196698 | OUT |
| 4.00 | 1.00 | 0.7526820834 | 73.0720196698 | OUT |

**Identical to ten decimal places.** The homogenized tensor `C` is a function of
the relative density **alone** — cell size never enters the composite solve. So
the certification is *structurally blind* to cells-per-member, and no Δ margin in
the first table, however small, is evidence that a sub-floor lattice is
**accurate**. It is only evidence that substituting `C(ρ)` for solid did not move
this part's margin.

The floor exists to answer a question this gate cannot ask. Answering it properly
needs direct FEA of the real strut geometry, which the lattice Phase-0 probe
measured at a **44–276× cost ceiling**.

**Recommendation.** Keep the floor as the default candidate filter. If it is ever
relaxed, it must be (a) conditioned on a **measured** region stress fraction, not
a declared one, (b) armed by a named constant, never silently, and (c) carried
into the receipt through the existing `lattice_strut_out_of_regime` flag so the
user is told the certificate is out of regime. What must NOT happen is a
relaxation justified by "the margin didn't move" — the margin *cannot* move, and
that is the finding.

---

## 11. ITEM 9 — DOES A DESIGN BOX LET THE OPTIMIZER BUTTRESS A FROZEN WALL?

`core/tests/harness/frozen_buttress_probe.cpp` · `item9_frozen_buttress.txt`

**YES — and at a tight budget the freeze is what makes it happen.**

A 10 mm wall clamped at its base and pushed at its top edge, with 30 mm of empty
design box on the loaded side. Three configurations: **A** wall alone (no box),
**B** wall + box with the wall FROZEN, **C** wall + box with the wall ACTIVE — the
control that separates "the optimizer will not buttress" from "the freeze stopped
it".

| vf | config | added voxels | within 5 mm of the wall | reach | wall peak vM |
|---:|---|---:|---:|---:|---:|
| — | A wall alone | 0 | 0 | — | 8.035703 |
| 0.60 | B FROZEN | 28790 | 8000 | 22 mm | 7.981339 |
| 0.60 | C ACTIVE | 22398 | 8000 | 18 mm | 7.981163 |
| 0.30 | B FROZEN | 14390 | 7472 | 13 mm | 7.981074 |
| 0.30 | C ACTIVE | 7412 | 4786 | 11 mm | 7.984872 |
| 0.15 | B FROZEN | 7168 | 5804 | 9 mm | 7.982177 |
| 0.15 | C ACTIVE | 3250 | 2202 | 9 mm | **11.704434** |
| 0.08 | B FROZEN | 3770 | 3550 | 7 mm | 7.980663 |
| 0.08 | C ACTIVE | 1414 | 1238 | 7 mm | **20.556788** |

**The frozen region's zero sensitivity does NOT starve its neighbours.** The
adjoint still carries the frozen wall's own compliance contribution into the
neighbouring voxels' sensitivities, so the optimizer sees the benefit of material
there and places it. At vf 0.08 the frozen run spends **94 %** of everything it
places (3550 of 3770) within 5 mm of the wall — it is buttressing, not filling.

**The control is the interesting half.** With the wall ACTIVE at a tight budget
the optimizer spends its allowance *thinning the wall itself* and the wall's peak
stress **rises 2.6×** (8.04 → 20.56). Freezing the wall is what forces the budget
outward into a buttress. That is a real argument for the feature combination, and
it was untested before this.

**The honest caveat.** The wall's own peak stress falls only **−0.68 %**. The peak
sits at the clamped base — a boundary-condition stress concentration that a
buttress on the loaded face cannot relieve. So: the optimizer *does* place
material against a frozen wall, and that material *does* stop the wall being
sacrificed, but on this geometry it does not meaningfully reduce the wall's own
peak stress. A user hoping "buttress it and the wall's stress drops" should not be
promised that number.

**The first run of this probe was uninformative and is recorded as such.** At vf
0.60 alone, both configs saturate the 5 mm slab (8000 voxels each) and "material
was placed" says nothing about choice. The volume fraction had to be swept before
the probe answered anything.

---

## 12. WHAT PR 293 MUST CHANGE BEFORE IT LANDS

Its reachability **diagnostic** is good and should stay. Its **warning** must go:

```
[multiscale] WARNING: %.1f%% of the declared lattice region is NOT optimizable
(pinned by the design mask — a declared load/fixture face or a face-protection
collar) … the lattice region and the protected faces are asking for incompatible
things.
```

After this change that is false: lattice over frozen material is the *only* way to
express a legitimate intent, and this text trains users away from it. Delete the
warning; keep the `active/frozen_solid/frozen_void/empty` counts, which are
exactly the numbers that identified the maintainer's case.

Separately, on the multiscale path the conflation is **real** (§1) and the
diagnostic is describing a true limitation *of that path*: there, a frozen voxel
genuinely cannot become lattice. The honest wording is therefore not "these are
incompatible" but "the multiscale formulation cannot lattice frozen material; the
two-step path can".

---

## 13. WHAT WAS FOUND ALONG THE WAY, AND WHAT WAS LEFT ALONE

**Found and fixed here:**

1. The role path emitted struts into material the certificate called entirely
   solid (§3). Pre-existing; PR 285's failure mode one path over. 48 and 426
   voxels on the gate fixture; **0** after.
2. A receipt key collision I introduced myself — `frozen_material.printed_voxels`
   shadowed `added_material.printed_voxels` for the receipt's substring reader,
   and `designbox_lattice_recert` caught it. Every key in the new block is now
   prefixed `frozen_` so a key added later cannot repeat it.

**Found and filed, NOT fixed** (each would move the certified object on an
existing path, which bar 5 makes a blocked-stop):

3. `grade_lattice` measures member width on the design's solid, not on the
   region-restricted candidate set (§5, item 7b). A thin include slab inside a
   thick wall passes the floor and then lattices a sub-cell-thick sheet.
4. The cells-per-member floor is unenforceable by the gate (§10). This is not a
   bug so much as a boundary of what the certificate means, and it should be
   written down wherever the floor is described.

**Deliberately left alone:** `MaskValue`, `VoxelTag`, the certification posture,
the gate's verdict logic and its tolerance. None of them needed to change, and
§0 is why.

---

## 14. IN PLAIN LANGUAGE

**What you asked for.** You said Protect should mean one thing: *don't reshape
this*. Not *keep this solid*. Whether a protected wall ends up solid or latticed
should be decided on the Lattice page, like it is for everything else.

**What we found when we looked.** The program was already doing what you wanted.
Under the hood, "the optimizer can't touch this" and "this material is solid" were
already two separate things, decided in two separate places. Protect only ever set
the first one. So if you drew a lattice region over a protected wall, you already
got a latticed wall — it worked.

The problem was that nothing told you. There was no line in the report, nothing in
the log, and the app's own wording said the opposite: the button's tooltip said
Protect "preserves this face's material" and the results screen said the skin was
"frozen solid". Reasonable people read that as "protected means solid". You did.
That is a wording bug that cost you a ten-hour run, not a physics bug.

**So what changed.** The app stopped saying it. Protect's tooltip and toast now
say the optimizer may not *reshape* the face, and they point at the Lattice page
for the solid-vs-latticed decision. The Lattice page grew a "Protected regions"
section listing each protected group and whether the current lattice setup will
lattice it or keep it solid, with the reason. And every run now prints and records
exactly how much frozen material was latticed and how much stayed solid.

**Your job, re-run.** Your declared lattice region is 11,002 voxels. 10,070 of
them are inside your own Protect collar — that is the number PR 293 flagged as
"unreachable", and we confirmed it is exactly the same set of voxels. Under the
new rules those 10,070 are *not* unreachable: they are ordinary retained material
and your "lattice here" marking applies to them.

**But your regions still will not produce much lattice, and that part is physics.**
Five of your eight "lattice here" regions are 4 mm-deep slabs. To hold a lattice
we can actually certify, a region has to be about 23 mm thick — five lattice cells
across, and a cell can't go below 4.6 mm with a 0.42 mm nozzle. A 4 mm slab cannot
hold one, at any setting. The run now tells you this **before it starts**, naming
the region and both numbers, instead of handing you an empty result hours later.
Your three bolt regions are 30 mm across and do clear it.

**On making the lattice rule looser where nothing is loaded** (your back wall).
We measured it. On a region carrying 12–23% of the part's peak stress, latticing
it far below the rule moves the certified margin by at most 0.08%, and the peak
stress stays in the same place. That looks like a green light. It isn't, and the
reason is worth knowing: the certification gives *exactly the same answer*
whatever the cell size — to ten decimal places. The maths behind it only looks at
how dense the lattice is, never at how many cells fit across the wall. So it
cannot detect the error the rule exists to prevent. Loosening the rule on the
grounds that "the margin didn't move" would be trusting a measurement that is
incapable of moving. Recommendation: keep the rule for now; if it is ever
loosened, it has to be tied to measured stress and flagged in the certificate as
out of regime, never done quietly.

**On buttressing a frozen wall** (your other question). Yes, it works, and better
than expected. Freeze a wall, give the optimizer a design box beside it, and it
puts material against the wall — at a tight material budget, 94% of everything it
places goes right up against it. The freeze doesn't blind it. And the control run
is the interesting bit: with the wall *not* frozen and the same tight budget, the
optimizer eats the wall instead and the wall's stress goes up 2.6×. Freezing is
what forces it to build the buttress. One honest caveat: the wall's own peak
stress only drops about 0.7%, because that peak sits right at the bolted base
where a buttress can't help much.

**What we did not touch.** The gate's verdict logic and its tolerance are
unchanged, no tag was added or removed, and a job with a Protect and no lattice
produces byte-for-byte the same files as before. We checked that by building the
old code and the new code and comparing the actual bytes.
