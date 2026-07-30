# Can surface geometry enter the solve? — surface stiffness PROBE

**Date:** 2026-07-31
**Branch:** `claude/surface-stiffness-probe-7fc0a8`
**Predecessors:** lattice skin freeform (`2026-07-30-lattice-skin-freeform` — the
finish-blind gate and the refused `skin` finish this probe exists to unblock),
lattice boundary finish (`2026-07-29-lattice-boundary-finish`), matrix-free cubic
tensor probe (`2026-07-30-matfree-cubic-probe` — Ke linear in D), multiscale
lattice feasibility (`2026-07-31-multiscale-lattice-feasibility` — row-count
adequacy), tensor library nine (`2026-07-29-tensor-library-nine`).
**Machine:** Apple M2 Pro (10 cores), 16 GB, Apple clang; library Release (-O3),
harness -O2.
**Production change: NONE.** The production library is linked UNMODIFIED — proven
by a stash-rebuild member-object comparison (37/37 objects byte-identical,
`k7_stash_rebuild.txt`). Everything lives in the harness
(`core/tests/harness/surface_stiffness_model.hpp`,
`core/tests/harness/surface_stiffness_probe.cpp`) and one pinning unit test
(`core/tests/unit/test_surface_stiffness_model.cpp`; the only production-tree
file touched is `core/CMakeLists.txt`, to register that test target). No gate
logic, no tolerance, no fixture, no materials.json.
**Evidence:** `evidence/2026-07-31-surface-stiffness-probe/` (CSVs + log +
`reproduce.sh`; deterministic, byte-identical rerun).

---

## Verdict in one paragraph

Surface geometry CAN be represented in the solve — PR 252's linearity carries to
every candidate mechanism, nothing structural blocks either route — but **neither
Route A (homogenize into boundary voxels) nor Route B (explicit embedded bars)
passes the stated accuracy bars for the DIAGRID SKIN, and the measured reason
changes what should be built.** Strut-resolved truth on a real-generator plate
shows the skin's stiffness contribution is dominated NOT by the skin's own
material (a Voigt bound on its printed union volume explains ≲25% of the
in-plane delta) but by **reconnection of the clipped boundary cells**: the
boundary clip severs interior struts a radius short of every face, and the skin
restores their load path. That effect is structural and non-local; no local
volumetric smear can carry it, and explicit skin bars recover only part of it
(the K2b control on a density-corrected base pins the residual). The **solid
shell is the opposite story and falls out almost for free**: an anisotropic
membrane smear predicts the shell's in-plane contribution within **±5%**
(measured), because a continuous wall's value IS its material. The recommended
route is therefore neither A nor B as posed, but **boundary-cell effective
tensors**: measure homogenized tensors for CLIPPED cells under each finish
(bare / skin / shell) the way PR 198 measured periodic cells, and feed them
through the per-voxel tensor mechanism the solver already carries. That needs a
measurement campaign that does not exist yet — specified below (§K6) with row
counts anchored to PR 255's adequacy cliff — and a tetragonal per-voxel
extension of the solve (6 constants + axis tag; same linearity, ~6 fixed blocks
instead of 3). **BLOCKED-STOP taken on gate work:** do not write skin-credit
gate code against any smear or bar model at these error levels.

---

## The fixture (all comparisons share it)

A 24×24×4 mm plate of octet lattice, cell 4 mm (6×6×1 cells), boundary = the
plate box (analytic faces — the PR 250 diagrid, freeform disarmed), uniform
strut radius r = 0.4583 mm chosen so `octet_relative_density` = 0.2597 (PR 253's
working density), PLA E=3500/ν=0.33, skin clamp `lattice_skin_min_radius_mm(0.8)`
= 0.6 mm. The REAL generator emits the geometry (observer tap): 672 interior
struts → 1,356 base elements (struts + node balls + anchor balls), **1,972
diagrid skin struts + 104 rim elements** from 624 landings; graded variant
r(x) = 0.4→0.9 mm across the plate (2,229 skin elements, skin radius genuinely
varying 0.6→0.9 mm).

Six grip states, stiffness K = 2U/δ² under rigid prescribed-displacement grips
(identical for every model, fine and coarse): S1/S2 in-plane tension x/y,
S3 in-plane shear, S4 through-thickness compression, S5 cantilever tip-z
bending, S6 transverse shear zx. In-plane/bending states use a 2 mm volumetric
clamp band — a zero-thickness plane grip's contact with the base VANISHES as
h→0 because the clip erodes all struts a radius from the grip faces (measured:
plane-gripped base K fell 1888→1826→1636 across the ladder with no floor in
sight; the clamp restores a geometrically fixed grip — residual drift reported
under K1. The first probe round was re-fixtured for exactly this). Through-thickness states keep plane grips (platen-on-skin contact IS the
question there) and carry their slower convergence as stated uncertainty.

**Bars stated before measurement** (printed by the probe before any solve):
BAR-T total K within ±10% of reference every state; BAR-D skin delta within
±25% where the delta ≥5% of base; BAR-C no over-credit beyond +10%.

## K1 — strut-resolved reference truth

Every generator-emitted element rasterized as a capsule (centre-in test) into a
fine voxel grid, solved with the PRODUCTION solver (`fea_solve_mgcg_matfree`,
graded per-voxel modulus, tol 1e-8; multigrid engages on the mid-ladder solves,
the large rungs fall back to the exact Jacobi path — same answer either way),
energy accumulated element-by-element. Resolution ladder h = 0.5 / 0.25 / 0.2 /
1/6 mm for base and skin configs (r/h = 2.75 at the reference rung); graded and
shell configs at h = 0.25. Reference = h = 1/6 (uniform), h = 0.25
(graded/shell). (`k1_reference.csv`)

Measured states (h = 1/6, N/mm): base 2084 / 2084 / 639 / 79,339 / 42.2 /
31,666; +skin **8468 / 8468 / 2501 / 236,543 / 344.5 / 78,204** — the skin
multiplies the plate's stiffness **4.1× in tension, 3.9× in in-plane shear,
8.2× in bending, 3.0× through thickness**. S1==S2 to 12 digits (the diagrid's
two diagonal families + rings are symmetric on this plate — measured, not
assumed). Last-rung ladder drift (0.2 → 1/6): the thin-strut base still
converges from above on three states (S1 −9.6%, S4 −10.6%, S5 −10.1%; S3/S6
≤1%) — blocky voxelization of r/h≈2.3 struts over-connects at coarse h — while
the denser skin config drifts ≤6.1%. The skin DELTA is skin-dominated, so its
reference uncertainty is of order ≤10% — an order under the route errors
measured against it. The plane-gripped platen states carry the drift caveat
explicitly (S4 base −10.6% / skin −6.8%).

Two structural facts the raster surfaces:

* **The strut-resolved base solid fraction is 0.374, not the labelled 0.26.**
  The generator meshes the FULL octet (legs + octahedral braces + node/anchor
  balls); the tensor library's "octet" rows are legs-only geometry (the
  labelling gap carried since PR 219, first QUANTIFIED at strut resolution
  here). Consequence measured in K2: the shipped composite posture (library
  tensor at the labelled rho) is **−42…−51% soft** against strut truth on five
  of six states (and +9% stiff on clamped bending).
* **The diagrid skin is not a sparse net at this landing density.** 624
  landings at ~1.6 mm spacing with 1.2 mm tubes: the per-chord (soup) volume is
  3,740 mm³ against a printed UNION of 1,220 mm³ (ratio 0.33 — the tubes
  overlap threefold; graded: 5,764 vs 1,578, ratio 0.27). Any volumetric route
  must union-correct or it injects ~3× phantom material (the probe corrects
  Route A per voxel from a skin-only raster and reports both bases).

## K2 — Route A (homogenize into boundary voxels): FAILS the bars, for a reason

Three representability tiers, all union-corrected, all on the certification-
scale 1 mm coarse grid (`k2_k3_routes.csv`): **A-iso** (isotropic
volume-fraction smear — what a scalar modulus bump could express), **A-cubic**
(Frobenius-closest cubic add — what `lat_c11/c12/c44` could express today),
**A-aniso** (full anisotropic rod-Voigt smear, engineering-shear-consistent
rank-1 per chord — needs a general per-voxel D; PR 252's linearity extends
verbatim, 21 fixed blocks).

Skin-delta errors vs reference (errD, per state S1/S3/S4/S5/S6):

| variant | S1 | S3 | S4 | S5 bend | S6 |
|---|---|---|---|---|---|
| A-iso | +35% | +22% | **+67%** | +36% | +47% |
| A-cubic | −82% | −80% | −80% | −79% | −82% |
| A-aniso | −77% | −57% | −95% | −70% | −92% |

* The PREDICTED anisotropy failure is real and measured: the isotropic smear
  **over-credits the through-thickness states** (+67% S4, +47% S6 deltas) —
  BAR-C violations in the dangerous direction — because an isotropic tensor
  cannot express "stiff in-plane, soft through-thickness". A cubic tensor
  cannot either (axis-symmetric by construction): the cubic projection of a
  z-face membrane spreads its in-plane stiffness onto ALL three axes (pinned
  analytically in the unit test) and lands −80% everywhere.
* The DECISIVE finding is A-aniso: it is a Voigt (affine, upper-bound) smear of
  the union-corrected printed skin volume, and it still under-credits the
  in-plane delta by 77%. **The skin's own layer stiffness explains ≲25% of the
  measured contribution.** The rest is the skin RECONNECTING the clipped
  boundary cells — restoring load paths the boundary clip severed. That effect
  lives in the base's boundary cells, not in any surface layer a smear could
  represent: Route A is not inaccurate, it is answering the wrong question.

## K2b — the control that pins it

Rebuild the coarse base at the MEASURED strut-resolved density (rho 0.389 from
the h=0.25 base raster, removing the labelling gap) and re-test A-aniso and B
on the honest base (`k2b_corrected_base.csv`). The base error collapses on the
membrane-dominated states — +12.5% (S1), +5.4% (S3), +2.9% (S4), −14.2% (S6) —
**and flips to +115% on bending**: with an honest density the periodic tensor
OVER-credits the clipped boundary cells' bending stiffness (the shipped
posture's two errors — legs-only labelling under-credit and periodic-tensor
over-credit at severed cells — partially cancel today; E8's finish-blind
"identical margins" hid both). The routes' in-plane delta under-credit barely
moves on the honest base: A-aniso **−74.9%** (was −76.8%), B −25.7% (was
−34.8%, and still +50% over on shear). The under-credit that survives an
honest base is the reconnection term, not a base artifact.

## K3 — Route B (explicit embedded bars): measured + the disruption answer

Each skin chord an axial bar (EA = Es·πr², the pin-jointed net model), endpoints
embedded in their coarse hexes by trilinear weights: K += Wᵀk_barW — **zero new
DOFs**, rank-1 PSD adds. Measured (soup EA / union-scaled EA deltas): in-plane
−35/−74% (S1), +38/−49% (S3), bending −39/−71%, through-thickness −93/−96%.
Route B sees part of the reconnection (its bars tie INTO the continuum at the
anchor points — S1 improves from −77% (A-aniso) to −35%) but the coarse
continuum it ties into carries the periodic tensor, which never modelled the
severed cells; the overlap ambiguity (soup EA over-credits S3 by +38%, union
EA under-credits everything) has no principled resolution at the bar level.
Through-thickness it is structurally blind (−93%): axial bars lying in a
surface have no membrane-normal stiffness — correctly conservative, far outside
BAR-D.

**The disruption answer PR 252 asked for (decisive property): linearity in D is
PRESERVED by every mechanism tested.** A bar's Ke = (EA/L)·(fixed geometric
block) — a scalar times a fixed block, the same property the cubic
decomposition leans on; a general per-voxel D is 21 coefficients × 21 fixed
blocks; a tetragonal one 6 × 6. Consequences, had a route passed:
matrix-free = a second element list (bar apply y += g(gᵀx), ~30k bars ≈ 7 MB
and negligible flops at the cylinder-E2E scale; deterministic by the
generator's own fixed emission order); Galerkin coarse = + Σ(Pᵀg)(Pᵀg)ᵀ,
rank-1 per bar; GenEO `build_local` = the same ~10-line extension shape PR 252
named; recycling operator-agnostic (proven there). For CERTIFICATION-ONLY
crediting nothing matrix-free is needed at all — the assembled
`fea_solve_cg_lattice` path would take bar triplets trivially. The blocker is
accuracy, not machinery.

## K4 — grading

Both routes CARRY a varying skin radius mechanically (the smear and the bars
read each chord's own r from the observer; the graded fixture's skin radius
genuinely varies 0.6→0.9 mm) — but accuracy stays failed and the overlap
ambiguity WORSENS with radius: graded route B (soup) over-credits in-plane
deltas up to **+96%** (S2) while A-aniso under-credits −55…−96%
(`k4_grading.csv`). Grading is no obstacle for the RECOMMENDED route: a
boundary-cell tensor table keys on the local (rho, r_skin) exactly as the
shipped grading law keys tensors on per-voxel rho — r_skin becomes one more
table dimension (§K6).

## K5 — the shell: it (mostly) falls out, and that doubles the value

Same machinery pointed at the solid shell (0.8 mm wall band — the printed
two-wall skin of the exported mesh; the exported "shell" is the closed MC
surface, its printed thickness set by line width × loops): fine truth vs
membrane smear (`k5_shell.csv`), deltas:

| state | errD A-iso | errD A-aniso (membrane) |
|---|---|---|
| S1/S2 tension | +3.6% | **+2.2%** |
| S3 shear | −2.7% | **−4.6%** |
| S4 compress z | −33% | −67% |
| S5 bend | −25% | −38% |
| S6 shear zx | −31% | −79% |

**In-plane, the shell's contribution is predicted within ±5%** — inside BAR-D
with margin and nearly inside BAR-T. The volume comparison makes the contrast
stark: the shell band is ~1,100 mm³, the skin union a COMPARABLE 1,220 mm³ —
yet the same smear machinery predicts one within ±5% and misses the other by
4×. A continuous aligned wall's value IS its material; the criss-crossed
overlapping net's value is mostly what it reconnects. Bending under-credits (the smear
loses the wall's exact surface position inside a 1 mm voxel — a knowable,
conservative geometric bias); through-thickness under-credits conservatively.
So: the gate has never credited the shell either, and HALF of that credit (the
membrane half) is already representable today at measured ±5% — via a
boundary-voxel tensor add, which is exactly the shape of the recommended route.
Under boundary-cell tensors (§K6) the shell is just another finish column of
the same table, bending arm included.

## K6 — recommendation, cost, and the error bar

**Recommend: NEITHER route as posed. Build boundary-cell effective tensors —
"Route C" — and stop before gate code until the table exists.**

* **What it is:** the homogenization unit for a boundary voxel is not the
  periodic cell (what the posture uses today, everywhere) but the CLIPPED cell
  + its finish: the cell cut by the surface at a given depth, with (a) nothing,
  (b) the diagrid skin at radius r_s, (c) the solid shell at thickness t on the
  cut face. Measure its effective tensor with PR 198's machinery (the offline
  homogenization probe, pointed at cut cells with the finish geometry
  included). The result keys on (rho, cut depth, finish, r_skin) and yields a
  TETRAGONAL tensor (the cut normal is a distinguished axis — 6 constants
  C11,C12,C13,C33,C44,C66 + an axis tag, exactly the symmetry class core
  already refuses for bccz/fccz because a CUBIC slot cannot hold it).
* **Why it can work where A/B cannot:** it puts the reconnection physics INSIDE
  the measured tensor — the bare-cut column measures the severed cell honestly
  (today's posture over-credits it with the periodic tensor), and the
  skin/shell columns measure the finish's true composite value including
  reconnection. It is local data measured from non-local truth, the same move
  the periodic library already made for the interior.
* **Solver cost:** the per-voxel tetragonal extension of PR 252's result — Ke =
  Σ₆ cᵢKᵢ per axis (the blocks are fixed per axis tag; the decomposition
  argument is verbatim). Assembled cert path: a second `hex8_stiffness_*`
  variant + wider lat arrays. Matrix-free (only needed if the optimizer ever
  carries it): 6 blocks instead of 3, boundary voxels only (~N^(2/3) of the
  grid). No new element type, no coupling scheme, no DOF change — the
  machinery this codebase has already proven.
* **The measurement campaign (the BLOCKED-STOP output):** axis-aligned face
  cuts first (the voxel base is axis-aligned; edge/corner cells Phase 2).
  Dimensions: 8 rho rows (PR 255's G4: 8 adequate, 5 a sharp failure — and
  certification-only use still wants ≥6) × 6 cut depths (0.1…0.9 of a cell) ×
  4 finish columns (bare, skin@r_s1, skin@r_s2, shell@t) ≈ **192 homogenization
  runs** of PR 198 scale, offline, one sitting. Validation instrument: THIS
  probe's harness (strut-resolved plate + grip states) re-run against the
  table's prediction — the accept bar for the campaign should be the bars
  stated here (±10% total / ±25% delta / no over-credit).
* **The error bar the maintainer would certify against** (if the campaign
  passes its bars): the table's own fit error (target ≤5%, PR 255 achieved
  ≤3.1% row error on 7 topologies) stacked on the library's ±10% resolution
  caveat and this probe's reference-ladder drift (≤10%) — i.e.
  **a ±10–15% posture, same class as today's interior caveat**. At the
  measured route-A/B error levels (−35…−95% deltas, +38…+96% over-credits),
  certifying the skin finish would have been a fiction; that is the probe's
  central protective finding.
* **Also fix the labelling gap:** −44% base error against strut truth is the
  dominant single error in the composite posture on this fixture and is
  independent of any finish question. The full-octet vs legs-only discrepancy
  (0.374 measured vs 0.26 labelled) deserves its own row-relabel or
  full-octet re-measurement before boundary-cell columns are added on top.

## K7 — determinism + no production changes

* **Byte-identical rerun:** the full probe run twice into fresh directories —
  **all five CSVs byte-identical** (`k1_reference.csv`, `k2_k3_routes.csv`,
  `k2b_corrected_base.csv`, `k4_grading.csv`, `k5_shell.csv`; `reproduce.sh`
  performs the same comparison). No RNG, no threads in the harness
  accumulations; the production solver paths are the bit-identical kernels.
* **Full ctest green:** **82/82** (81 pre-existing + the new
  `surface_stiffness_model` pinning test: production-integrator bit-identity
  for cubic and isotropic D, rod-smear analytic pins, embedded-bar == analytic
  pin-jointed bar, harness assembled energy == production `fea_solve` energy at
  1e-10, rasterizer determinism).
* **Stash-rebuild:** fresh builds with and without the probe's tree — all 37
  member objects of `libtopopt.a` byte-identical (`k7_stash_rebuild.txt`);
  archive-level sha differs only by ar timestamp metadata.

## Files

* `core/tests/harness/surface_stiffness_model.hpp` — general-D integrator (exact
  copy discipline of matfree_cubic_probe, pinned bit-for-bit), D6
  builders/projections, capsule rasterizer, rod-Voigt smear, trilinear
  embedding, embedded-bar coupling, coarse assembled solver. Harness-only.
* `core/tests/harness/surface_stiffness_probe.cpp` — fixture, K1 ladder, K2/K2b
  routes, K3 bars, K4 grading, K5 shell; CSVs + log.
* `core/tests/unit/test_surface_stiffness_model.cpp` — the pinning unit test
  (registered in `core/CMakeLists.txt`, Eigen-gated like assembly.cpp).
* `evidence/2026-07-31-surface-stiffness-probe/` — `k1_reference.csv`,
  `k2_k3_routes.csv`, `k2b_corrected_base.csv`, `k4_grading.csv`,
  `k5_shell.csv`, `k7_stash_rebuild.txt`, `probe_all.log`, `reproduce.sh`.

## Honest caveats

* The fixture is a THIN part (one cell thick): every cell is a boundary cell,
  so the reconnection term is at its maximum. On a thick part the boundary-cell
  fraction shrinks and Route A/B errors would dilute toward the interior — but
  the certification question is precisely the boundary, and PR 253's `skin`
  finish exists for thin, see-through parts.
* The reference is voxel-rasterized (centre-in capsules), not a conforming
  mesh, and thin struts converge slowly: last-rung drift is ≤10% on the
  clamped states (S3 ≤1%, S1/S5 ≈−10%) and S4 −10.6% base / −6.8% skin on the
  plane-gripped platen states. Route errors are read against that uncertainty
  — their signs and magnitudes sit an order beyond it.
* The coarse grid is 1 mm (certification scale). A coarser cell-scale grid
  would change the smear's dilution volumes; the conclusions about anisotropy
  representability and reconnection are grid-independent (they are properties
  of the truth, not the smear).
* Route B was tested as axial bars (the pin-jointed net model). Frame elements
  with bending would add stiffness but cannot repair the through-thickness
  blindness or the overlap ambiguity, and would ADD coupling complexity — the
  probe's conclusion does not hinge on it.
* The K5 shell smear samples the exact 0.8 mm band; a production shell credit
  must read the printed wall thickness from the print params (line width ×
  loops — already plumbed per handoff `wall-loops`/`line-width`).

---

## Plain language: what this probe found and what it means

The see-through lattice finish is refused a safety certificate today because
the solver literally has no way to describe a surface: it thinks in little
cubes of material, and the woven net (and the solid wall) live ON the surface
between the cubes. This probe built the ground truth — a small plate with its
real woven net, simulated bar by bar — and then tested the two obvious ways of
teaching the solver about surfaces: smearing the net's stiffness into the
outermost cubes, or adding each thread as an explicit little spring.

Both failed, and the failure taught us something more valuable than a pass.
The net's threads themselves turn out to explain only about a quarter of the
stiffness the net adds. The rest comes from something subtler: when the
lattice is trimmed to fit the part's shape, thousands of its bars are cut
short of the surface and left dangling; the net TIES THOSE CUT ENDS BACK
TOGETHER. Most of the net's value is repair, not reinforcement — and no amount
of smearing material into cubes can describe a repair. We also confirmed the
suspected trap: the crude smear makes the surface look equally stiff in every
direction, over-crediting the direction through the plate by up to two-thirds
— exactly the kind of error a safety check must never make.

Two genuinely good findings came out. First, the solid outer wall — which the
certificate has also never credited — IS predictable the simple way: its
in-plane stiffness lands within five percent, because a continuous wall's value
really is its material. Second, we measured for the first time that the
solver's picture of the lattice interior is about 44% too soft, because the
stiffness tables were measured on a simpler lattice than the one the printer
actually builds — a bookkeeping gap worth fixing on its own.

The way forward is clear and honest: measure a small new table — "what is a
CUT-OFF lattice cube worth: bare, with the net, with the wall" — using the
same offline measuring rig that built the existing lattice tables (about 200
runs, one sitting), and feed those numbers through the per-cube stiffness
machinery the solver already has. This probe's plate rig is the ready-made
validation bench for that table. Until that table exists, nobody should write
certificate code that credits the net — the numbers measured here say it would
be off by half or more, sometimes in the unsafe direction.
