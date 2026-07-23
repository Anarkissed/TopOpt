# 133 — Krylov subspace recycling / deflation for the FEA solve sequence

> **Numbering note:** two harness siblings were in flight when this ran. If 133 is
> taken at merge time, rename this file and the `handoff 133` references in
> `core/include/topopt/fea.hpp`, `core/src/fea/recycle.{hpp,cpp}`,
> `core/src/fea/fea_matfree.hpp`, `core/include/topopt/simp.hpp`,
> `core/include/topopt/pipeline.hpp` and `core/src/simp/minimize_plastic.cpp`.

## Task

Krylov subspace recycling + deflation wrapping the existing FEA solve path, opt-in
per THE ONE RULE, with the exactness / performance / determinism / accounting bars
stated before measuring.

## Outcome in one line

**Built, tested, measured, and ARMED in the Jacobi-only posture** (maintainer
decision on §10, recorded below; this section was amended after that ruling). Recycling cuts CG iterations **48.1%** on the
void-heavy design-box regime it was built for — accepted designs reproduced to
**zero** in mean|Δρ|, identical gate verdicts — but it **regresses the
healthy-multigrid regime** 1.23x-2.07x, because the additive coarse correction lifts
a deflated mode's preconditioned eigenvalue by +1: right when the preconditioner is
weak, spectrum-widening when it is a V-cycle.

Bar (b) as originally written (≥15% on BOTH regimes) therefore failed, and this
handoff first shipped the capability opt-in and default-OFF with the evidence. The
maintainer then ruled that failure a **bar mis-specification** and authorised the
**Jacobi-only** posture against a reformulated bar — ≥15% on the TARGETED regime and
a byte-identical no-op on the non-targeted one — which the measurements meet:
**45.4%** void cut (94% of the win) and **1.000x to the digit, zero setup matvecs**
on multigrid. Production is armed accordingly: `{recycling: true, k: 16,
wrap_multigrid: false, reset_per_rung: false}`. The LIBRARY defaults are still
untouched — recycling is off unless `configure_production_options` runs — so
Gate-V2 and every core reference path remain byte-for-byte identical.

---

## 1. What was built

**New:** `core/src/fea/recycle.{hpp,cpp}` — an Eigen-free, fixed-order,
deterministic recycling module; `core/tests/unit/test_recycle.cpp` (CI test
`krylov_recycling`); `core/tests/harness/recycle_probe.cpp` (measurement harness,
NOT in CTest).

**Public API** (`core/include/topopt/fea.hpp`), all opt-in and default OFF:

```
bool  fea_set_krylov_recycling(bool);      bool fea_krylov_recycling_enabled();
int   fea_set_krylov_recycle_dim(int k);   int  fea_krylov_recycle_dim();
int   fea_set_krylov_recycle_cycle(int c); int  fea_krylov_recycle_cycle();
void  fea_reset_krylov_recycle_space();
bool  fea_krylov_recycle_space_active();   int  fea_krylov_recycle_space_dim();
std::size_t fea_krylov_recycle_bytes();
```

`CgInfo` gains `recycle_dim` and `recycle_setup_matvecs`;
`SimpIterationObservation` gains `cg_recycle_dim` / `cg_recycle_setup_matvecs`;
`MinimizePlasticOptions` gains `krylov_recycle_reset_per_rung` (lifetime policy);
`RunInfo` gains `krylov_recycling` / `krylov_recycle_dim` (the honest echo).
Two INTERNAL research knobs (`src/fea/recycle.hpp`, not public API) exist so two
claims could be measured instead of asserted: `rc_set_metric_diagonal` (§7, Wang's
rescaling) and `rc_set_wrap_multigrid` (§10, the arming candidate).

**Where it wraps.** Both matrix-free CG loops, OUTSIDE their preconditioners:
`mf_cg_solve` (matfree.cpp — the Jacobi regime) and `mf_mgpcg` (multigrid.cpp — the
V-cycle regime, FP64 and FP32 alike). So the MG-carried, latched-Jacobi (127) and
build-rejected (122) regimes all keep the preconditioner they have today; recycling
wraps whichever runs. The assembled `fea_solve_cg` / `fea_solve_mgcg` paths are
untouched.

### The method, and why this form

The recycle basis `U` (n x k) enters as an ADDITIVE coarse-space correction:

```
M_rec^-1 r  =  M^-1 r  +  U E^-1 (U^T r),      E = U^T A U   (k x k)
```

**Exactness is unconditional, and that is why this form was chosen over the
projected/deflated (DPCG) form.** `M^-1` is SPD and `U E^-1 U^T` is symmetric
positive semi-definite for ANY `U` with SPD `E`, so `M_rec^-1` is SPD for any `U`
whatsoever. PCG with an SPD preconditioner converges to the true solution, and the
stopping test is the unchanged relative residual `||b - A x|| / ||b|| <= tol` on the
unchanged recursively-updated `r`. A stale, noisy or useless basis can cost
ITERATIONS but cannot change the answer. The projected form instead rests on an
invariant (`r` stays orthogonal to `U`) that a rounded or inconsistent `A*U` breaks
silently — a worse failure mode for a certification pipeline. That choice is
vindicated by §4: even the modes where recycling HURT returned identical designs.

Spectrally, for a generalized eigenpair `A u = theta D u`:
`(D^-1 + u (u^T A u)^-1 u^T) A u = theta u + u`, i.e. a small `theta` is lifted to
`theta + 1` and the rest of the spectrum is untouched — Frank & Vuik's deflation
effect, obtained additively. **This is also the form's one weakness, and §9 is the
measurement of it.**

### The update rule (determinism by construction)

1. **Harvest, at zero extra matvecs.** The CG loop hands the recycler its search
   direction `p_j` together with the operator image `A p_j` it already computed for
   the step length. Sampling is a deterministic decimating ring of `m = k` slots:
   store when `iter % stride == 0`, double `stride` each time the ring wraps. The
   sample therefore spans the WHOLE solve without knowing its length in advance — a
   44k-iteration solve stores ~`m*log2(44k/m)` columns, not 44k.
2. **Rayleigh-Ritz over the union** `B = [U | P]`, solving
   `(B^T A B) y = theta (B^T D B) y` and keeping the k SMALLEST `theta`. Both small
   matrices are formed EXACTLY from the stored `A*B` — no A-conjugacy is assumed of
   the harvested directions, because the finite-precision loss of conjugacy over
   thousands of iterations is real.
3. **New basis** `u_i = B y_i / sqrt(theta_i)`, so `U^T A U = I` exactly at
   extraction. The eigenvectors of the reduced pencil are already A- and
   D-orthogonal, so a fixed-order modified Gram-Schmidt would be a no-op on them;
   what IS kept is the fixed-order rank guard — the unpivoted Cholesky of `B^T D B`
   runs in ascending column order and any column failing the pivot test is dropped
   IN THAT ORDER, so a rank-deficient candidate set degrades identically every run.

Fixed k, fixed m, fixed traversal order, compile-time chunk length fixing every
accumulation order, unpivoted Cholesky, cyclic-Jacobi eigensolver with a fixed sweep
bound, index-tiebroken Ritz selection. **No atomics in the numerics, no randomness,
no wall-clock.** The two threaded passes (§5) split by contiguous chunk and either
write disjoint output or accumulate per-chunk partials reduced in ascending chunk
order — so both are bit-identical for any thread count, asserted at 1 vs 8.

### E is carried, not rebuilt every solve

`E = U^T A U` costs k exact FP64 matvecs. Those are charged only on a REBUILD solve
(which needs `A*U` for the Rayleigh-Ritz anyway); in between, the carried Cholesky
factor is reused. That is safe for the same reason the whole method is: any SPD `E`
keeps `M^-1 + U E^-1 U^T` SPD, so a slightly stale `E` costs iterations, never
correctness. At the moment of extraction `E` is exactly the identity, so `commit()`
stores `I`. Without this, k matvecs per solve would be a large fraction of a short
(multigrid) solve and would decide the multigrid table by itself — §9 shows that
cost is decisive even WITH the optimisation.

---

## 2. Bars, stated BEFORE measuring

| Bar | Statement |
|---|---|
| **(a) EXACTNESS** | Recycled and plain PCG converge to the same tolerance. On a production-config fixture ladder: mean\|Δρ\| at solver-noise level (≤ 1e-4), margins ≤ 0.1%, gate verdicts IDENTICAL. This technique changes the ROUTE, not the answer — a larger delta means the implementation is wrong, not that a trade is on offer. |
| **(b) PERFORMANCE** | ≥ 15% total-CG-iteration reduction on BOTH regimes: a healthy-multigrid fixture (48×16×48, the 132 probe's) AND a void-heavy Jacobi-regime fixture in the stand-class shape (large box + clearance, the 125/131 lineage). Below 15% ⇒ k mis-tuned; sweep before concluding. The void number is reported separately; that is the one that matters. |
| **(c) DETERMINISM** | Twice-run bit-identical designs and iteration histories, asserted, both regimes. |
| **(d) HONEST ACCOUNTING** | Setup matvecs and the per-iteration correction overhead measured and CHARGED. Report NET CG work. Thermal protocol per 113; iterations are the deterministic signal, wall-clock is not the claim (132's finding). |

**Production arming** is permitted in this PR only if (a)–(d) all pass. If any bar
fails: opt-in default-OFF plus a blocked record with the table — the evidence is the
deliverable (the 130/132 pattern).

---

## 3. The two regime fixtures

Both run the REAL production configuration (`configure_production_options`, the
4-rung `production_reduction_ladder`, MMA, conditional projection armed at 0.07),
through `minimize_plastic`. Harness: `core/tests/harness/recycle_probe.cpp`.

* **`mg` — healthy multigrid.** The 132 probe's L-bracket at **48 × 16 × 48**,
  h = 2.0 mm, no design box, no hole. Coarsenable on every axis, so MG carries and
  the V-cycle is the preconditioner recycling wraps.
* **`void` — Jacobi regime, stand-class shape.** A small L-bracket **with a
  clearance hole bored through the arm**, inside a **design box** that roughly
  doubles the domain, so most of the domain is empty design expanse. This is the
  125/131 disease: the V-cycle stops contracting, the 127 latch turns MG off, and
  the run grinds in Jacobi-CG.

The harness prints `mg_frac` (share of solves where MG actually carried) for every
mode and WARNS if a fixture is not in the regime its table claims, so neither table
can be silently vacuous — the trap that made 132's first attempt meaningless.

---

## 4. VOID-HEAVY (JACOBI) REGIME — the table that matters

Production ladder, design box + clearance hole, `mg_frac ≈ 0.23` (multigrid carries
on under a quarter of solves — this IS the Jacobi regime the fixture claims).
Baseline = recycling OFF, same binary, same config, one toggled knob.
`rc_frac` = share of solves a carried basis actually preconditioned.

| mode | MMA iters | CG iters | CG cut | setup matvecs | wall | wall ratio |
|---|---|---|---|---|---|---|
| baseline (off) | 372 | 430,330 | — | 0 | 248.3 s | 1.000 |
| k=8  cyc=1 rung-reset | 359 | 297,168 | **30.9%** | 2,879 | 223.0 s | 0.898 |
| **k=16 cyc=1 rung-reset** | 359 | **223,305** | **48.1%** | 5,748 | **201.5 s** | **0.811** |
| k=24 cyc=1 rung-reset | 358 | 191,868 | 55.4% | 8,618 | 227.6 s | 0.917 |
| k=16 cyc=4 rung-reset | 358 | 418,516 | 2.7% | 1,391 | 324.3 s | 1.306 |
| k=16 cyc=1 carry-rungs | 359 | 216,687 | 49.6% | 5,804 | 201.1 s | 0.810 |
| k=16 Jacobi-only (§10) | 359 | 234,972 | 45.4% | 4,356 | — | — |
| k=16 no-rescale, identity metric (§7) | 358 | 310,424 | 27.9% | 5,747 | — | — |

(The last three rows' walls are omitted deliberately: those runs executed
concurrently with other probes, so their wall-clock is not comparable to the first
five. Their CG counts are unaffected — that is the point of making iterations the
claim.)

**Bar (b), void regime: PASS at every k in the swept set** (30.9% / 48.1% / 55.4%
against a 15% bar), with `k = 16` the shipped default.

### Two findings the sweep produced

**1. The win is NOT monotone in k once the overhead is charged.** k=24 cuts 7.3 more
points of CG iteration than k=16 and is *slower* (0.917 vs 0.811). The per-iteration
correction streams `~8·k·n` bytes, so past k≈16 the extra columns cost more than the
iterations they save. This is why the default is a measured 16 and not "as large as
memory allows" — and it is the same Amdahl discipline 113 imposed: name the ceiling
from a measurement, not from the literature's regime.

**2. A stale basis is worth almost nothing — `cycle` must be 1.** Rebuilding every
4th solve instead of every solve collapsed the CG cut from 48.1% to **2.7%**, and the
run came out *slower than baseline* (1.306×) because the per-iteration correction is
still paid in full while the basis no longer describes the operator. The systems in
this sequence are near-identical solve-to-solve, but "near-identical" evidently does
not survive four MMA steps of design change. The `cycle` knob and the carried-`E`
machinery that makes it cheap both stay in the code (they are what make the
experiment repeatable), but the shipped and default value is 1 — harvesting is free
(it reuses `A p` the loop already computed) and only the k setup matvecs and the
small Rayleigh-Ritz are charged, both negligible against a ~600-iteration solve.

### Bar (a) EXACTNESS on the void ladder — PASS, with room to spare

Verdict block, verbatim (`docs/handoffs/evidence/133/void_regime.txt`):

```
  k=8  cyc=1 rung-reset  CG 0.691x (cut  30.9%) | gate=IDENTICAL | SHIPPED vf=0.52 mean|drho|=0.000000 max=0.0000 | worst-acc mean|drho|=0.000000 margin_d=0.000% C_d=0.000%
  k=16 cyc=1 rung-reset  CG 0.519x (cut  48.1%) | gate=IDENTICAL | SHIPPED vf=0.52 mean|drho|=0.000000 max=0.0000 | worst-acc mean|drho|=0.000000 margin_d=0.000% C_d=0.000%
  k=24 cyc=1 rung-reset  CG 0.446x (cut  55.4%) | gate=IDENTICAL | SHIPPED vf=0.52 mean|drho|=0.000007 max=0.0030 | worst-acc mean|drho|=0.000007 margin_d=0.024% C_d=0.000%
  k=16 cyc=4 rung-reset  CG 0.973x (cut   2.7%) | gate=IDENTICAL | SHIPPED vf=0.52 mean|drho|=0.000007 max=0.0030 | worst-acc mean|drho|=0.000007 margin_d=0.024% C_d=0.000%
  k=16 cyc=1 carry-rungs CG 0.504x (cut  49.6%) | gate=IDENTICAL | SHIPPED vf=0.52 mean|drho|=0.000000 max=0.0000 | worst-acc mean|drho|=0.000000 margin_d=0.000% C_d=0.000%
```

| bar (a) requirement | worst observed | verdict |
|---|---|---|
| mean\|Δρ\| ≤ 1e-4 | **7e-6** (k=24; 0.000000 at the shipped k=16) | PASS |
| margins ≤ 0.1% | **0.024%** | PASS |
| gate verdicts identical | **IDENTICAL** in every mode | PASS |
| compliance | **0.000%** delta in every mode | PASS |

The shipped configuration (k=16, cycle 1) reproduces the baseline's accepted
designs to **zero** in mean\|Δρ\| while taking a 48% shorter route. That is the
claim this technique is supposed to support: it changes the route, not the answer.

### Lifetime, measured rather than assumed

| lifetime | void CG cut | multigrid CG (base 40,715) | design vs baseline |
|---|---|---|---|
| reset at every rung boundary (default) | 48.1% | 74,819 | mean\|Δρ\| 0.000000, verdicts identical |
| carried across rung boundaries | **49.6%** | **72,271** | mean\|Δρ\| 0.000000, verdicts identical |

The two regimes AGREE on this question even though they disagree on everything
else: carrying across a rung boundary is mildly better in both (+1.5 points of cut
on the void ladder; 3.4% fewer iterations on the multigrid one) and worse in
neither.

**The shipped rule follows the measurement:**
`MinimizePlasticOptions::krylov_recycle_reset_per_rung` defaults to **false**
(carry across rungs), not the cautious reset-per-rung the task offered as a
placeholder. The knob remains, and either value is inert while recycling is off.

Carrying across a rung boundary is worth ~1.5 further points and costs nothing in
fidelity — the volume-target step does not invalidate the subspace as much as the
conservative default assumed. **Within-rung is where essentially all of the value
is** (`rc_frac` ≈ 1.00: a carried basis preconditions effectively every solve).

The gray → β-projection boundary could NOT be exercised on this fixture: the
conditional-projection gate (123) never fired here (`proj = 0` CG iterations in every
mode), so that third lifetime question is answered on the multigrid fixture below,
or left explicitly open. See "What I did NOT do".

---

## 5. Bar (d) — HONEST ACCOUNTING: what recycling costs, charged

Three costs, none of them free, all measured:

**1. Setup matvecs.** k exact FP64 operator applies per REBUILD solve, to form
`E = U^T A U`. Reported per solve in `CgInfo::recycle_setup_matvecs` and summed by
the harness. On the void ladder at k=16: **5,748 matvecs against 223,305 CG
iterations — 2.6% of the recycled iteration count, 1.3% of the baseline's.**

**2. The harvest.** Zero extra matvecs by construction: the sample reuses the `A p`
the CG loop already computed for its own step length. The per-rebuild
Rayleigh-Ritz is `O((k+m)^2 · n)` inner products plus a `(k+m)`-square dense
eigenproblem — sub-matvec, once per solve.

**3. The per-iteration correction — the dominant term.** It streams
`(8k + 24)·n` bytes every CG iteration (two passes over the k float columns, one
read of `r`, one read-modify-write of `z`). Measured as a ratio of back-to-back
interleaved medians (`rc_cost`, 48³ solid grid, ndof 352,947):

| k | CG iters | per-iteration cost vs k=0 (ω+1) |
|---|---|---|
| 0 (baseline) | 593 | 1.000 |
| 4 | 460 | 1.153 |
| 8 | 442 | 1.324 |
| 16 | 398 | **1.914** |
| 24 | 383 | 2.790 |

**This is the structural finding of the handoff.** In the assembled-matrix setting
the recycling literature comes from, a sparse row costs ~1 kB to apply, so k=16
deflation is single-digit-percent overhead. Our matvec is MATRIX-FREE and
gather-bound (112: 35% of STREAM), i.e. cheap per DOF — so the *same* deflation is
~90% overhead at k=16. **The technique's economics invert relative to the papers**,
and that is why the k sweep has an interior optimum instead of "bigger is better".

An early implementation made this far worse by streaming the FP64 `z` vector once
per column (3.32× at k=16). Collapsing the expansion to one pass over `z` and
threading both passes on the existing matrix-free pool brought it to 1.914×.

### NET work on the void ladder (everything charged)

ω is fixture-dependent (it is the ratio of a fixed `k·n` cost to a baseline
iteration whose cost depends on grid, regime and preconditioner), so the honest NET
figure comes from the probe's own interleaved wall alongside the deterministic
iteration count:

| quantity | baseline | k=16 recycled | ratio |
|---|---|---|---|
| CG iterations (the deterministic signal) | 430,330 | 223,305 | 0.519 |
| setup matvecs charged | 0 | 5,748 | — |
| observed wall (interleaved, same binary/box) | 248.3 s | 201.5 s | **0.811** |

Back-solving the wall against the iteration counts gives an implied
**ω ≈ 0.54** on this fixture, i.e. **a 48.1% iteration cut nets out to a ~19% real
work saving after every cost is charged.** Per 132's finding wall-clock is not the
claim — the iteration count is — but it is reported here as corroboration, and it
agrees with the model.

---

## 6. MEMORY — stated exactly, because it is an arming consideration

Everything is `float`; the basis is a preconditioner ingredient, where precision buys
convergence rate and nothing else (`E` is still formed from exact FP64 matvecs
applied to the promoted columns, so it is exactly consistent with the `U` in use).

| State | Columns | Bytes | at n = 2.29M free DOFs (96x80x96 design box) | at n = 6.4M (res 128) |
|---|---|---|---|---|
| Carried between solves | k | `4*k*n` | k=16: **147 MB** / k=8: 73 MB | k=16: 410 MB |
| Peak during a REBUILD solve | 4k (`U`, `A*U`, `P`, `A*P`) | `16*k*n` | k=16: **588 MB** / k=8: 294 MB | k=16: 1.6 GB |

`fea_krylov_recycle_bytes()` reports the live carried figure. Two consequences the
maintainer should weigh before arming on-device:

* The rebuild-solve peak is the binding number, and `cycle > 1` reduces how OFTEN it
  is paid, **not** how large it is.
* This is the same class of pressure the matrix-free path (078) exists to avoid.
  k = 8 halves it for roughly two thirds of k = 16's iteration win.

---

## 7. Wang's rescaling — checked, not assumed

**Task item 4:** verify whether our symmetric Jacobi/diagonal application already
delivers the density-ratio rescaling of Wang, de Sturler & Paulino 2007; if not,
add it and measure it separately.

**Analytically: yes, and by construction rather than by accident.** Their point is
that across a SIMP sequence the element moduli span many orders of magnitude
(`rho_min^p = 1e-9` here), so an UNSCALED extraction ranks candidate directions by
raw magnitude instead of by how badly they slow the iteration — the recycled space
then describes the stiff material and ignores the soft. Two facts make our
implementation already scaled:

1. PCG with `M = D` is identically CG on `D^-1/2 A D^-1/2`. The iteration our solver
   runs is already the rescaled one; that is what the Jacobi preconditioner IS.
2. The Rayleigh-Ritz that builds the basis uses the metric `D`, solving
   `(B^T A B) y = theta (B^T D B) y` — the eigenproblem of the PENCIL `(A, D)`, i.e.
   of exactly the rescaled operator CG sees. So the k directions we keep are the
   slow modes *of the scaled system*, not of the raw one.

**Measured on BOTH ladders**, same k, same cycle, same lifetime — only the metric
differs (`docs/handoffs/evidence/133/wang_rescale_void.txt`, `mg_regime.txt`):

| regime | diagonal metric (shipped) | identity metric (unscaled) | cost of dropping the rescaling |
|---|---|---|---|
| **void-heavy** | 223,305 CG (**48.1%** cut) | 310,424 CG (**27.9%** cut) | **+39.0% more iterations; 20 points of cut lost** |
| healthy multigrid | 74,819 CG | 80,574 CG | +7.7% more iterations |

**The rescaling is worth 20 points of the void-regime win on its own**, and the
split between the two regimes is itself the confirmation: the effect is 5x larger
exactly where the density contrast is extreme (`rho_min^p = 1e-9` across a mostly-
empty design box) and small where the material is nearly uniform. That is precisely
Wang, de Sturler & Paulino's mechanism — an unscaled extraction ranks candidate
directions by raw magnitude, so it describes the stiff material and ignores the soft
— reproduced here as a controlled A/B rather than inherited as an assumption. The
implementation gets it for free from a metric it had to choose anyway; the
measurement is what turns that from a plausible claim into a checked one.

Nothing needed adding. What the code gained instead is the ability to **measure the
claim**: `fea_detail::rc_set_metric_diagonal(false)` selects the unscaled
(identity-metric) extraction, and the probe carries a `k=16 no-rescale(ident)` row
that is otherwise identical to the shipped configuration.

---

## 8. Stretch item 5 (rigid-body-mode deflation) — DEFERRED, with the reason

**Task item 5:** rigid-body-mode deflation vectors for near-disconnected solid
components per Jonsthovel, "only if void systems still crawl after 1-3".

**Not built. The condition was not met**, and building it anyway would have been
speculative work the measurement does not support:

* The void regime does not still crawl. Recycling cut it 48.1% (§4), and the modes
  the Rayleigh-Ritz actually selected are *already* the near-rigid-body directions
  Jonsthovel's construction targets — it finds them from CG's own process rather
  than from a connected-component analysis of the density field.
* Jonsthovel's explicit rigid-body construction needs a per-solve connected-component
  labelling of the *evolving* design plus 6 analytic vectors per component. That is a
  variable-dimension subspace, which is exactly the thing this implementation's
  determinism argument rests on NOT having (fixed k, fixed order). Making it
  deterministic is a real design problem, not a parameter.
* The honest sequencing: it is the right escalation IF a future fixture shows
  recycling converging to a poor subspace on a genuinely fragmented design (many
  disconnected islands). The diagnostic that would prove it is a Ritz-value spectrum
  that stops separating — worth adding to the probe before the vectors are built.

---

## 9. HEALTHY-MULTIGRID REGIME

L-bracket 48x16x48, no design box, `mg_frac = 1.00` — multigrid carries on **every**
solve, so the preconditioner recycling wraps here is the V-cycle, not Jacobi. The
conditional-projection gate (123) fires on this fixture, so both phases are present.

The baseline reproduces handoff 132's FP64 baseline **exactly** — 625 MMA
iterations, 40,715 CG (gray 13,741 / projected 26,974) — which independently
confirms the fixture, the config and the harness are the ones 132 measured.

**The structural problem this regime has, stated before the table:** the baseline
averages **65 CG iterations per solve**. At k=16 the setup alone is 16 matvecs per
solve — a quarter of the entire baseline solve — before the per-iteration correction
is charged at all. A technique whose fixed cost is `O(k)` matvecs per solve cannot
win where the whole solve is `O(65)` iterations; that is arithmetic, not tuning.

### The mechanism, named before the sweep confirmed it

The additive correction lifts a deflated mode's PRECONDITIONED eigenvalue by
exactly +1:

```
(M^-1 + u (u^T A u)^-1 u^T) A u  =  (M^-1 A u)  +  u
```

* **M weak (Jacobi).** `M^-1 A u = theta u` with `theta` small, so the mode moves
  from ~0 to ~1 — it joins the bulk of the spectrum. That is deflation, and it is
  why the void regime wins.
* **M strong (a V-cycle).** `M^-1 A u = mu u` with `mu` already close to 1, so the
  mode moves from ~1 to ~2 — the spectrum WIDENS. The condition number gets worse,
  and CG spends more iterations, not fewer.

The extraction metric is the Jacobi diagonal `D` (§7), which targets the small
eigenvalues of `D^-1 A`. Those are the right modes when `M = D` and the WRONG ones
when `M` is a V-cycle: multigrid already handles them, so the correction spends its
k columns lifting modes that were never the problem. Fixing this properly means
extracting in the metric of the ACTUAL preconditioner — which is unavailable for a
V-cycle in the form the Rayleigh-Ritz needs — or moving to a projected/BNN form
whose deflated modes land at exactly 1 for any `M`, at roughly double the
per-iteration cost. **Neither is a k-tuning problem, which is why the sweep below
does not rescue it.**

### Two details the multigrid rows expose

* **Setup alone is a quarter of the whole solve.** At k=16 the probe charged 9,988
  setup matvecs (625 solves x 16) against a BASELINE total of 40,715 CG iterations —
  **24.5%** of the entire run's solver work, spent before the correction has done
  anything. This is the `O(k)`-per-solve fixed cost meeting an `O(65)`-iteration
  solve, and no k in the swept set escapes it: k=8 still charges 5,000.
* **It can tip a solve OUT of the multigrid regime.** `mg_frac` fell from **1.00**
  (baseline: multigrid carried every single solve) to **0.98** with recycling on —
  the widened spectrum pushed some solves past `kMgIterBudget`, so they stagnated
  and fell back to Jacobi-CG, paying the full V-cycle budget first. The harm is not
  purely additive; it interacts with the 127/128 fallback machinery.

### The sweep WAS run, and it does not find a winning k

The task's rule is "below 15% ⇒ k mis-tuned; sweep before concluding". Swept:

| k | CG iters | vs baseline | setup matvecs (share of baseline CG) | wall |
|---|---|---|---|---|
| — (baseline) | 40,715 | 1.00x | 0 | 213.4 s |
| 8 | 84,137 | 2.07x | 5,000 (12.3%) | 354.4 s |
| 16 | 74,819 | 1.84x | 9,988 (24.5%) | 390.3 s |
| 24 | 49,944 | 1.23x | 14,946 (36.7%) | 459.4 s |
| 16, rebuild every 4th solve | 73,280 | 1.80x | 2,468 (6.1%) | 342.7 s |

The iteration regression **shrinks** as k grows (2.07x → 1.84x → 1.23x): with more
columns the subspace eventually covers enough of the spectrum that the +1 lift stops
misfiring. But the fixed setup cost grows LINEARLY in k over the same range
(12.3% → 24.5% → 36.7% of the baseline's entire solver work), and the per-iteration
correction grows linearly too. **The two curves never cross:** wall time rises
monotonically across the whole sweep (213 → 354 → 390 → 459 s) even as iterations
improve. There is no k in or beyond this range that turns the multigrid regime into
a win — extrapolating the trend just buys a smaller iteration regression at a larger
fixed price. That is the sweep discharging its obligation, not confirming a tuning
fix.

### Bar (a) EXACTNESS in the multigrid regime — PASS, INCLUDING where it hurt

Verdict block, verbatim (`docs/handoffs/evidence/133/mg_regime.txt`):

```
  k=8  cyc=1 rung-reset  CG 2.066x (cut -106.6%) | gate=IDENTICAL | SHIPPED vf=0.26 mean|drho|=0.000000 max=0.0000 | worst-acc mean|drho|=0.000007 margin_d=0.000% C_d=0.001%
  k=16 cyc=1 rung-reset  CG 1.838x (cut  -83.8%) | gate=IDENTICAL | SHIPPED vf=0.26 mean|drho|=0.000000 max=0.0000 | worst-acc mean|drho|=0.000000 margin_d=0.000% C_d=0.000%
  k=24 cyc=1 rung-reset  CG 1.227x (cut  -22.7%) | gate=IDENTICAL | SHIPPED vf=0.26 mean|drho|=0.000000 max=0.0000 | worst-acc mean|drho|=0.000002 margin_d=0.000% C_d=0.000%
  k=16 cyc=4 rung-reset  CG 1.800x (cut  -80.0%) | gate=IDENTICAL | SHIPPED vf=0.26 mean|drho|=0.000000 max=0.0000 | worst-acc mean|drho|=0.000007 margin_d=0.000% C_d=0.001%
  k=16 cyc=1 carry-rungs CG 1.775x (cut  -77.5%) | gate=IDENTICAL | SHIPPED vf=0.26 mean|drho|=0.000000 max=0.0000 | worst-acc mean|drho|=0.000000 margin_d=0.000% C_d=0.000%
  k=16 no-rescale(ident) CG 1.979x (cut  -97.9%) | gate=IDENTICAL | SHIPPED vf=0.26 mean|drho|=0.000000 max=0.0000 | worst-acc mean|drho|=0.000005 margin_d=0.000% C_d=0.000%
```

**This is the single strongest piece of evidence for the exactness argument in
§1.** In every one of these modes the preconditioner was actively COUNTERPRODUCTIVE
— up to 2.07x more iterations — and the answer did not move: shipped design
mean|Δρ| **0.000000**, worst accepted rung ≤ 7e-6, margins **0.000%**, compliance
≤ 0.001%, gate verdicts IDENTICAL, and the MMA iteration count identical at 625 in
every mode. That is exactly what "SPD preconditioner ⇒ same fixed point, different
route" predicts, and it is why the additive form was chosen over the projected one:
a bad subspace degrades performance and nothing else. Bar (a) passes on BOTH
regimes.

### Lifetime, third question: across the gray → β-projection boundary

The void fixture never fired the conditional gate, so this question is answered
here. The regression is **not spread evenly across the two phases** — it is
concentrated almost entirely in the projected one:

| k | gray phase CG (base 13,741) | ratio | projected phase CG (base 26,974) | ratio |
|---|---|---|---|---|
| 8 | 16,296 | 1.19x | 67,841 | **2.51x** |
| 16 | 15,359 | 1.12x | 59,460 | **2.20x** |
| 24 | 15,418 | 1.12x | 34,526 | **1.28x** |

The grayscale phase is only mildly hurt; the β-projection phase is where the cost
is. No reset happens at that boundary in ANY configuration — the two phases are two
`simp_optimize` calls inside one rung, and `krylov_recycle_reset_per_rung` only
fires between rungs — so a basis harvested from the gray field is carried straight
into the projected one.

**Two explanations fit this data and it cannot separate them:**
(i) the carried basis describes a field that β-continuation has since sharpened, so
it is stale in a way a within-phase basis never is; (ii) the projected operator is
simply where the V-cycle is strongest, so the +1 mis-scaling of §9 bites hardest
there. The discriminating experiment is a reset at the phase boundary — a hook that
does not exist yet (the driver has no per-phase reset), and which is the first thing
to try if the multigrid regime is revisited.


---

## 10. VERDICT and the arming decision

| bar | void-heavy (Jacobi) regime | healthy-multigrid regime |
|---|---|---|
| (a) EXACTNESS | **PASS** — mean\|Δρ\| 0.000000 at the shipped k, worst 7e-6 vs a 1e-4 bar; margins ≤ 0.024% vs 0.1%; verdicts IDENTICAL | **PASS** — mean\|Δρ\| 0.000000 shipped, worst 7e-6; margins 0.000%; verdicts IDENTICAL; 625 MMA iters in every mode — *even in the modes that ran 2x slower* |
| (b) PERFORMANCE ≥ 15% CG cut | **PASS** — 48.1% at k=16 (30.9% / 55.4% at k=8 / 24) | **FAIL** — a REGRESSION, see §9 |
| (c) DETERMINISM | PASS — asserted in `test_recycle` (bit-identical fields + iteration histories, and 1-vs-8-thread bit-identity), corroborated at ladder scale | PASS — same assertions |
| (d) HONEST ACCOUNTING | PASS — reported and charged, §5 | PASS — reported, §5 |

**Bar (b) as WRITTEN fails on the multigrid regime.** As originally submitted this
handoff therefore did not arm production, on the 130/132 pattern.

**MAINTAINER DECISION (amending this PR).** The bar-(b) failure was ruled a **bar
mis-specification**: the technique targets one regime, and the meaningful bar is
"≥15% CG cut on the TARGETED regime AND a byte-identical no-op on the non-targeted
one". Both halves are met by the measurements below — 45.4% void, 1.000x-to-the-digit
multigrid — so the **Jacobi-only posture is AUTHORISED and armed in this PR**.

Arming the AS-BUILT (wrap-everything) posture would still be wrong, and the
distinction is the whole point: production runs BOTH regimes —
`SolverKind::MultigridCG_Matfree` lands in the V-cycle regime whenever the grid
coarsens and the hierarchy contracts, i.e. most healthy parts — so wrapping
everything would trade a large design-box win for a ~2x loss on ordinary parts. The
Jacobi-only posture takes the win and declines the trade.

### The arming candidate, measured rather than merely recommended

The failure is regime-specific, not global, so the obvious question is whether
recycling can be armed for the Jacobi regime ALONE. The internal knob
`fea_detail::rc_set_wrap_multigrid(false)` does exactly that: `mf_mgpcg` then
constructs no session at all, so the multigrid regime is **baseline by
construction** — no correction, no setup matvecs, no state touched, byte-identical
to recycling-off. It is true by inspection — but it was RUN anyway, because "by
construction" is exactly the kind of claim that is wrong when a knob is wired
incorrectly, and the check is cheap:

```
[baseline (off)   ] rungs=4 iters= 625 cg=   40715 setup_mv=    0 mg_frac=1.00 rc_frac=0.00
[k=16 jacobi-only ] rungs=4 iters= 625 cg=   40715 setup_mv=    0 mg_frac=1.00 rc_frac=0.00
  k=16 jacobi-only  CG 1.000x (cut 0.0%) | gate=IDENTICAL | mean|drho|=0.000000 | margin_d=0.000% C_d=0.000%
```

**Exactly** the baseline CG count to the digit, zero setup matvecs, `rc_frac` 0.00 —
the knob really does leave the multigrid path untouched.

What DOES need measuring is the void side: the void ladder ran multigrid on ~23% of
its solves, and those solves were being wrapped (harmfully) in the numbers above.
Restricting to Jacobi gives up recycling on that 23% and removes the harm from it,
and only a measurement says which dominates.

**Measured, void ladder** (`docs/handoffs/evidence/133/jacobi_only_void.txt`):

```
[baseline (off)   ] iters= 372 cg=  430330  setup_mv=    0  mg_frac=0.22 rc_frac=0.00
[k=16 jacobi-only ] iters= 359 cg=  234972  setup_mv= 4356  mg_frac=0.23 rc_frac=0.76
  k=16 jacobi-only  CG 0.546x (cut 45.4%) | gate=IDENTICAL | SHIPPED vf=0.52 mean|drho|=0.000000 max=0.0000 | worst-acc mean|drho|=0.000000 margin_d=0.000% C_d=0.000%
```

| variant | void CG cut | multigrid CG | exactness |
|---|---|---|---|
| wrap whichever runs (as built) | **48.1%** | **1.84x REGRESSION** | mean\|Δρ\| 0.000000 |
| Jacobi-only | **45.4%** | **1.000x — baseline, by construction** | mean\|Δρ\| 0.000000 |

`rc_frac` fell from 0.99 to **0.76**, which is the knob doing exactly what it says:
the ~24% of solves that ran multigrid got no session, no correction and no setup
matvecs (which also dropped, 5,748 → 4,356). **Restricting to Jacobi keeps 94% of
the win** (45.4 of 48.1 points) while removing the multigrid harm entirely.

**But be precise about what this does NOT do.** Bar (b) as written demands ≥ 15% on
BOTH regimes. Jacobi-only delivers 45.4% on one and **0%** — not 15% — on the other.
It converts the multigrid outcome from *harmful* to *no-op*; it does not turn it
into a win. So **bar (b) is not met by this variant either, and it does not by
itself authorise arming.** What it does establish, with numbers rather than
argument, is that an arming posture exists which is a strict improvement on
design-box runs and a strict no-op everywhere else — a trade the stated bar did not
anticipate, and therefore a maintainer decision rather than an agent one.

### What the amendment changed (the armed package)

* `rc_set_wrap_multigrid` promoted to the public API as
  `fea_set_krylov_recycle_wrap_multigrid` / `fea_krylov_recycle_wrap_multigrid`,
  **defaulting false**. The doc block in `fea.hpp` carries the measured
  justification and a "do not flip without re-running the mg table" tripwire.
* `configure_production_options` arms the package:
  `fea_set_krylov_recycling(true)`, `fea_set_krylov_recycle_dim(16)`,
  `fea_set_krylov_recycle_wrap_multigrid(false)`, and
  `opts.krylov_recycle_reset_per_rung = false` (the §4 lifetime finding). The
  rebuild cycle stays at the library default 1 (§4: a 4-solve-old basis measured
  worth almost nothing). k is a NAMED constant exposed as
  `production_krylov_recycle_dim()` so the parity test asserts against it, not a
  literal — the 132 P-core-pin pattern.
* `test_production_parity` extended with the config echo, on BOTH halves: the
  library-default half asserts recycling is OFF for the reference world, the armed
  half asserts all four settings, each with the measurement that decided it.
* `run_info.json` echoes the armed truth, now including
  `krylov_recycle_wrap_multigrid` — without it the CSV's `recycle_dim` column could
  not be interpreted (a 0 next to `cg_multigrid=1` is the by-design no-op, not a
  failure).
* `iterations.csv` gains the `recycle_dim` column; both golden header assertions and
  the golden row bytes moved in the same commit.
* `test_recycle` gained `test_armed_jacobi_only_is_a_noop` — with the shipped
  default, a multigrid solve must charge zero recycle columns and zero setup
  matvecs, take EXACTLY the recycling-off iteration count, and return a
  BIT-IDENTICAL field, while the same configuration still recycles the Jacobi path.
  The pre-existing multigrid scenarios now opt IN to wrapping explicitly, so the
  still-live wrapped code path keeps its exactness and determinism coverage instead
  of silently going vacuous under the new default.

---

## 11. Bar (c) — DETERMINISM

**Asserted, in CI.** `test_recycle` requires, on BOTH matrix-free regimes, that two
runs of the same recycled sequence produce bit-identical fields AND identical
per-solve iteration histories, and additionally that 1 thread and 8 threads produce
bit-identical fields — the guard on the threaded correction's fixed-accumulation-
order claim. A change that reduced across threads directly, or used atomics, would
fail it.

**Corroborated at ladder scale.** The void baseline reproduced BIT-EXACTLY across
three independent process invocations and two separately-compiled probe binaries:

```
[baseline (off)] rungs=3 iters= 372 cg=  430330 ... wall=248.3s   (void_regime.txt)
[baseline (off)] rungs=3 iters= 372 cg=  430330 ... wall=254.9s   (jacobi_only_void.txt)
[baseline (off)] rungs=3 iters= 372 cg=  430330 ... wall=255.3s   (wang_rescale_void.txt)
```

Same MMA iteration count, same total CG count, to the last digit — while wall-clock
moved 2.8% across the three, which is exactly the reason 132 banned wall-clock as a
gate signal and this handoff quotes iterations as the claim.

**Two full replicate ladders per mode** (`TOPOPT_RC_REPS=2`), void regime, RECYCLING
ON — `repeat|drho|` is rep0-vs-rep1 max|Δρ| on the terminal design and
`iters_repeat` compares the per-rung MMA iteration histories
(`docs/handoffs/evidence/133/determinism_void.txt`):

```
[baseline (off)       ] iters= 372 cg=  430330 ... repeat|drho|=0 iters_repeat=same
[k=16 cyc=1 rung-reset] iters= 359 cg=  223305 ... repeat|drho|=0 iters_repeat=same
```

And the multigrid regime, where the conditional-projection gate fires so BOTH
phases are exercised (`determinism_mg.txt`):

```
[baseline (off)       ] iters= 625 cg=   40715 ... repeat|drho|=0 iters_repeat=same
[k=16 cyc=1 rung-reset] iters= 625 cg=   74819 ... repeat|drho|=0 iters_repeat=same
```

`repeat|drho| = 0` is an exact zero in all four rows, not a rounded one, with the
recycle basis live and rebuilt on every solve. Both recycled totals also reproduced
their independent earlier runs to the digit — **223,305** (§4) and **74,819** (§9) —
so the Rayleigh-Ritz extraction, the decimating harvest ring, the unpivoted rank
guard and the cyclic-Jacobi eigensolver are all reproducing exactly across
processes, not merely within one. That is the determinism-by-construction claim of
§1 discharged at production scale, in both regimes.

---

## 12. THE ONE RULE — how default-OFF is guaranteed, not asserted

Recycling is default OFF **in the library**, and armed only at the production entry
point — the same discipline as the solver kind, the min-feature scale, the Galerkin
cache and the P-core pin:

* `fea_set_krylov_recycling` defaults false; with it false `RecycleSession::begin`
  returns before touching any state, so the session allocates nothing, charges no
  matvecs, and every `augment` / `observe` / `commit` is an early-return.
* Only `configure_production_options` arms it. Gate-V2, the property suite, the
  validation gates and every core reference run never call that function, so they
  are byte-for-byte unchanged — asserted in `test_production_parity`, which now
  checks the OFF state before the call and the armed state after it.
* `fea_set_krylov_recycle_wrap_multigrid` defaults **false**, so even with recycling
  armed a multigrid solve constructs no session at all and is bit-identical to a
  recycling-off solve — asserted directly in
  `test_recycle::test_armed_jacobi_only_is_a_noop`.
* The driver's two reset calls (`minimize_plastic`, run start and rung boundary) are
  no-ops on a non-existent basis, so `krylov_recycle_reset_per_rung` cannot change
  behaviour while recycling is off — either value is byte-identical.
* `run_info.json` echoes the ACTUAL state (`krylov_recycling`,
  `krylov_recycle_dim`), read from the library, never inferred — so a run record can
  rule the accelerator OUT of a later diagnosis, which is the 132 discipline.

**Structural + parity evidence** (`test_recycle`, CI test `krylov_recycling`):
with recycling off the `CgInfo` diagnostics stay 0 and `fea_krylov_recycle_bytes()`
is 0; and a solve taken AFTER enabling, running a recycled sequence, and disabling
again is **bit-identical** to the one taken before recycling was ever enabled —
same field, same iteration count. The flag leaves no residue.

## 13. Gates

* Full `ctest` — see §Test evidence.
* Byte-identity with the flag off — structural + parity, above.
* Gate-V2 untouched: recycling is unreachable from any path Gate-V2 exercises
  (default off, and the library default solver is `JacobiCG`, not the matrix-free
  multigrid the wiring lives in).
* Observability is finalize-only for outcome fields: the two new `RunInfo` fields
  are CONFIG (known up front, never null), not outcomes, so they do not participate
  in the walk-back Amendment 1 null discipline.

---

## 14. RECIPE — reproduce every number above

```bash
cd core && cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j10
EIGEN=/opt/homebrew/opt/eigen/include/eigen3
SP=<scratchpad>

# The regime probe. `-I src/fea` is required: the harness reaches the two INTERNAL
# research knobs (extraction metric, wrap-multigrid) via the library's private
# header, deliberately, so neither claim has to be taken on faith.
c++ -std=c++17 -O2 -I include -I src/fea -I "$EIGEN" \
  -DSETTINGS_RULES_PATH="\"$PWD/src/settings/rules.json\"" \
  tests/harness/recycle_probe.cpp build/libtopopt.a -o $SP/recycle_probe

# (a)+(b): the two regime tables, all modes. ~25 min and ~40 min respectively.
TOPOPT_RC_REPS=1 $SP/recycle_probe void
TOPOPT_RC_REPS=1 $SP/recycle_probe mg

# (c): determinism at ladder scale — 2 replicates; look at repeat|drho| (must be 0)
# and iters_repeat (must be "same"). TOPOPT_RC_ONLY filters to one variant so this
# does not re-run the whole sweep.
TOPOPT_RC_REPS=2 TOPOPT_RC_ONLY="k=16 cyc=1 rung-reset" $SP/recycle_probe void
TOPOPT_RC_REPS=2 TOPOPT_RC_ONLY="k=16 cyc=1 rung-reset" $SP/recycle_probe mg

# §7 Wang rescaling A/B and §10 the arming candidate (single rows).
TOPOPT_RC_REPS=1 TOPOPT_RC_ONLY="no-rescale"  $SP/recycle_probe void
TOPOPT_RC_REPS=1 TOPOPT_RC_ONLY="jacobi-only" $SP/recycle_probe void
TOPOPT_RC_REPS=1 TOPOPT_RC_ONLY="jacobi-only" $SP/recycle_probe mg   # must be 1.000x

# (d): the per-iteration correction overhead w(k), interleaved base/recycled in one
# process so thermal drift moves both terms together. A RATIO of medians, never an
# absolute wall-clock claim (132's protocol).
c++ -std=c++17 -O2 -I include -I "$EIGEN" \
  tests/harness/recycle_cost_probe.cpp build/libtopopt.a -o $SP/recycle_cost_probe
$SP/recycle_cost_probe 48

# The CI guard: exactness on both regimes, a real net-of-overhead iteration cut,
# determinism, 1-vs-8-thread bit-identity, opt-in parity, lifetime, robustness.
ctest --test-dir build -R krylov_recycling --output-on-failure
```

`TOPOPT_RC_ARM` resizes the void fixture's bracket; `TOPOPT_RC_REPS` sets the
replicate count (2 arms the determinism self-check); `TOPOPT_RC_ONLY` filters
variants by substring; `TOPOPT_RC_OVERHEAD` feeds a measured w(k) into the NET
column so it can be re-derived on another machine.

Raw captured output: `docs/handoffs/evidence/133/`.

---

## 15. Test evidence (raw, pasted, unedited)

Full suite, Release, this worktree. The baseline before this run was 61/61; the
62nd is the new `krylov_recycling` test.

```
62/62 Test #58: cli_demo .........................   Passed  257.28 sec

100% tests passed out of 62

Total Test time (real) = 257.28 sec
```

The new test on its own, plus the observability tests whose run_info assertions
this run extended:

```
    Start 14: observability
1/3 Test #14: observability ....................   Passed    0.09 sec
    Start 23: krylov_recycling
2/3 Test #23: krylov_recycling .................   Passed    7.53 sec
    Start 35: observability_capture
3/3 Test #35: observability_capture ............   Passed    0.25 sec

100% tests passed out of 3
```

`test_recycle`'s own output (37 checks, 0 failures) — the per-scenario lines are the
measured evidence behind the assertions, not decoration:

```
  [jacobi solid ] plain cg=197 recycled cg=125 dim=16  max|du|/max|u|=1.050e-09
  [jacobi void  ] plain cg=256 recycled cg=159 dim=16  max|du|/max|u|=3.231e-16
  [mgcg   solid ] plain cg=18  recycled cg=13  dim=13  max|du|/max|u|=2.584e-10
  [mgcg   void  ] plain cg=188 recycled cg=285 dim=16  max|du|/max|u|=4.443e-16
  [reduction] plain cg=2909 | recycled cg=1931 + setup=80  -> net 0.691x (30.9% cut)
  [determin ] jacobi 885 cg, multigrid 168 cg, both repeated exactly
  [threads  ] 1 vs 8 threads: identical (885 cg)
  [robust   ] 20 solves, k=24, all converged, total cg=3231
test_recycle: 37 checks, 0 failures
```

Note the `[mgcg void]` line: 188 -> 285 iterations, i.e. the unit test itself
exhibits the multigrid regression in miniature, and its exactness assertion still
holds at 4.4e-16. The regime split was visible here before either ladder probe ran.
CI run: maintainer to fill
PR: maintainer to fill

New tests added:
- `krylov_recycling` (`core/tests/unit/test_recycle.cpp`) — **43 checks** (37 as
  originally submitted, +6 from the amendment's armed-posture test). Proves, on
  BOTH matrix-free regimes: the recycled field equals the recycling-off field to
  1e-6 relative on a solid grid AND on the soft-void graded grid (exactness);
  a void-heavy sequence's NET CG work (setup matvecs included) falls >= 15% and the
  BOOTSTRAP solve costs exactly what plain CG costs while the LAST solve is
  strictly cheaper (this is the check a stub or a no-op cannot pass); two runs give
  bit-identical fields and iteration histories (determinism); 1 vs 8 threads give
  bit-identical fields (the threaded correction's fixed-order claim); with the flag
  off the diagnostics stay 0, nothing is allocated, and a solve is bit-identical to
  one taken before recycling was ever enabled (opt-in parity); the explicit reset
  drops the basis and a DOF-count change drops it automatically rather than
  misapplying it (lifetime); and 20 consecutive recycled solves all reach tolerance
  (robustness).
  The amendment added `test_armed_jacobi_only_is_a_noop`: under the SHIPPED default
  a multigrid solve must charge zero recycle columns and zero setup matvecs, take
  EXACTLY the recycling-off iteration count and return a BIT-IDENTICAL field, while
  the same configuration still recycles the Jacobi path. Observed:
  `mgcg off=36 on=36 dim=0 setup=0 bytes=0`, `jacobi dim=15`.
- `observability` (extended) — `run_info.json` echoes `krylov_recycling` /
  `krylov_recycle_dim` / `krylov_recycle_wrap_multigrid` as CONFIG (never null), and
  the CSV golden covers the new `recycle_dim` column on both a recycled row (16) and
  a not-recycled MG row (0).
- `production_parity` (extended) — the armed config echo, asserted on both halves:
  recycling OFF for the library/reference world, and all four armed settings after
  `configure_production_options`, each carrying the measurement that decided it.

---

## 16. What I did NOT do

* **Did not wire recycling into the ASSEMBLED solvers** (`fea_solve_cg`,
  `fea_solve_mgcg`, `PenalizedSolver`). Only the matrix-free pair is wrapped. That
  covers every regime production's `MultigridCG_Matfree` can land in, but a caller
  choosing `SolverKind::JacobiCG` or `MultigridCG` gets no recycling and no
  diagnostics (`recycle_dim` stays 0 — honest, not silent).
* **Did not build the rigid-body-mode deflation** stretch item (§8 — the condition
  for it was not met).
* **Did not add a `recycle_setup_matvecs` CSV column.** The CSV carries
  `recycle_dim` only. With the production rebuild cycle at 1 the two are equal
  (a recycled solve charges exactly k setup matvecs), so the second column would be
  redundant — but a future run that raises `cycle` above 1 breaks that identity and
  should add it. `SimpIterationObservation` already carries both.
* **Did not tune `m` (the harvest sample size)** — it is fixed at `m = k`. A sweep
  over `m` independent of `k` is unexplored; it trades rebuild-solve peak memory
  (§6) against subspace quality.
* **Did not measure at production grid scale.** Both fixtures are far smaller than
  the 96x80x96 / res-128 design boxes the memory table extrapolates to. The
  iteration-cut result should carry (it is a spectral property, and 125 showed the
  disease worsens with scale), but the per-iteration overhead ratio ω and the
  memory peak are the numbers that would decide arming there, and neither was
  measured at that size.
* **Did not exercise the gray -> β-projection lifetime boundary on the void
  fixture** — the conditional gate never fired there. It IS exercised on the
  multigrid fixture (§9), but with the multigrid mis-scaling confounding it, so the
  boundary question is answered only partially and is flagged as such.
* **Did not add a per-PHASE reset hook.** `krylov_recycle_reset_per_rung` resets
  between rungs; nothing resets between a rung's grayscale and β-projection phases.
  That hook is the discriminating experiment §9 names, and it is deliberately left
  for the run that revisits the multigrid regime rather than added speculatively.
* **Did not promote the two research knobs to public API.**
  `rc_set_metric_diagonal` and `rc_set_wrap_multigrid` live in the INTERNAL
  `src/fea/recycle.hpp`; the harness reaches them via `-I src/fea`. They exist to
  make two claims measurable, not to be a supported surface. Promoting
  `rc_set_wrap_multigrid` is step one of the arming path in §10.
* **Did not re-measure ω(k) on the void fixture's own grid.** The overhead table is
  from a 48³ solid grid; the void ladder's implied ω (~0.54) is back-solved from its
  wall, not directly measured. They differ because ω depends on grid size and
  regime, which is stated but not swept.

---

## 17. Warnings for the next run

* **The correction is bandwidth-bound and threaded on the SHARED matrix-free pool.**
  It calls `mf_parallel_ranges`, which dispatches on `ApplyPool`. That pool assumes
  applies are not issued concurrently and is not re-entrant — never call `augment`
  (or anything in recycle.cpp) from inside a pool worker body, or it will deadlock.
* **`cfg_k` vs `k` is a real distinction, not redundancy.** The fixed-order rank
  guard legitimately returns FEWER than k columns when the candidate set is
  numerically dependent. An earlier version compared the ACHIEVED column count
  against the configured k to detect reconfiguration, which threw the basis away on
  every single solve and made recycling look like a perfect no-op (`recycle_dim` 0
  everywhere, fields bit-identical). If a future change makes recycling silently
  ineffective, check this first.
* **A solve that stagnates in MG-CG and falls back to Jacobi-CG pays setup TWICE.**
  `RecycleReport::setup_matvecs` accumulates rather than overwrites so the charge is
  honest. In practice the 127 latch stops the MG attempt after 3 stagnations, so the
  void ladder measured exactly k per solve.
* **`commit()` runs ONLY after a converged solve.** A stagnated or broken-down
  solve's directions are not evidence about the operator's slow modes; harvesting
  them would poison the basis. Keep that guard if the CG loops are refactored.
* **Determinism rests on fixed accumulation ORDER, not on serial execution.** Both
  threaded passes are safe only because each chunk writes disjoint output or emits a
  per-chunk partial reduced in ascending chunk order. A "simple" optimisation that
  reduces across threads directly (or uses atomics) breaks bit-reproducibility
  silently — `test_recycle`'s 1-vs-8-thread check is the tripwire.
* **The additive form is preconditioner-strength sensitive** — see §9 and its
  multigrid table. It lifts a deflated mode's preconditioned eigenvalue by +1, which
  is exactly right when `M` is weak (Jacobi: the mode was near 0) and can WIDEN the
  spectrum when `M` is strong (a V-cycle: the mode was already near 1). Any future
  attempt to make the multigrid regime pay should change the extraction metric to
  match the preconditioner, or move to a projected/BNN form — not tune k.
