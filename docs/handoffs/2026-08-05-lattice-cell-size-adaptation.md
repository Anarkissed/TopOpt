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
every declared lattice include region is too thin to hold a certifiable lattice
at this cell size, so this run cannot put lattice anywhere you asked for it —
refusing before spending a solve.
  regions declared (include): 7, all of them too thin
  planned cell: 8 mm; cells-per-member floor 5 => required member 40 mm
  thinnest declared region: 4 mm
  NO (cell, density) PAIR IN THE CERTIFIABLE BAND FITS THIS THICKNESS AT THIS NOZZLE.
    smallest cell any certifiable strut prints at (0.42 mm bead): 1.094961872 mm
    largest cell a 4 mm member can homogenize: 0.8 mm
    the two bounds cross, so no cell satisfies both.
  WHAT WOULD CHANGE THE ANSWER (your call, not this pipeline's):
    * thicken the region to at least 5.474809359 mm; or
    * use a nozzle/bead of at most 0.30686 mm; or
    * dress the region with a SKIN instead of a lattice — an option offered
      here, never substituted automatically.
```

**The "23 mm member" you were told you needed was a conditional number and the
condition was never stated.** It is 5 x the printability floor evaluated at the
*lightest* certifiable lattice in the band. Nothing forces you to lattice at the
lightest density. Evaluated at the density a member can actually carry, the same
arithmetic gives **5.47 mm**, not 23 mm. Both numbers now come out of one core
function instead of one of them being folded into a floor nobody could see into.

**But this does not rescue your part, and I am not going to imply it does.** At
your run's density and your 0.45 mm line width the requirement lands at 5.87 mm.
You have 4 mm. The derivation takes you from **10x short to 1.47x short**. It
does not close the gap. What closes it is 5.9 mm of wall, or a 0.31 mm nozzle.

Three more things are wrong with that run and are **diagnosed but not fixed** —
read §B2, §B3 and §B5 before you run anything: lattice is landing outside your
declared regions by construction, `skin: "rim"` is a silent no-op on your
geometry, and the shipped mesh carries loose fragments.

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

The rim is emitted **only where two ANALYTIC boundary faces meet**
(`emit_rim_edge`, `core/src/mesh/lattice_gen.cpp:598-666`, indexes
`B->faces()`). `faces_` is populated in exactly two places
(`core/src/mesh/lattice_boundary.cpp:122` for planes, `:160` for **bolt** bores
only). But `lattice_boundary_for` (`core/src/cli/run_job.cpp:568-586`) builds the
boundary from `set_voxel_base` plus keep-outs plus roles, and **never calls
`add_half_space` or `add_box`**; roles are documented to contribute no analytic
faces (`core/include/topopt/lattice_boundary.hpp:242-245`).

So on a voxel-derived design with no bolt clearances — his run exactly —
`faces_` is empty, there are no face pairs, and the rim, the skin and the anchor
nodes are all structurally unreachable. That is one cause for all four zeros.

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

**The honest part: this does not save your part.** At your run's settings the
requirement lands at about 5.9 mm and you have 4 mm. So the fix takes you from
"ten times too thin" to "about one and a half times too thin". Closer, still
short. To actually get a lattice in those walls you need roughly 5.9 mm of
material there, or a 0.31 mm nozzle instead of 0.45 mm.

**Three things I found and did not fix, which you should know before your next
run:**

1. **Lattice lands outside the regions you draw.** The software checks region
   membership one voxel at a time, but it *builds* lattice one whole cell at a
   time. When the cell is bigger than the region — 8 mm cell, 4 mm region — every
   cell it builds sticks out of the region by construction. Your job now refuses
   before this can bite, but a job with one workable region will still do it.

2. **The "rim" finish does nothing on your part, silently.** Rim only knows how to
   dress flat faces and bolt holes that the job describes mathematically. Your
   part's shape comes from the voxel grid, which has none of those, so rim had
   nothing to attach to and quietly produced zero geometry. **This means the
   "use a skin instead" option the new refusal message offers you is not really
   available yet.** That is the most misleading thing left and it is next on the
   list.

3. **The exported mesh contains loose bits.** Between 4 and 128 fragments float
   free of both main bodies, depending on how close two pieces have to be before
   you call them joined. I built the tool that measures this and checked it
   against your file, but it does not yet run automatically or block an export.
   Assume any lattice file you get right now has some loose material in it.

**What I did not get to at all:** letting the app ask for any of the new options
(so this is command-line only for now), the design-box-plus-grading combination,
and the full before/after verdict table across every rung. None of it is blocked —
I ran out of time, not out of a way forward. The order I would tackle them in is
at the end of §10.
