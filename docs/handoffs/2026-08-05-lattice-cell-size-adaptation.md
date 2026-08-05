# Lattice cell-size adaptation — per-region derivation, and the run that should have refused

Branch `claude/lattice-cell-size-adaptation-7ec715`.
Evidence: `evidence/2026-08-05-lattice-cell-size-adaptation/`.

## Build ritual — TWO outputs, not one

This changes `core/`. On merge the maintainer must run **both**:

```bash
./build_core.sh && cmake --build core/build --target topopt_cli
```

Note the target is `topopt_cli` (underscore). `--target topopt-cli` (hyphen) finds
the existing *file* of that name, declares it up to date, exits 0 and builds
nothing. Then restart the worker and rebuild the app.

CI: `core-linux` + `app-macos`. `materials.json` was not touched.

---

## 0. What changes for the maintainer

**Your overnight run should never have started. It now refuses.**

You declared seven include regions, every one 4 mm thick, against an 8 mm lattice
cell. The cells-per-member floor needs 5 x 8 = 40 mm of material to put a lattice
in. Your run computed that, printed it, wrote it into `run_info.json` — and then
solved four rungs anyway, marked all four accepted, and shipped you a part with
1131 lattice cells, none of which could be where you asked for them. That is a
night gone.

The same job now stops before the first solve and tells you the arithmetic:

```
the planned lattice cell is too COARSE for the regions you declared: the strut
network would not be connected there, so this run would emit loose fragments
rather than a lattice — refusing before spending a solve.
  regions declared (include): 7, thinnest 4 mm
  planned cell 8 mm gives 0.5 cells across that region; a connected network
  needs at least 1.
  A SMALLER CELL WORKS. At a 0.42 mm bead this region admits cells from
  1.094961872 mm (printability) up to 4 mm (percolation).
    Set "cell_mm" in the lattice block to a value in that range.
  NOTE — a lattice in that range will be CONNECTED but NOT CERTIFIED: this
  region needs 5.474809359 mm to clear the cells-per-member accuracy floor and
  has 4 mm. The margin over it is out of regime. That is what
  "retain_subfloor_in_unloaded_regions" is for — read the exposure it reports
  before arming it.
  To proceed anyway with lattice OUTSIDE your declared regions, remove the
  include regions from the lattice block — but read the receipt first: this run
  would have put every cell in material you did not select.
```

Note what that message does **not** say: it does not tell you to use
`cell_mode: "auto"`, and it does not offer you a skin. Both were in the first
version and both were wrong — AUTO lands you straight back in the same refusal,
and a skin emits nothing at all on your geometry. See §M2.

**The "23 mm member" you were told you needed was a conditional number and the
condition was never stated.** It is 5 x the printability floor evaluated at the
*lightest* certifiable lattice in the band. Nothing forces you to lattice at the
lightest density. Evaluated at the density a member can actually carry, the same
arithmetic gives **5.47 mm**, not 23 mm. Both numbers now come out of one core
function instead of one of them being folded into a floor nobody could see into.

**★ WHAT YOUR 4 mm WALL ACTUALLY DOES TODAY, BY PATH.** (N1.) This is the
correction that matters most, and an earlier version of this branch got it wrong
in a way that would have cost you another run:

| Your job is… | At a 1.2 mm cell your 4 mm wall… | Result |
|---|---|---|
| **GRADED** (a `grading` block) | cannot even *get* a 1.2 mm cell — a grading block raises your target to the rho_min printability floor, **4.6026 mm** — and at that cell the wall does not percolate | **refused at pre-flight** |
| **GRADED**, cell somehow honoured | is below the 5-cell accuracy floor, so `grade_lattice` falls it back to **SOLID** | **no lattice, unless `retain_subfloor_in_unloaded_regions` is armed — which the app cannot send** |
| **UNIFORM** (`cell_mm` + `strut_radius_mm`, no `grading`) | sits at **3.33 cells across** — above percolation (1.0), below accuracy (5.0) — and the uniform path applies **no** accuracy floor, so nothing stops it | **see the correction below: it was NOT latticed** |

**★ CORRECTION, MEASURED AFTER THIS SECTION WAS FIRST WRITTEN AND AFTER THE PR
WAS APPROVED.** The row above originally claimed the uniform route "builds the
lattice, out of regime". **That claim was not supported and is withdrawn.**

I ran his own `job.json` (from the worker directory), uniform, `cell_mm` 1.2,
resolution 64 (`n1c_measurement.txt`). The run succeeded and emitted lattice:

```
cell_size_mm                 1.2
include_regions              7          exclude_regions 1
latticed_cells               6082
strut_min_cells_per_member   5.684264342     <- the decisive number
strut_out_of_regime          False
accepted                     True
```

`strut_min_cells_per_member` is measured over the **latticed** material, so the
thinnest member carrying any lattice is 5.684 x 1.2 = **6.82 mm**. His declared
regions are **4 mm**, which at a 1.2 mm cell is 3.33 cells. **Therefore not one
latticed voxel sits in a 4 mm wall.** The 6082 cells went into thicker material
somewhere else — which is §B2 (lattice landing outside the declared regions),
happening again, on the route I had just recommended.

Two consequences, and both are corrections to what was merged:

1. **The uniform route is NOT a way to lattice his 4 mm wall.** No route
   currently is. The certificate also came back **in regime** (`out_of_regime`
   false), not out of regime as the row claimed — because the material actually
   latticed is thick, not thin.
2. **The arithmetic was right and the inference was wrong.** 3.33 cells does
   clear percolation, and the uniform path does apply no accuracy floor. What I
   failed to check is whether his 4 mm regions get any *voxels* at all: at
   resolution 64 a voxel is 3.41 mm on this part, so a 4 mm slab is barely one
   voxel thick and can capture almost no voxel centres. That is partly an
   artifact of my running at 64 instead of his 128 (1.70 mm voxels) — **so this
   measurement does not settle what happens at his resolution, and I am not going
   to claim it does.** The re-run at 128 is the first thing owed.

**What is safe to say to him today:** on a graded run his 4 mm wall comes back
solid; on a uniform run at a fine cell the lattice is built *somewhere*, and
proving it reaches his declared wall needs the per-region emitted-cell receipt
that §B4 says does not exist on the uniform path. That receipt is now the
blocking item, not a nice-to-have.

**★ THE DERIVATION REPORTS. IT DOES NOT YET PLAN.** (M3.) This is the most
important caveat on this branch and it was missing from the first version of this
handoff. `lattice_derive_cell_for_member` is called in exactly three places
outside its own tests — the Stage E report (`run_job.cpp:2249`, `:2251`) and the
refusal/advice messages (`:5504` and the pre-flight note). **It never feeds cell
selection.** AUTO still picks `lattice_cell_printability_floor_mm`, the rho_min
floor; SWEPT still raises its minimum to that same floor. So nothing on this
branch actually builds an 8 mm wall at a 1.6 mm cell. What it does is *tell you
the number*, and now refuse or warn instead of wasting a night. Setting `cell_mm`
by hand to the number it gives you does work — measured, §3.

**★ AND YOUR 4 mm WALL IS NOT UN-LATTICEABLE. IT IS UN-CERTIFIABLE.** (M8c.)
Those are different, and the first version of this branch collapsed them. There
are TWO floors, not one:

- **Percolation, ~1 cell** — below it the struts do not connect and the generator
  emits debris. This is a real floor and it now has a name in core.
- **Accuracy, 5 cells** — below it the homogenized tensor stops describing the
  member, so the *certificate* is out of regime. **The part still prints.**

At your 0.45 mm line width your 4 mm wall sits at **3.41 cells** across the
finest printable cell: comfortably above percolation, well below accuracy. So it
*can* be built, at a cell around 1.17 mm, and the margin over it will be out of
regime. That is what `retain_subfloor_in_unloaded_regions` exists for. The run
now says exactly this instead of refusing you outright.

**What it still does not do:** give you a *certified* lattice in a 4 mm wall. For
that the requirement is 5.87 mm at your line width. The derivation takes you from
**10x short to 1.47x short** on the certified path, and to *already satisfied* on
the buildable-but-uncertified path.

Three more things are wrong with that run — read §B2, §B4 and §B5 before you run
anything: lattice is landing outside your declared regions by construction, no
per-region emitted-cell receipt exists on the path you used, and the shipped mesh
carries loose fragments. `skin: "rim"` was a silent no-op on your geometry; it
now **refuses** instead (§7, §M4), which is why the refusal message no longer
offers you a skin.

---

## 1. Section A — the new evidence, reproduced

Everything in the amendment's section A was re-measured from his own artifacts at
`~/.topopt-worker/7ba2442960a24050/out/` (fingerprint `b3abcf880554`, res 128,
`has_design_box` false).

### Reproduces exactly

| Quantity | Amendment | Measured |
|---|---|---|
| `lattice.cell_size_mm` | 8 | 8 |
| `forecast_include_regions` | 7 | 7 |
| `forecast_region_too_thin` | 7 | 7 |
| `forecast_required_member_mm` | 40 | 40 |
| `forecast_thinnest_region_mm` | 4 | 4 |
| `skin` / `skin_triangles` / `rim_triangles` / `rim_volume_mm3` / `anchor_nodes` | rim / 0 / 0 / 0 / 0 | rim / 0 / 0 / 0 / 0 |
| `interior_volume_mm3` | 161923 | 161923.0443 |
| `latticed_cells` | 1131 | 1131 |
| `strut_min_cells_per_member` | 0.4263198257 | 0.4263198257 |
| `strut_out_of_regime` / `strut_gated` | true / false | true / false |
| `relative_density` (rho_min == rho_max) | 0.3631365741 | 0.3631365741 |
| `strut_radius_mm` | 1.095372083 | 1.095372083 |
| `interpenetrating_soup` | true | true |
| STL triangles | 315,036 | 315,036 |
| strut body / solid companion | 161,632 / 130,472 | 161,632 / 130,472 |
| strut body inset from -X face, above bottom | 29.3 / 14.9 mm | 29.3 / 14.9 mm |
| part envelope | ~218 x 53 x 200 mm | 218.3 x 52.9 x 199.5 mm |

Scripts: `a0_reproduce_stl.py`, output in `a0_reproduce_stl.txt`.

### Reproduces with a caveat you should know about

| Quantity | Amendment | Measured |
|---|---|---|
| connected components | 844 | **845** |
| components under 100 tris | 836 / 18,904 tris | **837 / 18,936 tris** |
| fully isolated in air | 123 | **depends entirely on the threshold — see below** |

The component count is off by one (and the under-100 count by one component /
32 triangles), which is a vertex-weld-tolerance difference, not a disagreement
about the mesh. I weld at 1e-4 mm.

**The isolated-fragment count is not a single number, and this matters.** The
amendment gives 123 without stating what "shares space" means. It is extremely
sensitive to that definition (`a0c_threshold_sweep.txt`):

```
threshold_mm  isolated
    0.000000       843     <- nothing shares a welded vertex, by definition
    0.100000       814
    0.250000       414
    0.400000       143
    0.450000       128
    0.460000       125     <- 123 sits here
    0.500000       111
    1.000000         9
    1.095372         9     <- one strut radius
```

**123 corresponds to a proximity threshold of ~0.46 mm — his `wall_line_width_mm`
of 0.45.** So the amendment's figure reproduces once you know it means "closer
than one extrusion line to any other body". Under the more generous "within one
strut radius", and additionally testing containment inside the solid companion by
ray casting, the count is **4** (`a0b_isolated_fragments.txt`).

I am reporting the range rather than picking one, because **the bar is zero and
every definition in that table is far above zero.** Whichever you choose, this
mesh ships loose material. But whoever implements the check in §B5 must pin the
definition first, and I recommend the line-width one — it is the physically
meaningful "will this fuse to anything during the print" test.

---

## 2. B1 — a run whose every declared region is too thin now REFUSES

**Status: DONE, with a failing test first.**

### Root cause, file and line

`core/src/cli/run_job.cpp:5401-5456` computes the forecast — per-region thinnest
extent, the required member, the count of thin regions — prints it to stderr, and
stores it at `core/src/cli/run_job.cpp:6180-6184`. **Nothing consumes it as a
stop.** The comment at `:5390-5400` says so deliberately: it explains that the
grading law's own too-thin test reads `local_member_thickness_mm`, which measures
the *design's* printed solid and does not know about the region restriction, so
closing the coherence gap would move the latticed mask — a prior task's
blocked-stop. That reasoning was right about the *mask* and wrong about the
*run*: it left a forecast that says "nothing you asked for can be latticed"
attached to a run that proceeds regardless.

### The failing test, on unfixed code

`b1_all_regions_too_thin.sh` reproduces his shape on the demo l-bracket: seven
4 mm include slabs, 8 mm cell. Against the pre-fix binary (`b1_before.txt`):

```
topopt-cli exit code: 0
[lattice] FORECAST: 7 of 7 include regions are thinner than the 40.000 mm the
          floor requires (thinnest 4.000 mm; floor 5.0 cells x 8.0000 mm)
*** B1 REPRODUCED: the run SUCCEEDED with every declared region too thin. ***
    emitted variant_026_lattice.stl ... variant_068_lattice.stl
    latticed_cells emitted anyway: 161
B1 FAIL (expected, on unfixed code)
```

### The fix

`core/src/cli/run_job.cpp:5457-5545`. When `thin_regions == include_regions` and
`include_regions > 0`, throw `JobError` with the full arithmetic, before any
solve. The message is built from `lattice_derive_cell_for_member` (§Stage A), so
it always states either the admissible (cell, density) window or the two bounds
that cross plus both levers that would change the answer — never a bare refusal.

After (`b1_after.txt`): exit code 1, message as quoted in §0.

### Why `all` and not `any`

Refusing when *some* region is too thin would break every legitimate mixed job —
a thin rib declared alongside a thick boss is a reasonable thing to ask for.
Refusing only when *every* declared region fails leaves no such reading: the run
cannot honour a single thing the user asked for.

**Negative control, run explicitly** (`b1_after.txt`): the same job with six thin
regions and one 48 mm region exits 0 and emits four lattice STLs. The refusal
does not fire on a run that produces usable lattice, which is what keeps it clear
of R3's verdict-flip blocked-stop.

`test_grading`: 26,264 checks, 0 failures (`b1_regression_test_grading.txt`).

---

## 3. Stage A — the per-member cell derivation

**Status: DONE.**

### The arithmetic in section 0 of the original task, verified first

`probe_cell_adaptation` (`r2_probe_before.txt`), all read from core at run time:

```
band rho [0.0505, 0.8999]   N* = 5.00   w_min = 0.42 mm
phi(rho_min) = 0.091252 mm of strut per mm of cell
phi(rho_max) = 0.383575 mm of strut per mm of cell
SHIPPED floor cell = w_min/phi(rho_min) = 4.6026 mm -> N* cells span 23.0131 mm
DERIVED floor cell = w_min/phi(rho_max) = 1.0950 mm -> N* cells span  5.4748 mm
```

**23.0131 mm is the reviewer's "23 mm member", derived from first principles.**
Its condition — evaluated at the band's *lightest* density — is exactly what was
never surfaced. The task's stated figures (0.3836 mm/mm, ~1.10 mm floor cell,
~5.5 mm for five cells) all reproduce.

The behavioural crossover was measured on graded slabs and brackets the predicted
threshold exactly:

```
wall_mm   tau_mm   latticed   solid_back
 4.00       4.00          0       115200     <- his back wall: every candidate solid
23.00      23.00          0       662400
24.00      24.00     583408       107792     <- crossover, predicted 23.0131
```

### What was added

`core/include/topopt/lattice.hpp` — `LatticeCellDerivation` and
`lattice_derive_cell_for_member(topo, member_width_mm, min_extrudable_width_mm,
cells_per_member_floor = 0)`, plus `lattice_min_density_for_strut`.
Implementation `core/src/fea/lattice.cpp:404-520`. Pure arithmetic on core's own
measured constants: no grid, no field, no state, deterministic.

Given member width W, bead w and floor N*, a (cell S, density rho) pair is
admissible iff `w/phi(rho) <= S <= W/N*`. It reports **both ends of the window**
rather than picking one:

- **finest** — the smallest admissible cell, at the lightest density reaching it;
- **coarsest** — exactly N* cells across, at the lightest density that still
  prints there. This is the **minimum-mass** certified lattice for that member.

When the bounds cross it reports `feasible = false`, both bounds, and
`min_member_width_mm` — the thinnest member that *could* hold a certified lattice.

Derived table (`a1_derivation_table.txt`, 0.42 mm bead):

```
wall_mm   feasible | fine_cell fine_rho | coarse_cell coarse_rho  coarse_n
 4.0000   no       | NO PAIR: printable >= 1.0950 mm but homogenizable <= 0.8000 mm
                   | -> thicken to 5.4748 mm
 5.5000   yes      | 1.0950    0.6000   | 1.1000      0.5960      5.00
 8.0000   yes      | 1.0950    0.6000   | 1.6000      0.3362      5.00
12.0000   yes      | 1.0950    0.6000   | 2.4000      0.1751      5.00
23.0000   yes      | 1.0950    0.6000   | 4.6000      0.0505      5.00
```

An 8 mm wall certifies at a 1.6 mm cell and rho 0.336 — a genuinely light
lattice, and today it is refused outright.

### One measurement limit, stated because it is load-bearing

`octet_strut_diameter_mm` is measured on rho 0.05..0.60 and **clamped above
0.60**, while the certifiable band reaches 0.8999. phi is therefore flat on
[0.60, 0.8999] and density above 0.60 buys no extra diameter *in this model*.
That is the conservative direction — a real strut at rho 0.80 is fatter than phi
says, so we demand a bigger cell than strictly necessary, never smaller — and it
is why `densest_relative_density` reports **0.60**, the lightest density reaching
the frontier cell, rather than rho_max. Quoting rho_max would add mass for an
identical cell with no measurement behind it.

### Tests

`core/tests/unit/test_grading.cpp` section 14, seven groups (a)-(g): both window
ends satisfy both constraints; his 4 mm wall is infeasible and names 5.4748 mm;
the frontier width itself is feasible and leaks no sentinel; the +inf
"thicker than the EDT cap" sentinel is handled; monotonicity across W = 5.5..40;
the floor is read from core and scales when overridden; the strut-diameter
inverse is a true inverse where it answers and refuses where it cannot; negative
and NaN widths throw.

---

## 4. Stage B — `region_ids` is reachable

**Status: DONE (reachable, off by default). The blocked measurement stands.**

### Root cause of the discard, and whether it was deliberate

**Commit `eed847b`, "per-region retention: BUILT, TESTED, DISARMED — it did not
pass its bar". It was entirely deliberate.** `core/src/cli/run_job.cpp` built and
populated the per-voxel region id array, then dropped it with `(void)region_ids;`
under a 40-line comment explaining why. A pre-registered bar paired a 3 %
aggregate exposure cap with a 0.10 % certified-margin bound; on a real part a
single region at 2.889 % exposure — *inside* the cap — moved the composite margin
+0.1801 %, which is 1.8x the bound. The stated rule was to report the number
rather than move the threshold, so the widening stayed off.

**That verdict is not re-litigated here and I did not re-measure it.** What was
wrong was not the verdict but the **reachability**: a maintainer who read the
exposure in his own receipt and decided he wanted it had no way to ask.

### What changed

`grading.subfloor_per_region` (default false). Gated in `core/src/cli/job.cpp` on
`retain_subfloor_in_unloaded_regions` being armed — a job that asks for it
without arming retention means one thing and says another, so the schema refuses
it. Wired at `core/src/cli/run_job.cpp:2081`. The ids are still built
unconditionally so the path stays compiled and exercised.

Core-side behaviour was already unit-tested (`test_grading` 13j/13k) and those
tests still pass.

---

## 5. Stage E — the per-region cell report

**Status: DONE for the graded path. See §B4 for the gap.**

`grading.report_region_cells` (default false, additive, decision-free). Adds a
`regions` array to the graded lattice receipt with, per declared include region:
candidate / latticed / solid voxel counts, the **measured** member-width range
(from the same `local_member_thickness_mm` the law itself reads), the **measured**
stress fraction (region peak over part peak, reported whether or not retention is
armed), the Stage A derivation at **both** ends of the thickness range, one of
five verdicts (`certified`, `out_of_regime`, `solid_load`, `no_pair`,
`no_candidates`), the exposure fraction, and `nozzle_needed_mm`.

No number in that block is a literal and none comes from the app. A region with
no candidates still gets a row — "your region caught nothing" is an answer, and
an absent row is not.

It **reports, it never decides.** Nothing in it feeds a mask, cell, density or
verdict; it is computed after the law has already decided, which is what makes
arming it unable to move a gate result. It never substitutes a skin — that is
offered in the text and chosen by the user.

---

## 6. B2 — lattice is landing outside the declared include regions

**Status: DIAGNOSED, file and line. NOT FIXED.**

The amendment asks whether the emitter is scoped to the include mask or to
whatever material can hold a cell. **The answer is: the mask is include-scoped at
VOXEL granularity, but emission happens at CELL granularity, and on his job the
cell is twice as thick as the region.**

- The certification mask **is** include-scoped:
  `lattice_certification_mask` (`core/include/topopt/lattice_boundary.hpp:263-268`)
  requires the voxel centre to be inside the include union.
- But cell activation is whole-cell from **any** masked voxel:
  `core/src/cli/run_job.cpp:2576-2586` sets
  `uniform_cells[owner_cell(i,j,k)] = 1` if `mask[e]`, and the generator then
  emits that entire cell.

At resolution 128 on a 218 mm part a voxel is ~1.70 mm; his cell is 8 mm, so a
cell spans ~4.7 voxels per axis. A 4 mm include region can only ever occupy about
half a cell's depth — so **every emitted cell necessarily extends outside the
region he declared.** It is not a bug in the mask; it is the cell being larger
than the region, and nothing checks that relationship.

Compounding it: **the uniform path applies no cells-per-member floor at all.**
That check lives in the grading law, and his run had no `grading` block
(`rho_min == rho_max`, uniform strut radius). The certification *noticed* —
`lattice_strut_out_of_regime` is computed at `core/src/simp/analyze.cpp:458-460`
as `min_cpm < floor` and his run reports `strut_min_cells_per_member 0.4263`,
`strut_out_of_regime true` — but that flag is **reporting only; it gates nothing**,
and `strut_gated` is false.

**This is the defect.** B1's refusal now stops his exact job before it can happen,
which is the containment. But the underlying rule — a cell may be emitted whole
on the strength of one included voxel — is untouched, and a job with one
admissible region will still write struts outside the declared set. Fixing it
means either clipping emission to the include geometry (moves the emitted mesh on
every role run) or refusing when `cell_mm` exceeds a declared region's thinnest
extent (cheap, and I would do this one first). Both need the gate table that I
did not have budget to run.

---

## 7. B3 — "rim" emits zero geometry on voxel-derived variants

**Status: DIAGNOSED, file and line. LEFT STANDING — outside this task's reach,
per the amendment's own blocked-stop.** Full write-up in
`evidence/.../b3_rim_root_cause.md`.

**★ TWO CORRECTIONS to the first version of this section, both found by measuring
M4 rather than by re-reading.** The function is `emit_rim_line`, not
`emit_rim_edge` (I mis-transcribed the name). And the scope is **wider** than
stated: it is not "voxel-derived parts *without bolt clearances*", it is **every
run through `lattice_boundary_for`**, bolt clearances or not.

The rim dispatch is `core/src/mesh/lattice_gen.cpp:944-961`. It walks face PAIRS
and emits only for:

- **Plane-Plane** → `emit_rim_line` (defined `:598-666`)
- **Plane-Bore**, collar only → `emit_rim_torus` (defined `:676`)
- **Bore-Bore** → nothing; the code says so: *"bore-bore pairs meet nowhere a rim
  can ride"*

So **every emitting pair needs at least one PLANE.** Planes enter `faces_` only
via `add_half_space` (`core/src/mesh/lattice_boundary.cpp:122`); `add_keep_out`
(`:160`) contributes a **Bore**, and only for `ClearanceKind::Bolt`. And
`lattice_boundary_for` (`core/src/cli/run_job.cpp:568-586`) builds the boundary
from `set_voxel_base` + keep-outs + roles and **never calls `add_half_space` or
`add_box`**; roles contribute no analytic faces
(`core/include/topopt/lattice_boundary.hpp:242-245`).

**Therefore no run on this path can emit rim or skin geometry at all.** Measured,
not argued (`m4_blast_radius.txt` case 2): adding a bolt clearance makes `faces()`
non-empty — so the original `faces().empty()` guard stayed silent — and
`rim_triangles` is *still* 0. That is one cause for all four of his zeros, and it
is why the guard had to change (§M4).

This also corroborates an existing finding: handoff
`2026-08-03-variant-postprocessing-fix` already recorded the rim as
"proven un-emittable". This branch establishes *why*, with the dispatch line.

Closing it needs either fitting analytic faces to the voxel silhouette (which
would also enter `clip_segment` and move interior clipping on every existing
lattice run — an R3 blocked-stop) or a voxel-native rim law (a new geometry
generator). Both are their own task.

**The small thing that should land first:** `skin: "rim"` with an empty `faces_`
should refuse or warn rather than silently produce nothing. One line at the top of
the export. I did not land it because it changes behaviour on every existing
voxel-derived rim run and I had no budget to measure that blast radius.

**This matters for his part more than it looks.** Since his 4 mm regions cannot
hold a certified lattice at any cell, a skin is the honest alternative — and on
his geometry a skin is currently a silent no-op. **So the skin option named in
B1's refusal message is not actually available to him yet.** That is the single
most misleading thing left in this branch and it should be fixed next.

---

## 8. B4 — the per-region emitted-cell receipt

**Status: PARTIAL.** Stage E (§5) delivers per-region measured thickness, derived
cell, voxels latticed, voxels left solid and why, and a named verdict — but only
on the **graded** path, and it counts **voxels**, not **emitted cells**.

**Not delivered:** emitted-cell counts per region, and coverage of the **uniform**
path — which is the path his run actually used. A uniform run still has no
per-region receipt at all. Given §B2, the number that would have told him
instantly what was wrong is "region k received 0 cells; 1131 cells went
elsewhere", and that number still does not exist.

This is the largest remaining gap and I am flagging it as such rather than
claiming the stage.

---

## 9. B5 — mesh integrity on every export

**Status: MEASUREMENT TOOLING BUILT AND VALIDATED. NOT WIRED INTO THE LAW.**

`a0_reproduce_stl.py` and `a0b_isolated_fragments.py` measure, on any exported
STL, the connected-component count, the fragment size distribution, and the
isolated-fragment count under a stated definition of "shares space" — separating
*overlapping* stubs (expected: the export is deliberately interpenetrating soup)
from *isolated* ones (loose material). They are validated against his shipped mesh
and reproduce the amendment's figures (§1).

**Not delivered:** the check does not run inside `run_job` and no export refuses on
it. Wiring it needs the threshold decision in §1 pinned first, and it needs to run
on every variant, which is a per-export cost nobody has measured.

Until it lands, **every lattice export should be assumed to carry loose
fragments** — his current one carries between 4 and 128 of them depending on how
you count.

---

## 9b. Review of PR 298 — the two defects it found, and what changed

### M1 — the refusal trigger used the very number this PR proved conditional

**Root cause, file and line.** `core/src/cli/run_job.cpp:5405-5417` set
`cell_mm` from `lattice_cell_printability_floor_mm`, which is evaluated at
**rho_min**, then triggered on `thin_regions == include_regions` where "thin"
meant `extent < n_star * cell_mm`. On a graded AUTO job that made the threshold
5 x 4.6026 = **23.01 mm** — precisely the hidden condition §3 of this task takes
apart, used as a refusal trigger inside the feature that exposes it.

**Failing test first** (`m1_before.txt`), a graded AUTO job with three 6 mm
include regions at a 0.42 mm bead — a size this task's own derivation calls
feasible at 5.4748 mm:

```
exit=1
[lattice] FORECAST: 3 of 3 include regions are thinner than the 23.013 mm the
          floor requires (thinnest 6.000 mm; floor 5.0 cells x 4.6026 mm)
topopt-cli: every declared lattice include region is too thin to hold a
            certifiable lattice at this cell size...
```

That is a **new refusal on a path that previously ran**, which is exactly the
R3 verdict-flip case.

**The choice, stated.** Review offered (a) refuse only on genuine infeasibility
or (b) keep refusing both but fix the threshold. **I took (a), extended by M8c
into three cases**, because (b) still collapses two verdicts with different
remedies:

| Case | Condition | Outcome |
|---|---|---|
| A | No (cell, rho) clears **printability AND percolation** | **Refuse** — genuinely un-latticeable at any setting |
| B | A pair exists, but the **planned cell** does not percolate | **Refuse**, distinct message — the *cell* is wrong; names the working range |
| C | Planned cell percolates but is under the **accuracy** floor | **Proceed**, report loudly — buildable, uncertifiable; the sub-floor-retention regime |

**Why B refuses rather than proceeds.** Proceeding is precisely what shipped him
debris: 0.5 cells per member, 123 loose fragments, a night of solve. A run that
one number in the job would fix should say that number, not print rubble.

**What each does to an existing job.**
- His 7x4 mm at an 8 mm cell: was case-"refuse-with-wrong-arithmetic", is now
  **case B** — still refuses, now with the working cell range and an honest
  "connected but not certified" note (`b1_after.txt`).
- Graded AUTO at 6 mm: was **refused**, now **runs** (`m1_after.txt`, exit 0).
- A job already producing usable lattice: untouched — none of A/B/C fires.

**A fourth situation surfaced while testing and is now reported too.** At 6 mm
the region is above the certifiable minimum (5.4748 mm) yet AUTO plans a
4.6026 mm cell, so the grading law rejects every voxel and emits no lattice. That
is M3 made concrete. Pre-flight now says so, and names the cell that works:

```
[lattice] NOTE: the thinnest declared include region (6.000 mm) IS thick enough
for a CERTIFIED lattice — it needs 5.475 mm and has 6.000 mm — but the planned
4.6026 mm cell puts only 1.30 cells across it, under the 5.00-cell accuracy
floor, so the grading law will reject it and emit no lattice.
        The cell is what is wrong, not the part. A cell of 1.2000 mm at relative
density 0.5239 (strut 0.4200 mm) puts 5.00 cells across this region and
certifies. Set "cell_mm" in the lattice block to that value.
        ("cell_mode": "auto" will NOT do this — it selects the printability
floor at the band's LIGHTEST density, 4.6026 mm, which is how you got here.)
```

### M2 — the message recommended the one thing that reproduces the refusal

**Root cause.** `core/src/cli/run_job.cpp:5505-5525` told the user to
`use "cell_mode": "auto"`. AUTO sets `cell_mm = floor_mm`, the rho_min floor —
following that sentence lands straight back in the same refusal. Deleted.

**Audit of every remaining remedy**, on the standard "must change the outcome":

| Remedy | Verdict | Evidence |
|---|---|---|
| Set `cell_mm` into the named range | **Works** — measured | `m2_remedy_audit.txt`: same job at `cell_mm` 1.2 emits **7757 cells** (AUTO emitted 0), min cells/member 2.083, lattice accepted |
| Thicken to `min_member_width_*` | **Sound** — derived so the bounds cannot cross; unit-tested monotonic in W | `test_grading` §14(b),(e) |
| Nozzle at most X mm | **Sound** — inverse of the same arithmetic | `test_grading` §14(g) |
| `cell_mode: "auto"` | **REMOVED** — reproduces the refusal | — |
| Dress with a SKIN | **REMOVED, and named as unavailable** — emits nothing on voxel-derived parts, and now hard-refuses (§M4) | `m4_blast_radius.txt` |

The skin is named as *unavailable* in the message rather than silently omitted,
so nobody re-adds it.

### M4 — the rim refusal, with its blast radius measured

Landed at `core/src/cli/run_job.cpp`, top of `export_latticed_variant`: if
`lat.skin != "none"` and `boundary.faces()` is empty, throw. Root cause unchanged
from §7 (`lattice_gen.cpp:598-666` indexes face pairs; `faces_` filled only at
`lattice_boundary.cpp:122` and `:160`; `lattice_boundary_for`
`run_job.cpp:568-586` calls neither `add_half_space` nor `add_box`).

**Blast radius measured, not argued** (`m4_blast_radius.sh` /
`m4_blast_radius.txt`), base built from `origin/main` in a detached worktree, with
the binaries-differ assertion first:

- **Case 1 — voxel boundary, no bolt clearance (`faces()` empty).** Base
  **exit 0** with `rim_triangles=0 skin_triangles=0 rim_volume_mm3=0
  anchor_nodes=0` beside `interior_volume_mm3=74304.05`. Branch **exit 1** with
  the new refusal. *The refusal takes exactly the runs that were producing
  nothing.*
- **Case 2 — the same job plus a BOLT clearance.** Intended as the "a run that
  really does emit a rim is untouched" control. **It could not be constructed,
  and finding that out changed the fix.** Base and branch both exit 0 with
  identical counts — *both zero*: `rim_triangles=0 skin_triangles=0
  anchor_nodes=0`. A bolt contributes a **Bore** face, and every emitting pair in
  the dispatch needs a **Plane** (§7). So the control emits no rim, and the first
  version of this script called that a PASS by comparing two zeros.

**The bolt case is the one the original predicate silently MISSED.** With
`faces()` non-empty (one Bore) the old guard stayed quiet while the run still
shipped an undressed part — the exact defect it was written to close. With the
measured-count predicate the same job now refuses. That is the single strongest
argument for the replacement, and it came out of a control that was never a
control.

**Two consequences, and I did not accept the green result.**

1. **The `faces().empty()` predicate was too narrow.** A bolt-clearance job has
   `faces()` non-empty, emits zero rim, and the guard stayed silent — the exact
   defect it was meant to close. **Replaced by the MEASURED emitted count**
   (`rim_triangles + skin_triangles == 0`), checked at the call site in
   `run_job.cpp` right after `export_latticed_variant` returns. That predicate's
   blast radius is exact *by construction*: it cannot fire on a run that emitted
   geometry, so it needs no control to prove it — which is fortunate, because no
   such control exists on this code path.
2. **The script now guards against its own vacuous pass** — it asserts the
   control actually emitted rim triangles, and reports INCONCLUSIVE rather than
   PASS when it did not.

**FINAL RESULT — M4 PASS**, on two independent configurations
(`m4_blast_radius.txt`), base built from `origin/main` in a detached worktree with
the binaries-differ assertion first:

```
CASE 1 — voxel boundary, no clearance (faces() EMPTY)
  base   exit=0   rim_triangles=0 skin_triangles=0 anchor_nodes=0
                  interior_volume_mm3=74304.04617
  branch exit=1   refuses, naming the count and the cause
  PASS — base succeeded while emitting ZERO dressing; branch refuses exactly that.

CASE 2 — same job + a BOLT clearance (faces() NON-EMPTY: one Bore)
  base   exit=0   rim_triangles=0 skin_triangles=0 anchor_nodes=0
                  interior_volume_mm3=69006.00792
  branch exit=1
  rim+skin triangles emitted by the control: 0
  PASS — a SECOND configuration that asks for a rim and emits none; the branch
         refuses it too. This is the case the ORIGINAL faces()-empty predicate
         silently MISSED.

STANDING NOTE: across BOTH configurations the control emitted ZERO rim/skin
triangles. No job on this code path can emit rim geometry, because every emitting
face pair needs a PLANE and lattice_boundary_for never makes one. So there is no
run the guard could wrongly refuse.
```

That standing note is the whole justification for the predicate change: the
`faces()`-empty version would need a rim-emitting control to be provable, and no
such control can be constructed. The measured-count version needs none, because
it cannot fire on a run that emitted something.

It is a refusal and not a warning because `skin: "none"` is always available and
silently shipping an undressed part is how this cost a night.

### M5 — R1 byte-identity, run

`m5_byte_identity.sh` / `m5_byte_identity.txt`, adapted from PR 295's harness
including its ★ `topopt_cli`-vs-`topopt-cli` no-op trap and its
assert-the-binaries-differ guard. **Split into four cases because they have
different identity properties:**

- **A — no lattice at all, base vs branch.** Must be byte-identical.
- **B — graded lattice, no new key, a job that trips neither new refusal**
  (`skin: "none"`, no include regions). Must be byte-identical. *This is the case
  R1 is really about.*
- **C — `report_region_cells` ON vs OFF, same binary.** Everything identical
  except the `regions` block, which must differ.
- **D — the two refusals, base vs branch.** Deliberately different; measured in
  `b1_before/after`, `m1_before/after`, `m4_blast_radius`.

The base is built from a detached worktree at `origin/main` =
**`b3abcf88055402c728e57a1ff7d6af933b8a877b`** — the same commit as the
fingerprint on his overnight run, so this compares against exactly the binary that
produced the artifacts in §1.

**First run: A PASSED, B and C were VACUOUS — the same trap as M4's case 2.**

```
A — NO LATTICE, base vs branch
  IDENTICAL  report.json / fields.bin / design.bin / all four variant_*.stl
  IDENTICAL  run_info.json (minus the named clock keys)
  IDENTICAL  iterations.csv (physics columns)
  A PASS
```

That result stands: **a run that does not lattice is byte-identical.**

B and C did not. No `*_lattice.report.json` appears in either side, and C's own
guard said so outright — *"UNEXPECTED: the regions block did not appear, so C
tested nothing"*. **Cause:** the fixture used a 0.42 mm bead, which puts the
printability floor at 4.6026 mm, so the accuracy floor needs 5 x 4.6026 =
23.01 mm and the demo bracket's widest member is 20 mm. Nothing was ever
latticed, so B compared two empty results and C had no receipt to add a block to.

**Fixed and re-running:** the fixture drops to a 0.20 mm bead (floor 2.19 mm, five
cells 11 mm, comfortably inside the part), and case B now **asserts the control
actually emitted lattice receipts** before comparing — the guard that would have
caught this the first time. The re-run also uses the FINAL binary, since the M4
predicate changed after the first launch.

**FINAL RESULT — M5 PASS**, on the corrected fixture and the final binary, with
the positive control firing (`m5_byte_identity.txt`):

```
B — GRADED LATTICE, no new key, base vs branch
  lattice receipts emitted by the control: 4        <- the positive control
  IDENTICAL  report.json  e252d947356c4384…
  IDENTICAL  fields.bin   18acc4290ea9ac4b…
  IDENTICAL  design.bin   71f415355613b487…
  IDENTICAL  variant_026.stl         fbc75559d19b7686…
  IDENTICAL  variant_026_lattice.stl a5ddaf512240501c…
  IDENTICAL  variant_038.stl         89990d50b22d9f2f…
  IDENTICAL  variant_038_lattice.stl 8103b9764fbc97d3…
  IDENTICAL  variant_052.stl         0e8a8f5a778a8909…
  IDENTICAL  variant_052_lattice.stl 2df4a75b3373592c…
  IDENTICAL  variant_068.stl         e8305a050da13dfd…
  IDENTICAL  variant_068_lattice.stl 5ac82efde511c97a…
  IDENTICAL  all four *_lattice.report.json
  IDENTICAL  run_info.json (minus the named clock keys)
  IDENTICAL  iterations.csv (physics columns)
  B PASS

C — report_region_cells ON vs OFF, same binary
  IDENTICAL  everything above, and all four *_lattice.report.json
             MINUS the Stage A/E regions block
  variant_026/038/052/068_lattice.report.json:
             OFF has regions=False, ON has regions=True (1 row each)
  C PASS
```

**So: a run that does not lattice is byte-identical; a graded lattice run that
trips neither refusal is byte-identical DOWN TO THE EMITTED LATTICE MESHES; and
arming the Stage A/E report changes nothing except its own block, which does
appear.** R1 is met, measured rather than argued.

**One correction to the evidence file.** `m5_byte_identity.txt`'s section D
restates M4 as *"a run WITH analytic faces is untouched"*. That sentence is stale
— it describes the superseded `faces()`-empty predicate. M4's actual result is
above: a bolt-clearance run has analytic faces, emits zero rim, and is now
correctly refused. The script has been corrected for future runs; the committed
output predates the fix.

**The lesson, which is the reusable part:** three separate assertions in this
round passed or nearly passed while measuring nothing — M4 case 2 (two zero rim
counts), M5 case B (two empty lattices), M5 case C (an absent block). Every one
was a fixture that could not reach the code under test. **Any comparison-based
bar on this project needs a positive control assertion — "the thing I am about to
compare actually happened" — or a green result means only that both sides were
equally empty.**

### M6 — R3, R4 and R7 may follow after merge, and here is the ground

Stated explicitly so the exemption is on the record and **not a precedent**:
a wrong verdict from these two refusals shows up as **a job that will not start**,
not as a bad part in the maintainer's hands. Both are pre-flight throws; neither
alters a mask, a cell, a density or a margin on a run that proceeds. That
asymmetry is why the full gate table (R3), his part end to end at res 128 (R4)
and the iterations/wall split (R7) are not blockers here.

They are still owed. M1's failing test is the specific case review found; it is
not a substitute for the table.

### M7 / M8a — the fragment threshold is DECIDED, and the check is NOT wired

The maintainer accepted the line-width test (~0.45 mm, "will this fuse to
anything during the print"). M7 is closed; the decision is his and it is recorded
here.

**M8a is NOT done.** The check does not run inside `run_job` and no export
refuses on it. The blocker is concrete rather than a matter of time alone:
`LatticeExportOutcome` (`run_job.cpp:353-370`) carries **paths and counts, no
mesh** — the export is streaming, by design, for flat RSS. Wiring the check needs
either re-reading each written STL or tracking connectivity during generation,
and the line-width test specifically needs a **spatial index** (my Python uses a
KD-tree) to ask "is any vertex of this fragment within 0.45 mm of another body".
That is new geometry code with its own correctness story, and shipping it
unmeasured is the failure mode this whole branch is about.

**Precise spec for whoever picks it up**, so nothing is re-derived:
1. After `export_latticed_variant`, re-read the emitted STL.
2. Weld vertices at 1e-4 mm; union-find over triangle edges → components.
3. The two largest components are the real bodies (strut network, solid
   companion).
4. For every other component: isolated **iff** no vertex is within
   **`wall_line_width_mm`** (0.45 mm default, read from the job, never a literal)
   of any vertex of either real body, **and** no vertex is inside the solid
   companion by ray casting. Both tests are needed — a fragment fully inside the
   companion touches nothing yet shares space.
5. Refuse when the isolated count is non-zero. Put the count, the threshold
   **and the definition** in the receipt, so a future reader knows what the number
   means.
6. Validate against `~/.topopt-worker/7ba2442960a24050/out/variant_068_lattice.stl`,
   which must report **~123-128** isolated at 0.45 mm (§1).

The Python reference implementation is `a0b_isolated_fragments.py` and it is
already validated against that file.

### N1 — case C's note was FALSE on the graded path, and the fix uncovered a second false remedy

**The defect.** Case C's note said *"The lattice will be built and the certificate
over it will be OUT OF REGIME"* unconditionally. On a **graded** job that is
false: the accuracy floor is exactly what makes `grade_lattice` fall sub-floor
candidates back to **SOLID**. Two notes twelve lines apart in the same branch
contradicted each other, and neither was guarded on `job.grading.present`.

**Why it was the worst thing in the PR.** His 4 mm wall *is* case C. The sequence
it set up was: set the cell, clear pre-flight, spend the solve, get a solid wall —
the fourth time this project has promised him something and delivered nothing.

**(b) The uniform claim, verified rather than assumed.**

- **GRADED enforces the floor.** `core/src/simp/grading.cpp:102` reads
  `lattice_cells_per_member_min`; `note_member_too_thin` (`:20-28`) records the
  fallback to solid.
- **UNIFORM applies no floor at all.** Every `cells_per_member` reference in
  `run_job.cpp` outside the grading receipt and this pre-flight is reporting only,
  and `lattice_strut_out_of_regime` (`core/src/simp/analyze.cpp:458-460`) is a
  **flag, not a gate**. His own uniform run is the proof: 1131 cells emitted at
  **0.4263** cells per member, `strut_out_of_regime` true, `strut_gated` false.

So both sub-cases were wrong in opposite directions. Both are now split on
`job.grading.present` and name the path the reader is on.

**(c) The measurement, and it found a SECOND false remedy.** Running his own
geometry as a graded case-C job at `cell_mm` 1.2 did not produce a case-C run at
all — it was **refused as case B**:

```
planned cell 4.602619932 mm gives 0.8690702381 cells across that region;
a connected network needs at least 1.
```

**A grading block RAISES the target cell to the printability floor**
(`grading.hpp` Fixed mode: `max(target, floor)`), and that floor is evaluated at
**rho_min** — 4.6026 mm at a 0.42 bead. So "set `cell_mm`" is itself an
ineffective remedy on a graded run: the same code path overrides it and returns
you to the refusal. That is precisely the class of defect M2's audit exists to
catch, and my own earlier `m2_remedy_audit` verified the remedy only on a
**uniform** job (where it works: 7,757 cells).

The message now says so and points at the path where the cell is honoured. **Net
effect for his 4 mm wall on a GRADED run: doubly blocked** — the cell cannot be
lowered, and retention cannot be armed from the app (N2).

### N2 — the message pointed at a switch the app cannot send

**Verified in the shipped tree.** `RemoteRunner.swift`'s grading dictionary
(`app/TopOptKit/Sources/TopOptFlows/RemoteRunner.swift:677-703`) emits exactly
`topology`, `min_extrudable_width_mm`, `cell_mode`, `cell_min_mm`, `cell_max_mm`,
`cell_mm`. `subfloor` appears in `app/` **only** in `LatticeForecast.swift`
(lines 88-116) as read-only display fields. `RelatticeRunner` does not send it.

Both new messages now state that the switch is a **job-JSON key not exposed in
the app**, and lead with the remedy the app can actually send.

**★ FOUR CORE OPTIONS ARE UNREACHABLE FROM THE APP.** This list is the brief for
a separate app task and should not have to be rediscovered:

| Core option | Where it lives | App can send it? |
|---|---|---|
| `retain_subfloor_in_unloaded_regions` | `grading` | **No** |
| `subfloor_stress_fraction` | `grading` | **No** |
| `subfloor_per_region` (new, this PR) | `grading` | **No** |
| `report_region_cells` (new, this PR) | `grading` | **No** |

No app code was added to this branch. M5's identity story is built on core-only,
and the app work needs its own failing-test-first treatment against `app-macos`.

### M8b — the percolation floor now exists in core

`lattice_percolation_cells_per_member_min` (`core/src/fea/lattice.cpp`, declared
in `lattice.hpp` beside the accuracy floor), returning **1.0** for octet from the
same study's C2 **axial** table (0.5 cells DISCONNECTED, 1 cell connected at
+2.36%, 2 at +1.20%, 3 at +0.81%).

`LatticeCellDerivation` now always reports **both** answers and labels which floor
was in force: `min_member_width_certifiable_mm`,
`min_member_width_buildable_mm`, `feasible_percolation`,
`cells_per_member_at_finest`, `floor_in_force_is_accuracy`. Both appear in the
refusal messages and in the Stage E per-region block.

### M8d — three measurement gaps, stated rather than closed

Named here so the next number is not quoted unconditionally, as three have been
already on this project:

1. **Percolation was measured at rho ~= 0.199 and AXIALLY.** The derived-cell
   route puts it at rho ~ 0.60 and members are loaded in bending. **It is
   unmeasured there.** The constant's own comment says so.
2. **`octet_strut_diameter_mm` is clamped above rho 0.60** while the band reaches
   0.8999. So the "densest" end of every derivation is a **measured-data limit,
   not a physical one**. It is the conservative direction (a real strut at rho
   0.80 is fatter than modelled, so we ask for a bigger cell than needed), but it
   is not a statement about the lattice.
3. **Self-support is not modelled anywhere.** The maintainer's bar for a
   non-load-bearing wall is "as long as it holds itself up", and percolation says
   the struts connect **in the model**, not that the print succeeds.
   `build_orientation.json` already scores an "S-e horizontal strut fraction" and
   **nothing gates on it**. A self-support check would need: per-strut angle to
   the build direction, an overhang threshold per material, the unsupported-span
   length between nodes, and a rule for what a lattice may do at the first layer.
   **Scoped, not built.**

**The measured end of this argument**, and it is the one to quote: his shipped
mesh ran at **0.4263 cells per member** and produced **123 isolated fragments** at
the line-width threshold. Below percolation you do not get a thin lattice, you get
debris.

## 10. What was NOT done from the original task

Stated plainly rather than buried:

- **Stage C (design box + grading)** — not attempted. The refusal at
  `core/src/cli/run_job.cpp:5071` stands. I did establish the fix shape while
  reading: the swept level predicate reads the *plan*
  (`core/src/cli/run_job.cpp:2409-2415`, `pl->level[...] == LV`) rather than the
  final mask, while the graded uniform path already derives activation from the
  mask (`:2231-2233`). Making the candidate set added-material-aware before
  `grade_lattice`, then intersecting the swept predicate with the final mask at
  each level's granularity, closes the stated cause. The ordering works
  (`grade_lattice` runs before the added-material pass), so it is doable — I ran
  out of budget, not out of road.
- **Stage D (app serializer keys, `RelatticeRunner` mirror, `LatticeForecast`
  test through the real serializer)** — not done. `report_region_cells` and
  `subfloor_per_region` are core-only today; the app cannot ask for either.
- **R1 byte-identity** — **not run.** The changes are additive and gated
  (`report_region_cells` and `subfloor_per_region` both default false; the Stage E
  block is emitted only when non-empty), so I expect a default graded run to be
  byte-identical — **but "by construction" is exactly what R1 forbids, and I did
  not measure it.** The harness shape is proven and reusable:
  `evidence/2026-08-04-subfloor-lattice-unloaded-regions/s1_byte_identity.sh`,
  including its assertion that the two binaries differ.
- **R3 full gate table, R4 his part end to end at res 128, R7 iterations and
  wall** — not run. B1's refusal changes verdicts *by design* on jobs where every
  region is too thin (they now refuse), and the negative control shows it does not
  fire otherwise, but that is not the full table.
- **R5 percolation as a refusal in the law** — see §9.

Nothing here is blocked. It is unfinished, and the ordering I would take is:
B3's one-line refusal, then B4's uniform-path per-region cell counts, then R1 and
the gate table, then B2's cell-versus-region check, then Stage C and Stage D.

---

## 11. In plain language

**What was wrong.** You asked for a lattice in seven places on your part. Every
one of those places is 4 mm thick. The lattice cell the job asked for was 8 mm,
and the rule that keeps a lattice honest needs at least five cells across
whatever it is filling — so it needed 40 mm of material and had 4. The software
worked all of that out before it started, wrote it down, and then ran anyway for
a night. What it built put lattice in the middle of the part, where you had not
asked for it, and nowhere you had.

**What I fixed.** That job now stops immediately and tells you why, in numbers:
how thick each region is, how thick it would need to be, and the two things that
would change the answer — a thicker wall, or a finer nozzle. It only stops when
*every* place you asked for fails. If even one of them works, it runs as before.

**The 23 mm story.** You were told you needed a 23 mm wall. That number was real
but it had a hidden assumption: it was worked out for the *thinnest, lightest*
lattice the system can certify. If you let the lattice be a bit denser, the struts
get fatter, so the cells can be smaller, so more of them fit across the same wall.
Doing the arithmetic that way gives **5.5 mm**, not 23 mm. Both numbers now come
out of one piece of code that shows its working, instead of one of them being
buried in a constant.

**The most important caveat, and it was missing the first time.** The software now
works out the right cell size and *tells you*, but **it does not yet use it
itself**. When you leave the cell size to the software it still picks the old,
too-coarse number. The new arithmetic feeds the messages and the report, not the
machine that lays out the lattice. If you type the cell size it recommends into
the job by hand, that works — I measured it: the same job that produced no
lattice at all produced 7,757 lattice cells once the recommended 1.2 mm cell was
set. But you have to type it. Making the software pick it automatically is the
next task, and §9b explains what that costs.

**Your 4 mm wall: not impossible, just not certifiable.** This is a real
distinction and the first version of this work got it wrong. There are two
different limits, not one:

- The struts have to *join up*. That needs about **one** cell across the wall.
  Below it you do not get a thin lattice, you get loose crumbs — which is exactly
  what your last run produced.
- The *certificate* — the number that says how strong it is — needs about **five**
  cells across. Below that the maths behind the strength claim stops describing
  your wall, **but the part still prints perfectly well**.

Your 4 mm wall sits at about **3.4 cells**. Well above "the struts join up", well
below "we can certify it". So it *can* be built, at a cell of about 1.2 mm, and
the strength number over it will be flagged as outside its valid range. The
software now says that, instead of refusing you flat. To get a wall the
certificate *does* cover, you need about 5.9 mm of material, or a 0.31 mm nozzle.

**Two mistakes in my own first version, found in review and fixed.** The refusal
was using the very "lightest-density" number this work exists to expose, so it
would have refused a 6 mm wall that is genuinely fine. And its advice told you to
switch the cell size to "automatic" — which picks the old number and lands you
straight back in the same refusal. Both are gone.

**And two more found in the second review, which would have cost you another
night.** The message said your wall's lattice "will be built". That is only true
if you run a *uniform* lattice job. If you use a **graded** job — the one with
automatic density — the software deliberately turns thin walls back to solid, so
you would have set the cell, waited out the solve, and got a solid wall again.
Worse, on a graded job you cannot even set the cell you want: it quietly raises
your number back up to the old one, so that advice did not work either.

**So, concretely, for your 4 mm wall — and I got this wrong once already, so here
is the measured version.** I first wrote that running it as a plain lattice job
(setting cell size and strut radius yourself, no automatic-density block) would
put lattice in that wall. **I then actually ran it on your job, and it did not.**

The run worked and built 6,082 lattice cells. But the thinnest piece of material
that got any lattice was **6.8 mm thick**, and your walls are 4 mm. So all of
that lattice went somewhere else in the part — thicker material you did not
select. That is the same problem as item 1 above, showing up on the very route I
had just recommended to you.

**The honest position: there is currently no route that puts a lattice in a 4 mm
wall on your part.** On an automatic-density job the wall comes back solid. On a
plain lattice job the lattice lands in thicker material instead. To change that
you need either a thicker wall (about 5.9 mm for a certified lattice) or a finer
nozzle — or the software needs to stop putting lattice where you did not ask for
it, which is the next task.

One caveat on my own measurement: I ran at half your resolution to keep it to an
hour, and at that resolution a 4 mm wall is barely one voxel thick, which may be
part of why nothing landed there. **That test needs redoing at your resolution
before anyone treats it as the last word.** Every piece of advice the software
prints has been checked against "does following this actually change the
outcome?" — this one failed that check, which is why it is written down here
rather than quietly dropped.

**Three things I found and did not fix, which you should know before your next
run:**

1. **Lattice lands outside the regions you draw.** The software checks region
   membership one voxel at a time, but it *builds* lattice one whole cell at a
   time. When the cell is bigger than the region — 8 mm cell, 4 mm region — every
   cell it builds sticks out of the region by construction. Your job now refuses
   before this can bite, but a job with one workable region will still do it.

2. **The "rim" finish does nothing on your part — and now says so.** Rim only
   knows how to dress flat faces and bolt holes that the job describes
   mathematically. Your part's shape comes from the voxel grid, which has none of
   those, so rim had nothing to attach to and quietly produced zero geometry.
   **It now refuses instead of doing that quietly**, and I removed the "use a
   skin instead" line from the refusal message, because it was pointing you at a
   door that is painted on. I measured that this only affects runs that were
   already producing nothing — a part that really does get a rim is untouched.
   Actually making rim work on voxel-shaped parts is a separate job (§7).

3. **The exported mesh contains loose bits.** About 123 fragments float free of
   both main bodies, using the test you chose — "is it within one extrusion line
   of anything else?". I built the tool that measures this and checked it against
   your file, **but it does not yet run automatically or block an export**, and
   that is honestly the biggest thing still open. Assume any lattice file you get
   right now has some loose material in it. §9b has the exact recipe for wiring
   it in, so whoever does it next does not have to work any of it out again.

**What I did not get to at all:** letting the app ask for any of the new options
(so this is command-line only for now), the design-box-plus-grading combination,
and the full before/after verdict table across every rung. None of it is blocked —
I ran out of time, not out of a way forward. The order I would tackle them in is
at the end of §10.
