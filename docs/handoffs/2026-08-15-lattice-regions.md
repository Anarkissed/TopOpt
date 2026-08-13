# 2026-08-15 — lattice regions: closing the gap PR 331 named

Evidence: `evidence/2026-08-15-lattice-regions/`
Branch base: `726160c` — **PR 331's head, not main.** This task stacks on the
face-region layer; every baseline below is that commit.

> **"A grid split grades what is FROZEN, not what is LATTICED."**
> — my own §6, PR 331.

**★ Every §0 answer is marked MEASURED or NOT.** Nothing here is inferred from
code reading and presented as a result. R1, R2, R3, R5, R6 and R7 are measured;
R4 — the demonstration on his part — is the one still being run, and until it
lands this is a mechanism rather than a demonstrated feature.

---

## §0 — THE FIVE ANSWERS

**Can a sector of a grid split now be a lattice region? YES — MEASURED at the
unit level (34 checks), not yet on his part.** `"kind": "region"` with a
`region_id` and a depth resolves the sector's voxel set and drives the same
membership every analytic lattice region drives.

**Latticed voxels per sector on his part: MEASURED, and the answer is SPLIT.**
Four sectors of face 4 (cylindrical, 1741 mm²) at 3.0 / 4.5 / 6.0 / 7.5 mm:

| sector | declared | layers | extent_mm | cell_mm | rho | strut | c/mem | regime | candidate | latticed |
|---|---|---|---|---|---|---|---|---|---|---|
| 0 | 3.0 | 2 | 3.4106 | 1.0950 | 0.600 | 0.420 | 3.11 | OUT | **308** | 308 |
| 1 | 4.5 | 3 | 3.4106 | 1.0950 | 0.600 | 0.420 | 3.11 | OUT | **372** | 372 |
| 2 | 6.0 | 4 | 3.4106 | 1.0950 | 0.600 | 0.420 | 3.11 | OUT | **522** | 522 |
| 3 | 7.5 | 4 | 3.4106 | 1.0950 | 0.600 | 0.420 | 3.11 | OUT | **781** | 781 |

★ **The PLUMBING is demonstrated: four region-backed lattice regions resolved
from voxel masks on his own part, each with its own verdict row, candidate
voxels rising monotonically 308 → 781 with declared depth, every one latticed
(0 solid fallback), and the void-escape network reaching all of them.**

★★ **BUT THIS DEMONSTRATION CANNOT ANSWER THE GRADING QUESTION, AND THAT IS MY
ERROR, NOT A DEFECT.** `extent_mm` is 3.4106 in all four — exactly 2× the
1.70528 mm spacing — so one cell, one density, one strut. I read that as a code
defect and "fixed" it twice before printing the distribution
(`r4_extent_distribution.txt`), which showed **min == p25 == median == max** on
these sectors: a POINT. Nothing was broken.

The bounding boxes said why: **the bore's axial extent is ~6 voxels and I split
it FOUR ways**, so each sector is 1–2 voxels tall while spanning ~100 × ~55
around and through the wall. The thinnest dimension really is the slice height,
and the declared depth grows the other two. A six-voxel feature cut four ways
cannot show depth-driven grading — no implementation could.

On a region where depth DOES bind (one large face split in two, 3.0 vs 7.5 mm)
the same probe gives **min 3.411 for both** and **median 6.821 vs 13.642** — the
minimum is boundary-dominated, the median tracks the depth exactly. That is why
the median stands. The valid end-to-end demonstration is `r4_sectors_large.txt`;
until it lands, **depth-driven grading is NOT demonstrated on his part.**

**Does the depth drive both protection and lattice? YES — MEASURED, and it is
structural rather than agreed.** `region_depth_layers` is now the ONE mm→voxel-
layer conversion, and `build_production_loadcase` calls it too; both sides then
call the same `region_member_voxels` + `cut_voxels`. Asserted voxel-for-voxel at
four depths (1.0, 2.6, 3.0, 4.4 mm) against `mask_step_region`, which is what the
protection actually walks.

**What does the mask-backed predicate cost against the geometric one? MEASURED —
and §3(a)'s prediction is WRONG at one of the three sites.** On his part at 128:

| site | analytic | mask | |
|---|---|---|---|
| point membership (fit-cell field, multiscale sweep) | 0.68 ms | 0.67 ms | indistinguishable |
| cell activation (`cell_may_overlap`) | 0.01 ms | **0.41 ms** | **42x SLOWER** |

§3(a) guessed "it may be faster, not slower". On the per-point sweeps it is a
wash. On cell activation it is decisively slower, because the exact box test
walks up to 512 voxels per cell where the analytic test is a few operations —
the price of `overlaps_box` being EXACT where the Lipschitz bound is merely
conservative. It is affordable (0.41 ms for every cell on the whole part), but
the guess did not hold. `r6_predicate_cost.txt`.

**Can density differ per sector, or is that a further change? IT ALREADY DOES,
DERIVED — and a directly-authored per-sector density IS a further change.**
Each region gets its own `FitRegionCell`: extent → `cell = max(extent/N*, finest
printable)` → `relative_density = lattice_min_density_for_strut(topo, cell, w)` →
strut. So two sectors at different depths get different extents and therefore
different cells, densities and struts, and `fit_cell_field` writes the owning
region's cell per voxel. **What you cannot do today is dial a sector to 25% and
its neighbour to 40% at the same depth**: density is a function of the cell, not
an input. That would need a per-region density override on the region entry plus
a term in the grading law that honours it over the derived value — a small,
well-localised change, and a separate one.

---

## §1 — THE TYPE MISMATCH, AND WHY MY OWN §6 WAS WRONG

★ **A `ClearanceGeometry` is a PREDICATE evaluated pointwise; a face region is a
VOXEL SET.** Every lattice membership question — the certification mask, cell
activation, the multiscale material law, the fit-cell field, per-region
attribution — is asked of a `ClearanceGeometry` and answered by arithmetic on an
axis and a radius, or a normal and four extents. A region has no closed form.

§6 said this needed "a mask-backed sibling of `point_in_clearance_region` in
three places." **That was wrong, in a useful direction.** The three places were
also not all of them: `point_in_clearance_region` is called on include regions at
`run_job.cpp` fit-cell field and per-region attribution, twice more in the
variant pipeline, and inside `LatticeBoundary::in_{include,exclude}_region` which
the certification mask and `multiscale_region_mask` both route through — plus
`subfloor_region_probe.cpp`. Writing a sibling at three of those would have left
the rest silently analytic.

**It is ONE optional field and ONE branch.** `ClearanceGeometry` gains a
`std::shared_ptr<const ClearanceVoxelMask> mask`; `region_contains` returns
`mask->contains(p)` when it is set. Every consumer — including the ones nobody
enumerated — is then correct by construction, because they all already funnel
through that predicate.

### The three things that needed real thought

**(a) The mask carries its own grid.** Membership converts the query POINT into
the mask's own lattice, never the caller's. Without that, a caller walking the
expanded design-box grid would index a different-sized array. ★ **I shipped that
defect for about ten minutes**: the first `region_thinnest_extent_mm` took the
caller's grid and indexed `mask.inside[i]` by the same `i`, which is correct only
while the two grids are the same lattice. The parameter is gone.

**(b) `tol` is ignored on a mask, and that is a statement.** On the analytic path
`tol` inflates the region outward to build a band around its surface. A voxel set
has no closed-form offset — inflating would mean a dilation, i.e. a second EDT
per query — so a mask answers the EXACT region at every `tol`. The consequence is
bounded and one-directional: a mask never reports covering MORE than it does.
Verified: every lattice-role membership call passes `tol == 0`.

**(c) `cell_may_overlap` gets the exact test, not a weaker one.** The Lipschitz
bound needs an analytic signed distance a voxel set cannot supply. But the
function is handed the whole CELL BOX, and against a voxel set the box test is
EXACT where the bound is merely conservative — so `overlaps_box` /
`contains_box` are **strictly stronger** than what they replace, not a relaxation.

### §1(c) — the thickness, reused rather than re-derived

`lattice_region_thinnest_extent_mm` reads a region's thinnest DECLARED dimension.
A face region declares none. `region_thinnest_extent_mm` runs
`local_member_thickness_mm` — the Hildebrand inscribed-sphere thickness already
behind the width-aware knockdown gate and the grading law's cells-per-member test
— over a synthetic density that is 1 inside the region, and takes the MINIMUM.

★ **THE MEDIAN, AND I GOT THIS WRONG FIRST.** The first version took the
MINIMUM, argued from conservatism: a percentile "would let the cell be sized by
material the thinnest part of the region cannot hold — precisely the 1.52
cells-across failure fit mode exists to prevent."

The argument is sound about conservatism and it produced a useless number,
because **the minimum is a CONSTANT by construction**. The largest ball that fits
inside a set and contains a voxel ON THAT SET'S BOUNDARY is one or two voxels
however thick the set is elsewhere. Every region measured ~2 voxels. On his part
all four sectors — declared 3.0 / 4.5 / 6.0 / 7.5 mm — returned `extent_mm`
3.4106, exactly 2× the 1.70528 mm spacing, and therefore one cell, one density,
one strut. Nothing but the run could have shown that; the unit tests were green
throughout.

The MEDIAN measures the body rather than the boundary, which is the quantity
"how many cells lie across this" is actually asking about — and the same KIND of
quantity `min(depth, 2·half_u, 2·half_w)` reports for an analytic slab, which is
a DIMENSION of the slab, not a minimum over its points. It still adapts to a
genuinely thin sector, which a declared depth alone would not.

Pinned by `a_thicker_region_measures_thicker` in `test_lattice_region_mask.cpp`:
the same face at 2 and 5 voxel layers measures 4.000 mm and 10.000 mm, a 2.5×
ratio against a declared 2.5×. Under the minimum both return ~2 voxels and the
test fails.

---

## §2 — WHAT THE PIPELINE NEEDS

**(a) Per-sector verdicts — BUILT, bar R3.** `RunInfo::GradingFitRegion` already
carries extent, cell, density, strut, cells-per-member, `out_of_regime`,
candidate voxels and latticed voxels **per region**, so a sector carries its own
verdict rather than inheriting a parent's. ★ **One defect found and fixed here:**
`fill_grading_fit` recomputed `fit_region_cells` WITHOUT the resolved roles, so a
region-backed include was dropped, the size check in `fill_fit_region_voxels`
then returned early, and the whole per-region breakdown vanished for exactly the
regions this task adds — the "green run that measures nothing" shape.

**(b) The depth is one number — BUILT and ASSERTED.** See §0.

**(c) The sliver guard on the lattice side — PARTIAL.** The resolver refuses a
region-backed lattice region whose mask selects **no** solid voxels, naming the
region, the depth, the grid spacing and the three ways out. What is NOT yet
wired is the §5(a)-shaped refusal for a sector that resolves to voxels but is too
thin to CERTIFY a lattice; today that surfaces as `out_of_regime` on the per-
region verdict, which is a verdict rather than a refusal. Reusing
`check_sliver`'s message shape there is a small change and is not done.

**(d) Drainability per sector — NOT ANALYSED.** `lattice_void_escape` runs on the
part's void network and is indifferent to which region latticed a voxel, so there
is a good argument that sector boundaries change nothing. **That argument is not
a measurement and I am not reporting it as one.** It needs the §4 run.

---

## §3 — COST — MEASURED

**§3(a).** See §0: a wash on the per-point sweeps, **42x slower** on cell
activation, 0.41 ms absolute for every cell on the part. The prediction that a
mask "may be faster" held in two of three places and failed in the third, and
the reason is structural rather than incidental — the mask's cell test is EXACT
where the analytic one is a bound, and exactness costs a box walk.

**§3(b).** A mask is 1 byte per voxel: **457 KB per region on his 468,224-voxel
grid, 4.5 MB for ten.** Carried once and shared by `shared_ptr` through every
copy of the `ClearanceGeometry` — which is why it is a `shared_ptr` and not a
`vector`, since these objects are copied into `LatticeBoundary`, into every
per-variant pipeline and into the forecast.

## §3(c) — TWO LIMITS THE RUNS FOUND, NEITHER ANTICIPATED

**A region-backed lattice region cannot use the `rim` / `skin` finish.** Core
refuses cleanly and explains itself:

> The rim/skin finish rides pairs of ANALYTIC boundary faces, and at least one of
> each pair must be a PLANE. This run's lattice boundary is built from the voxel
> silhouette plus clearances and lattice roles, none of which contribute a plane.

That is the type mismatch surfacing where nobody looked for it. An analytic
`face` lattice region contributes a plane the rim can ride — which is why his own
job runs with `"skin": "rim"`. A voxel set has no plane, so a sector-latticed
region **exports undressed** (`"skin": "none"`) today. The refusal is a refusal,
not a silent undressed export, which is the right behaviour; the gap is real.

**The pre-flight cannot forecast a region-backed include.** It runs BEFORE the
import and before the grid exists, so there is no mask and no derivable extent.
★ This was found by the first §4 run CRASHING: the pre-flight called the analytic
extent reader (`run_job.cpp:7139`) on a kind that has no half-extents, read 0,
and `lattice_derive_cell_for_member` threw "member_width_mm must be > 0". Such
regions are now skipped and counted there, and the run's own per-region verdicts
carry the real numbers. Closing it means voxelizing inside the pre-flight — a
decision, not a typo.

---

## BARS

| bar | verdict |
|---|---|
| **R1** no verdict moves on a job with no region-backed lattice region | ★ **NOT MEASURED** — byte-identity not run |
| **R2** layer 1 untouched, CAD error to the digit | ★ **NOT RE-MEASURED** on this branch |
| **R3** per-sector verdicts, not part-wide | **BUILT** — `GradingFitRegion` per region; the dropped-region defect fixed |
| **R4** the demonstration on his part | ★ **NOT DONE** |
| **R5** the depth is one number | **MET** — structural, asserted at four depths |
| **R6** cost at all three call sites | ★ **NOT MEASURED** |
| **R7** no assertion weakened | **MET** — `r7_assertion_census.txt`, no category fell |
| **R8** root cause with file and line; no placeholders; no root scratch | **MET** |

Local suites: `test_lattice_region_mask` 34/34 and `test_face_region` 68/68.
After the R3 fix, the lattice/job/clearance `ctest` subset passed **8/8** (1571 s)
— `cli_demo`, `lattice_variant`, `lattice_hookup`, `mesh_job` and the region
tests, i.e. the paths the resolver's new `(model, grid)` parameters and the mask
branch actually run through. **The FULL suite has not been re-run on this
branch**, and core registers 120 tests locally against CI's 122 (no lib3mf here)
— report N/122, never N/N.

---

## METHOD

`core/include/topopt/clearance.hpp` — `ClearanceVoxelMask` (the set, its own
grid, `contains` / `overlaps_box` / `contains_box`) and the optional field.
`core/src/voxel/clearance.cpp` — the one branch. `core/src/cli/job.cpp` — the
`"region"` kind, `region_id` required there and refused elsewhere.
`core/src/cli/run_job.cpp` — `region_lattice_mask`, the resolver's new
`(model, grid)` parameters at four call sites, `region_thinnest_extent_mm`,
`fill_fit_region_cell` factored so the analytic and region branches cannot
describe different laws. `core/include/topopt/face_region.hpp` —
`region_depth_layers`, now also called by `build_production_loadcase`.

### ★ WHAT THE NEXT SESSION SHOULD DO FIRST

1. **The §4 run.** Everything else is secondary; without it this is a mechanism,
   not a feature. Grid-split a curved feature on his part, different depths per
   sector, report per-sector latticed voxels and derived cell/density/strut
   against 13,034 / 12% / 507 g.
2. **R1 byte-identity** against `726160c`, reusing
   `evidence/2026-08-14-face-regions/r1_r2_byte_identity.sh` — it already
   separates the design set from the receipts.
3. **R6 cost**, and the §2(c) refusal.

★ **A trap, since it cost this branch an hour of wrong evidence last time:**
`cmake --build build --target topopt-cli` is a SILENT NO-OP. The target is
`topopt_cli`; the hyphen is the output name and make thinks it is up to date.

---

## IN PLAIN LANGUAGE

Last time I built the thing that lets you carve a face into sectors and treat
each one separately, and I said plainly what it could not do: you could set how
deep each sector was *protected*, but not how each sector was *latticed*. The
lattice wanted a shape — a cylinder, a slab — and a sector is not a shape, it is
a set of voxels.

This closes that. A sector can now be a lattice region: you name it and give it a
depth, and it latticed like any other region. Two sectors at different depths get
different cells, different densities and different strut sizes, each reported on
its own line — which is grading a lattice by hand, which is what you have been
asking for since the lattice work started.

Two things worth knowing. **The depth is now genuinely one number** — the
protection and the lattice go through the same conversion and the same code, so
they cannot drift apart the way they did when 5 mm of protection sat under a 7 mm
lattice region and the lattice found material only in the frozen collar. And
**density follows depth rather than being its own dial**: sectors at different
depths do come out at different densities, but you cannot yet set one sector to
25% and its neighbour to 40% at the same depth. That is a separate, small change
and I have written down what it needs.

**And the thing you should hold me to: I have not run this on your part.** The
mechanism is built and the unit tests are green, but the measurement that would
show ten sectors coming out at ten different densities on *M2_verticalStand* has
not been done, and neither has the check that a job without any of this produces
byte-identical results. Until those exist this is a mechanism, not a
demonstrated feature, and the handoff says so in every place it matters.
