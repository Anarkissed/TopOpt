# reference-implementation-bakeoff — somebody else's software makes your part 43-53% smoother where it has never moved before, and it is not a blur. It is also 25x slower per iteration and it lets go of your CAD faces.

**Slug:** `reference-implementation-bakeoff` · **Branch:** `claude/reference-impl-bakeoff-6cc834`
**Evidence:** `evidence/2026-08-09-reference-implementation-bakeoff/`
**Changes:** three test harnesses and their CMake targets. **No production file changed** — see R1.
**Required reading it builds on:** PR 299 (Taubin NO-GO), 303 (SDF/RBF), 306 (the sphere bake-off), 307 (CAD projection + the classifier), 314 (MCF), 315 (closing + the field), 319 (SEMDOT — **not yet merged**, and this task's baseline comes from it).

---

# 0. WHAT CHANGES FOR YOU

Nothing ships. Two third-party programs were built on your Mac, run on your part
and measured with our instruments, and one of them moved a number that five of
our own attempts could not.

## ★ A LEVEL-SET REPRESENTATION OF YOUR OWN DESIGN IS 43-53% SMOOTHER ON THE CUT SURFACE. That number has never gone the right way before.

Six things have now been measured on the optimizer-cut population of your part.
Five of them are ours. This is the sixth, and it is the first that wins:

★ EACH ROW NAMES ITS OWN METRIC, because they are not all the same one and
stacking them into a single column would be the kind of quiet mismatch §S1.3 is
about. Only the last two rows and SEMDOT's are the SAME column —
`dihedral_cut_deg`, rung 068 — and those three are directly comparable.

| | what it did, in its own terms |
|---|---|
| Taubin (PR 299) | 23.4% of the CAD-population stair-step AMPLITUDE at its strongest setting; whole-mesh dihedral 8.36° → 8.09°, i.e. barely |
| SDF/RBF (PR 303) | QUALIFIED — 21.5% of that same amplitude, against Taubin-best 23.4% |
| mean-curvature flow (PR 314) | **ROUGHER** on his part at every setting |
| morphological closing (PR 315) | reaches **3.17%** of his cut surface at one whole voxel; removes **0.0%** |
| SEMDOT (PR 319) | cut-population dihedral **7.5521° → 20.0126°, 165% ROUGHER** |
| **GridapTopOpt's level set (here)** | cut-population dihedral **7.5521° → 4.0156°, 46.8% SMOOTHER** |

All four rungs, on your grid, measured by PR 299/306/307's own instruments —
included, not retyped, and the SIMP rows in this task's table are byte-equal to
PR 319's committed ones across 96 fields (R2).

| rung | roughness, CUT (deg) | | | stair-step, CAD (mm) | | |
|---|---|---|---|---|---|---|
| | SIMP | level set | | SIMP | level set | |
| 0.68 | 7.5521 | **4.0156** | **+46.8%** | 0.4293 | 0.7080 | −64.9% |
| 0.52 | 9.6338 | **4.4942** | **+53.3%** | 0.4507 | 0.7282 | −61.6% |
| 0.38 | 10.4580 | **5.8108** | **+44.4%** | 0.4394 | 0.7386 | −68.1% |
| 0.26 | 10.2657 | **5.8574** | **+42.9%** | 0.4375 | 0.7638 | −74.6% |

## ★ AND IT IS NOT A BLUR. That is the control that makes this worth your time.

Every previous win on this project has died on a control. The obvious way this
one could have been fake: their ersatz interpolation ramps the material over
`η = 2·(voxel)`, which is a **four-voxel-wide smoothing kernel**, and anything
smoothed is smoother. So η was swept.

| ersatz bandwidth η | roughness, CUT, rung 068 | vs SIMP |
|---|---|---|
| 2.0 voxels (**their default**) | 4.0156° | +46.8% |
| 1.0 voxel | 4.0616° | +46.2% |
| **0.5 voxel** — no blur left | **4.1476°** | **+45.1%** |

**The win survives at a half-voxel ramp.** It is the representation, not the
smoothing. And the mechanism reads correctly: the sub-voxel content in the field
goes from SIMP's 0.1297 mm to 0.5790 mm, and — this is the part PR 319 said was
necessary and SEMDOT could not deliver — it is **spatially coherent**, because a
signed distance function's neighbouring values are related by construction. Only
**2.35% to 7.20%** of the marching-cubes crossings land on an edge midpoint
across the four rungs, against SIMP's **85.28%** at rung 068 and 99.96-99.99% on
the other three. A crossing at the edge midpoint IS a staircase: SIMP's field
puts nearly all of them there, and the level set puts almost none.

The volume control passes too: the smoother arms are 3.6-6.6% lighter, not
melted, and their min-feature violation count is **lower** than SIMP's (4547 vs
5619 at rung 068).

## ★ WHAT IT COSTS, AND THE FIRST ONE IS THE REAL PROBLEM.

**1. It lets go of your CAD faces.** The stair-step amplitude on the CAD
population is 62-75% WORSE on every level-set arm, and 1.9-2.6% of the part's
volume ends up OUTSIDE the imported part envelope. Nothing in a level-set method
holds a boundary onto an imported face — the reinitialiser is free to move it,
and it does. ★ **You already own the fix for this**: PR 307's CAD-face
projection is exactly the operator that puts those vertices back, and §S4c is
about spending it here.

**2. It is 25x slower per iteration.** Measured, not guessed: 277.7 s per
augmented-Lagrangian iteration on your 1,473,696-DOF grid against SIMP's 11.2 s.
Your four rungs took 1 h 23 m. From a cold start GridapTopOpt would need hundreds
of iterations per rung — **21 to 77 hours for one rung**. It builds in four
minutes and runs perfectly well; what it cannot do on your Mac is finish your
ladder. That is a BLOCKED-STOP and it is reported as one.

**3. Nothing it produces is certified.** It minimises compliance under a volume
constraint. It has no stress functional, no knockdown, no accept gate. Every
level-set row in the table has an empty margin column and the probe prints "NOT
CERTIFIED BY CORE" rather than a zero.

## ★ PICOGK IS THE EASY ONE, AND IT IS BETTER THAN EXPECTED.

Installed and building in **165 seconds** (and 99 s of that was optional — it
ships a prebuilt arm64 dylib). A graded lattice on your rung-068 design, with
strut thickness driven by your own field, is **twenty lines of new code** and
runs in **18 to 63 seconds**.

* **The grading is continuous by construction.** `IBeamThickness` is one method
  taking a POINT, and `AddBeam` tapers between end radii. There is no per-cell
  quantisation in the path, so **PR 302's cell-size seam does not arise for
  thickness grading at all**.
* **But your field cannot ask it to grade.** Driven by your density field the
  thickness still steps by 19-23% of its range across 0.1 mm, because that field
  is binary (PR 315). This is PR 315's finding arriving from the lattice side:
  the tool can grade; the field has nothing to grade with.
* **The file-size answer is real.** At a lattice pitch of 0.20 mm, one rung is
  26,276,120 triangles — which agrees with your four variants' 102,972,348
  (25.7 M each), so nobody is making that number smaller. What changes is that
  **PicoGK never has to write them**: 182.3 MB of VDB against 1252.9 MB of STL,
  **6.9x**, and the VDB is the live form every boolean operates on. Your ~5.1 GB
  of triangles becomes ~0.75 GB.
* **It does no FEA and the certificate cannot move to it** — §S3.d.

## THE SMALLEST USEFUL STEP, WHICH IS NOT ADOPTION

**Convert your converged SIMP rung to a signed distance field, then project the
CAD population back onto the CAD.** That is what the winning row in the table
already is, minus the projection you already own. It needs no optimiser change,
no certification change, no Julia: an exact Euclidean distance transform is ~40
lines and ran in 0.02 s on your grid. The measured split says roughly 60% of the
smoothness win is the distance representation itself and 40% is GridapTopOpt's
reinitialiser — so **most of it is available without adopting anything**. §S4c.

---

# S1 — HIS PROBLEM, IN A PORTABLE FORM

`core/tests/harness/portable_problem_export.cpp` calls
`build_production_loadcase` — the production builder `topopt-cli run` and the
iPad bridge both call — and writes what it returns. The voxel tags, the clamped
DOFs and the nodal loads that cross to Julia are core's own, not a re-derivation
of them from the STEP. Re-deriving the boundary conditions would have put a
silent difference exactly where the comparison lives, which is the failure this
whole task exists to break.

## S1.1 The positive control

Eleven scalars of his job document are transcribed by hand (the
job.json → `ProductionLoadCase` mapping lives inside `run_job.cpp`'s translation
unit). A transcription is checked, not trusted — the counts
`build_production_loadcase` produces are compared against the counts the RUN OF
RECORD wrote into its own `loadcase.json`:

| | run of record | this export | |
|---|---|---|---|
| anchor_bc_dofs | 21000 | 21000 | MATCH |
| external_load_nodes | 7382 | 7382 | MATCH |
| declared force | 22.24113464 N | 22.24113464 N | MATCH |
| group 0 voxels tagged | 5165 | 5165 | MATCH |
| solved_grid_dofs | 1473696 | 1473696 | MATCH |
| resolution / min_feature_mm / margin_stop | 128 / 2.5 / 1.5 | 128 / 2.5 / 1.5 | MATCH |

Full text in `s1_positive_control.txt`. Grid 128 × 31 × 118, spacing
1.7052793026343613 mm; 110,904 solid voxels; **70,688 Active, 40,216
FrozenSolid, 357,320 FrozenVoid** — 36% of his part is frozen, which turns out
to matter a great deal (§S1.2 item 7).

## S1.2 ★ WHAT DOES NOT SURVIVE THE CROSSING

Ten differences, in `s1_fidelity_losses.txt` at full length. Three are
STRUCTURAL — no work on the driver script removes them:

1. **The part exterior cannot be dropped from the FEA.** core gives Empty voxels
   no element. A level-set method on a Cartesian background must keep an ersatz
   material over the whole box, so 76.31% of the box carries ϵ = 1e-3 of PLA.
3. **`min_feature_mm` 2.5 has no counterpart.** Their two length scales (the
   interpolation bandwidth η and the Hilbertian extension radius α) regularise
   the integrand and the velocity; neither bounds a member's thickness. The
   arm's min-feature count is therefore MEASURED, not constrained.
7. **The frozen-solid set is held by a different mechanism.** core pins 40,216
   densities to 1. GridapTopOpt has no design-variable mask; the nearest idiom is
   a zero Dirichlet on the velocity extension. It is exact in the pad interior —
   **99.75% held at full resolution** — and inexact at the pad boundary.

And the ones that are choices rather than walls: the load is a statically
equivalent body force over the same 5,165 voxels rather than core's consistent
nodal traction over their exposed faces (7,382 nodes); `margin_stop`, the
interlayer knockdown and the grading law do not cross because the certification
does not; the hole seeding has no counterpart in his run.

## S1.3 ★ THREE PLACES THE BRIEF AND THE RECORD DISAGREE

Full text in `s1_premise_corrections.txt`. The one that changes a number:

**`0.4293 mm` is the CAD population's amplitude, not the cut surface's.** The
brief quotes "0.4293 mm amplitude and 7.55 deg rms dihedral on the cut surface";
those are two different columns of PR 319's table. `obl_cad_rms_mm` = 0.429291
(CAD), `obl_cut_rms_mm` = 3.745211 (cut), `dihedral_cut_deg` = 7.552074 (cut).
The cut surface's own amplitude is **8.7x larger** than the figure quoted for it.
This is deliberate in PR 319 and PR 314 says why: the cut population has no
ground truth, so its distance-to-CAD is a fact about the part's shape and not an
error. Both columns are reported for every arm here.

Also: the brief's fingerprint `d9fe8f768331` / 33.36 N is a capture with **no
`design.bin`** — no surface can be extracted from it and no row in any table
stands on it. Every measured row in this lineage is the 22.24 N document, which
is what this task uses. And the iteration counts are 27/**127**/140/**153**, and
the four rungs took **1 h 23 m 08 s**, not 1 h 07 m.

---

# S2 — GridapTopOpt.jl

## S2.1 ★ APPLE SILICON IS NOT THE PROBLEM. It builds in 237 seconds.

The documented risk (JuliaParallel/PETSc.jl#184) does not apply: GridapPETSc
consumes `PETSc_jll`, whose arm64 macOS artifact is prebuilt. Nothing compiled
PETSc. `Pkg.instantiate()` 229.6 s, the 13 direct dependencies 5.6 s, and the
smoke test comes back with MPICH 5.0.1 built `--host=aarch64-apple-darwin20` and
`PETSC_INIT=OK`. `s2_build_and_install.txt`.

## S2.2 The driver, and the one thing it deliberately does not do

`his_part_ALM.jl` is their `3d_elastic_compliance_ALM.jl` with the domain, the
boundary conditions and two mask factors changed. ★ **No analytic shape
derivative is supplied.** The masks change the weak forms; a hand-written `dJ`
would then have to be re-derived to match, and a wrong re-derivation is exactly
the failure this task exists to rule out. `PDEConstrainedFunctionals` falls back
to automatic differentiation, so every sensitivity is theirs.

The part mask is on the STIFFNESS and it has to be: without it the optimiser
grows structure outside his part and collects full modulus for it — 8.4% of the
part's volume by iteration 20 of a coarse run, still climbing.

## S2.3 ★ THREE THINGS IN THE LIBRARY BROKE AT HIS SIZE

At full length in `r5_what_could_not_be_done.txt`. In short:

* **`update_labels!` is O(n²) in marked vertices** and does not return when
  396,797 of his 491,232 nodes are marked. Replaced with a vertex-only
  `tag_vertices!`, and the replacement is PROVED equivalent — same free dofs,
  same Dirichlet dofs, **same free-dof-to-node maps**, 134x faster at coarsen 4
  (`s2_labelling_control.txt`).
* **Two overlapping `update_labels!` calls silently erase each other.** Every
  anchor node is also a pinned node, so tagging anchor-then-pinned left
  `Gamma_D` with **zero** clamped DOFs and the run solved an unclamped structure
  without complaining.
* **Their reinitialiser returns NaN, and `H_η` swallows it** — its three
  branches are `t<-η`, `|t|≤η`, `t>η`, NaN matches none, so it returns `nothing`
  and the run dies in Gridap's assembler with nothing pointing at the level set.
  Measured on his part: a 6-neighbour BFS distance over the whole part gives
  **6767 NaN nodes**; an exact Euclidean distance transform gives **0**. The
  cause is ours as much as theirs — an L1 distance's gradient is wrong by up to
  73% on diagonals, and a first-order upwind eikonal solver assumes |∇φ| ≈ 1.

Also: `initial_lsf(ξ,a)`'s holes repeat with period 2/ξ **in model units**. Their
examples run on a 2×1×1 domain; on his 218 mm part ξ=4 is a 0.5 mm period,
aliased four times finer than his voxel, and the reinitialiser collapses it to
all-solid.

## S2.4 ★ THE COST, MEASURED

| arm | rung | iterations | wall (s) | s / iteration | converged |
|---|---|---|---|---|---|
| SIMP | all four | 447 | 4988.4 | **11.16** | yes |
| GridapTopOpt, from scratch | 0.68 | 3 | 1110.9 | **277.73** | **NO** |

**24.9x more wall per iteration** on the same grid, the same DOF count, the same
machine. The matrix is 1,452,696² with 113,893,146 nonzeros; PETSc GAMG takes
57-65 CG iterations for the primal and adjoint, plus a Hilbertian extension
solve, plus reinitialisation, per ALM iteration. At iteration 3 the volume
constraint was at 0.309 and moving by ~0.003 per iteration.

`s2_cost.csv`, `s2_from_scratch_timing.log`. What was NOT tried and would be
tried first: MPI (their headline script is the MPI one; this ran serial),
loosening their `-ksp_rtol 1.0e-12`, and reusing the GAMG hierarchy. None of them
changes the order of magnitude and none was measured, so none is claimed.

## S2.5 ★ THE MEASUREMENT THAT FITS THE BUDGET, AND WHY IT IS THE RIGHT ONE

Four converged rungs from a cold start do not fit in a day. Rather than report
four unconverged designs at the wrong volume fraction — where a surface
comparison means nothing — **the four-rung answer in this handoff is a
REPRESENTATION measurement and zero optimiser iterations were run for it.**
Saying that plainly, because the distinction is the whole of §S4a:

* φ₀ is the exact signed distance to HIS converged rung's 0.5 level set.
* GridapTopOpt's own `reinit!` runs ONCE on it (5.3 s).
* The field exported is their own `ρ = 1 − H(φ)` — the relaxed Heaviside their
  volume constraint integrates, with ρ(0) = 0.5 — so the iso, the bandwidth and
  the void convention are all theirs and none of them is a choice of ours.
* That field then goes through **his own shipped extraction**: tricubic ×2,
  marching cubes at 0.5, largest component. Identical to SIMP's path.
* No state solve, no shape derivative, no ALM. `iterations = 0` in every row and
  the compliance column reads NA.

That is not a consolation prize; it is the cleaner experiment. It separates the
two things that were tangled together — does the smoothness come from the
level-set REPRESENTATION or from the level-set OPTIMISATION? — and it is
precisely the question §S4c turns into a recommendation.

★ **WHAT IS STILL MISSING, AND IT IS NAMED RATHER THAN QUIETLY ABSENT.** An arm
where the ALM actually refines that boundary — `run_seq_arm.sh`, five iterations
per rung against his printed fraction — was written and started, and was
**stopped part-way through rung 068 so the core suite could finish** on a
machine it was contending with. So this handoff says nothing about whether
optimising on top of the representation helps or hurts, and the
`GTO-ALM-3iter-UNCONV` row is the only place an optimiser ran at all. The script
is committed as `run_seq_arm.sh`; the cost of running it is ~100 minutes, and it
is the obvious next measurement alongside the CAD projection in §S4c.

## S2.6 THE FULL TABLE, WITH ITS CONTROLS

Amplitude on the CAD population; roughness as rms dihedral on the CUT
population; sub-voxel content as rms |frac − 0.5| on the design lattice, signed
so bigger = more sub-voxel placement.

| arm | rung | amp CAD (mm) | | rough CUT (deg) | | sub-voxel (mm) | |
|---|---|---|---|---|---|---|---|
| SIMP | 0.68 | 0.4293 | — | 7.5521 | — | 0.1297 | — |
| **GTO-SDF** | 0.68 | 0.7080 | −64.9% | **4.0156** | **+46.8%** | 0.5790 | +347% |
| CTRL η=1.0 | 0.68 | 0.7104 | −65.5% | 4.0616 | +46.2% | 0.5834 | +350% |
| CTRL η=0.5 | 0.68 | 0.7269 | −69.3% | 4.1476 | +45.1% | 0.6466 | +399% |
| CTRL EDT, no reinit | 0.68 | 0.7245 | −68.8% | 5.5559 | +26.4% | 0.7441 | +474% |
| CTRL node lattice, ×1 | 0.68 | 0.8426 | −96.3% | 30.0400 | −297.8% | 0.5214 | +302% |
| GTO-ALM, 3 iter, UNCONV | 0.68 | 0.7635 | −77.9% | 11.5102 | −52.4% | 0.4934 | +280% |
| SIMP | 0.26 | 0.4375 | — | 10.2657 | — | 0.0030 | — |
| **GTO-SDF** | 0.26 | 0.7638 | −74.6% | **5.8574** | **+42.9%** | 0.5829 | +19475% |
| CTRL η=1.0 | 0.26 | 0.7598 | −73.7% | 5.8388 | +43.1% | 0.5886 | +19663% |
| CTRL η=0.5 | 0.26 | 0.7710 | −76.2% | 5.7762 | +43.7% | 0.6577 | +21986% |
| CTRL EDT, no reinit | 0.26 | 0.7347 | −67.9% | 7.1172 | +30.7% | 0.7700 | +25755% |

Rungs 0.52 and 0.38 are in `s2_reference_impl_vs_simp.csv` and §0's table.

**What the four controls say.**

* **η sweep** — the win survives at a half-voxel ersatz ramp. It is the
  representation, not a blur. This is the control that makes the headline
  survivable.
* **EDT with no reinitialisation** — an exact signed distance alone gives
  **+26.4%**; their reinitialiser takes it to **+46.8%**. Roughly 60/40. Most of
  the win is available without adopting anything, and the rest is real.
* **node lattice at factor 1** — −298%. The win needs the shipped ×2 tricubic
  extraction: the level set supplies the sub-voxel content, the tricubic renders
  it. Neither alone.
* **from scratch, 3 iterations** — worse than SIMP on both. Unconverged, so it
  is not a verdict on the method; it is in the table so the cost row has a
  geometry beside it.

**The controls PR 299 demands of any roughness claim** — because melting the
part is also smoother: volume 3.6-6.6% below SIMP (not melted), minimum
cross-section identical at 3.411 mm², and min-feature violations **lower** than
SIMP's (4547 vs 5619 at rung 068).

**And the cost, in the same table:** every level-set arm is 62-78% worse on the
CAD population, and 1.9-2.6% of the part's volume sits outside the part
envelope.

---

# S3 — PicoGK

Full text in `s3_graded_lattice.txt`; the headline is in §0. Three things worth
repeating here.

**(a) The install is trivial and Apple Silicon is a non-issue.** 165 s total,
and 99 s of that was an optional from-source build of the runtime — the repo
ships a prebuilt `native/osx-arm64/picogk.26.2.dylib`.

**(b) The maintainers' recipe is literally what the API does.** PicoGK
discussion #29 says to put the simulation field in a `ScalarField` and modulate
the wall thickness from it. `IBeamThickness` is one method taking a `Vector3`;
`Lattice.AddBeam(a, b, rA, rB)` tapers. The whole of the new code is one
twenty-line class. It is not a build task.

**(c) The seam question dissolves for thickness and stays open for cell size.**
Thickness is a continuous function of position with no per-cell quantisation, so
PR 302's seam cannot occur. But LatticeLibrary ships only `RegularCellArray` and
`ConformalCellArray`, and neither grades the cell size spatially — so the
transition between two CELL SIZES could not be measured without writing a new
`ICellArray`, which would make it a build task. Left as one (R5 item 7).

---

# S4 — THE VERDICT

## S4.a Does it actually come out smoother on his part, by our metric, on the cut population?

**YES, by 43-53%, on all four rungs, and the controls hold.** 7.5521° → 4.0156°
at rung 068. It is the first thing in six attempts to move that number the right
way, it is not a blur (η sweep), it is not melting (volume, min-section,
min-feature), and it is the coherent sub-voxel content PR 319 said was necessary
— 2.35-7.20% of crossings at an edge midpoint against SIMP's 85.28% (rung 068)
and 99.96-99.99% (the other three).

**And it is not free: 62-75% worse on the CAD population.** The two answers point
in opposite directions and both are real. What you would ship is a part whose
optimizer-invented surfaces are half as rough and whose imported CAD faces are
two-thirds worse — unless the CAD faces are put back, which is §S4c.

## S4.b What would adoption cost, and what breaks

**The three the brief names, with file and line.**

1. **`analyze_fixed_design`** — `core/include/topopt/analyze.hpp:306`. Its
   signature is `(const VoxelGrid& grid, const SimpParams&, const
   std::vector<double>& density, const std::vector<DirichletBC>&, const
   std::vector<NodalLoad>&, const Material&, ...)`. It takes **a density per
   design voxel**. A level-set design is a nodal φ, and its whole value is the
   sub-voxel boundary position that a per-voxel density cannot hold. Handing it
   `ρ(φ)` cell-averaged — which is what this task's own table does — throws away
   the thing that made the surface smoother before the certificate ever sees it.
   ★ **The certificate would measure a design that is not the one you print.**

2. **`grade_lattice`** — `core/include/topopt/grading.hpp:442`,
   `(grid, density, demand, region, params, iso)` — and the cells-per-member
   floor, `analyze.hpp:179-185` (`lattice_min_cells_per_member`,
   `lattice_strut_out_of_regime`) and `cell_plan.hpp:43,108`. Same shape, same
   problem: a density per voxel.

3. **min-feature and margin.** `min_feature_mm` is enforced by a density filter
   radius and counted on the extracted mesh; a level set has no density to
   filter. `margin_stop` is the ladder's accept gate and rides on (1).

**★ AND THE ANSWER TO PR 319's QUESTION: A LEVEL SET MAKES IT BETTER, NOT WORSE.**
PR 319's §S3 found that smooth and latticed want opposite things from one
per-voxel number and would need two — an occupancy that places the boundary and
a density the lattice is built from. A level-set design gives you exactly that
split for free, and it is the natural shape of the data rather than a second
field bolted on:

* **φ places the boundary.** It is defined everywhere, it is sub-voxel, and it is
  coherent. This is the occupancy.
* **the density stays a density.** Nothing about adopting a level set changes
  what `grade_lattice` wants; it wants a relative density per cell, and under a
  level set the region inside φ<0 is simply solid, with the lattice's relative
  density coming from the demand field as it already does.

So the two numbers stop fighting. What it costs is that `analyze_fixed_design`
and `grade_lattice` would need a second argument — the boundary field — rather
than inferring the boundary from the density they are handed. That is a
signature change on two functions and every call site, not a rewrite of the
certification.

**What adoption of GridapTopOpt itself would cost, separately:** a Julia runtime
and a PETSc/MPI stack on device (it is 237 s to install on a Mac and there is no
iPad story at all), 25x the solve cost per iteration, and no certification. That
is not a near-term proposition and this task does not recommend it.

## S4.c ★ What is the smallest useful step?

**Convert the converged SIMP rung to a signed distance field, extract from THAT,
and project the CAD population back onto the CAD.** Nothing is adopted.

The measurement says why this is the right size of step:

* The `CTRL-EDT-noreinit` row is that step, minus the projection: an exact
  Euclidean distance transform of his own rung, extracted through his own
  pipeline. **+26.4% on the cut population at rung 068, +30.7% at rung 026**, and
  it is ~40 lines that ran in **0.02 s** on his grid (`edt.jl`). No Julia, no
  PETSc, no optimiser change, no certification change.
* Their reinitialiser adds the rest (+26.4% → +46.8%), so there is a second step
  available later if the first one is worth having.
* **The CAD cost is the thing to fix first, and you already own the fix.** PR
  307's `attribute_to_cad_faces` + CAD-face projection is exactly the operator
  that puts the CAD-attributed vertices back on their faces. Every row in this
  table is measured WITHOUT it. Applying it to an SDF-extracted mesh is the
  obvious next measurement and it is cheap.

**Is sequential SIMP → level-set refinement available in GridapTopOpt?**
Yes, in the sense that matters: the optimiser takes φ₀ as an argument and does
not care where it came from, so seeding it from a converged density is a
one-line change (`his_part_ALM.jl`'s `SEED_DENSITY` path). What it costs is
§S2.4's 277.7 s per iteration, which is why this task measured the
representation and not the refinement. The arXiv 2605.04735 / rho2sdf.jl route
the brief names is the same idea; PR 303 already measured that codebase's
extraction, and the number here (+26.4% for the distance transform alone) is
consistent with PR 303's "QUALIFIED".

---

# THE BARS

**R1 — NO PRODUCTION FILE CHANGED.** `r1_no_production_change.txt`:

```bash
git diff main -- core/src core/include app/TopOptKit/Sources
```

prints nothing; `--name-only | wc -l` is 0. Everything this task added is three
`EXCLUDE_FROM_ALL` harness programs and their CMake blocks (+30 lines in
`core/CMakeLists.txt`, which is none of the three protected paths).

**R2 — OUR INSTRUMENTS, INCLUDED NOT RETYPED.**
`external_field_surface_probe.cpp` `#include`s PR 299's `stairstep_metric.hpp`
and PR 306's `surface_instruments.hpp` and calls PR 307's
`attribute_to_cad_faces`. `r2_reproduces_pr319.py` compares this task's SIMP rows
against PR 319's committed CSV: **4 rungs, 24 shared columns, 96 fields, 0
differing.** No number in this handoff came from GridapTopOpt's or PicoGK's own
post-processing.

**R3 — EVERY NUMBER ON HIS PART, ALL FOUR RUNGS.** The `GTO-SDF` arm is all four.
The from-scratch arm is rung 0.68 only and is labelled UNCONVERGED everywhere it
appears; §S2.4 says why and R5 item 1 says what it would take.

**R4 — ITERATIONS AND WALL, SEPARATELY.** `s2_cost.csv`, and §S2.4. Build and
install time is in `s2_build_and_install.txt` (237 s Julia side) and
`s3_graded_lattice.txt` (165 s PicoGK side).

**R5 — WHAT COULD NOT BE DONE.** `r5_what_could_not_be_done.txt`, seven items at
full size, plus one defect of this task's own.

**R6 — NOTHING VENDORED, NOTHING AT THE REPOSITORY ROOT.** Both libraries were
cloned into the session scratch directory outside the repo; commits and licences
in `third_party_commits.txt`.

**R7** — any review response goes in a separate commit.

---

# IN PLAIN WORDS

**Does your part come out smoother when somebody else's software does it?**
Yes — on the surfaces the optimizer invented, by about half, and this is the
first time anything has managed that. The reason is not that their software
polishes better. It is that a level set stores *where the boundary is* as a
number in every cell, so neighbouring bits of surface agree with each other,
whereas a density field on your grid has already collapsed to solid-or-empty and
has nothing left to say about where between two voxels the edge sits. We checked
the obvious objection — that it is just blurred — by turning their blur down to
almost nothing, and the improvement stayed.

The catch is that it stops respecting the faces of the part you imported. Those
get about two-thirds worse, and a couple of percent of the material drifts
outside the original shape. Nothing in the method knows your CAD faces are
special.

**What would it cost to adopt?** Too much to be worth it as a whole. Their
optimiser is twenty-five times slower per step on your part — your ladder takes
an hour and twenty; theirs would take days — and it produces nothing our
certification can check, because it optimises stiffness and has no idea about
stress or printing. Two of our own functions would need a second input to
understand a boundary that lives between voxels.

**Could you still lattice and certify the result?** The lattice side is
genuinely good news: PicoGK installed in under three minutes, and putting a
lattice on your part whose struts thicken and thin according to your own
simulation took twenty lines of code and under a minute to run. It keeps the
lattice as a compact volume rather than a pile of triangles — about seven times
smaller on disk, and it only makes triangles when you ask it to export. But it
does no stress analysis at all, so the certificate cannot move there; it would
still have to be done on the design before the lattice is made, exactly as now.
And the same wall appeared on that side too: the tool can vary strut thickness
perfectly smoothly, but the field you would drive it with is the same binary
density we already found had nothing left in it.

**The thing actually worth doing** is small. Take a finished design, compute the
distance from every voxel to the surface — about forty lines, two hundredths of
a second — and build the mesh from that instead of from the density. That alone
gets a quarter of the improvement with nothing adopted and nothing changed
downstream. Then put the CAD faces back with the projection you already built
last week. If that pair measures well, the rest of this is a question for later.
