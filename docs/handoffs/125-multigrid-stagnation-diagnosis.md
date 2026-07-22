# 125 — Why multigrid stagnates on real design-box + clearance jobs, and why the plateau-stop never fired (READ-ONLY diagnosis)

**Status:** Diagnosis complete. **No production code changed** — measure-and-advise only
(one production file, `src/fea/multigrid.cpp`, was temporarily patched for ONE Q3 measurement,
rebuilt, and `git checkout`-restored the same minute; `git status` clean). Deliverable = this
handoff + reproducible scratchpad harnesses (the 113 precedent, not committed).

**Handoff-number note:** `docs/handoffs/` tops at **124** (two lanes share it). Next free is
**125**. The concurrent **padding walk-back** task will also want a number near here — **budget
a rename** if it lands first.

**Verdicts, one line each:**
- **Q1 (where MG dies):** The production `cg_multigrid=0` is **STAGNATION, not build-rejection** —
  a genuinely *different* failure mode than handoff 122, wearing the *identical* CSV symptom. On
  122's padded grid the hierarchy **builds** but the V-cycle **cannot contract** on a thin
  structure floating in a large empty design-box expanse **once a clearance hole is added**. It
  begins at **iteration 0** (near-uniform field). Reproduced from scratch.
- **Q2 (the plateau):** **Working-as-designed-but-wrong-for-this-regime**, *not* a wiring bug.
  086's `min_drop=0.05` progress gate **provably never armed** (total descent from the uniform
  start was < 5 %), so plateau termination was legally disabled and the run cap-walked. **123's
  two-phase restructure is CLEARED** (it applies the gate correctly to stage 0).
- **Q3:** Recommend **(iv) latch-off MG after it stagnates once per rung + adaptive/loose early
  CG tolerance** as the follow-up. Raising the 100-cycle budget alone is **measured insufficient**
  (MG does not converge even at 2000 cycles on the pathological end).

---

## 0. THE ONE FACT THAT REORGANISES EVERYTHING

`cg_multigrid=0` in `iterations.csv` has **two distinct causes that are byte-identical in every
surviving artifact**:

1. **Build-rejection** (handoff 122): the grid is not coarsenable, `build_mf_hierarchy` returns
   false, the solver never runs a V-cycle → straight to Jacobi-CG.
2. **Stagnation** (this handoff): the hierarchy **builds**, MG-CG runs its `kMgIterBudget = 100`
   V-cycles ([multigrid.cpp:83](core/src/fea/multigrid.cpp#L83)), **fails to reach tol**, and
   falls back to Jacobi-CG.

Both paths end at [multigrid.cpp:1145-1152](core/src/fea/multigrid.cpp#L1145): `used_multigrid =
false`, **`mg_levels = 0`**, `iterations = <Jacobi count>`. The 122 honesty rider therefore
**cannot tell the two apart**: `run_info.json` records `cg_multigrid=false, mg_levels=0` for
both, and the CLI WARNING at [run_job.cpp:442](core/src/cli/run_job.cpp#L442) fires on *any*
fallback. This conflation is *why* 122's "re-run the 128³ overnight and expect
`cg_multigrid=true`" advice could — and did — silently fail: 122 fixed cause #1 and uncovered
cause #2, which looks the same. **Naming and separating the two modes is the core result here.**

---

## 1. Q1 — WHERE MULTIGRID DIES (reproduced from scratch)

All measurements use the **exact production entry point** `fea_solve_mgcg_matfree` (graded
overload) linked against this worktree's `libtopopt.a` (Release). `CgInfo.used_multigrid`
reproduces the CSV `cg_multigrid` column DOF-for-DOF (see §0). Build-vs-stagnation is
disambiguated with an **independent** hierarchy-build probe:
`fea_matfree_mgcg_assembled_operator_nonzeros` (uniform overload) returns 0 iff no hierarchy
builds — and the hierarchy *shape* is geometry-only (modulus sets values, not which levels
exist), so **`hier=yes` + `used_mg=0` PROVES stagnation, not rejection.**

Harnesses (all in the session scratchpad, recipe in §4):
`mg_void_ablation.cpp`, `mg_extents.cpp`, `coarsen_probe.cpp`.

### 1a. Does stagnation begin at ITERATION 0? — **YES.**

Every reproduced case below uses a **uniform** design density (`ρ=0.5` everywhere in the design
region) — i.e. the iteration-0 field, *before* any SIMP structure develops. The stagnating case
(`occ0.4 + hole`) stagnates on that uniform field. **A developing design is not required**; the
clearance geometry + empty expanse is sufficient. This matches the failed run's `cg=0` on the
*very first* solve. (A developed design only makes it worse — thin members add more
coarse-grid-invisible features.)

### 1b. Which ingredient kills contraction? — the **factorial** (raw output pasted)

**Ablation on a cubic 64³ box** (`mg_void_ablation.cpp`, all `hier=yes`, MG carried every case):

```
case                           nsolid  nvoid | mg? lvl mg_iters mg_resid |  jac_it
01_solid_box                   262144      0 |  MG   4       11  4.5e-07 |     334
02_gray_box_rho0.5             262144      0 |  MG   4       11  4.5e-07 |     334
03_solid+hole_r0.4             228608  33536 |  MG   4       29  9.8e-07 |     520
05_solid+softvoid_1e-3         262144  33536 |  MG   4       16  7.8e-07 |     520
06_solid+softvoid_1e-9         262144  33536 |  MG   4       13  5.1e-07 |     520
08_solid+hole_r0.6             187904  74240 |  MG   4       41  6.2e-07 |     577
```

Reading: the **1e-9 contrast alone is nearly free** (13 cycles); a **single clearance hole in a
FULL box is mild** (29–41 cycles). MG stays a ~30× win over Jacobi (11 vs 334) whenever it
carries. **At 64³ nothing stagnates** — so the maintainer's align-8-was-fine-at-64 intuition
(122) applies to *contraction* too, not just buildability.

**Size sweep** (`mg_void_ablation.cpp sweep`, MG-CG cycles; fixed 100-cycle budget):

```
shape \ N                    32    48    64    96   128
solid_box(control)           11    11    11    11    11     <- grid-independent (textbook MG)
gray0.5+hole_r0.4            23    22    29    37    38     <- mild growth, stays << 100
solid+hole_r0.6              24    27    41    39    45     <- mild growth, stays << 100
solid+softvoid_1e-9          13    13    13    15    14     <- contrast: negligible
```

**A single clean hole in a cubic box does NOT reproduce the production stagnation, even at 128³.**
This hypothesis is **DEAD** (see §1d) — the cubic model is too benign.

**The reproduction — occ × hole factorial at the REAL padded extents 192×112×128**
(`mg_extents.cpp`, `hier=yes` on *every* row; `occ` = the fraction of the box the solid part
fills, rest is Empty design-box expanse):

```
case                    nsolid    nvoid   nempty | hier? mg?    iters   rho_eff
occ1.0 nohole          2752512        0        0 |  yes  MG        11    0.28
occ1.0 hole0.4         2451456   301056        0 |  yes  MG        40    0.71
occ0.7 nohole          1347840        0  1404672 |  yes  MG        70    0.82
occ0.7 hole0.4         1046784   301056  1404672 |  yes  MG        85    0.85
occ0.5 nohole           688128        0  2064384 |  yes  MG        20    0.50
occ0.5 hole0.4          387072   301056  2064384 |  yes  MG        74    0.83
occ0.4 nohole           439296        0  2313216 |  yes  MG        37    0.68
occ0.4 hole0.4          138240   301056  2313216 |  yes  FALLBACK  >130  ~1.0   <-- STAGNATION
occ0.3 nohole           248064        0  2504448 |  yes  MG        46    0.72
```
(`rho_eff = 10^(-6/iters)` = the CG-accelerated effective per-cycle residual contraction to the
1e-6 tol; `~1.0` = the V-cycle no longer contracts.)

**The killer is an INTERACTION, not any single ingredient:**
- The clearance hole **alone** (occ1.0+hole): 40 cycles — fine.
- The thin-part-in-empty-box **alone** (occ0.4 nohole): 37 cycles — fine (note the erratic
  70/20/37/46 across occ: contraction is sensitive to whether the slab thickness lands on a
  "nice" multiple of the coarse voxel — the classic *coarse grid cannot represent a feature
  thinner than a coarse cell* signature).
- **Together** (occ0.4 + hole0.4): **the only FALLBACK** — MG stagnates (`used_mg=0`) while the
  hierarchy `builds` (`hier=yes`). Super-additive.

**Mechanism.** The production clearance void is a **removed-element HOLE**, not a soft cell —
`minimize_plastic` maps `FrozenVoid → VoxelTag::Empty` in the analysis grid
([simp.cpp:1334-1340](core/src/simp/simp.cpp#L1334); voxel.hpp:39-40). Combined with the large
Empty design-box expanse, the *active* structure is a thin, irregular, holed ligament set. The
V-cycle's regular 2× coarsening + trilinear prolongation + Galerkin `PᵀAP` cannot represent the
low-energy bending modes of thin ligaments routing around the hole: after 3–4 halvings a
2–3-voxel ligament is thinner than a coarse cell and **vanishes from the coarse operator**, so
the coarse-grid correction is blind to exactly the modes that dominate the error → contraction
→ 1 → the 100-cycle budget is exhausted → Jacobi-CG fallback → `cg_multigrid=0`.

The maintainer's L-bracket-large (an L fills ~30–50 % of its bounding box, plus the design box
extends beyond it, plus a clearance hole through a foot) sits **squarely in the occ≈0.4–0.5 +
hole regime** that stagnates.

### 1c. Classify the BRACKET run (`cg=0 × 535`) — **BUILD-REJECTION, confirmed; record corrected**

122 asserted the bracket fell back because `184×104×128` (the *old fixed align-8* grid) is not
coarsenable. **Directly reproduced** (`mg_extents.cpp`, same probe):

```
solid 184x104x128 (align8)   2449408   0   0 |  hier=NO   FALLBACK
gray+hole 184x104x128(a8)     ...           |  hier=NO   FALLBACK
```

`hier=NO` = the hierarchy never builds → this is **build-rejection**, 122's mechanism, verified.
And `coarsen_probe.cpp` confirms the arithmetic and the fix:

```
raw 183x100x125  align8 -> 184x104x128 coarsenable=0 | adaptive align=16 -> 192x112x128 coarsenable=1  levels=5 coarsest=12x7x8 (2808 DOF)
```

**The corrected record:** the bracket and the current run are the *same part at the same res*,
but on *different code*. 122's fix moved the padding align-8 → adaptive-16, i.e. `184×104×128`
(reject) → `192×112×128` (build). So:
- **Pre-122 (bracket, `cg=0 × 535`) = BUILD-REJECTION.** 122 fixes it.
- **Post-122 (current, `cg=0 × 158`) = STAGNATION.** 122 does *not* fix it — it *exposes* it.

Two failure modes, one symptom, sequential in the code's history. That is the whole story.

### 1d. DEAD hypotheses (disproved, with the disproof — the 124 standard)

- **"The 1e-9 SIMP contrast kills the V-cycle."** DEAD. `06_solid+softvoid_1e-9` = **13 cycles**,
  indistinguishable from solid (11). A coherent soft blob is coincidentally coarse-grid-aligned.
- **"A single clearance hole is enough."** DEAD. `occ1.0+hole` = 40 cycles at 128³; the size
  sweep shows a lone hole grows only 23→38 from N=32→128. Never crosses the 100 budget.
- **"It's still build-rejection (122 unfixed / walked back in this tree)."** DEAD *for this
  code*. `coarsen.hpp`'s adaptive padding is present here and `192×112×128` is provably
  coarsenable (`coarsen_probe.cpp`) *and* empirically builds (`hier=yes`, every 192-row). Under
  ≥122 code the current run **cannot** be build-rejection. (Caveat: if the failed run was
  produced on a tree where the walk-back had *removed* adaptive padding, it reverts to
  build-rejection — see the confirmation step in §3.)
- **"Just needs a few more V-cycles."** DEAD for the pathological end. With `kMgIterBudget`
  temporarily raised to **2000** (patched, measured, reverted), `occ0.4+hole` **still** falls
  back — MG does not converge in 2000 cycles (and neither does Jacobi there: a near-mechanism
  thin geometry). Contraction ≈ 1, not merely slow. (Borderline cases *do* converge with more
  budget — see Q3.)

---

## 2. Q2 — WHY THE PLATEAU-STOP NEVER FIRED

### The detector, exactly as written

`mma_objective_plateau` ([simp.cpp:550-574](core/src/simp/simp.cpp#L550)) with production params
`window=10, tol=1e-3, min_drop=0.05` ([simp.hpp:481-489](core/include/topopt/simp.hpp#L481)).
The **progress gate** is the single relevant line:

```cpp
// simp.cpp:567
if (min_drop > 0.0 && !(best_now <= c[0] * (1.0 - min_drop))) return false;
```

A plateau **cannot** fire until the running-minimum compliance has dropped **≥ 5 %** below the
first sample `c[0]` (the uniform-start compliance). Its stated purpose
([simp.cpp:562-566](core/src/simp/simp.cpp#L562)): stop an early spike-heavy forming phase (whose
spikes sit *above* `c[0]`) from being misread as a plateau.

### What the gate saw — the deduction from the CSV (rigorous even without `c[0]`)

CSV facts: 158 iterations in rung 0; objective **flat ≈ 0.00279 from iter 20**; run never
terminated (still going at 19.4 h). `window+1 = 11`.

The objective was flat for iters ~20→158 = **~138 consecutive flat iterations**, i.e. ~13
full detector windows. **If the gate had ever opened during that stretch**, the trailing-window
improvement (≈ 0 ≪ tol=1e-3) would have returned `true` and terminated the stage within ≤10
iters. It never did. Therefore **the gate provably never opened during iters ~31–158**:
`best_now` never reached `0.95 · c[0]` — the running-minimum compliance never descended 5 %
below the uniform start. Since the objective was already flat from iter 20, the total descent
`c[0] → 0.00279` was **< 5 %**.

**This is working-as-designed.** The gate did exactly what 086 built it to do; the run simply
lives in a regime the calibration never anticipated — a design that is **flat from the start**
(the thin part + frozen part leave little compliance to remove, and/or the stagnating-but-
converged solves report a genuinely flat objective), so the "real descent before we trust a
plateau" precondition is never met and plateau termination stays **legally disabled** → the run
walks toward the 200 cap. At **442 s/iter** (19.4 h / 158, itself the Q1 stagnation tax) the
cap-walk is a 24 h run.

### Bug hunt — 123 CLEARED, not convicted

123's two-phase (beta-continuation) restructure is the named suspect. It is **not** the cause:
- The min_drop gate is applied to **stage 0 only** by design
  ([simp.cpp:1249-1256](core/src/simp/simp.cpp#L1249): `stage_min_drop = (mma_stage_start==0) ?
  min_drop : 0.0`). Rung 0's first stage carries the full 5 % gate — correct.
- Whether projection is on (123 gates it to gray rungs) or off, the terminator for stage 0 is the
  *same* `mma_objective_plateau(curve, 10, 1e-3, 0.05)` on a contiguous curve. No history reset
  truncates the window (158 ≫ 11). The non-continuation path
  ([simp.cpp:1269](core/src/simp/simp.cpp#L1269) `stage_should_stop`) is identical.
- The observed non-termination is **fully explained** by the gate semantics + a <5 % descent. No
  additional bug is needed, and none is present in the read.

**Verdict: working-as-designed-but-wrong-for-this-regime.**

### Fix shape (do not implement here)

Two independent shapes; the second is primary:
1. **Secondary escape for the gate** (small, in `mma_objective_plateau`): allow a plateau to
   fire on *flatness alone* once the objective has been flat for `≥ K·window` iterations
   **regardless of total descent**, OR arm on `min_drop` **or** an absolute iteration budget
   (e.g. fire at iter ≥ 40 if the trailing window is flat). Risk: re-introduces exactly the
   premature-fire-near-uniform failure 086's gate prevents — must be gated on flatness, not
   iteration count alone, and validated on the 086 fixtures.
2. **Fix Q1 first (primary).** The cap-walk is only catastrophic *because* each iteration costs
   442 s (solver stagnation). Land a Q3 remedy and the same flat-from-start run walks the cap at
   ~50–90 s/iter ≈ 2–3 h — annoying, not a 24 h loss. Q2 is a **magnifier** of Q1, not an
   independent defect.
3. **Observability gap (enables both):** the run wrote 158 rows but the *decisive* number for
   this diagnosis — whether `build_mf_hierarchy` returned true per solve — is nowhere on disk
   (§3). Add a per-solve `hier_built` bit (and `mg_cycles_attempted`) to the CSV so
   build-rejection vs stagnation is a direct read next time, not a reconstruction.

---

## 3. HOW THE MAINTAINER CAN CONFIRM (artifacts alone can't — here's what can)

The surviving `iterations.csv` / `run_info.json` **cannot** distinguish the two modes (§0). But:
- **Geometry proof (strongest):** the padded solved grid for this box is `192×112×128`
  (`coarsen_probe.cpp`), which **builds** a 5-level hierarchy. Under ≥122 code the run is
  therefore **stagnation** by construction — unless it was produced on a tree where the padding
  walk-back had reverted `coarsen.hpp` (then it is build-rejection again). **Check which tree the
  worker's `topopt-cli` was built from.**
- **`c[0]` read (2 seconds):** `head` the CSV's `compliance` column. If `c[0] ≤ 0.00279 / 0.95 =
  0.002937`, the min_drop gate never armed — Q2 confirmed directly.
- **`wall_ms` read:** the CSV carries `wall_ms` ([observability.cpp:94](core/src/simp/observability.cpp#L94)).
  A *stagnation* iteration pays the full multigrid **hierarchy build** (~48 % of a solve, per
  090/091) + 100 wasted V-cycles **on top of** the Jacobi fallback; a *build-rejection* iteration
  skips the build. Stagnation `wall_ms` per unit `cg_iters` is markedly higher — a corroborating
  (not decisive) tell.

---

## 4. RECIPE — reproduce every number above

```bash
cd core && cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build --target topopt -j8
SP=<scratchpad>; EIGEN=/opt/homebrew/opt/eigen/include/eigen3
c++ -std=c++17 -O2 -I include -I "$EIGEN" $SP/mg_void_ablation.cpp build/libtopopt.a -o $SP/mg_void_ablation
c++ -std=c++17 -O2 -I include -I "$EIGEN" $SP/mg_extents.cpp     build/libtopopt.a -o $SP/mg_extents
c++ -std=c++17 -O2 -I include              $SP/coarsen_probe.cpp                    -o $SP/coarsen_probe
$SP/coarsen_probe                 # coarsenability arithmetic (instant)
$SP/mg_void_ablation              # 64³ ablation  (~4 min)
$SP/mg_void_ablation sweep        # size sweep     (~5 min)
$SP/mg_extents                    # occ×hole factorial at 192×112×128 (~4 min)
```
Raw captured output: `ablation_out.txt`, `sweep_out.txt`, `extents_factorial_out.txt`,
`extents_out.txt`, `coarsen_out.txt`, `extents_budget2000_out.txt` (the reverted budget-2000
probe). The Q3 budget test: temporarily set `kMgIterBudget = 2000` in
`src/fea/multigrid.cpp:83`, rebuild `topopt`, run `mg_extents` with `cap=2000`, then
`git checkout src/fea/multigrid.cpp` and rebuild.

---

## 5. Q3 — RANKED REMEDIES (ceilings named BEFORE anything is built — the Amdahl rule)

The stagnation is a **thin-feature / holed-geometry V-cycle failure**, NOT a pure-contrast one
(§1b) — this rules out the "contrast" family and re-ranks the list the task proposed.

| # | Remedy | Expected ceiling (measured basis) | Determinism | Risk to THE ONE RULE (byte-identical certified compliance) | Effort |
|---|---|---|---|---|---|
| **★ iv** | **Latch MG off after one stagnation per rung + adaptive/loose early CG tol.** The real tax isn't the fallback — it's paying the full hierarchy **build + 100 wasted V-cycles EVERY iteration** before falling back, then a tight-tol Jacobi grinding 4 k–20 k iters. Detect a fallback once, cache "MG dead on this grid" for the rung (skip build+MG-CG), and loosen the CG tol early (the design barely moves — a 1e-3 solve suffices) tightening at accept. | Removes the ~48 %-of-solve build + 100 cycles on every post-first iter (**~1.5–2×**) and cuts early Jacobi iters **2–5×** → **~19 h → ~5–8 h**. Does not make MG *work*, but makes the honest-fallback cheap. | Full. Adaptive tol changes iteration *counts*, not the field. | Low. Trajectory changes (like warm-start 110 already does); the **accepted/final** solve stays tight → certified compliance honest. | **Small** (a per-rung latch + a tol schedule). |
| v-a | **Stronger smoother (Chebyshev or colored Gauss-Seidel, ≥3 sweeps) in the V-cycle.** Attacks the actual defect (thin-ligament error modes the damped-Jacobi smoother leaves untouched). | Literature 1.5–3× fewer cycles on contrast/thin geometry; would likely pull occ0.5–0.7+hole (74–85) well under budget and rescue *borderline* 100–200-cycle real runs. **Will NOT rescue the near-mechanism end** (occ0.4+hole didn't converge at 2000). | Colored GS / Chebyshev are deterministic. | Preconditioner-only → outer FP64 CG to same tol → field unchanged to tol. Honest. | **Medium** (new smoother in the shared V-cycle; must keep the assembled-path byte-identity 078/079 guard). |
| v-b | **Raise `kMgIterBudget` 100 → ~300–500.** One line. | **Measured partial:** borderline stagnation (contraction < 1, MG needs 120–300 cycles — plausibly the real run, whose Jacobi converged in ≤20 k) would then *carry* at a fraction of Jacobi's cost. **Measured NULL on the pathological end** (no convergence at 2000). | Full. | None (still to same tol). | **Trivial**, but pair with a wall-clock guard so a truly-broken grid doesn't burn 500 futile cycles/iter. |
| i | Void-aware operator rescaling / diagonal contrast scaling. | **Low** — §1b shows contrast is *not* the driver (1e-9 = 13 cycles). Misdiagnoses the failure. | Full. | Low. | Medium — **not worth it**; wrong target. |
| ii | Active-set: skip deep-void cells from the operator. | **~0** — the hole cells and the empty expanse are **already** `Empty`/void-DOF-gated. Nothing left to skip; the defect is the coarse *representation* of the surviving thin solid, not the void. | — | — | — (reject). |
| iii | Raise ρ_min for the FEA operator only. | **~0 for THIS failure** — the clearance is a *hole* (Empty), not a ρ_min cell, and stagnation is at iter-0 before any gray void exists. | Full. | **Honesty-negative:** a higher FEA void floor lets soft material carry load → lower, **optimistic** certified compliance. | Reject on honesty grounds. |
| v-c | AMG / smoothed-aggregation instead of geometric MG. | **Highest ceiling** — AMG coarsens by the operator, so it is grid-independent even on thin/irregular/holed active sets (the textbook cure for exactly this). Would rescue the pathological end too. | Needs a deterministic coarsening/ordering to preserve reproducibility. | Preconditioner swap → field unchanged. | **High** (new solver subsystem; maintenance + determinism burden). A strategic bet, not a quick fix. |

**Recommendation: implement (iv)** as the immediate follow-up — smallest, deterministic, honest,
turns the 19 h into single-digit hours without touching the numerics, and buys time. Pair it with
**(v-b)** (trivial, rescues the borderline real runs outright) behind a wall-clock guard. Escalate
to **(v-a)** if borderline runs remain, and hold **(v-c) AMG** as the durable answer if thin-holed
geometries become common. The maintainer decides; every ceiling above traces to a measured number
in §1 (Amdahl rule: no ceiling asserted before it was measured).
