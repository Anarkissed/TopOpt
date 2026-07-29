# 2026-07-28 — Void-DOF elimination: Phase 0 feasibility (harness + read-only trace)

**Track:** core only, **measurement harness + this doc**. NO production change (BAR
B3): nothing in `core/src` or `core/include` is touched. The only new file is a
standalone, not-wired-to-CTest probe, `core/tests/harness/void_dof_probe.cpp`, that
drives the EXISTING production paths and reads out numbers. Nothing it does can
change a shipped result.

**Verdict up front: NO-GO as a distinct accelerator.** BAR B4 does not *hard*-close
the route — sensitivity correctness CAN be preserved — but only by the exact
machinery (a per-iteration growth band, or Heaviside reintroduction) that our
production optimizer either already ships as **Active Domain** or has deliberately
turned OFF. Measured on the real stagnation ladder, the idea's two headline premises
do not both hold at any usable density threshold, it **harms the production
multigrid solver**, and it **collides with the armed Krylov recycling** — a collision
the codebase already measured and acted on when it **disarmed Active Domain**. Detail
and numbers below.

**The one-sentence why:** *void-DOF elimination in our formulation is a
re-derivation of the Active Domain feature (`active_domain_mask`, shipped handoff
134, armed then reviewed 2026-07-27), and AD already answered every question this
task asks — including the recycling collision, which it lost.*

Evidence: `evidence/2026-07-28-void-dof-elimination-phase0/` (`void_dof_probe.out`
= the full run; `void_dof_probe.cpp` = the harness source).

---

## 0. What the idea is, and what our code already is

The proposal (arXiv 2012.02860 / CMAME 2021): remove the DOFs connected only to void
elements and replace them with fictitious (traction-free) boundary conditions; keep
all design variables active so sensitivities stay correct; let material reappear
along boundaries because **Heaviside projection amplifies boundary-adjacent
sensitivities**.

Three facts about *our* code decide the entire study, and all three were found by
reading before running:

1. **We already have the reduced solve.** `fea_solve_{cg,mgcg}_matfree`'s
   `active_mask` (fea.hpp:466–487, simp.hpp:138–181) does exactly "a 0 on a solid
   voxel removes that element; the M3.1 void-DOF gate drops every DOF no surviving
   element touches, so the band boundary is a **traction-free free surface** and the
   solve is EXACT on the system that survives." That IS "eliminate void DOFs, replace
   with fictitious BCs." So E1/E2/E4 are **measured on production code**, not modelled.

2. **We already ship the reintroduction layer, and it is a growth band, not
   Heaviside.** `active_domain_mask` keeps `solid ∧ (ρ>1.5·ρ_min ∨ Load/Fixture ∨
   cheb_dist≤band)` — the solid core plus a Chebyshev growth band of width
   `ceil(rmin)+1` (simp.hpp:149–195). The band exists *because* of premise-3's
   failure in our formulation (see §B4).

3. **Our production optimizer does NOT run Heaviside as a reintroduction driver.**
   The MMA updater skips projection (handoff 066); conditional projection (handoff
   123) only *polishes already-gray converged rungs*, it does not amplify
   boundary sensitivities during descent. So the proposal's stated reappearance
   mechanism is absent from the path this would live on.

---

## 1. The fixture (BAR B1 — real stagnation, not a toy)

The canonical stagnation case the codebase already uses:
`draft_arming_gate::make_big_stagnation` / `ad_stag_mechanism_probe` — an L-bracket
part (~4% of the box) inside a design box, contrast `(ρ_min)^p = (1e-3)^3 = 1e9`.
The full 48³ / 96×80×96 / 128³ forms of this case are what stagnate in production
(15,349 CG @48³ under recycling; ~11.5 h @128³).

The probe runs the **tractable proportional reduction, 32×24×32 = 24,576 voxels,
81,540 free DOFs** — the same reduction `removal_probe.cpp` uses and for the same
reason: the dilute high-contrast regime and its density trajectory are
scale-invariant, while the *absolute* CG cost grows with N (which is exactly why the
full grid is intractable to converge here). That it is genuinely the stagnation
regime and not a toy is visible in the run itself: the dilute rungs **diverge**
(compliance blows up 12.7 → 640 → 1669 across vf = 0.52→0.38→0.26) and their
per-iteration solve cost explodes (40 s → 138 s per 25-iteration rung) — the
"developing structure makes geometric MG monotonically worse; deepest rung = hardest"
behaviour (handoff on MG latch re-arm). Each rung's converged (or last-iterate)
physical density field is captured and analysed.

Production SIMP posture: MMA updater (no Heaviside), `MultigridCG_Matfree` solver,
ρ_min = 1e-3, p = 3, E0 = 3500, ν = 0.33.

---

## 2. E1 — DOF elimination and remaining-operator contrast, per rung

Void = element with physical ρ ≤ ρ_t. A free DOF is eliminated iff **every** element
touching it is void (the M3.1 gate); Load/Fixture elements are pinned (the AD BC-pin,
so the load gate is never handed a stiffness-free DOF). "contrast" = maxE/minE over
the surviving elements. Full numbers in `void_dof_probe.out`; the shape (rung vf=0.26,
the tightest/most-void):

| ρ_t | surviving elems | free-DOF reduction | contrast_full → contrast_reduced | floating regions | load path |
|---|---|---|---|---|---|
| **1.5e-3** (AD core) | 20.6% | **77.0%** | 1e9 → **2.95e8** | 0 | connected |
| 1e-2 | 15.8% | 81.9% | 1e9 → 9.99e5 | 0 | connected |
| 5e-2 | 7.5% | 90.2% | 1e9 → 7.98e3 | 0 | connected |
| 1e-1 | 1.6% | 97.2% | 1e9 → 999 | **2 floating (of 4)** | **SEVERED** |
| 3e-1 | 0.3% | 99.5% | 1e9 → 1 | 0 | **SEVERED** |

Across all four rungs the free-DOF reduction at the safe AD-core threshold is
**72–95%** — the premise "removes 60–97% of the system" is **CONFIRMED**.

**But the contrast premise fails at every safe threshold.** At ρ_t = 1.5e-3 the
remaining contrast is still **1.8e8 – 2.95e8** — barely 3–6× below the full 1e9,
because the surviving set still contains grey material right down to ρ≈ρ_t, whose
modulus is (1.5e-3)³·E0 ≈ 3e-9·E0. To actually collapse the contrast to ~1e3 you must
push ρ_t ≥ 0.1 — which is exactly where the structure severs (next section). So the
claim that elimination "removes the very DOFs that create the 1e9 contrast" is **not
true at any threshold that preserves the design**: size and conditioning are *not*
attacked at once; they trade off against each other through ρ_t.

**B2 (threshold sensitivity):** the tables ARE the sensitivity, and it is steep and
adverse. ρ_t moves the contrast over 8 orders of magnitude (2.95e8 → 1) while moving
the DOF reduction only from 77% → 99.5%; the useful contrast reduction lives entirely
in the ρ_t range that destroys connectivity. There is no threshold that is both
conditioning-useful and structurally safe.

---

## 3. E2 — the floating-island problem, and the connectivity belt

★ **The handoff-169 connectivity belt is directly reusable, and the probe reuses it.**
`load_path_connected` (voxelize.cpp:609) is a 26-connectivity flood-fill from printed
Fixture voxels over the printed set, checking all Load voxels are reached. Floating
islands are the dual: anchor the same 26-conn walk on {Fixture ∪ Load}, and every
surviving-solid element it does **not** reach is a floating region. The probe does
exactly this (a connected-component labelling with the identical neighbour walk) and
also calls `load_path_connected` on the reduced set as an independent check.

Measured floating-region counts per rung (surviving-solid components not reachable
from an anchor):

* **ρ_t ≤ 0.05: zero floating regions, single connected anchored component, load path
  intact** on every rung.
* **ρ_t = 0.1: 2–4 components, 2–3 floating** on the diverged rungs (vf 0.38, 0.26);
  load path already severed on vf 0.26.
* **ρ_t ≥ 0.3: load path severed on every dilute rung** (only ~64 elems survive — the
  64 pinned Load+Fixture voxels — as 2 disconnected anchored stubs).

So floating regions **do** occur, the belt **does** detect them cheaply and
deterministically, and it is the natural constraint mechanism. But the finding is
sharper than "we can detect them": on this fixture floating islands appear *precisely
at the threshold where contrast reduction would start to matter* (ρ_t ≥ 0.1). Below
that the reduced system is well-posed but barely better-conditioned; at and above it
the reduced system is **singular** (a floating island is a free rigid body → the
free-surface subsystem has a null space → the solve is ill-posed). E4 shows this
directly.

---

## 4. E4 — measured CG and wall, full vs void-reduced, on the stagnating case

Full soft-void system vs the void-reduced system (realized by `active_mask`), same
matrix-free Jacobi-CG and MG-matfree, tol 1e-8, on each rung's converged field.
Representative rows (full table in the evidence file):

| rung | solver | FULL iters | RED @ρ_t=1.5e-3 | RED @ρ_t=0.1 | RED @ρ_t=0.3 |
|---|---|---|---|---|---|
| vf 0.68 | Jacobi | 933 | **574** (−38%) | 575 | 587 |
| vf 0.68 | **MG** | **47** | **107** (+128%) | 129 | 168 |
| vf 0.38 | Jacobi | 990 | 734 (−26%) | **1086 (+10%)** | ✗ non-conv (severed) |
| vf 0.38 | **MG** | **54** | 57 | **1086, fell to Jacobi** | ✗ non-conv |
| vf 0.26 | Jacobi | 1145 | 811 (−29%) | ✗ non-conv | ✗ non-conv |
| vf 0.26 | **MG** | **54** | **100** (+85%) | ✗ non-conv | ✗ non-conv |

Three results, all adverse for the production path:

1. **The production solver (MG-matfree) is HARMED by elimination.** Full MG converges
   in 47–54 iters on every rung — it does *not* stagnate at this scale; that is why
   production uses it. The reduced MG takes **100–168 iters** (healthy rungs) or
   **loses its coarse grid entirely and falls back to plain Jacobi / diverges**
   (aggressive/dilute). Mechanism: cutting the void elements replaces a regular,
   fully-coarsenable voxel block with an **irregular free-surface boundary** that
   geometric multigrid cannot coarsen through — the very structure MG depends on.
   Elimination trades a well-conditioned-under-MG system for a badly-coarsenable one.

2. **The Jacobi win, where it exists, is smaller than what recycling already gives
   for free.** At the only safe threshold, reduced Jacobi is **−26% to −38%** iters.
   Krylov recycling already delivers **−45.4%** on this same Jacobi regime (handoff
   133, production posture) with **no DOF-set change and no severance risk**.

3. **Aggressive thresholds don't converge at all.** At ρ_t = 0.1 the reduced solve is
   already *worse* (990→1086) on vf 0.38 and non-convergent on vf 0.26; at ρ_t ≥ 0.3
   every dilute rung throws `SolverNonConvergence` (residual ~1e6–1e8) — the singular
   floating-island subsystem of §3.

Wall time mirrors iterations but is dominated on this small grid by the many-iteration
Jacobi fulls (4–6 s) vs the sub-second reduced solves; the wall "win" of the reduced
Jacobi is real *only* against the Jacobi fallback, and is a loss against the MG the
fallback exists to avoid.

---

## 5. E3 — the recycling collision (this is the crux, and it is already measured)

★ **The recycled subspace must be discarded on a DOF-set change; there is no re-map,
and the code already enforces the discard.**

* The carried basis U is `n × k` float columns keyed on `n` = the free-DOF count
  (recycle.hpp:112–115). `RecycleSession::begin` (recycle.cpp:283–284):
  `if (g_space.k > 0 && (g_space.n != n || ...)) rc_reset_space();` — **any** change
  in the free-DOF count drops the entire basis. Elimination changes the free-DOF set
  **every MMA iteration** (as material drains and the band re-derives), so under
  elimination the basis resets every iteration → recycling degenerates to
  **harvest-only, never-apply = 0% cross-solve benefit**, forfeiting the whole −45.4%.
* **Can it be re-mapped instead of discarded?** In principle you could inject/delete
  rows of U at the changed DOF positions and re-orthogonalize — but (a) `E = UᵀAU`
  must be re-formed regardless (k matvecs) because A changed shape; (b) the deflation
  modes ARE the near-rigid-body motions of the weakly-connected solid **near the
  elimination boundary** — exactly the region the moving band invalidates; (c) the
  Ritz vectors were extracted against the old pencil (A, D), and both A and the Jacobi
  metric D change under elimination. Re-mapping preserves storage, not spectral
  meaning. **Honest answer: it must be discarded and re-harvested each time the DOF
  set changes.**
* **The trade has an empirical data point already.** Active Domain IS the band-form of
  this elimination, and PR 209 / the 2026-07-27 AD-arming review measured it on this
  exact big-stagnation fixture, recycling armed in both:

  | posture | CG total (12 capped iters) |
  |---|---|
  | recycling, no AD | **15,349** |
  | recycling + AD (band elimination) | **19,329  (+25.9%)** — AD escaped its band 1008× → reverted to full domain |

  AD **hurts by 26%** on the stagnation case it targets (range across fixtures
  −25%…+26%, mean ≈ −5%, "a coin-flip"), which is why production **disarmed** it. The
  reason is precisely E3: elimination changes the DOF set → recycling resets → you pay
  recycling's setup and AD's O(N) escape scan for a benefit that the reset erased.

**What elimination would need to win:** its reduced-system CG cut must exceed the
−45.4% recycling gives for free, *and* survive the band overhead, *and* not harm MG,
*and* not sever. E4 measured the cut at −26…−38% (Jacobi) and **positive** (MG harm).
It loses on every clause.

---

## 6. B4 — is sensitivity correctness preserved? (does the route close?)

**No hard STOP, but the premise as stated is false in our formulation.** The proposal
says "all design variables stay active so sensitivities remain correct." In our code
that is not automatic:

`simp.cpp:472–493` — the self-adjoint compliance sensitivity is
`dc/dρ_e = −p·ρ_e^{p−1}·E0·(u_eᵀ K_unit u_e)`. For an eliminated (masked-out) element,
simp.cpp:493 does `continue`, leaving **dc/dρ_e = 0 exactly**. The code's own comment
states the consequence: *"an out-of-band voxel sees dc/dρ = 0 and the updater drives
it to the density floor, so it cannot grow before the band grows to admit it."* An
eliminated void element's nodal displacements simply are not computed (they are the
DOFs we removed), so its strain energy — hence its gradient — is unavailable, and the
optimizer freezes that variable at the floor. The design variable stays "active" in
name but its gradient is **zeroed, not correct**.

Correctness is therefore **preservable only by a reintroduction layer** that keeps
valid DOFs where material may reappear:

* **Growth band** — our shipped AD solution. Sound, but the growth invariant is
  *per-iteration* (simp.hpp:166–175), so the band re-derives every iteration → the
  DOF set changes every iteration → the E3 recycling collision is *forced*, and the
  invariant is empirical: it **escaped 6,979 / 1,008 times** on divergent stagnating
  trajectories and reverted to the full domain (the escape-latch amendment).
* **Heaviside boundary amplification** — the paper's mechanism, which our production
  MMA path does not run as a descent driver (handoff 066).

So B4 does not slam the door — but it shows the "sensitivities stay correct for free"
premise is the part that is actually wrong, and repairing it re-introduces exactly the
per-iteration DOF churn that kills recycling and the band-escape fragility that
disarmed AD.

---

## 7. Bars

* **B1 — real stagnation, not a toy.** ✅ The canonical big-stagnation fixture at its
  standard proportional reduction; dilute rungs measurably diverge and the per-rung
  solve cost explodes (the stagnation signature). Absolute cost scales to the
  documented 15,349 CG @48³ / 11.5 h @128³.
* **B2 — threshold stated and swept.** ✅ Void := ρ ≤ ρ_t, swept
  {1.5e-3, 1e-2, 5e-2, 1e-1, 3e-1, 5e-1}; 1.5e-3 = the AD core (1.5·ρ_min). Results
  are extremely sensitive to ρ_t and the sensitivity is adverse (§2/§3).
* **B3 — no production change.** ✅ One standalone probe; zero edits to `src`/`include`.
* **B4 — correctness.** ✅ Reported: preservable only via band/Heaviside; the naive
  "keep all vars active" zeroes the eliminated gradients. Does not hard-close, but the
  repair forces the E3 collision.

---

## 8. Recommendation

**NO-GO for a Phase 1 build of void-DOF elimination as a distinct accelerator.** It is
functionally the Active Domain feature, which already exists, was armed, was reviewed,
and was **disarmed** for the same reasons this trace re-derives from scratch:

1. Size reduction is real (72–95%) but **conditioning is not attacked** at any safe
   threshold (contrast stays ~1e8); the two premises don't co-hold.
2. It **harms the production MG solver** (+85–128% iters, or loss of coarsening) —
   MG-matfree is the production path, and it does not stagnate at solvable scales.
3. Where it helps (Jacobi fallback, −26…−38%) it is **beaten by recycling's free
   −45.4%**, and it **collides with recycling** (measured +26% via AD), which
   production keeps armed.
4. Aggressive thresholds **sever the structure** into singular floating-island
   subsystems.

If anyone revisits this, the *only* regime with a prize is the one AD's review already
named: the ultra-dilute Jacobi-fallback grind at production scale (128³) where MG
itself stagnates — but there elimination still (a) can't beat recycling without
discarding it, (b) risks severance, and (c) hurts MG on the iterations where MG does
carry. The honest scaling lever for that regime remains the AMG-lean rebuild
(`amg-lean-rebuild-unsmoothed-is-the-cure`), not DOF elimination.

**Do not disturb the armed recycling posture or re-arm AD on the strength of the
"60–97% of the system" figure** — that figure is real and is exactly the trap: the
DOFs are removable, but removing them costs more than it saves in every solver the
production path actually uses.

---

## 9. Reproduce

```bash
# library (Eigen via CMAKE_PREFIX_PATH); ~40 s
cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=/opt/homebrew
cmake --build core/build --target topopt -j8
# probe (standalone, not a CTest target); arg = per-rung MMA iteration cap
c++ -std=c++17 -O3 -I core/include core/tests/harness/void_dof_probe.cpp \
    core/build/libtopopt.a -pthread -o /tmp/void_dof_probe
/tmp/void_dof_probe 25 > evidence/2026-07-28-void-dof-elimination-phase0/void_dof_probe.out
```

Deterministic up to the optimizer's own trajectory; the E1/E2 tables and the E4
severance/exception rows are field-derived and stable. The probe leaves the process's
recycling/AD state untouched (recycling explicitly off; galerkin cache restored off).
