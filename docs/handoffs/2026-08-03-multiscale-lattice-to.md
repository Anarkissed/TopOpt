# Multiscale lattice TO — the optimizer places the lattice while it grows the shape

**Slug:** `multiscale-lattice-to` · **Branch:** `claude/multiscale-lattice-to-11d898`
· started from `main` at `34175a5`.
**Evidence:** `evidence/2026-08-03-multiscale-lattice-to/` (+ `reproduce.sh`).
**Machine:** Apple M2 Pro (10 cores), 16 GB, Apple clang, library Release.
**Predecessors:** matrix-free cubic probe (`2026-07-30-matfree-cubic-probe`, PR 252
— the exact three-block decomposition), multiscale lattice feasibility
(`2026-07-31-multiscale-lattice-feasibility`, PR 255 — the C(ρ) model and the
forbidden-interval measurement), multiscale production wiring
(`2026-08-01-multiscale-production-wiring`, PR 257 — the armed matrix-free cubic
route and the GenEO cubic fingerprint), strut-strength report
(`2026-07-31-lattice-strut-strength-report`, PR 263).

---

## Verdict in one paragraph

**The optimizer can now place lattice while it grows the shape, and doing so alone
makes latticeability WORSE, not better.** C(ρ) from the measured octet table replaces
ρᵖ·E₀ inside the lattice region, with exact three-block sensitivities (dC/dρ 9.6e-9
and dc/dρ 3.1e-7 against central differences — the latter better than the classic
path's 1.0e-6 on the same fixture), the feasible-set projection charged not absorbed,
and the `/*lattice=*/nullptr` certification gap closed. On a control fixture with no
geometric excuse the two-step latticed **19.0 %** and multiscale latticed **0.8 %** —
24× worse — because legalizing intermediate density lets the optimizer spread material
into thin webs, and thin is exactly what the cells-per-member floor forbids. SIMP's ρ³
had been *accidentally protecting* latticeability by forcing consolidation. Adding
length-scale control derived from the floor (min_feature = floor_cells·cell/2, so a
sub-floor member is INEXPRESSIBLE rather than merely unrewarded) takes the same
fixture to **59.5 %** — 3.1× better than the two-step, with the member-thickness
histogram moving out of the 1–3-cell buckets into [6,7). Separately and more
importantly for the maintainer: **91.5 % of their declared lattice region is frozen
solid** by their own face-protection collar (10,070 of 11,002 voxels), so the
motivating 0 / 82 / 472 was substantially a job-level conflict and not the optimizer's
doing. Library default OFF throughout.

---

## Why this exists — the two-step is structurally broken

On the maintainer's real run (`M2_verticalStand`, 128³, Mac worker, ladder
[0.68, 0.52, 0.38, 0.26]), whose job document is captured at
`~/.topopt-worker/95f4130119414636` and reproduced **verbatim** here as
`evidence/.../job_twostep.json`:

| variant | region_voxels | latticed_voxels | solid_fallback | latticed |
|---|---:|---:|---:|---:|
| 038 | 10,405 | **0** | 10,405 | **0.0 %** |
| 052 | 10,485 | **82** | 10,403 | **0.8 %** |
| 068 | 10,607 | **472** | 10,135 | **4.5 %** |

Variant 038 additionally reported `region_ungradeable=true`, `rho_min_used=0`,
`rho_max_used=0` — nothing at all was latticed.

**The mechanism, and it is not a bug in the lattice pass.** `minimize_plastic`
optimized the shape assuming SOLID material, with penalty 3.0 driving density to
the extremes *by design*. What survives is thin tendrils. The lattice pass then
cannot fill a member thinner than the cells-per-member floor (5), so it falls back
to solid. **The optimizer ate the material the lattice needed, because nothing told
it a lattice was coming.** No post-process can undo that.

---

## What shipped

Everything is in `core/`. No fixture, no `materials.json`, no `ARCHITECTURE.md`,
no `DECISIONS.md`. **No assertion was weakened or deleted** — `git diff | grep '^-'`
matches no `assert`/`throw`/`static_assert` line (`m1_no_assertion_removed.txt`).
The gate's verdict logic and tolerance are untouched.

### 1. The material model, promoted to production

`core/include/topopt/lattice_material.hpp` + `core/src/fea/lattice_material.cpp`
— PR 255's three-regime curve C(ρ) (Hermite void bridge → origin-anchored
polynomial through the MEASURED resolved rows → quadratic solid bridge), with one
structural improvement over the probe: **it reads its rows from core**
(`lattice_resolved_rows`, new in `lattice.hpp`/`lattice.cpp`) instead of
transcribing them. The probe needed a pinning test to catch table drift; production
cannot drift, because there is only one copy of the numbers.

The bars reproduce the probe's measurements exactly
(`unit_multiscale_material.txt`, ctest `multiscale_material`):

| bar | measured |
|---|---|
| rows reproduce `lattice_cubic_tensor` at every row ρ | rel err **0** |
| C(0) = zero tensor; C(1) = exact isotropic solid triplet | rel err **0** |
| C0 / C1 at both regime joints | **5.1e-8** / **3.1e-8** (slope drift over the 2e-9 window — no discontinuity) |
| **dC/dρ vs central differences** (41,976 interior samples, 7 topologies) | **9.56e-9** (at-joint 1.6e-6, the expected O(h·\|ΔC″\|), reported separately) |
| in-band fit accuracy, worst row | **3.086 %** (octet C12) — the probe's 3.09 % |
| admissible + derivative-PSD on (0, 1], accepted by `hex8_stiffness_cubic` | worst normalized margin **0.0092** |
| **C11·K_A + C12·K_B + C44·K_C ≡ hex8_stiffness_cubic** on the model's own curve | **1.2e-14** |

`lattice_material_model_trustworthy()` admits **octet only**: the other six
certifiable topologies are refused, each with a quotable reason (upper gap
0.41–0.50 wide, and/or below the 6-row model-order cliff where the fitted C12
derivative reaches ~35 % error). `minimize_plastic` **refuses** an untrustworthy
topology rather than optimize on a fiction.

### 2. The SIMP loop's material law

`simp.cpp` — `SimpParams` gains `lattice_material` + `lattice_region` (both null =
the entire existing world, byte-for-byte). When set, a design voxel inside the
region carries the measured homogenized cubic tensor at **its own** density instead
of ρᵖ·E0, the solve routes to the composite `fea_solve_cg_lattice[_matfree]`, and
the sensitivity comes from the three-block decomposition:

```
q_A = uᵀK_A u,  q_B = uᵀK_B u,  q_C = uᵀK_C u        (one solve, three scalars)
c_e     =   C11·q_A + C12·q_B + C44·q_C
dc/dρ_e = −(dC11·q_A + dC12·q_B + dC44·q_C)
```

exact for the same reason the isotropic loop's is exact — linearity of Kₑ in the
constitutive matrix. `hex8_cubic_blocks` is the new public name of PR 252's
reference blocks (**forwarding**, never a second integration, so the blocks the
optimizer differentiates against are the blocks the solver applies). Routing the
derivative *triplet* through `hex8_stiffness_cubic` would have been shorter and is
wrong: it would demand admissibility of dC/dρ, which fails where a component
vanishes at a band edge.

### 3. The feasible-set projection, charged

A printable, certifiable voxel is void, in-band lattice, or solid:
{0} ∪ [ρ_lo, ρ_hi] ∪ {1}. PR 255 measured that **no in-loop strategy zeroes the two
gaps** — 96.5–100 % of parked gap voxels sit on the density filter's own transition
ring, which the filter guarantees is non-empty. So the design is projected onto the
feasible set at rung termination, **before** the connectivity belt, the
certification solve and the export, so all three see the same field.

The volume-constraint violation the projection causes is **charged and reported**
(`volume_constraint_violation`, signed, as a fraction of the target the optimizer
was held to), never absorbed into a re-normalization. Idempotence, exact charge
accounting, the deterministic mid-gap tie-break and the mask confinement are all
pinned by the unit test.

### 4. The cells-per-member floor — **reporting, not a constraint** (scope stated)

**Making the floor a differentiable in-loop constraint is not tractable, and this
is the BLOCKED-STOP the task anticipated.** Local member width is a granulometric
opening of the *thresholded* design (`local_member_thickness_mm`): it is a distance
transform of a level set, so it is both non-differentiable and discontinuous in ρ.
There is no gradient to hand MMA/OC.

What shipped instead is the task's stated fallback, and deliberately **live** rather
than post-hoc: `measure_floor_occupancy` runs the *same* EDT the grading law and the
gate use, at the same 32-voxel cap, **every design iteration** (stride 1), and
`run_info.json`'s `multiscale.rungs[].floor_history` records `measured` / `below` /
`min_cells_per_member` per iteration, plus a 1-cell-bucket histogram of the
converged design. A run whose members are starving below the floor says so *while it
is happening* instead of at export. Measured cost: **≈1 %** of the design iteration
(see M7) — it is charged in the cost table, not hidden behind a coarse stride.

**The mechanism that actually fixes the floor problem is the formulation, not a
constraint.** Under the two-step the optimizer had a positive incentive to thin
members (ρ³ penalization rewards concentrating material); under multiscale an
intermediate density is a real, efficient, printable material, so the incentive is
gone. M3 measures whether that is enough.

### 5. Closing the gap the task named

`minimize_plastic.cpp` passed `/*lattice=*/nullptr` to `analyze_fixed_design`
unconditionally: the per-rung **certification** solved the design as if every voxel
were solid, even on a job about to be latticed. A multiscale variant now hands the
certification the posture it was actually optimized under — the projected in-band
voxels, each at its own relative density, carrying the measured cubic tensor. *The
gate's verdict logic and tolerance are untouched; it is given the right object to
apply them to.*

### 6. Two coherence fixes without which the claim would be false

These were found while wiring, and both are cases of the loop and the export
disagreeing — the same disease as the two-step, one stage later.

**(a) The grading law re-derived ρ from stress.** `grade_lattice` maps a *demand*
field to relative density. Under multiscale the optimizer has already chosen ρ per
voxel and *paid a compliance objective evaluated at the measured tensor of that ρ*.
Re-deriving it would print a different material distribution than the one optimized
and certified. `GradingLawParams::prescribed_relative_density` (null by default =
the demand map, byte-for-byte) lets a multiscale run prescribe. **The band clamp,
the cells-per-member floor, the L4 solid fallback, the cell plan and the L2
certifiability assertion are the same code on the same terms**; only the source of ρ
changes.

**(b) The printed set was defined at ρ > 0.5.** Under classic SIMP "is there
material here" and "is this voxel more than half full" are the same question. Under
the lattice law they come apart: a converged voxel at ρ = 0.30 is not a half-empty
solid voxel, it is a real, printable, measured 30 %-dense lattice cell — and reading
the design at 0.5 would delete every in-band voxel below it. `printed_iso` is
threaded through `minimize_plastic`, `analyze_fixed_design`, the mesh export, the
lattice candidate set, the boundary base, the certification mask and the grading
law, from **one** resolver (`run_printed_iso`), defaulting to **0.5** — so every
non-multiscale path takes the value it always used as a literal and is
byte-identical by construction. A multiscale run uses `multiscale_printed_iso()` =
half the band floor: strictly below every certifiable density, strictly above zero,
and — since projection leaves nothing strictly between 0 and ρ_lo — any value in
that interval selects the same set, so it is not a knife edge.

**(c) The band clamp latticed voxels the design made SOLID.** With the design's own
ρ prescribed, `grade_lattice`'s band clamp pulled every voxel above ρ_max = 0.900 down
to the ceiling and latticed it — *removing* material the optimizer deliberately kept.
Measured on the maintainer's part before the fix: **1,110 of 1,124 "latticed" voxels
(98.8 %) were voxels the projection had made solid.** They are now excluded from
lattice candidacy and counted in the solid companion, where they belong. This made the
headline latticed count *smaller* and the receipt *true*.

**(d) The latticed re-certification read the design at 0.5** while the optimizer, the
export and the grading law read it at the multiscale threshold — so the composite
re-certification was solving an object with every sub-0.5 in-band voxel deleted. The
threshold now rides on `LatticeCertContext`, so the solid certification, the latticed
re-certification, the clamp counterfactual and the connectivity belt cannot drift apart.

### 7. Arming

`kProductionMultiscaleLatticeTO` (production.cpp) is a **permission, not a
posture**: unlike every other constant in that file, multiscale changes the answer
by design, so it cannot be a run-wide flip — it gates whether a *job's own*
`lattice.multiscale: true` is honoured. A job that does not ask is byte-identical
either way, and the reference world never calls `configure_production_options` at
all. A refusal (production withholding the permission, or an untrustworthy
topology) is **loud** — never a silent downgrade to the two-step, because the whole
point of the flag is that the two-step does not work here.

---

## THE BARS

> **STATUS: ALL BARS MEASURED.** Evidence in
> `evidence/2026-08-03-multiscale-lattice-to/`. **ctest: 102/102 passed**
> (`ctest.txt`, 1154 s, zero failures).

### M2 — the maintainer's part, actually latticed — **MEASURED**

Full ladder, multiscale with length-scale control (`m2_multiscale_final/`):

| variant | region | latticed | fallback | two-step, for comparison |
|---|---:|---:|---:|---|
| 068 | 57 | **3 (5.3 %)** | 54 | 472 / 10,607 |
| 052 | 29 | **0 (0.0 %)** | 29 | 82 / 10,485 |
| 038 | 38 | **8 (21.1 %)** | 30 | 0 / 10,405 |
| 026 | 71 | **0 (0.0 %)** | 71 | — |

**This is far under a large majority. On the maintainer's job, multiscale did not
solve the problem it exists for, and no reading of these numbers should suggest
otherwise.**

THREE MEASURED REASONS, and none of them is "the formulation does not work" — the
control fixture reached 59.5 % (M2c):

1. **91.5 % of the region is unreachable** — `active 932, frozen_solid 10070`.
2. **The ceiling is 2,506 of 11,002 (23 %).** Even on a FULLY SOLID part, only
   23 % of the declared region has members thick enough for a 4.6026 mm cell. A
   design can only remove material, so this bounds every configuration.
3. **The volume-constraint violation reaches +41 %, +82 %, +148 %, +263 %** down the
   ladder. That is not a rounding correction. The floor-implied length scale
   (11.507 mm, raised from 2.5) leaves ~2.3 members across a 52.9 mm-deep part, and
   at that coarseness the design **cannot hold its volume target at all**. The
   arithmetic predicted ~2.3 members before the run; the run turned that from a
   tightness concern into a failure mode.

**So the length-scale lever — which tripled latticeability on a fixture with room for
it — does not apply to this part at this nozzle.** That is a scope boundary, now
measured rather than argued. Latticing this part needs a finer cell, which means a
finer nozzle (`min_extrudable_width_mm`, 0.42 today) or a re-measured
cells-per-member floor. Neither is a solver change.

The reason is measured, not inferred, and it is mostly not about the optimizer:

```
[multiscale] region reachability: active=932 frozen_solid=10070 (of 11002)
[multiscale] WARNING: 91.5% of the declared lattice region is NOT optimizable
```

**10,070 of 11,002 region voxels are pinned FrozenSolid** by the design mask — the
face-protection collar on face 16 plus the declared load/fixture faces. They are held
at density 1 for the whole run and can never become lattice in any formulation. Only
932 voxels were ever the optimizer's to move. The job asks to protect a face and to
lattice the same material.

Two consequences worth carrying: (a) the motivating 0 / 82 / 472 was substantially a
**job-level conflict**, not a solver failure — which is a different diagnosis from the
one this task was commissioned under; (b) the two-step nevertheless latticed 472
voxels of that 91.5 %-frozen region, because its grading derives ρ from stress rather
than from the design — i.e. **it hollows out material the mask protected.** Whether
"protected" should also mean "not latticed" is a design question this task does not
decide.

### M2b / M2c — the positive control, and the lever — **MEASURED**

The maintainer's job cannot test the formulation (its region is 91.5 % unreachable),
so the same two configurations were run on a fixture that can: whole part latticed,
nothing frozen (`frozen_solid = 0`), ceiling admitting 10,002 of 10,040 voxels.

| config | latticed | vs two-step | margin |
|---|---:|---|---:|
| two-step | **1,879 / 9,876 = 19.0 %** | — | 2600–2717 |
| multiscale, no length scale | **54 / 6,391 = 0.8 %** | **24× worse** | 121–212 |
| multiscale + floor-derived length scale | **7,368 / 12,391 = 59.5 %** | **3.1× better** | 87–96 |

At vf 0.60 alone the last row is **73.4 %** latticed.

### M3 — no thin-tendril collapse — **MEASURED**

On the maintainer's part the below-floor population is 10,026/10,612, 10,327/10,449,
10,380/10,408 and 10,431/10,431 down the ladder — i.e. essentially the whole region is
below the floor whatever the optimizer does, which is reason (2) above restated per
rung. The mechanism is visible on the control fixture, where the floor is reachable:

Member thickness in cells against the floor of 5, vf 0.60, from
`run_info.multiscale.rungs[].floor_histogram`:

```
                     [1,2) [2,3) [3,4) [4,5) [5,6) [6,7)   below floor
multiscale            2813  1787  1297    81     0  2397   5978/8375 = 71 %
multiscale + length   30     104   792   794     0  8055   1720/9775 = 18 %
```

**This is the whole mechanism in one table.** Without length-scale control the
multiscale design's mass sits at 1–3 cells across — thinner than the two-step's, which
is why it latticed less. With it, the mass moves to [6,7) and the below-floor
population falls from 71 % to 18 %. The residual 18 % is the density filter's boundary
ring, the same phenomenon PR 255 measured for the density gaps; it falls back to solid
and is reported.

### M4 — certification under the existing gate — **MEASURED**

Every rung of the full ladder was ACCEPTED, on both the solid and the composite
(latticed) certification, with the gate's verdict logic and tolerance untouched. No
verdict moved on any existing path — M1 shows the non-multiscale path is byte-identical,
which is a stronger statement than a negative-control floor: the flip count is exactly
zero by construction, not merely below 1e-9.
Note the honest cost already visible: a genuinely latticed part carries a far lower
margin (87–96 vs 2600–2717) — still ~58× the required `margin_stop` of 1.5, but the
two are not interchangeable. You are buying mass savings with margin you had in hand.

### M5 — strut strength reported, not hidden — **MEASURED**

PR 263's separate margins ride every multiscale receipt with PR 259's caveat verbatim.
On the maintainer's rung 0.68: in-plane **6609.6**, interlayer **3926.3**,
`z_knockdown = 0.55` carrying its "UNSOURCED … never measured by coupon" provenance
string, and `strut_strength_uncertified = true` as designed. **Both margins are far
above 1.5 on this part**, so the prominent warning the task asks for is not triggered
here — but it would be, and the fields are on every receipt.

### M6 — the accelerators in a design loop — **MEASURED**

Multigrid engages **40/40** on the composite operator; multiscale needs **0.746×** the
CG iterations of the penalized loop (mean 15.6 vs 20.9) and 0.746× the matvecs.

On the maintainer's real part **multigrid never engages, in either configuration** —
`cg_multigrid = 0` on 0 of 400 iterations of the captured two-step run, and likewise
multiscale. Pre-existing, not caused by anything here, but it means the accelerator
carrying that part is the Jacobi-CG fallback with recycling.

**GenEO's cubic fingerprint, in a loop** (`m6_geneo_fingerprint.csv`): six moving
designs gave actions 3, 2, 3, 2, 2, 2 — build or refresh, **never** a silent reuse —
and two repeats of an unchanged design gave action 1, REUSE. So it discriminates
rather than refreshing unconditionally, which is the half that makes the first claim
mean anything. Deflation on the cubic operator: 522 → 160–165 iterations (3.2×).
Two honesty notes: the parity pad is off for this bar (with it on, multigrid rescues
the odd axis and GenEO never runs — the first attempt measured exactly that and
reported it as not-established rather than passing vacuously), and the engagement gate
is opened via the harness-only override `test_matfree_cubic` already uses.

### M7 — cost — **MEASURED**

**Net 1.138× wall per design iteration** against PR 252's 2.4–2.7× per-apply
expectation — the apply is dearer but the loop needs 25 % fewer iterations. The
per-iteration floor EDT costs ≈1 % of an iteration (87 ms of ~9 s) and is charged
here rather than hidden behind a coarse stride. Host load recorded either side of
every run (`host_*.txt`); this machine also carried an unrelated 128³ job throughout,
so wall figures are read with that in mind — CG and matvec counts are load-independent.

### M8 — determinism — **MEASURED**

Loop: identical density (FNV `85b849ecf5dd0b5c`), CG counts and compliance history
across two runs, and an identical projection charge. 128³: the restarted ladder
reproduced CG counts (880, 1102, 942, 957 …) and rung 0.68's margin to all printed
digits. Pipeline: two full runs byte-identical on every result artifact; the
instrument files match once machine measurements (wall clock, RSS, OS paging counters,
`gen_fraction`) are stripped — those are measurements of the host, not the design.

### M1 — OFF is byte-identical — **MEASURED, PASSES**

One worktree, one cmake cache, `Release` both sides, base `34175a5` vs branch, on a
lattice+grading job with multiscale absent (`m1_controlled.txt`). **Every artifact
carrying an answer is byte-identical**: `design.bin`, `fields.bin`, `report.json`,
`loadcase.json`, `variant_045.stl`, `variant_045_lattice.report.json`,
`variant_045_lattice.stl`. The only differences are four stopwatch readings —
`sweep_seconds`, `created_wall_ms`, `gen_seconds`, `gen_fraction`.

Recorded because it nearly became a false alarm: a first attempt compared an `-O0`
comparison build against the `Release` branch build and reported a 1-ulp difference
(`0.006372359774` vs `…73`). That was the build type changing floating-point
contraction, not the code. Matching the build type made it vanish. **A byte-identity
claim is only as good as the build configuration on both sides of it.**

Also, on the maintainer's own part: the artifacts a two-step run produced are
byte-identical to the captured pre-branch run (`m1_captured_vs_branch.txt`), core
being unchanged between `2b8b715` and `34175a5`.

### Full suite — **102/102 PASSED** (`ctest.txt`, 1154 s, zero failures)

---

## Plain language

Think of every small cube of the part as having a dial from 0 % to 100 % material.
The old optimizer punished middle settings, because a 40 %-dense blob of plastic isn't
a thing you can print. But a 40 %-dense *lattice* is, and we have measured stiffness
numbers for it. So this work taught the optimizer that dial — it now knows a lattice
is coming while it decides the shape.

The surprise is that this made things worse, and the reason is worth understanding.
The old penalty didn't just discourage middle settings; it forced material to bunch up
into chunky beams. Lattice needs chunky beams — you can't fit five lattice cells across
a thin sliver. When we removed the penalty, the optimizer did the sensible thing for
stiffness and smeared material out into thin webs, and thin webs can't hold a lattice.
The old rule had been protecting us by accident.

The fix is to change what the optimizer is *able* to draw rather than what it's
rewarded for: widen the blur it designs through, so a sliver thinner than five cells
simply can't be expressed. On a test part that took latticing from 19 % (old pipeline)
down to 0.8 % (new one, no blur) and up to 59.5 % (new one with it) — three times
better than where we started.

Separately, and probably more useful day to day: on the maintainer's actual part,
**91.5 % of the region they asked to be latticed is material they had also asked to be
protected.** Protecting a face freezes it solid for the whole run, so the lattice had
nowhere to go. That explains the original near-empty result far better than anything
about the optimizer does, and it's a warning at job setup rather than a solver change.
The code now prints exactly that warning.
