# levelset-match-the-reference

Evidence: `evidence/2026-08-09-levelset-match-the-reference/` — `./reproduce.sh`
regenerates all of it, and nothing is cloned to do so.

## 0. THE FOUR NUMBERS

All five differences landed. Four of the five things they were supposed to fix
got better, the one the task was named for got worse — and then reading the
paper found **why**, and most of it back.

Rung 0.68, his part, fingerprint `d9fe8f768331`, **3 threads throughout**. The
SIMP baseline was RE-MEASURED at 3 threads rather than quoted from PR 321/322,
because a 3-thread level set beside a 6-thread SIMP is not a comparison. It
reproduces PR 321's production run bit-for-bit in compliance, CG count and every
certified number, so it is that run re-timed, not a re-implementation.

| | SIMP (3 thr) | run of record | **best operating point** | PR 322 (6 thr) | Gridap |
|---|---|---|---|---|---|
| | | s2, converged | **s6 @ it 20** | | |
| **cut roughness (deg)** | 7.5521 | 13.0156 (+72.3%) | **8.3451 (+10.5%)** | 6.7080 (−11.2%) | 4.0156 (−46.9%) |
| whole-mesh roughness | 8.4075 | 10.7063 (+27.3%) | **8.6894 (+3.4%)** | — | — |
| **midpoint fraction** | 85.28% | **60.96%** | **66.60%** | 72.82% | 7.20% |
| **margin worst case** | 3254.36 | 3405.33 (+4.6%) | **3400.31 (+4.5%)** | 3378.49 | not certified |
| **verdict** | ACCEPTED | ACCEPTED | **ACCEPTED** | ACCEPTED | — |
| min-feature violations | 5464 | 5194 | **4731** | — | 4547 |
| CAD amplitude (mm) | 0.4293 | 0.4657 | 0.4640 | 0.4489 | 0.7080 |
| **s / iteration** | **11.281** | 22.206 (1.97x) | 24.075 (2.13x) | 25.09 | 277.73 |
| **iterations** | 27 | 76 (converged) | **20** | 120 (did NOT) | 3 |
| total wall, the rung | 304.6 s | 1687.6 s (5.54x) | **481.5 s (1.58x)** | 3010.5 s | 1110.9 s |
| achieved vf (printed) | 0.679951 | 0.674962 | 0.678226 | 0.681319 | 0.774451 |

**1. It CONVERGED — 76 iterations, then 43 once the parameters were right.** PR
322 ran 120 and never converged; this hits the shipped MMA plateau rule. Per rung
the cost fell from PR 322's 8.19x SIMP to 5.54x, and to **1.58x at the operating
point below**.

**2. The margin went UP and stayed up.** 3400-3405 against SIMP's 3254 across
every converged arm, VERDICT ACCEPTED, on *less* material. Peak von Mises is
below SIMP's. This is not bought with strength.

**3. Sub-voxel placement is the best any of our own arms has reached** — 60.96%
edge-midpoint crossings against SIMP's 85.28% and PR 322's 72.82%.

**4. ★ THE CUT SURFACE GOT ROUGHER — 13.0156 against SIMP's 7.5521 — AND TWO
THINGS FIXED MOST OF IT.** §4 is the decomposition, §5 is the parameter-transfer
error that reading arXiv 2405.10478 exposed, and §6 is the stopping rule, which
is the larger of the two and the one worth acting on.

★ **THE ONE-LINE RESULT: stop at iteration 20 and the level set matches SIMP's
surface to +3.4% whole-mesh while carrying +4.5% margin, 19 points better
sub-voxel placement, and 1.58x SIMP's cost per rung.** Margin SATURATES at
iteration 20; the remaining 23 iterations to the compliance plateau buy +0.02%
margin and cost 16% roughness. The stopping rule, not the method, was spending
the surface.

### the differences, one line each

| # | difference | implemented? | where |
|---|---|---|---|
| 1 | ★★★ surface delta `DH_η(φ)·\|∇φ\|` on the compliance AND volume terms | **YES** | `dheaviside()`, `grad_mag()`, `delta[]` |
| 2 | ★★ linear ersatz (no SIMP penalty) on the trajectory | **YES** | `traj_params.penalty = 1.0`; certification untouched at 3 |
| 3 | ★★ six HJ steps per solve, γ = 0.1 | **YES** | `--hj-steps 6 --gamma 0.1` |
| 4 | ★ Hilbertian velocity extension, Dirichlet on the load set | **YES** | `hilbertian_extend()` |
| 5 | ★ η = 2 voxels | **YES** | `--eta 2.0` |
| — | γ_reinit = 0.5, their reinit tolerance 0.00645 | **NO — nothing to apply to** | §3 |
| — | true Augmented Lagrangian | **NO — kept PR 322's λ + offset, as permitted** | §3 |
| **6** | ★ **their γ oscillation damper — A SIXTH DIFFERENCE THE FIVE MISSED** | **YES**, added after the run of record | `has_oscillations()`, `--damp` |

★ **And a seventh thing, which is not a difference but an error in transferring
one: their rule for α does not survive contact with a slab.** §5. It came from
reading the paper rather than the transcription of it, and it is worth more than
any of the five.

## 1. what was built

The same `EXCLUDE_FROM_ALL` sandbox target as PR 322,
`core/tests/harness/levelset_probe.cpp`. **`git diff main -- core/src
core/include app/` is EMPTY** (R4) — the entire change is one file under
`core/tests/harness/`, and this time not even a CMake line, because the target
already existed.

It still writes no FEA: `simp_compliance` runs every state solve,
`analyze_fixed_design` the certification, `build_production_loadcase` supplies
the grid, tags, clamped DOFs and loads.

### the defect PR 322 had that only difference 1 could expose

PR 322 held the volume correction as a scalar `offset` and read the ersatz at
`φ + offset`. That is harmless while the velocity is a volume field. It is fatal
once difference 1 concentrates the velocity at the interface:

* the interface is `{φ = −offset}`, and the surface delta puts ALL of the
  velocity there, so `{φ = 0}` is the one surface that barely moves;
* reinitialisation re-distances about `{φ = 0}` — it pins the band around φ's own
  zero set — so every iteration **rebuilt φ from the surface that had not been
  advected and discarded the motion at the surface that had**.

Measured on a 3-iteration smoke run before the fix: `offset_mm` sat at +3.57,
+3.58, +3.58 mm instead of shrinking, and the achieved volume fraction moved
0.0017 in three iterations. The fix is to ADD the offset into φ, which is exact
(a signed distance plus a constant still has |∇φ| = 1) and is the structure the
reference has, where there is no offset at all. After it, the offset collapses to
−0.03 mm on iteration 2 and **compliance falls about 3x faster per iteration**.

Anyone re-reading PR 322 should know its trajectory carried this.

## 2. R5 — what was implemented, and where

### (1) ★★★ the surface delta — IMPLEMENTED

`dheaviside()` is their `DH_η(t,η) = 1/(2η)(1 + cos(π t/η))`, and it is literally
the derivative of the `heaviside()` this file already had, so there is ONE
smoothing law in the program rather than two. `grad_mag()` is their
`norm ∘ ∇φ`, central differences, one-sided against a box face.

    delta[v] = DH_η(φ) · |∇φ|
    v        = (energy − λ) · delta

Their volume sensitivity `dVol = ∫ −1/vol_D · q · (DH∘φ)(norm∘∇φ)` carries the
identical factor and differs from the compliance term only in replacing the
energy density by a constant — so the factor comes out front and one multiply
implements both, which is why the code has one `delta` and not two.

λ is now the **delta-weighted** mean energy, the unique multiplier for which
`∫(e − λ)·DH·|∇φ| = 0`. PR 322's was a flat mean over a two-voxel band, which is
the wrong measure once the delta exists.

### (2) ★★ linear ersatz on the trajectory — IMPLEMENTED

`traj_params.penalty = 1.0`. Core's own law is `E(rho) = clamp(rho,ρ_min,1)^p·E0`,
so at p = 1 it is `rho·E0`; our rho is already `ϵ + (1−ϵ)·occ` with
`ϵ = ρ_min = 1e-3`. That IS their `I(φ) = (1−H(φ)) + ϵH(φ)`, not an approximation
of it.

★ **The certification is unchanged.** `params` (penalty 3) is built first, never
modified, and is what `analyze_fixed_design` receives, isolated exactly as
production isolates a re-certification. The trajectory law and the certification
law differ deliberately. The consequence, stated so nobody has to infer it: **the
trajectory compliance this run prints is on a different material law from SIMP's
and from PR 322's and the three are NOT comparable.** The margin, the roughness
and the volume are, because they are measured on the geometry.

### (3) ★★ six HJ steps per solve — IMPLEMENTED

`dt = γ·h/max|v|` computed once from the velocity field (a function of the state
solve, which is not repeated), then six advection steps with the Godunov gradient
**re-evaluated at the new φ each sub-step**.

Honest arithmetic, because the task's framing overstates it: six steps at γ = 0.1
is 0.6·h/max|v| of travel against PR 322's single step at CFL 0.4 — **1.5x the
distance per FEA solve, not 6x**. What the six buys is that the motion is
resolved in six stable sub-steps rather than one large one, and on the evidence
of §0 that is what the convergence came from.

### (4) ★ Hilbertian velocity extension — IMPLEMENTED

`hilbertian_extend()`: Jacobi-preconditioned CG on the 7-point screened Poisson
`(I − α²∇²)v̄ = g`, α = 2.4 voxels (`α_coeff = 4·max_steps·γ`), to rtol 1e-12 as
theirs. Converged in 108-112 iterations every iteration of the run and cost
**0.244 s of a 22.2 s iteration — 1.1%**. Homogeneous Dirichlet `v̄ = 0` on the
FrozenSolid set, which on his job is exactly the load pad, the anchor (face 18)
and the face protection (face 16): all three the task names, in one set.

Stated rather than hidden: this is a **collocation** reading — the right-hand
side is `g` at the cell, not the consistent FE load vector `∫gw` — so it differs
from theirs by a mass-matrix scaling. It cannot reach the trajectory, because the
only use of v̄ is a direction plus a CFL step `dt = γh/max|v|` that normalises its
amplitude away exactly. PR 322's `[1 2 1]` passes stay reachable via
`--alpha-coeff 0`.

### (5) ★ η = 2 voxels — IMPLEMENTED

`--eta` default 2.0, their `η_coeff`, so H_η spans [−η,+η] and the transition is
four voxels wide.

## 3. what could NOT be made the same — a finding, not a failure

**γ_reinit = 0.5 and their reinit tolerance `1/(5·order²)/min(el_size)` = 0.00645
have nothing in our scheme to apply to.** Both are parameters of a
reinitialisation-by-PDE: they integrate a second Hamilton-Jacobi equation to
steady state. Ours is fast sweeping, a direct Eikonal solve with no time step and
no iteration count to tune. Rather than transplant a number that does not exist
here, the run **measures the property both schemes are reaching for**:
`reinit_rms` in `iterations.csv` is `rms | |∇φ| − 1 |` over the band. It ran
0.171 at iteration 1 to **0.201** at 76.

★ Read the RMS, not the max, and the reason is not convenience. The exact signed
distance function of any solid has kinks on the medial axis, where the nearest
boundary point changes discontinuously and the discrete central difference of
|∇φ| is 0 — an error of exactly 1. This part's thinnest members sit near the
minimum feature size, so their medial axes lie INSIDE the two-voxel band and the
max is pinned at 1.0 by geometry that is CORRECT (measured: 0.996 at the end). A
statistic that saturates on the right answer measures nothing.

**Their optimiser is a true Augmented Lagrangian.** This kept PR 322's
mean-band-energy λ plus offset bisection, which the task permits if (1)-(4) land.
λ is taken under the delta measure now (§2), which is the part of their
constraint sensitivity that actually bites.

## 4. WHY IT GOT ROUGHER — the account, not a guess

The roughness curve is the finding, and it is not monotone:

| iteration | 1 | 10 | 20 | **30** | 40 | 50 | 60 | 70 | 76 |
|---|---|---|---|---|---|---|---|---|---|
| cut roughness (deg) | 9.72 | 8.79 | 8.42 | **8.22** | 8.55 | 9.89 | 11.66 | 12.61 | **13.02** |
| whole mesh (deg) | 9.17 | 8.91 | 8.71 | **8.62** | 8.75 | 9.25 | 10.01 | 10.49 | **10.71** |
| CAD (deg) | 7.50 | 7.65 | 7.59 | 7.59 | 7.66 | 7.66 | 7.68 | 7.69 | 7.70 |
| cut share of triangles | 36.2% | 34.3% | 34.3% | 34.5% | 35.2% | 36.5% | 38.1% | 39.2% | 39.7% |
| midpoint fraction | 69.4% | 68.8% | 67.0% | 67.1% | 66.4% | 65.0% | 63.1% | 61.6% | 61.0% |

Three things this says, and one it kills.

**(a) The CAD surface is untouched — 7.50 to 7.70 deg across the whole run,
against SIMP's 7.5842.** Everything that happened, happened on the CUT surface.
That is the right place for a shape optimizer to act and it is worth knowing the
level set is not damaging the surfaces that have a CAD reference.

**(b) About 2.2 deg of the gap is the REPRESENTATION, and it is there at
iteration 1** — before the optimizer has moved anything of consequence.
Reinitialising the SIMP seed to a signed distance and reading it through the η=2
ersatz gives 9.72 deg where SIMP's own field gives 7.55, and reclassifies half
again as many triangles from CAD to CUT (18.4% → 36.2%). The band is not free.

**(c) The remaining ~4.8 deg accumulates after iteration 30, and it tracks the
cut share.** From iteration 30 to 76 the cut share rises 34.5% → 39.7% and the
roughness 8.22 → 13.02, while the compliance improves only 1.1%. **The design is
growing fine internal structure, and nothing in this formulation limits feature
scale except α.** §5 stops this being a story: the paper says so in its own
words, and two arms test it.

**(d) ★ IT KILLS PR 322's STATED NEXT STEP.** PR 322 §4 argued the shortfall was
sub-voxel content and that widening η would grow the win: "the mechanism column
predicts the roughness win grows … it is a one-argument change." **Widening η
delivered exactly the sub-voxel content it predicted and the roughness went the
wrong way.** Midpoint fraction improved decisively (72.82% → 60.96%) and
fractional-sample count is comparable, yet the surface is rougher on every
population at every point in the run. Sub-voxel content and dihedral smoothness
are not the same axis — which is PR 319's coherence lesson arriving from the
other side.

### two things that are NOT the explanation, because they were checked

**The ersatz band is not softening the certificate.** Re-certifying the same
final design with the field thresholded to binary at the iso gives margin
**3400.87 against the banded 3405.33 — 0.13%**, same verdict, min-feature 1576
against 1578 (`s4_recert_binarized/recert.txt`). The margin is a property of the
design, not of the four-voxel band it is read through.

**The extraction is more faithful, not less.** Our mesh encloses 371131.0 mm³
against a printed-voxel volume of 371204.4 mm³ — a ratio of **1.000**. SIMP's
encloses 440550.9 mm³ against 373948.2 mm³ — **1.178**. A nearly-binary field put
through the shipped tricubic factor-2 resample inflates and rounds; a smooth one
does not. Part of SIMP's 7.5521 is that resample acting as a smoother on a
staircase, and this comparison has carried that since PR 306 without anyone
naming it. It does not rescue our number — Gridap's smooth field got 4.0156 — but
it means the 7.5521 baseline is not a neutral yardstick.

## 5. ★ THE PARAMETER RULE DOES NOT SURVIVE CONTACT WITH A SLAB

This section exists because the paper was read, not just the brief's
transcription of it. arXiv 2405.10478 is right about α, and the brief's
arithmetic from it is right, and the result is still wrong for this part.

### what the paper actually says

On the inner product (their Eq. 5):

> ⟨u, v⟩_H = ∫_D (α²∇u·∇v + uv) dx, where α is the so-called **regularisation
> length scale**

and on how to pick it (§4.1.6):

> α = 4·max_steps·γ·maximum(get_el_Δ(model))
> "This ensures that as the mesh is refined and max_steps increased, **the number
> of elements over which we regularise the gradient is increased**."

with (Appendix B line 18, and §4.1.10 for the 3D doubling):

> max_steps = floor(order·minimum(el_size)/10)
> "we double the number of max_steps … as we have found that this yields better
> convergence for three-dimensional problems"

**There is no perimeter term and no feature-size constraint anywhere in the
paper.** α is the ONLY thing in the formulation that limits how fine the
structure can get, and the authors name it as such.

### the arithmetic, and where it breaks

γ = 0.1, so the regularisation length in VOXELS is just `0.4 · max_steps`:

| | mesh | min(el_size) | max_steps | **α, in voxels** |
|---|---|---|---|---|
| their 2D example | 200 × 200 | 200 | 20 | **8.0** |
| their 3D example | 150 × 150 × 150 | 150 | 30 | **12.0** |
| **his part** | 128 × **31** × 118 | **31** | 6 | **2.4** |

**Their own 3D example regularises the velocity over 12 voxels. We regularised
over 2.4 — five times less.**

`minimum(el_size)` is standing in for MESH REFINEMENT. On their cubic meshes the
smallest axis IS the resolution and the proxy is exact. His part is a 4:1 slab,
so the rule reads the THIN axis and returns a regularisation length sized for a
31³ mesh — on a mesh with fifteen times the elements of one. The brief's
α_coeff = 2.4 is a correct evaluation of their formula; the formula is what does
not transfer.

★ This is executable, not a comment. `--gridap-auto min|max` evaluates their rule
on the actual grid and prints the derivation. **`min` is a positive control: it
must return max_steps 6 and α 2.4, i.e. reproduce the run of record's parameters
from the paper's own formula.** It does (`s6_gridap_auto_min.txt`). `max` keys the
same formula to the resolution axis — 24 steps, α 9.6 voxels, inside their own
8-12 range — with the coupling α = 4·max_steps·γ·h preserved, so it is their rule
with one substitution and not a tuned number.

### the sixth difference: their γ damper

Also in the paper, and not in the brief's five (§4.1.8):

> "We slightly modify the method to include a check for oscillations of the
> Lagrangian using the `has_oscillations` function. If oscillations are detected
> we **reduce the CFL number γ** for the Hamilton-Jacobi evolution equation
> **by 25%**."

Our γ was fixed at 0.1 for every iteration of every run above. `--damp` adds it.

★ **It is an equivalent, not a transcription, and it took two attempts.** Theirs
reads the AUGMENTED LAGRANGIAN, which we do not carry. Mine reads the objective
we do. The first cut counted sign flips only, and fired on every window — γ
annealed 0.1 → 0.075 → 0.05625 → 0.042 inside twenty iterations, which would have
frozen the design short of its fixed point and let the compliance plateau test
report that as "converged": a wrong number wearing a right one's clothes. The
trajectory it fired on was a noisy DESCENT (0.0025450 → 0.0025402 across the
window, rippling ±0.2% on the way), and a Lagrangian that is still descending is
not oscillating. The trigger now requires **no net progress across the window AND
at least two sign changes**. Replayed against the aborted run's own history: the
old trigger fires, the new one stays quiet, and the window's net change was
−5.4e-6. That run was discarded and re-run.

Their stopping rule also differs from ours and neither is obviously better: they
test the augmented Lagrangian over a 5-window, we test compliance over a
10-window at 1e-3.

### the arms: alpha is a real, monotone lever

Three arms, one instrument, one invocation of `external_field_surface_probe`
carrying its own four SIMP baseline rows (`s3_levelset_vs_simp.csv`).

| arm | alpha (voxels) | HJ steps | damper | iterations | cut (deg) | whole (deg) | midpoint | margin |
|---|---|---|---|---|---|---|---|---|
| SIMP | — | — | — | 27 | 7.5521 | 8.4075 | 85.28% | 3254.36 |
| s2 — their rule as written | 2.4 | 6 | — | 76 | 13.0156 | 10.7063 | 60.96% | 3405.33 |
| **s5 — alpha ALONE** | 8.0 | 6 | — | 68 | **10.9833** | 9.7247 | 63.57% | 3404.00 |
| s6 — corrected + damper | 9.6 | 24 | 3 fires | 43 | 9.6572 | 9.1614 | 64.71% | 3401.08 |

**s5 is the clean single-variable test — only alpha moved — and it recovers 2.03
deg of the 5.46 deg regression, 37% of it.** s6 adds the corrected max_steps and
the damper and reaches 9.66, 61% of the way back, in 43 iterations instead of 76.
The margin does not move across any of it (3401-3405), so none of this is bought
with strength, and the min-feature count falls monotonically with alpha
(1578 -> 1118 -> 864 by `analyze_fixed_design`'s count) — an independent measure
that is not the roughness metric restated.

alpha is therefore a real lever and the diagnosis was right. It is also **not
enough**: at their own 3D value we would still be above SIMP. The rest is §6.

## 6. ★ THE STOPPING RULE IS SPENDING THE SURFACE

Every arm's roughness has a MINIMUM early and then climbs, and higher alpha both
lowers the minimum and reaches it sooner:

| arm | best cut roughness | at iteration | at convergence |
|---|---|---|---|
| s2 (alpha 2.4) | 8.2247 | 30 | 13.0156 (it 76) |
| s5 (alpha 8.0) | 7.9247 | 30 | 10.9833 (it 68) |
| s6 (alpha 9.6) | **7.8448** | **10** | 9.6572 (it 43) |

So the optimiser walks past its own best surface and keeps going. The question is
what those extra iterations buy, and the answer is: **after iteration 20, nothing
that is certified.** Each row below is `analyze_fixed_design` at the production
penalty on that iterate, run from the snapshot on disk (`s7_early_stop/`):

| s6 iterate | cut (deg) | whole (deg) | **margin** | min-feature (probe) | min-feature (`analyze`) |
|---|---|---|---|---|---|
| SIMP | 7.5521 | 8.4075 | 3254.36 | 5464 | — |
| it 10 | 7.8448 | 8.5180 | 3027.91 | 4701 | 691 |
| **it 20** | **8.3451** | **8.6894** | **3400.31** | **4731** | **663** |
| it 30 | 8.9332 | 8.8848 | 3400.29 | 4785 | 758 |
| it 43 (converged) | 9.6572 | 9.1614 | 3401.08 | 4903 | 864 |

Two min-feature columns because they are two different instruments and must not
be read as one: `external_field_surface_probe`'s count is on the extracted mesh,
`analyze_fixed_design`'s is on the voxel field. SIMP's `analyze` count was not
re-measured in this task, so that cell is empty rather than filled from PR 322's
remembered 5619. Both columns move the same way.

★ **The margin saturates at iteration 20 and is FLAT to convergence — 3400.31,
3400.29, 3401.08. The 23 iterations from 20 to 43 buy +0.02% margin and cost 16%
cut roughness.** They also cost 55% of the rung's wall clock.

At iteration 20 the level set is:

* **+3.4% whole-mesh roughness against SIMP** (8.6894 vs 8.4075), and +10.5% on
  the cut population;
* **+4.5% margin** (3400.31 vs 3254.36), ACCEPTED, on less material;
* **19 points better sub-voxel placement** (66.60% edge-midpoint crossings
  against SIMP's 85.28%);
* **13% fewer min-feature violations** than SIMP (4731 vs 5464) by the probe's
  count;
* **1.58x SIMP's cost per rung** (481.5 s vs 304.6 s), against the run of
  record's 5.54x.

That is a defensible operating point and it is one number away from the shipped
ladder: the trajectory is stopped by a COMPLIANCE plateau, and compliance is not
what this part is certified on. Margin is. A rule that stopped on margin
saturation instead would have found iteration 20 by itself.

★ **This is the finding to act on, and it is bigger than alpha.** alpha bought
back 37% of the regression; stopping at the right iteration buys back 76% of what
remains, and it costs nothing — it is strictly less work.

### the honest caveats on it

**It is not a free win against SIMP, and iteration 10 shows why.** At iteration 10
the surface is essentially SIMP's (7.8448 cut, 8.5180 whole) but the margin is
3027.91 — 7.0% BELOW SIMP. Roughness and margin move in OPPOSITE directions along
the trajectory, so "as smooth as SIMP" and "stronger than SIMP" are available at
different places on it. Iteration 20 is where margin has arrived and roughness has
not yet left; it is a knee, not a free lunch.

**Iteration 20 was found by reading a curve, not by a rule.** Nothing here
proposes a margin-saturation stopping criterion, tests one, or knows whether the
knee sits at iteration 20 on any other rung or part. It is one part, one rung.

**Only the s6 trajectory was certified per-iterate.** s2's and s5's knees were not
re-certified; their roughness curves are measured but their per-iterate margins
are not.

## 7. what this does and does not settle

**Settled.** The five differences are implementable on our solver at 1.97x SIMP
per iteration and 5.54x per rung, they converge where PR 322 did not, and they
certify better than both SIMP and PR 322 on less material. Difference 4 costs
1.1% of an iteration. None of that was known before.

**Not settled — and this is the honest headline: the task's premise did not hold.**
The premise was that these five differences were the gap between our 11.2% and
Gridap's 46.9%. They are not. Implementing all five moved us from 11.2% BETTER
than SIMP to 72.3% WORSE, while moving every other number the right way. Whatever
produces Gridap's 4.0156 deg is not on this list.

**Not attributable to one difference.** The task said to change all five together
and not to ablate, and that is what ran, so nothing here says which of the five
carries the roughness regression. §4(b) isolates the part that is present at
iteration 1 (the representation, which is difference 5 plus reinitialisation) from
the part that accumulates later (feature scale, which §5 tests) — but that is a
decomposition in time, not an ablation.

**Only rung 0.68, only a SIMP seed.** As PR 322. Nothing here says the level set
holds its margin at 0.52, 0.38 or 0.26, and it never had to survive a severed
load path.

**The volume target is met on the occupancy measure, not the printed one.** The
achieved printed vf is 0.674962 against a requested 0.68 — a 0.7% undershoot,
where SIMP lands on 0.679951. The bisection holds the *occupancy* integral
exactly on target (75414.7 every iteration), and with a four-voxel band the
occupancy and the printed count diverge. This is the same convention
GridapTopOpt's volume constraint uses, and it is conservative on mass, but it
means our margin is measured on slightly less material than SIMP's.

## 8. in plain language

We were told our own version of a smoothing method was only getting a quarter of
the benefit the borrowed software got, and given five specific things to fix.

**All five were fixed, and four things got better.** It now settles down on its
own instead of running out of budget. It got cheaper. The part came out
*stronger* than our current method, using slightly less material. And the surface
sits between the grid cubes far better than anything we have written before —
which is the actual defect we have been chasing for six attempts.

**But the surface came out rougher, which is the one thing the task was named
for.** So rather than hand that back as a number, we went and read the reference
paper properly instead of the summary of it. Two things came out of that.

**The first is that we had inherited a badly-sized setting.** The method has one
knob controlling how fine the internal structure is allowed to get. The paper
gives a formula for it, and the formula was copied correctly — but the formula is
written for parts that are roughly cube-shaped, and it works by looking at the
*smallest* dimension of the grid. His part is a slab: 128 by 31 by 118. The
formula looked at the 31, decided this was a small job, and set the knob five
times finer than the paper's own three-dimensional example uses. Turning it back
up recovered about a third of the lost smoothness, and we confirmed it is really
that knob by changing nothing else.

**The second is bigger, and it is about when we stop.** The surface is at its
best early in the run and gets worse the longer the optimizer works. Meanwhile
the *strength* — the thing we actually certify the part on — stops improving at
about iteration 20. Everything after that is the optimizer chasing a fraction of
a percent of stiffness while quietly wrecking the finish.

Stop at iteration 20 instead of running to the end and the part is: as smooth as
our current method to within 3%, **4.5% stronger**, with much better sub-voxel
detail, fewer too-thin features, and it takes about one and a half times our
current method's time instead of five and a half. That is a real, usable result,
and it costs nothing — it is less work, not more.

The catch worth stating plainly: this is a trade-off curve, not a free win. Stop
even earlier and the surface matches our current method exactly, but the part
comes out 7% *weaker* than it. Iteration 20 is the knee where the strength has
arrived and the surface has not yet degraded. We found it by looking at a graph
on one part at one weight setting — we have not built a rule that finds it
automatically, and we do not know where that knee sits on a different part.

**And the honest headline: the task's premise was wrong.** The five differences
were supposed to be the gap between our result and the borrowed software's. They
are not. Fixing all five, plus a sixth the list missed, plus the sizing error,
still leaves us short of what the borrowed tool achieved. Whatever explains that
is not on the list we were given.
