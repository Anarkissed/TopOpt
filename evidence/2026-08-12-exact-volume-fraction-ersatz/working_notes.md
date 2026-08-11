# working notes — the problems, written down AS THEY HAPPENED

ARM 2's brief is explicit that its input is the list of things that went wrong
while ARM 1 was built, not a list of interesting ideas. This file is that list,
kept while the work was going on. The handoff's §7 is built from it and adds
nothing that is not here.

---

## P1 — the bar and the seed are on an OPEN branch whose base predates PR 325

The brief says "SAME SANDBOX as PR 324/325/326" and R5 says one variable changes
from PR 326's re-baseline. PR 326 is `gh pr 326`, **OPEN**, and it branched from
PR 324's merge — before PR 325 shipped the production parametric optimiser into
`core/include/topopt/plsm_*.hpp`. So PR 326's tree does not contain those files,
and `git diff main -- core/include` on a branch taken from PR 326 would show
PR 325's entire production path as DELETED — which is precisely what R6 forbids
reporting.

Branching off PR 326 satisfies R5 and breaks R6. Branching off main satisfies R6
and makes the bar unreproducible.

**Solved by merging PR 326 into main rather than branching from either.** Two
conflicts, both mechanical: PR 325 turned `plsm_basis.hpp` and `plsm_probe.cpp`
into shims over core while PR 326 added functions beside them; both resolved by
keeping both sides. **Verified rather than asserted** — `check_merge.sh` runs
three iterations of PR 326's own re-baseline configuration on the merged tree
and diffs them against PR 326's committed `iterations.csv`. Identical to twelve
digits on compliance, both volumes, the achieved fraction, the offset, the step,
|v|max and lambda.

Cost: about forty minutes. **Solved.**

---

## P2 — the HARD-sampled fraction is piecewise constant in alpha

`f_v` is a count of sample signs, so it jumps by 1/k³ as each sample crosses and
its derivative is zero almost everywhere. The sensitivity S1(c) prescribes is the
derivative of the CONTINUUM quantity `f_v` approximates, not of the number the
solver is handed. **This is exactly the shape of PR 326's P2** — a hard-count
volume constraint with a smoothed derivative — and I hit it one level down.

Three consequences, and the third is the one that could have wasted the run:

1. R4's finite difference cannot be run at one step size. Too small and it
   differences a flat; too large and it leaves the linear regime. **The step is
   swept and the plateau is the answer**, which is why `--frac-fd` runs five
   steps on the volume (free) and two on the compliance (two state solves each).
2. A single-coefficient probe is the worst case, because one coefficient's
   support covers few cut cells and there is nothing for the staircase to
   average over. Random directions that touch every knot average over ~10⁴ cut
   cells and are the clean check. Both are reported.
3. MMA is handed a gradient of a function it is not evaluating. **Partly
   solved**: `--frac-soft` replaces the hard indicator with the exact
   ANTIDERIVATIVE of the quadrature mollifier, so the value and the gradient
   become two facts about one function; it is the same O(1/k) approximation to
   the exact fraction and its ε shrinks like 1/k, so it is not a return to η.
   It is built, finite-differenced and run as its own arm.

---

## P3 — ★ THE OLD GRADIENT IS NOT THE DERIVATIVE OF THE OLD DENSITY EITHER

Writing the new sensitivity made the old one legible for the first time.

`delta = DH_η(φ)·|∇φ|` is the SURFACE measure: `∫ f·DH_η(φ)|∇φ| dΩ → ∫_Γ f dS` by
the co-area formula. But the derivative of a density defined by `ρ_v = H_η(-φ_v)`
is `∂ρ_v/∂α_i = -DH_η(φ_v)·ψ_i(x_v)` — **no `|∇φ|`**. The two agree only when φ
is a signed distance, and PR 326's own P3 measured `‖∇φ‖−1` at 0.35–0.39 rms
through every arm.

So PR 326's `dc` and `dv` are the derivatives of the CONTINUUM shape functional
with respect to a normal motion of the boundary, and the thing MMA is stepping is
the DISCRETE ersatz compliance — and those are two different functions when φ is
not a distance function.

**Measured, not argued.** `--frac-fd` without `--frac` differences PR 326's own
gradient against the functions it is a gradient of, on PR 326's own converged
design. Results in the handoff §4.

Not "solved" — it is a finding about the arm this task's control IS, and the
control is left exactly as PR 326 ran it (R5). Fixing it would have been a second
variable.

---

## P4 — Ψ is built at cell CENTRES and the fraction's derivative needs ψ at the SAMPLES

`∂f_v/∂α_i = -(1/k³) Σ_s δ_q(φ_s)·ψ_i(x_s)`. `Ψᵀ` evaluates ψ_i once, at the
cell centre, and factors it out of the sub-cell sum. Building a Ψ on the sample
lattice is k³ = 64 times bigger — ~57 million non-zeros rebuilt every iteration.

**Solved by scattering instead of projecting**: the knot walk that evaluates φ at
a sample already has the (index, ψ) list, so the sensitivity re-walks it and
accumulates into per-thread coefficient accumulators. Cost is the same order as
the sampling itself. The centre form is kept reachable (`--frac-sens centre`) as
an ablation so the sub-cell ψ is priced rather than assumed to matter.

---

## P5 — ε_q IS A BAND, and S2(b) says name it or do not have it

S2(a) says remove the smoothed Heaviside from the density path entirely; S2(b)
says if something structurally needs a band, keep it and NAME it. The quadrature
of `∫_C δ(φ)ψ_i dx` needs a mollifier, and a mollifier has a width.

**Named: `ε_q`, the QUADRATURE BANDWIDTH.** What makes it not η wearing a hat:

* it appears in NO density — `f_v` is a hard count of sample signs;
* it is `eps_mult · |∇φ| · h/k`, tied to the SAMPLE SPACING, so it shrinks like
  1/k. η is fixed at 2 voxels and shrinks with nothing;
* at `eps_mult = 1` and a locally planar interface the tent is a partition of
  unity along the normal, so the estimator is smooth in α by construction rather
  than by averaging. That is a property of the tent at exactly that width and is
  the reason the tent was chosen over the raised cosine `H_η` differentiates to.

---

## P6 — the PRINTED predicate still reads η, and it is kept ON PURPOSE

`occ`, the printed occupancy, is still `H_η(-φ)` at the cell centre. Everything
that defines the PART reads it: the volume constraint, `printed_voxels`, the F=1
export, the certificate, the mass.

It is kept because `{H_η(-φ) > 0.5} = {φ < 0}` — H is monotone with H(0) = 0.5
exactly, which PR 326 §3(e) both proves and measures — so the printed SET does
not contain η at all. Changing it would have changed what "the part" means and
made the mass column incomparable, which is a second variable.

**The place η is NOT free is the EXPORT**, where the field VALUES set where
marching cubes puts a vertex. That is a separate axis, and it is measured as one:
`--frac-export` emits the same design as a volume-fraction field beside the H_η
one.

---

## P7 — the volume bisection would have re-sampled 100 times per iteration

`solve_offset` bisects `volume_at(offset)` ~100 times. If the constrained
quantity were the fraction, each of those would re-sample every active cell.

**Solved by NOT moving the constraint** (P6): the constraint stays on the centre
predicate, which is unchanged, so the bisection costs exactly what it cost in
PR 326 and the sub-cell sampling happens ONCE per iteration, after the offset has
been folded into α. `build_fields` refuses a non-zero offset under `--frac` so
this cannot be broken later by someone who does not know why.

---

## P8 — the sensitivity's OTHER consumers were not rewritten

`--robust` reads the objective's band on the ERODED surface (PR 326's P7);
`--plsm-hilb` extends the velocity by a solve on the VOXEL field; the descent and
L-BFGS branches consume `g = Ψᵀv`. None of those carries a sub-cell ψ.

**Not solved — REFUSED.** Each combination exits with a message saying which
quantity would be inconsistent. A density and a sensitivity that describe
different objects is the single most likely way this run is wasted, and PR 326's
P7 is the precedent: a mis-localised sensitivity produces a converged arm
reporting "the mechanism does nothing", which is believable and wrong.

---

## P9 — the export convention is a SECOND substitution, and the density change does not touch it

Changing what the solver sees does not change what marching cubes is handed. The
brief's two headline questions — CAD error and midpoint share — are questions
about the EXTRACTED SURFACE, and the extracted surface is built from the exported
field, not from `ρ_e`.

**Handled by measuring it as its own axis** rather than folding it in: the same
design is emitted both ways and both are measured, so "the optimiser walked
somewhere better" and "the export carries more sub-voxel information" are
separable. ★ And the PREDICTION is written down in `frac_ersatz.hpp` before the
measurement: a volume fraction SATURATES within about a half-cell of the
interface where `H_η` at η = 2 voxels ramps over four voxels, and PR 324 §3's
band control showed a narrow band MANUFACTURES a staircase. So the more faithful
field may well be the worse one to hand marching cubes.

---

## P10 — this host was running another worktree's optimiser throughout

`ps` shows a `levelset_probe` from `.claude/worktrees/lattice-page-core-hookup-…`
running for the whole of this task. Every wall clock here is measured under that
contention. PR 326's P10 said the same thing and this repository has measured the
host's run-to-run offset directly
(`evidence/2026-08-09-reference-implementation-bakeoff/host_contention.txt`).

**Stated, not fixed.** The designs are deterministic and no conclusion rests on a
wall clock; the fraction's per-iteration cost is reported as a SHARE of the
iteration it sits in, which is the ratio the brief asks for and is far less
sensitive to contention than either number alone.

---

## P11 — the binary changed between two finite-difference arms

`--frac-aniso` was added while `run_fd.sh` was mid-flight, so the control arm ran
on a binary that lacked it. The added code is a separate, default-off block and
cannot execute in the control, but "cannot" is how a comparison becomes a claim.

**Solved by re-running the control on the final binary** so all four rows come
from one build. Cost: nine minutes.

---

## P14 — ★★ MY BANDWIDTH USED THE WRONG NORM, AND THE LITERATURE FOUND IT, NOT ME

P5 named `eps_q` and justified it with a partition-of-unity argument: at
`eps_mult = 1` the tent's half-width equals the sample spacing in phi, so
`SUM_m (1 - |t - m*D|/D)/D = 1/D` exactly and the estimator is smooth in alpha by
construction.

★ **THAT ARGUMENT IS EXACTLY RIGHT FOR AN INTERFACE WHOSE NORMAL IS A GRID AXIS,
AND ONLY THEN.** Along an axis the k³ samples project onto the normal at exactly
the axis spacing and the tent tiles. For an OBLIQUE interface they do not, the
tent does not tile, and the error does not vanish with refinement. I wrote the
axis-aligned case, checked it, and generalised it without noticing that the check
had used the one orientation where the two norms agree.

★ **Engquist, Tornberg & Tsai (JCP 207(1):28-51, 2005) prove precisely this and
give the fix.** Their closed-form counterexample is a straight line at 45
degrees, where the narrow hat at `eps = h` leaves a **12.1% error that does not
decrease with h** — the implicit mollifier `delta_eps(phi)` scaled by
`|grad phi|_2` is **NOT CONVERGENT** in two or more dimensions. Scaling by the
**L1** norm instead,

    eps_q = eps_0 * (h/k) * (|phi_x| + |phi_y| + |phi_z|)

makes it first order. Their Theorem 4 is why it is the right norm and not a tuned
one: for a plane orthogonal to a relatively prime `(p,q,r)`, the hat of
half-width `(p+q+r)/sqrt(p^2+q^2+r^2)` sample spacings gives the **EXACT** area,
invariant under translation of the interface relative to the lattice. That ratio
IS `|n|_1 / |n|_2`.

The two norms coincide on an axis-aligned interface and differ by up to `sqrt(3)`
on a diagonal one, so my choice was systematically NARROW — worst on exactly the
oblique surfaces this part is mostly made of.

★ **This is what ARM 2 is for and it is the clearest example of it in this task:
a thing I built, could not see was wrong, and that a specific paper had already
solved.** Implemented as `--frac-eps-l1`, defaulting OFF so ARM 1's arithmetic is
unchanged by inspection, and finite-differenced against the L2 version on the
same design with the same probe. §5 M5.

---

## O1 — ★ AN OBSERVATION THAT FELL OUT OF R4 AND IS NOT A PROBLEM AT ALL

`--frac-fd` evaluates the density and the compliance on ONE design before it
differences anything, so running it twice on PR 326's re-baseline — once with
`H_eta`, once with the fraction — prices the two ersatz models against each other
on the SAME geometry, with no optimiser between them. Both runs solve the same
offset (the volume constraint is unchanged), so the φ is identical.

| on PR 326's re-baseline at iteration 60 | material in the ACTIVE region | compliance |
|---|---|---|
| the printed set `#{phi < 0}` (75,415 − 40,216 frozen) | 35,199 | — |
| `H_eta`, eta = 2 voxels — PR 326's ersatz | **35,325.3** | 0.0025130525 |
| ★ the exact volume fraction | **34,959.5** | 0.0025401228 |

★ **THE SMEARED ERSATZ CARRIES 365.8 VOXELS OF MATERIAL THAT ARE NOT THERE —
1.05% of the region the optimiser owns — AND IS 1.08% STIFFER FOR IT.**

★ **And it is a BIAS, not a rounding.** `H_eta` is antisymmetric about a PLANE
interface, so on a flat boundary the smearing cancels exactly and the error is
zero. It only fails to cancel where the surface is CURVED — and the sign says it
ADDS material. **A more branched design has more curvature and is therefore
credited with more phantom material and more phantom stiffness.** The volume
constraint counts the printed set and never sees any of it, so the phantom is
free.

That is a mechanism by which the smeared ersatz REWARDS exactly the fine
branching PR 326 spent a task trying to suppress. It is an observation, not a
proof that removing it fixes the surface — §3's arms are what say that — but it
is the first quantitative reason to expect the change to move the surface at all,
and it was not part of the brief's reasoning.

---

## P13 — ★ THE HARD FRACTION HAS NO SMALL-STEP FINITE DIFFERENCE, AND I NEARLY READ THAT AS A BUG

The first `--frac` finite difference came back at **+182%** on the volume, at
step 1e-3. On the H_η control the same probe reads 0.46% at the same step. For
about ten minutes that looked like a broken quadrature.

★ **IT IS P2, ARRIVING.** `f_v` is a count of sample signs, so `V(α)` moves in
steps of 1/k³ = 1/64 of a voxel. At step 1e-3 the predicted change is 0.37
voxels — about 24 samples — and the observed one was 67. The FD is not measuring
a derivative there; it is measuring the difference of two staircases.

★ **AND THE STEP SWEEP IS WHAT SAYS SO, WHICH IS THE REASON IT EXISTS.** On one
random direction:

| step | 0.001 | 0.01 | **0.1** | 0.3 | 1.0 |
|---|---|---|---|---|---|
| dV rel err | +182% | −17.6% | **−2.0%** | +6.8% | +19.5% |

That is the textbook shape — quantisation-dominated below, truncation-dominated
above, a minimum in between — and the minimum is the answer. **The volume
sensitivity is verified to 2%.** A single step size would have produced one
number and no way to know which of the three regimes it came from.

★ **WHAT IS *NOT* SETTLED BY IT: the COMPLIANCE finite difference.** Two state
solves cost about a minute, so only two steps carry one, and at both of them the
hard fraction's compliance FD is still quantisation-dominated (−34% at 1e-2,
−25% at 1e-1 — moving, not converged). **The H_η control's is not**: it reads
+10.6% and +10.5% at the same two steps — a CONSISTENT offset, which is a
gradient error and not noise, and is P3 measured.

**Discriminated rather than argued**: `--frac-soft`'s value function is smooth,
so if ITS compliance FD lands on the prediction with the same quadrature and the
same scatter, the quadrature and the scatter are right and the hard variant's
residual is entirely the staircase. That arm is run for exactly this reason.

---

## P12 — 120 iterations is a change from PR 326, and it applies to BOTH arms

The brief asks for margin convergence, not compliance convergence. PR 326 §2
measured every unsettled arm still climbing in margin at iteration 60 — the
re-baseline by 26.7% between 40 and 60 while its compliance moved 0.05% — and its
§9 ranks running longer as the top item. Sixty iterations is known not to reach
what the brief asks for.

**Declared under R5 rather than slid in**: 120 iterations is applied to BOTH
arms, so it is not a variable between them, and the settling iteration is
reported as a number rather than assumed.
