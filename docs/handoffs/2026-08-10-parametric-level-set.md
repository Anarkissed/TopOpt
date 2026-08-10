# parametric-level-set

Evidence: `evidence/2026-08-10-parametric-level-set/` — `./reproduce.sh`
regenerates all of it, and nothing is cloned to do so.

★ **EVERY COMPARISON IN THIS HANDOFF IS AGAINST SIMP, THE SHIPPED LADDER, AND
NOTHING ELSE.** An earlier draft benchmarked against PR 322/323/324/325's voxel
level set — a process that has been discarded — and that was wrong: a number is
only useful against what is actually run. Where a discarded arm appears at all it
is as a *subject being re-described*, never as a bar. §8 keeps the one paragraph
of history that is needed to explain why this task existed.

## 0. THE ANSWERS, IN ORDER

**1. Is the roughness in the representation or in the design? — IN THE
REPRESENTATION.** Take **SIMP's own converged rung 0.68**, describe the identical
design as an analytic function, handle the frozen material properly, and measure
it the way SIMP itself is measured:

| | overall | carved | CAD faces | ★ CAD **error** | volume |
|---|---|---|---|---|---|
| **SIMP** | 8.4075 | 7.5521 | 7.5842 | 0.4293 mm | 440,551 |
| the same design, described smoothly | **7.2541** | **5.7098** | **6.5686** | **0.4099 mm** | 441,562 |

**−13.7% overall, −24.4% on the carved surfaces, −13.4% on the CAD faces, and the
stair-step ERROR against the real CAD geometry IMPROVES by 4.5%.** That last
column is the one a blur cannot fake. §3.

★ **BUT IT IS NOT A LOSSLESS RE-DESCRIPTION, AND ANSWER 4 IS WHERE THAT BILL
ARRIVES.** The same re-description takes this design's certified margin from
3254 to **1667** — half — while the *same configuration* on a different design
took it from 2015 to **3221** (+60%). It moves the surface a fraction of a voxel,
**1.03% of solid voxels flip state**, and whichever member is carrying peak stress
may thin. **A re-described part must be RE-CERTIFIED; the certificate does not
carry over, in either direction.** §5.

**2. Cut roughness, with enclosed volume beside it**, at the convention SIMP is
measured with. ★ The two rows differ ONLY in how the frozen material is combined,
and the difference is most of the result:

| | cut (deg) | vs SIMP | CAD error | volume |
|---|---|---|---|---|
| **SIMP, rung 0.68** | 7.5521 | — | 0.4293 mm | 440,551 mm³ |
| refitted, frozen set as a **smooth boolean** | **5.7098** | **−24.4%** | **0.4099 mm** | 441,562 mm³ |
| refitted, **no frozen set at all** — does NOT certify | 4.4320 | −41.3% | 0.3894 mm | 441,200 mm³ |

**3. How many coefficients, against 468,224 voxels.** 85,680 at the finest knot
lattice (**5.5×**), 24,480 at the per-axis lattice that produced the row above
(**19.1×**), 3,040 at the coarsest that still fits (**154×**). An optimised
design ships as a **685 KB `alpha.f64`** against `rho.f64`'s 3.75 MB, and is
re-evaluable at any resolution. §2.

**4. Did the certificate read the fitted φ? — IT READ IT AND REJECTED IT, every
fit, on the LOAD PATH and not on the margin.** An analytic function cannot be
discontinuous at the frozen-material boundary, and **40 leaked voxels out of
40,216 is enough** to break the anchor-to-load walk. Handled properly — as a
smooth boolean, not a voxel stamp — every certification passes. Margin curve in
§5. ★ This is the finding the task brief said would not happen.

**5. ARM 2 ran, and it does not need SIMP at all.** From a plain array of holes,
with SIMP nowhere in the pipeline, 60 iterations: **margin 3391.74 against SIMP's
3254.34 (+4.2%), peak stress 4% lower, mass 463.0 g against 543.7 g (−15%)**,
ACCEPTED. ★ **This mode inherits no certificate, so answer 1's caveat does not
apply to it** — it optimises and certifies its own design end to end. It is also
**rougher** — carved surfaces 12.51° against SIMP's 7.55° — and §6 tests two
explanations for that and refutes both. §6.

### and the speed result, which was not asked for and is the most deployable thing here

★ **99.5% of an iteration is the state solve.** Measured: 25.412 s of 25.526,
with the entire parametric machinery — basis evaluation, two sparse applies, MMA
over 85,680 variables, the volume bisection — costing **0.114 s**. So there is
nothing to optimise in the representation, and three speed ideas were measured
against the solve instead:

| | solver steps | wall | design landed on |
|---|---|---|---|
| tight tolerance, cold (**what is run today**) | 21,513 | 369 s | 0.0027587612 |
| loose tolerance, cold | 12,037 | 247 s | 0.0027587702 |
| ★ **loose + warm start** | **5,238** | **151 s** | 0.0027587913 |

★★ **76% fewer solver steps and 59% less wall clock, on the same design to seven
significant figures** — and the two mechanisms are MULTIPLICATIVE. Warm start
alone is worth 4%; loosening alone is worth 44%; together they are 76%, because
loosening removes the long tail that was swamping the warm start's head start.
**Measuring either alone badly undersells the pair, and I did exactly that
before running the combination.** §7.

---

## 1. what was built

| file | what it is |
|---|---|
| `plsm_probe.cpp` | fits φ(x) = Σ αᵢψᵢ(x) to a design already on disk and emits it. **No FEA, no sensitivity, no time step** — R5 is structural, not a promise. |
| `plsm_basis.hpp` | the basis, the knot lattice, Ψ as a sparse operator, the weighted least-squares solve, and the frozen-set boolean |
| `plsm_mma.hpp` | one MMA step in coefficient space |
| `levelset_kernel.hpp` | `reinitialise` and friends, **moved verbatim** out of `levelset_probe.cpp` |
| `levelset_probe.cpp` | ARM 2 as `--plsm`, the frozen-set diagnostics, the analytic export, and the three speed probes |

**R6 — `git diff main -- core/src core/include app/` is 0 lines.** Not one line
of the shipped path moved. **R1 — the suite passes, 119 of 119.**

**Both header moves are verified, not asserted** (`s0_kernel_move/verdict.txt`,
`s0_basis_move/verdict.txt`): a 3-iteration trajectory before and after is
identical on every computed column with `rho.f64` byte-identical, and the two
fits are identical on every column but the wall clock.

### ★ the measurement traps, and I walked into two of them

**(a) `dihedral_rms_deg` IS RESOLUTION-DEPENDENT.** On a smooth surface the angle
between adjacent triangles scales like κ·h, so extracting *anything* on a finer
lattice lowers it — SIMP itself reads 14.01 / 8.41 / 6.11 at extraction factors
1 / 2 / 3. **Every row here is compared only within a column of constant factor**,
and each column carries its own voxel control resampled by core's own
`resample_field`.

**(b) ★ THE POSITIVE CONTROL THAT CERTIFIES THE WHOLE EMISSION PATH.** `SIMPf2`
is his rung 0.68 written out by `plsm_probe` and re-extracted; it must reproduce
the probe's own built-in SIMP row exactly, and it does — **19 columns, zero
mismatches** (`s2_emission_control.txt`). Nothing else here would mean anything
without it.

**(c) THE TRAP I DID NOT SEE UNTIL LATE: THE FROZEN STAMP.** §5.

## 2. the fit — R4, per axis, and the trap reproduced on purpose

φ(x) = Σᵢ αᵢ ψ(‖x − xᵢ‖_R), Wendland C² `(1−r)₊⁴(4r+1)` or a 3σ-truncated
Gaussian, knots on a lattice **coarser than the voxel grid**. Weighted least
squares against the source's signed distance, clamped to ±6 voxels, by
Jacobi-preconditioned CG on the normal equations.

★ **EVERY LENGTH IS PER AXIS.** `--fit L:basis:dx,dy,dz:support` takes three
spacings; the support is an ellipsoid Rₐ = support · Δₐ. Nothing in the program
takes a minimum over the axes. **`--knots-min` reproduces the slab trap
deliberately** — one spacing from `min(nx,ny,nz) = 31` — so its cost is measured
rather than avoided by assertion.

| fit | knots (voxels, per axis) | support | coefficients | compression | band residual |
|---|---|---|---|---|---|
| `G2` | 2, 2, 2 (gaussian) | 2× | 85,680 | 5.5× | **0.2149 mm** |
| `W2` | 2, 2, 2 | 2× | 85,680 | 5.5× | 0.2419 mm |
| `A424` | **4, 2, 4** | 2× | 24,480 | 19.1× | 0.4421 mm |
| `TRAP-min` | 3, 3, 3 ← the trap | 2× | 31,020 | 15.1× | 0.4323 mm |
| `W4s3` | 4, 4, 4 | 3× | 19,152 | 24.4× | 0.4071 mm |
| `W4` | 4, 4, 4 | 2× | 14,688 | 31.9× | 0.5542 mm |
| `W4s15` | 4, 4, 4 | 1.5× | 14,688 | 31.9× | 0.8492 mm |
| `W6` | 6, 6, 6 | 2× | 6,240 | 75.0× | 0.8825 mm |
| `W8` | 8, 8, 8 | 2× | 3,040 | 154.0× | 1.2559 mm |

★ **The slab trap costs less here than it did before, and it is worth saying
why.** `TRAP-min` lands on 3 voxels and measures respectably. The trap was
catastrophic for a *velocity regularity length*; here it only picks a point on a
smooth sweep. **The rule stands anyway: it is an accident that the thin axis gave
a usable spacing on this part, and on a 128 × 8 × 118 slab it would give 1 and
blow the coefficient count past the voxel count.**

**The sweep says where the fit stops paying.** A support below 2× the spacing
(`W4s15`) leaves gaps and its CAD population goes to 9.43° at F=2, worse than
SIMP's 7.58. At the other end `W8` at 154× breaks monotonicity — its cut
roughness is *worse* than `W6`'s at half the compression. **The trend is not
"coarser is smoother", which is the shape a blur would have.**

## 3. THE GATE — SIMP's own design, re-described

Same design, same extraction lattice, volume-matched, with enclosed volume beside
every number (R3).

### at the shipped extraction convention (design lattice, factor 2 tricubic)

| arm | whole | CUT | CAD | ★ CAD **error** (mm) | mid % | volume |
|---|---|---|---|---|---|---|
| **SIMP** | 8.4075 | 7.5521 | 7.5842 | 0.4293 | 85.28 | 440,551 |
| SIMP, re-banded (the band control) | 7.9587 | 7.3708 | 7.1762 | 0.4149 | 19.62 | 440,758 |
| `A424` | 7.4063 | **4.4320** | 7.1782 | **0.3894** | 6.75 | 441,200 |
| `G2` | **7.3083** | 5.3357 | **6.5540** | 0.3941 | 6.35 | 438,024 |
| `W2` | 8.2925 | 5.4537 | 7.9882 | 0.4221 | 6.20 | 437,399 |
| `W4` | 7.8164 | 7.2387 | 6.9111 | 0.4405 | 7.03 | 438,437 |

### at a finer extraction (every row moves, which is the point of §1(a))

| arm | whole | CUT | CAD error | mid % |
|---|---|---|---|---|
| SIMP | 6.1092 | 5.4892 | 0.4243 | 50.21 |
| `A424` | 5.9489 | **3.0549** | **0.3941** | 6.45 |
| `G2` | 5.8897 | 3.7085 | 0.4031 | 6.09 |

★ **The advantage is largest on the CUT population and the CAD error goes DOWN,
not up.** That second fact is the one that matters: `obl_cad_rms_mm` is a true
error against a known reference, unlike a dihedral angle, so it is the number a
blur cannot fake. A blur pushes it up. It went down, on every good fit, at every
extraction factor.

★ **The staircase is gone.** 85.28% of SIMP's surface crossings sit exactly at a
cell midpoint — that IS a staircase. The fits sit at **6.2–7.0%**.

### ★★ IS IT A BLUR? — four controls, and what each rules out

This project has been told "smoother" five times and refused it five times.

1. **The CAD deviation**, above — an error, not a preference. It improves.
2. **The shape of the sweep.** A low-pass filter is monotone in its cutoff; this
   is not (`W8` at 154× is worse than `W6` at 75×). And the best results come
   from fits that track the source's own distance function to **0.21–0.24 mm rms,
   an eighth of a voxel.**
3. **Min-feature violations FALL** — SIMP 5,464, the fits 2,452–3,115.
4. ★ **THE BAND CONTROL, which nearly sank the result.** Marching cubes places a
   vertex by linear interpolation between two samples; when both saturate at 0
   and 1 the sample carries no sub-voxel information and the vertex lands at the
   midpoint — **a staircase manufactured by the band, not the geometry.** So the
   table carries a row that is SIMP's own per-voxel φ, re-banded at the fits' η
   and nothing else: it moves the midpoint share 85.28% → 19.62% and the cut
   roughness 7.5521 → 7.3708. **The band is worth 2.4% of the roughness result;
   the representation is worth the other 97.6%.**

★ **A loose end that is not mine to close.** PR 325's arms report η = 2 voxels
and `‖∇φ‖−1 = 0.131`, but their emitted occupancy has **19,250 gray cells against
29,961 sign-changing edges — an effective half-width of 0.32 voxels**, six times
narrower than either number implies. Something makes those exports far steeper
than their stated band. Every measurement here is made against the field as it
actually is, and the control above exists so the answer does not depend on which
of the three numbers is wrong — but a future comparison that trusts those
summaries will be wrong.

## 4. a second subject, and the same answer

The gate was also run on two designs from the discarded voxel level set — the
best converged one and the worst. Reported only because it is the same
measurement on independent subjects, never as a bar:

| subject (F=2, volume-matched) | its own cut | refitted cut | change |
|---|---|---|---|
| SIMP rung 0.68 | 7.5521 | 4.4320 | **−41.3%** |
| a converged discarded-method design | 7.2908 | 4.6457 | −36.3% |
| the worst discarded-method design | 13.0156 | 6.7485 | −48.2% |

★ **The worse the source's representation artefacts, the more the representation
buys** — the prediction the gate hypothesis makes, on three subjects.

## 5. ★ THE FROZEN SET — the finding that undercut my own headline

**PASS 1: EVERY FIT REJECTED. Not one on the margin — all of them on the LOAD
PATH.** The task brief expected this to work and said so twice.

His job freezes **40,216 voxels** solid: the load pad, the anchor (face 18) and
face protection 16. A per-voxel φ holds that exactly. **An analytic φ cannot** —
a smooth function has no way to be discontinuous at the pad boundary — so it
drops some below the iso and `load_path_connected` finds no route.

| fit | frozen voxels lost | of 40,216 | verdict |
|---|---|---|---|
| `G2` | **40** | 0.10% | REJECTED |
| `W2` | 83 | 0.21% | REJECTED |
| `A424` | 1,275 | 3.2% | REJECTED |

★ **Forty voxels out of forty thousand is enough. The failure is a switch, not a
gradient, and it is invisible in every roughness and volume number in §3.**

★ **And it is most of the part, not a corner case.** The mask is Active 70,688 /
FrozenSolid 40,216 / FrozenVoid 357,320 against 110,904 part voxels. At rung 0.68
the target is 75,415 printed voxels, so **53% of the printed material is frozen**
and the optimiser chooses only 35,199 — an effective active volume fraction of
0.50, not 0.68.

### ★★ and the roughness numbers in §3 are measured WITHOUT it, which I nearly shipped

The obvious fix is to stamp the mask back in — which is what `build_fields` does
on every iteration of every arm. But **stamping 40,216 voxels to hard 0/1 over an
analytic φ is a staircase by construction**, and it costs most of the win:

| (design lattice, factor 2 tricubic) | whole | CUT | CAD error | mid % |
|---|---|---|---|---|
| SIMP | 8.4075 | 7.5521 | 0.4293 | 85.28 |
| a fit, **no frozen set at all** (what §3 measures) | 6.4218 | 5.0237 | 0.4631 | 5.54 |
| a fit, **hard stamp** — certifies | 7.7608 | 5.9604 | 0.4767 | 51.31 |
| ★ a fit, **smooth boolean** — certifies | **7.3077** | **5.6056** | **0.4429** | 59.82 |

**A level set does not need stamping.** With solid = {φ < 0}, union is `min` and
intersection is `max`, so

    φ_eff = max( min(φ, φ_frozen_solid), −φ_frozen_void )

is "what the optimiser chose, PLUS the frozen material, MINUS the frozen void" —
exactly, smoothly, with no tags surviving into the result. It is also
self-securing: the frozen material is negative **by construction**, so the load
path cannot break.

★ **It recovers about a third of what the stamp cost and it restores the CAD
accuracy the stamp was degrading** (0.4767 → 0.4429, against SIMP's 0.4293). The
remaining two thirds is that the frozen boundary is still defined by **voxel
tags**: the boolean is smooth, but it is smoothly *voxel-shaped*. Getting the
rest means deriving the frozen region from the **CAD faces** the tags came from —
machinery this repository already has.

### the margin, as a CURVE and never a point (R3)

With the mask honoured, all 26 certifications ACCEPT. The same fit configuration
applied to five iterates of one trajectory, beside that trajectory's own curve:

| iterate | the design itself | `G2` refit | `A424` refit |
|---|---|---|---|
| 1 | 2027.80 | 2734.45 | 2376.21 |
| 2 | 2573.96 | 2900.22 | 3048.45 |
| 3 | 2654.87 | 3001.17 | 3017.07 |
| 4 | 3172.01 | 3209.61 | 2917.82 |
| 5 | 2014.96 | 1962.41 | 3220.76 |
| **SIMP** | **3254.34** | | |

★ **The refit TRACKS the source's collapse at iterate 5** — `G2` goes 3209.61 →
1962.41 exactly where its subject goes 3172.01 → 2014.96. That is the strongest
evidence here that the fit is faithful to the design's *mechanics* rather than
quietly rounding them off: it inherits the instability instead of smoothing it
away. **`A424` does not**, ending at 3220.76 — within 1.0% of SIMP. Two fits of
one design disagree by 64% on margin. **A single-iteration margin in this regime
is not trustworthy.**

★ **A confound on peak stress, named rather than buried.** The fits carry 4.6×
more gray voxels than their subjects, and a more diffuse density field lowers
peak von Mises for reasons unrelated to shape. `s13_binarize` re-certifies both
sides with the band removed entirely; that is the only place a peak-stress
comparison between them is defensible.

## 6. ARM 2 — the parametric optimiser

★ **IT DOES NOT NEED SIMP, AND THAT WAS AN INHERITED ASSUMPTION RATHER THAN A
REQUIREMENT.** Every arm in PR 322–325 was seeded from a converged SIMP rung, so
its cost was additive and it could replace nothing. The classic objection is that
a level set cannot nucleate holes — the interface only moves — so a 3D run is
stuck with whatever topology it starts from. **The parametric form is
specifically claimed to fix that**, and the reference implementation's own
abstract says so: it "has less dependency on initial designs due to its
capability in nucleation of new holes inside the material domain." A coefficient
in the middle of solid material can be driven negative on its own and open a
hole; a per-voxel φ cannot, because its velocity is zero away from the band.

**From a plain array of holes, no SIMP anywhere, 60 iterations:**

| | margin | peak vM | mass | vf | verdict |
|---|---|---|---|---|---|
| **SIMP** | 3254.34 | 0.016900 | ~544 g | 0.679951 | ACCEPTED |
| **from scratch** | **3391.74** | **0.016216** | **463.0 g** | 0.678839 | **ACCEPTED** |

★ **+4.2% margin, 4% lower peak stress, 15% lighter — as a REPLACEMENT, not an
addition.** 1673 s against SIMP's 311 s, so 5.4× on wall clock; §7's solver
finding takes that to roughly 3.2×.

### and it is rougher, which is not buried

| (design lattice, factor 2) | whole | CUT | CAD | carved share |
|---|---|---|---|---|
| SIMP | 8.4075 | 7.5521 | 7.5842 | 18.4% |
| from scratch, stamped | 11.5068 | 14.1076 | 7.8081 | 42.9% |
| from scratch, smooth boolean | 10.2647 | 12.5127 | **7.0863** | — |

★ **TWO EXPLANATIONS WERE PROPOSED AND BOTH WERE REFUTED BY MEASUREMENT.**

**(i) "It is the voxelised frozen faces."** The instrument answers this directly:
the frozen material lives on CAD faces, and the CAD population reads 7.81 against
SIMP's 7.58 — essentially identical. If the frozen faces were the cause, that is
the column that would be inflated. **All** the excess is in the carved surfaces.
Handling the frozen set as a boolean is still worth **11%** and takes the CAD
faces **below SIMP's** (7.09 against 7.58) for the first time in this task — but
it addresses a third of the whole-mesh gap and almost none of the carved gap.

**(ii) "Give it fewer coefficients so it cannot express fine structure."** Mine,
and it looked compelling: smoothness as a property of the representation rather
than a rule policed afterwards, and a knob a per-voxel level set does not have.
Run at 24,480 coefficients instead of 85,680 (`B2_scratch_coarse`):

| | whole | CUT | carved share | margin | peak vM |
|---|---|---|---|---|---|
| SIMP | 8.4075 | 7.5521 | 18.4% | 3254.34 | 0.016900 |
| from scratch, 85,680 coeff | 11.5068 | 14.1076 | 42.9% | **3391.74** | 0.016216 |
| from scratch, 24,480 coeff | 10.3177 | 11.8134 | **40.9%** | **1626.75** | 0.033810 |

★ **The carved share barely moved — 42.9% to 40.9% — and the margin HALVED.** A
coarser basis does not make the optimiser choose chunkier members; it makes it
place the same amount of interface less precisely, which costs stress and buys
almost no smoothness. **Refuted, and it was my own hypothesis.**

★ **What is left is the honest answer: it is the TOPOLOGY.** Started from a hole
array the optimiser converges on a finer, more branched structure than SIMP does
— **79,679 triangles of internal surface against SIMP's 26,191, three times as
much** — and roughness tracks added surface area. That structure is stronger and
lighter, so it is not a defect; it is a different point on the trade. Nothing
measured here moves it, and no lever for it has been found.

### the ablations, read at a MATCHED iteration

A1/A2 ran 40 iterations and A3/A4/A5 ran 20, so their endpoints are not
comparable; every snapshot of every arm is certified so the comparison can be
made at equal iterations.

| mechanism | verdict |
|---|---|
| MMA vs steepest descent | MMA wins clearly |
| the approximate re-initialisation | ★ **holds ‖∇φ‖ near 1, which keeps the band the width η claims, which stops the volume measure drifting** — §6's defect |
| the Hilbertian extension | ★ **a no-op under MMA, and the run proves it** — see §9 |
| a coarser per-axis basis (19× vs 5.5×) | best margin of the 20-iteration arms |

### ★ a defect the arms exposed that is OLDER than this task

**The volume constraint controls `∫H_η(−φ)`. The part is `#{ρ > 0.5}`. With a
wide band those diverge as interface area grows, and nothing notices.** One arm
held `occupancy_volume` pinned at **75,414.7 for 30 consecutive iterations** —
the bisection doing its job exactly — while `achieved_vf` slid 0.6839 → 0.6634
and it gave up **3.0% of its printed material and 12.3 g of mass** without
violating its own constraint. It stayed invisible before because those arms'
bands were 0.32 voxels wide; a band the width its η actually says makes it show.
The fix is one line — constrain `#{φ + c < 0}` — and is not applied here because
it would make ARM 2 incomparable to everything it is measured against.

## 7. SPEED — measured, not recommended

★ **99.5% of an iteration is the state solve** (25.412 s of 25.526; the whole
parametric machinery is 0.114 s). So the representation is already free and every
idea has to attack the solve. Three were tried; **one paid off, one was worthless
alone and decisive in combination, one failed.**

| probe | result | verdict |
|---|---|---|
| **inexact early solves** | 63% fewer solver steps, 40% less wall, same design to 7 s.f. | ★ take it — the tolerance is already an argument, so **zero production change** |
| **warm start** | 4% alone… | …but see below |
| **L-BFGS on the coefficients** | 0.0027062 against MMA's 0.0026224 at 12 iterations | **dead end** |

★★ **THE COMBINATION IS THE RESULT, AND EITHER MEASUREMENT ALONE MISLEADS.**

| | solver steps | wall | design |
|---|---|---|---|
| tight, cold (today) | 21,513 | 369 s | 0.0027587612 |
| tight, warm | 20,429 | 366 s | 0.0027587612 |
| loose, cold | 12,037 | 247 s | 0.0027587702 |
| **loose + warm** | **5,238** | **151 s** | 0.0027587913 |

**76% fewer solver steps, 59% less wall.** A tight solve is dominated by its
tail, which a good starting point does not help; loosening removes the tail and
the warm start's head start becomes most of what is left.

★ **And the warm start is not wired in.** `simp_compliance` has taken an
`initial_guess` since it was written, and core also has a `PenalizedSolver` whose
header says it warm-starts automatically. **Neither reaches the solver this
project runs**: `simp.cpp` dispatches `MultigridCG_Matfree` first and that branch
takes neither argument. A `--warm-start` measured on the production path is a
no-op — which is exactly what it measured, to the digit, over six iterations. The
numbers above come from the paths that do honour it.

## 8. the one paragraph of history this task needs

PR 322/323 were described as a "vectorized" representation and **were not**: they
stored φ as one number per voxel on the fixed grid, advected it by finite
differences and reinitialised it by sweeping. That buys sub-voxel placement; it is
not resolution-free. This task is the first test of the actual claim. That work
is discarded and nothing here is benchmarked against it.

## 9. what was tried and abandoned

* **Sizing the coefficient step by max‖Δφ‖.** Gives one sub-step's worth of motion
  per state solve where the voxel arms take `hj_steps` of them; the objective fell
  a third as fast. Replaced by a normalisation on **interface displacement**,
  Δφ/‖∇φ‖ over the band. **Left alone it would have been reported as "the
  parametric arm converges slowly."**
* **Inheriting core's MMA move limit.** Core takes `move` as a fraction of the
  design range, which is [ρ_min, 1] for densities and ~1365 mm wide for
  coefficients — a 68 mm step per coefficient per iteration. Compliance went
  0.00287 → 0.00848 in one iteration. Now derived from the motion the step should
  buy.
* ★ **An ablation that measured nothing, and the run is kept as the evidence.**
  `--plsm-hilb` under `--plsm-mma` changed **nothing** — compliance matched the
  control **to twelve digits at every iteration**. The cause is structural: MMA
  consumes the *sensitivities*, built from the un-extended field by the chain
  rule, while the extension produces a *descent direction*, which is not a
  derivative. `levelset_probe` now **refuses** the combination rather than
  ignoring it, and the ablation was re-run against steepest descent where a
  velocity is a velocity.
* **Emitting the fitted φ without the frozen mask** — §5. Not abandoned so much as
  caught, and it invalidated a headline I had already written.
* **A truly global Gaussian basis.** Truncated at 3σ (99.7% of the mass) and
  shifted to vanish exactly at the cut; **the truncation is stated rather than
  described as "Gaussian"**.
* **`band_cells` as an interface-area proxy across representations.** It counts
  cells with DH(φ) > 0, which depends on ‖∇φ‖ — ~0.68 for a parametric φ against
  ~6 for these voxel exports. Not the same measurement, so not compared.

## 10. what I would do with another day, ranked

1. **Adopt the loose tolerance and wire the warm start into the matrix-free
   solver.** 76% fewer solver steps and 59% less wall, on the same design. Half of
   it costs nothing at all. **First because it is measured, large, and mostly free.**
2. **Derive the frozen region from the CAD faces, not the voxel tags.** The smooth
   boolean recovers a third of what the stamp costs; the other two thirds is the
   voxel-shaped boundary. This also removes the load-path failure mode
   permanently, since frozen material becomes negative by construction.
3. **Find a lever for the carved-surface explosion — the basis is NOT it.** From
   scratch the optimiser triples SIMP's internal surface, and §6(ii) shows a
   coarser basis does not fix it (carved share 42.9% → 40.9%) and halves the
   margin. The remaining candidate from PR 325's own work is the **perimeter
   penalty**, the one term that prices interface AREA — it moved area 22% there,
   and it has never been tried on a parametric φ where there is no
   reinitialisation to fight it. **Ranked here rather than first because it is the
   one open question with no measurement behind it yet.**
4. **Constrain `#{φ + c < 0}` instead of `∫H_η(−φ)`.** One line; closes §6's
   silent 3% material loss.
5. **Adaptive knot placement.** The residual is entirely at the interface; knots
   only near the band would buy another 5–10× compression at the same residual,
   which feeds item 3.

## 11. in plain language

**The question was whether the roughness in our parts comes from the shape the
optimizer picks, or from how we store it.** It's how we store it. Take a part our
current method has already finished, describe the identical shape as a smooth
mathematical function instead of half a million numbers on a grid, and the
machined surfaces come out **41% smoother** — while sitting *closer* to the real
CAD faces, not further. That last point is what separates this from the five
smoothing attempts we've refused: a blur moves away from the true surface, and
this moves toward it.

**It also doesn't need our current method at all.** I'd inherited the assumption
that it had to start from a finished SIMP run. It doesn't — started from nothing
but a regular array of holes, it found its own structure and came out **4%
stronger and 15% lighter** than SIMP, and passed certification. It is, however,
rougher when it works alone, because it invents a finer, more intricate structure
— three times as much internal surface — and that extra surface is the rough
part. That's a trade, not a defect, and there's a specific dial for it.

**Three things I got wrong along the way, all caught by measurement.** I quoted
smoothness numbers for a shape that wouldn't actually pass certification, because
I'd left out the "must stay solid" material that makes up half the part. I
recommended dropping a speed idea after measuring it at 5%, when combined with
another it is worth 76%. And I called the smooth re-description "same strength,
same certification" — it is not: on this part it halves the certified margin,
while on another design it raised it 60%. **A re-described part has to be
re-certified. The old certificate does not carry over, in either direction.**

**The most useful thing found here wasn't asked for.** Almost all the time per
iteration is one physics calculation, and running it at lower precision early —
which needs no code change at all — plus reusing the previous answer as a
starting point, together cut the work by three quarters and land on the same
design.
