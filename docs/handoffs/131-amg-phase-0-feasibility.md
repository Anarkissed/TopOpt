# 131 — AMG Phase 0: does algebraic multigrid contract on OUR pathology? (measure-first, HARNESS ONLY)

**Status:** Feasibility measurement complete. **NO production code changed** — `git status`
shows exactly two new files, both under `core/tests/harness/`, neither compiled into
`libtopopt.a` nor referenced by CTest nor included by any production translation unit.
Deliverable = this handoff + a **committed, reproducible harness** (an improvement on the
113/125 precedent, which left its probes in a session scratchpad and could not be re-run).

**Handoff number:** `docs/handoffs/` tops at **130** on `main` (126 is a pre-existing gap);
`gh pr list --state open` returned **none**. This takes **131**.

**Track:** core measurement only. **Parallel-legal:** adds two files, edits none.

**Verdicts, one line each — the full statement is §5:**

- **R1 (the stagnation regime): GO on intent, MISS on the literal number.** On **3 of 3**
  fixtures where geometric MG exhausts its 300-cycle budget and falls back
  (`hier_built=1, used_mg=0`), AMG **builds and carries** — 32/37/63 PCG cycles against
  1357/3602/1607 Jacobi iterations, i.e. **25–97× fewer outer iterations**. But the
  measured contraction (stationary 0.89–0.93, CG-accelerated ρ_eff 0.65–0.80) **misses the
  stated ≤0.5 bar** — a bar §4 shows is also missed by *both* methods on a perfectly
  healthy solid box, so it cannot discriminate (§5c).
- **R2 (the build-rejection regime): PASS, 2 of 2, and on the bar's own number.** Where
  the geometric builder **refuses to build at all** (`hier_built=0`), AMG builds and
  converges in **19 cycles** on both fixtures — **ρ_eff 0.483, meeting ≤0.5** — against
  438 and 518 Jacobi iterations. Also see §3a: a measured correction to the
  coarsenability record.
- **R3 (the healthy control): PASS with room.** AMG within **1.07–1.29×** of geometric's
  cycle count on clean boxes and **1.7× better** on the box-with-a-bore. **No regime split
  needed.**
- **R1b (a SECOND point on the solve sequence — §2d): the result that undercuts the
  headline, stated up front.** On a developed-design-like field (thin members + ~10⁵
  contrast) AMG still carries — 133 cycles vs 13 741 Jacobi iterations (**103×**), and
  88 vs 3 565 (**40×**) — but its setup blows up 6.7×, its coarse operators go **100 %
  dense**, and its total wall-clock goes from **2.1× faster** than the failing geometric
  path to **1.11× and 4.1× SLOWER**. A real run lives here, not at iteration 0. **The
  iteration win is robust; the §2b speed-up is not, and must not be extrapolated
  end-to-end.** The same section also shows contrast on sub-coarse-cell members stagnates
  geometric MG *on a clean 48³ box with clean extents* — refining (not contradicting)
  125 §1d's dead "contrast" hypothesis, which was tested on a coarse-grid-aligned blob.
- **R4 (the costs): setup tax is ordinary; MEMORY is the blocker.** Setup is 32–83 % of
  AMG time — the same category as the geometric Galerkin rebuild this project already pays
  every MMA iteration (090: ~48 %, 112: ~66 %). But the AMG hierarchy is **23.3×** the
  geometric matrix-free footprint (2 072 MB vs 88.9 MB at 804 864 DOF) because it
  **assembles the fine matrix 078 deliberately removed**. That, not contraction, gates
  Phase 1 (§6c, §7a).
- **R5 (determinism): IDENTICAL, every case.** Two independent setups per case,
  `memcmp` on every level's `A`/`P` and on the residual history. Bit-identity, not
  agreement-to-tolerance.

---

## 0. WHAT WAS BUILT, AND WHY IT IS TRUSTWORTHY

Two files, both harness-only:

| file | what it is |
|---|---|
| `core/tests/harness/amg_sa.hpp` | A standalone **smoothed-aggregation AMG** (Vanek/Mandel/Brezina, elasticity flavour): node-block strength graph → 3-phase greedy aggregation → tentative prolongator from a 6-rigid-body-mode near-nullspace with per-aggregate modified Gram-Schmidt → Jacobi-smoothed prolongator → Galerkin `PᵀAP` → V-cycle with symmetric Gauss-Seidel and a dense LDLᵀ bottom. Standard library only — **no Eigen, no hypre, no ML/AMGX, no new dependency**. |
| `core/tests/harness/amg_probe.cpp` | The measurement driver: fixtures, the geometric/Jacobi baselines through the **production entry points**, the contraction/cost/determinism tables. Modes: `extents correctness hunt stagnation developed reject healthy sweep costs all`. |

### 0a. The systems are the PRODUCTION systems, not a re-derivation

The probe does not build its own linear system. It calls
`fea_detail::mf_build_reduced` — the *same* function `fea_solve_mgcg_matfree`
calls — to get the BC-reduced, void-gated element table, then assembles that
identical operator `K_gg` into CSR. Same element table, same M3.1 void gate, same
free-DOF numbering, same RHS. So "AMG on the same system as geometric MG" is true
**by construction**, not by reconstruction.

The geometric and Jacobi baselines are the real library calls
(`fea_solve_mgcg_matfree`, `fea_solve_cg_matfree`) against this worktree's Release
`libtopopt.a`, and they are read through **128's new `CgInfo::hier_built` /
`mg_cycles_attempted`** — so build-rejection and stagnation are a *direct read*
here, exactly as 128 §3 intended, with no inference from `cg_multigrid=0`.

### 0b. Correctness first (the task's precondition)

On a small healthy system (16³ solid, 13 872 reduced DOF) the AMG-PCG solution is
compared against the library's own solver at a tight tolerance:

```
   reference Jacobi-CG: iters=189 resid=8.86e-13 | AMG-PCG: cycles=23 resid=3.59e-13 converged=yes
   max|u_ref|=1.327923e-02  max|u_amg - u_ref|=1.103e-15  relative=8.308e-14
   assembled-CSR symmetry max|A - A^T| = 2.842e-14
   VERDICT: PASS (bar: relative difference <= 1e-8)
```

Relative difference **8.3e-14** against a **1e-8** bar. The assembled CSR is symmetric
to 2.8e-14 (accumulation-order roundoff only). The prototype solves the right system.

### 0c. Determinism (R5) — asserted, every case

The prototype is deterministic **by construction**, not by luck: no threads, no
atomics, no randomness (the prolongator smoother's spectral scale is a closed-form
**Gershgorin bound**, deliberately chosen over a power iteration so there is no random
start vector), ascending traversal everywhere, smallest-index tie-breaks, sorted column
emission, fixed floating-point summation order. The aggregation rule is written out in
full at `amg_sa.hpp:aggregate()` and reproduced in §1b below.

Every case runs **two independent setups** and bit-compares (a) every level's `A` values,
`A` column indices and `P` values via `memcmp` on raw bytes, and (b) the stationary
residual history. **Result: IDENTICAL on every case measured.** Not "agrees to
tolerance" — bit-identical.

---

## 1. METHOD AND FIXTURES

### 1a. The fixture rule (stated explicitly, because 125's could not be recovered)

125's `mg_extents.cpp` lived in a session scratchpad and was never committed, so its
exact geometry is unrecoverable. This harness therefore states its own rule and proves
provenance by **reproducing 125's measured signature**, not by matching its source:

* A design box of `(ex, ey, ez)` elements at spacing 1 mm.
* The **part** is a centred prism of `round(occ·ex) × round(occ·ey) × ez` — a column
  spanning the full box height, floating in an otherwise **Empty** design-box expanse.
* A **clearance bore** of radius `hole · min(ex,ey)/2` along the given axis, centred on
  the box, is **removed** (`VoxelTag::Empty`) — the production clearance is a removed
  element, not a soft cell (125 §1b; `simp.cpp` maps `FrozenVoid → Empty`). Its size is a
  property of the **box**, not the part, matching 125's constant `nvoid` across `occ`.
* Design density **uniform ρ = 0.5** — the iteration-0 field. 125 §1a established the
  stagnation begins there; a developed design is not required.
* BCs: all three components of every part node on the `z=0` face that a solid element
  touches. Load: a transverse (+x) shear resultant spread over the part nodes at `z=ez`
  — **bending**, the low-energy mode a coarse grid loses first.

**Provenance check.** At 64³ with `bore 0.40` this rule produces
`solid=228608, bore-removed=33536` — **digit-for-digit 125 §1b's `03_solid+hole_r0.4`
row** (`nsolid 228608  nvoid 33536`). The fixture family is 125's.

**Honest divergence.** At the padded `192×112×128` extents the *empty expanse* also
matches closely (this harness 2 308 992 vs 125's 2 313 216) but the bore is smaller
(200 704 removed vs 125's 301 056 — 125's radius was ≈0.49 of the box half-width, not
0.40). The part cross-section differs by 33 voxels/slice (77×45 here vs 78×44 there).
These are *different fixtures in the same family*; the claim below rests on this
harness's own geometric baseline reproducing the stagnation, which it does (§2).

### 1b. The aggregation rule (the task's "document it" requirement)

Verbatim from `amg_sa.hpp`:

```
PHASE 1 — root selection.
  for a = 0 .. N-1 (ASCENDING):
    if a is unassigned AND every strong neighbour of a is unassigned:
      open a new aggregate; assign a and all its strong neighbours to it.
PHASE 2 — enlargement.
  Snapshot the phase-1 assignment first, so phase 2 never chains onto an
  aggregate that phase 2 itself grew.
  for a = 0 .. N-1 (ASCENDING):
    if a is unassigned and has >= 1 strong neighbour assigned IN PHASE 1:
      join the aggregate of the SMALLEST-INDEXED such neighbour.
PHASE 3 — leftovers.
  for a = 0 .. N-1 (ASCENDING):
    if a is still unassigned:
      open a new aggregate holding a and every still-unassigned strong neighbour.
```

Strength is the **operator's**, never the grid's: nodes `a,b` are strongly coupled iff
`||A_ab||_F ≥ θ·sqrt(||A_aa||_F·||A_bb||_F)`, θ = 0.08 default. In a SIMP field a
coupling through near-void material fails that test automatically — this is the
density-aware coarsening the task is after, and it is why **no coarsenability
arithmetic exists anywhere in the method**.

### 1c. The two contraction metrics (read this before the tables)

There are two, and conflating them is the easiest way to get a wrong verdict:

| metric | what it is | who quotes it |
|---|---|---|
| **stationary contraction** | `r_{k+1}/r_k` of the plain V-cycle iteration with **no** Krylov acceleration. The method's intrinsic rate. | this handoff (new) |
| **ρ_eff = tol^(1/cycles)** | the **CG-accelerated** effective per-cycle rate to reach tol. | **125 §1b quotes this** (`rho_eff = 10^(-6/iters)`), and so does every geometric number in 125. |

**The task's GO bar ("sustained overall contraction ≤ ~0.5") is stated in the language
of 125, whose numbers are ρ_eff.** Applying the bar to the *stationary* rate instead
would be a category error, because — as §4 shows — **standard SA does not meet a
stationary 0.5 even on a perfectly healthy solid box** (it measures 0.78–0.83 there);
that is textbook behaviour for aggressive aggregation, which is designed to be used
*with* CG. Both numbers are reported for every case; the verdict is taken against
ρ_eff (125-comparable) and the stationary rate is reported as the stricter intrinsic
number, so nothing is hidden either way.

---

## 2. R1 — THE STAGNATION REGIME (the 125 killer)

**Bar (stated before measuring): GO iff sustained contraction ≤ ~0.5 — i.e. AMG carries
where geometric stagnates.**

### 2a. The pathology is reproduced, and 128's diagnostics name it directly

`192×112×128`, `occ 0.40` + `bore 0.40`, uniform ρ=0.5 — **804 864 reduced DOF**
(242 816 solid elements, 200 704 bore-removed, 2 308 992 empty expanse). Raw capture:

```
GEOMETRIC (fea_solve_mgcg_matfree): hier_built=1 used_mg=0 levels=0 mg_cycles=300
                                    cg_iters=3602 resid=9.97e-07  71.27s
   -> geometric FELL BACK (STAGNATION: hierarchy built)
JACOBI-CG baseline: iters=3602 resid=9.97e-07 44.62s
```

`hier_built=1` with `used_mg=0` and `mg_cycles=300` is **125's stagnation mode, read
directly off 128's new diagnostics** — the hierarchy builds, the V-cycle exhausts the
*post-128* 300-cycle budget without reaching tolerance, and the solve falls back to
3602 Jacobi-CG iterations. Not build-rejection. No reconstruction needed. This is the
first time that distinction has been made from a live instrument rather than inferred.

Two supporting rows from the same run confirm 125's **super-additivity** finding on this
harness's own fixture rule:

| fixture | geometric | reading |
|---|---|---|
| `occ0.40` + `bore0.40` | `used_mg=0`, budget-300 exhausted, 3602 Jacobi iters | **stagnation** |
| `occ0.40` no bore (1 377 792 DOF) | `used_mg=1`, **157** cycles, ρ_eff **0.916** | carries, but only because 128 raised the budget 100→300 — this is 128 §A's "borderline band" caught live |
| `64³` solid + `bore0.40` (720 384 DOF) | `used_mg=1`, **33** cycles, ρ_eff 0.658 | a bore alone is survivable |

Thin-part-alone survives (barely, and only post-128). Bore-alone survives. **Together
they stagnate.** That is 125 §1b's interaction, independently reproduced.

`./amg_probe hunt` (geometric baseline only, no AMG) pins the healthy end of the same
factorial at the real extents, and it lands on top of 125's numbers:

```
   case                    solid    red.DOF   hier usedMG   mg_cyc    cg_it   rho_eff
   occ1.00 bore0.00      2752512    8374656      1      1       14       14     0.373
   occ1.00 bore0.40      2551808    7805952      1      1       43       43     0.725
```

125 §1b measured **11** and **40** cycles for the same two configurations. Together with
the exact `64³` voxel-count match (§1a), that is as close to provenance as a
non-committed predecessor harness allows. *(The lower-`occ` rows of this factorial were
cut when the run went swap-bound — see §8.)*

### 2b. AMG on the identical system

```
    level      n        nnz    nnz/row   aggregates
        0   804864   60742584     75.5        11210
        1    67260   21123079    314.1         1238
        2     7428    5355864    721.0          165
        3      990     568764    574.5            0
    coarsest n=990 dense-LDL^T=yes  hierarchy memory=2071.6 MB

AMG stationary V-cycle: cycles=60 converged=NO final_rel=4.41e-03
                        contraction overall=0.914 sustained=0.902 worst=0.914
AMG-PCG: cycles=37 converged=yes | setup 17.04s, solve 17.72s, 0.479s/cycle | 2071.6 MB
DETERMINISM: IDENTICAL
```

**AMG builds a 4-level hierarchy on the geometry that defeats the geometric V-cycle, and
carries the solve in 37 cycles.**

| metric | geometric | AMG | note |
|---|---|---|---|
| carries the solve? | **NO** (budget-300 exhausted) | **YES** (37 PCG cycles) | the qualitative answer |
| outer iterations to 1e-6 | 3602 (Jacobi fallback) | **37** | **97× fewer** |
| ρ_eff (125's metric) | **≈1.0** (MG); 0.996 (Jacobi) | **0.688** | |
| stationary contraction | not reached in 300 cycles | 0.902 | the strict intrinsic rate |
| wall to solve | 71.3 s (threaded library) | 34.8 s (single-threaded prototype) | **2.05×**, before counting CSR assembly (§6) |

### 2c. Per-level contraction — where the rate is lost

Each level's own system solved by the sub-hierarchy beneath it:

```
   level 0 (n=804864): cycles=40 NO  overall=0.917 sustained=0.893
   level 1 (n= 67260): cycles=40 NO  overall=0.858 sustained=0.887
   level 2 (n=  7428): cycles=40 NO  overall=0.761 sustained=0.793
   level 3 (n=   990): coarsest — solved directly
```

Contraction **improves monotonically with depth** (0.893 → 0.887 → 0.793). The coarse
hierarchy is healthy; the loss is concentrated at the **fine level**, i.e. in the
smoother/aggregate size, **not** in the coarsening's ability to see the geometry. That
is the opposite of the geometric failure 125 diagnosed (where the *coarse operator* goes
blind to sub-cell ligaments) and it is the actionable difference: a fine-level smoother
is a knob (§4b), coarse-grid blindness is not.

### 2d. A SECOND point on the solve sequence

Everything above is the **iteration-0** field (uniform ρ=0.5). 125 §1a established that
the stagnation already begins there, which is why it is the right first probe — but "the
same systems **across the solve sequence**" needs more than one point, and a *developed*
design adds the thing iteration 0 lacks: **high modulus contrast carried on thin
members**, both at once.

**Scope, stated plainly:** a true trajectory sweep needs an optimizer run (hours at these
sizes) and **was not done**. Instead the same geometry carries a deterministic synthetic
lattice density — thin axial columns on an 8-voxel pitch, 2 voxels thick, plus a tie layer
every 16 in z, at ρ=1.0 against ρ=0.02 elsewhere, so E = ρ³E₀ gives a **≈1.25 × 10⁵**
modulus contrast on sub-coarse-cell members. It is documented, reproducible and
deterministic, but it is **synthetic, not optimizer output**, and no claim here rests on
it being a faithful SIMP iterate.

**This is where the study is least flattering to AMG, and it is the point a real optimizer
run spends most of its iterations at. It is reported first and in full.**

```
== occ0.40+bore0.40 LATTICE   192x112x128, 804 864 DOF
GEOMETRIC: hier_built=1 used_mg=0 mg_cycles=300 cg_iters=13741 resid=9.72e-07  191.94s
   -> STAGNATION again (hierarchy builds, budget-300 exhausted)
JACOBI-CG baseline: iters=13741  155.64s

    level      n        nnz    nnz/row   aggregates
        0   804864   60742584     75.5        12681
        1    76086   24558782    322.8         2473
        2    14838   17049204   1149.0          807
        3     4842   11488356   2372.6          600
        4     3600   12960000   3600.0          587      <-- 100% DENSE
    coarsest n=3600  hierarchy memory=3296.3 MB

AMG stationary V-cycle: cycles=60 converged=NO | overall=1.009 sustained=0.988 worst=0.990
AMG-PCG: cycles=133 converged=yes | setup 113.85s, solve 99.99s, 0.752s/cycle | 3296.3 MB
DETERMINISM: IDENTICAL
per-level sub-hierarchy contraction:
   level 0 (n=804864): sustained 0.985
   level 1 (n= 76086): sustained 0.979
   level 2 (n= 14838): sustained 0.958
   level 3 (n=  4842): sustained 0.900
```

The per-level ladder is the diagnostic. On the iteration-0 field (§2c) and on the
build-rejected fixtures (§3b) contraction **recovers sharply with depth** — 0.808 → 0.605
→ 0.398 → 0.223 in the best case — proving the coarsening sees the geometry. Here it
recovers only from 0.985 to 0.900: **every level is bad**. The coarsening itself, not just
the fine-level smoother, has lost quality under the ~10⁵ contrast.

| | iteration-0 field (§2b) | developed-design field |
|---|---:|---:|
| geometric | 300 cycles → **3602** Jacobi, 71.3 s | 300 cycles → **13741** Jacobi, 191.9 s |
| AMG stationary sustained | 0.902 | **0.988** — the V-cycle barely contracts at all |
| AMG-PCG cycles | 37 | **133** |
| AMG ρ_eff | 0.688 | **0.902** |
| outer-iteration win | 97× | **103×** (holds) |
| AMG setup / solve | 17.0 / 17.7 s | **113.9 / 100.0 s** |
| AMG total vs geometric total | 34.8 s vs 71.3 s (**2.1× faster**) | 213.8 s vs 191.9 s (**1.11× SLOWER**) |
| hierarchy memory | 2 072 MB | **3 296 MB** |

**Three honest conclusions, in order of importance:**

1. **The wall-clock win evaporates here.** At iteration 0 AMG was 2.1× faster than the
   failing geometric path; on the developed-design proxy it is **1.11× slower**. Since a
   real run spends almost all of its iterations *away* from iteration 0, **the §2b
   speed-up must not be extrapolated to an end-to-end run.** The headline economics of
   this study rest on the easiest point of the sequence, and this is the correction.
2. **The iteration win does hold** — 103×, essentially unchanged. AMG still *carries* a
   solve geometric cannot, on a field where the Jacobi fallback needs 13 741 iterations.
   The 5-of-5 "no fixture defeated AMG" claim survives; the *cost* claim does not.
3. **The cause is identifiable and is the un-swept knob.** The coarsening ratio collapses
   down the hierarchy — 10.6× → 5.1× → 3.1× → **1.35×** — and the coarse operators fill in
   until level 4 is **100 % dense** (3600 nnz/row on 3600 rows). That is what makes setup
   explode from 17 s to 114 s and memory from 2.1 GB to 3.3 GB. It is a classic
   smoothed-aggregation failure mode on high-contrast fields, and the levers for it
   (strength threshold / aggregate size / a hard level cap) are **exactly the ones §4b
   records as NOT swept**. So this is a *measured weakness of this prototype's tuning*, not
   a demonstrated intrinsic limit of AMG — but it is unfixed here, and no Phase-1 estimate
   may assume it away.

#### A control that REFINES 125's dead "contrast" hypothesis

The second lattice fixture is the **healthy `48³` solid box** — full occupancy, no bore,
coarsenable extents, the fixture that converged geometrically in **15 cycles** at uniform
ρ (§4). Carrying the lattice field instead:

```
== solid_box_48 LATTICE   48x48x48, 345 744 DOF, coarsenable(rule)=YES
GEOMETRIC: hier_built=1 used_mg=0 mg_cycles=300 cg_iters=3565  18.70s   -> STAGNATION
JACOBI-CG baseline: iters=3565  12.64s
```

**15 cycles → total stagnation, with the geometry and the extents held fixed.** The only
change is the density field. So on a clean box, *contrast alone stagnates the geometric
V-cycle* — provided the contrast is carried on **sub-coarse-cell members**.

That deserves care, because 125 §1d killed a hypothesis that sounds like this one:

> **"The 1e-9 SIMP contrast kills the V-cycle." DEAD.** `06_solid+softvoid_1e-9` =
> **13 cycles**, indistinguishable from solid (11). A coherent soft blob is coincidentally
> coarse-grid-aligned.

125 is **not** contradicted — its own disproof names the reason: the ablation used a
*coherent blob*, which a coarse grid represents perfectly well. What it did not test is
contrast carried on **thin structured members**, which is what a developed SIMP design
actually is. On that field the contrast hypothesis is **alive**. The honest restatement:

> Contrast alone is harmless when it is coarse-grid-aligned (125, confirmed). Contrast on
> sub-coarse-cell members is sufficient on its own to stagnate the geometric V-cycle — no
> thin-part-in-empty-box and no clearance bore required.

This widens the blast radius of the 125 pathology considerably: it is not confined to
design-box + clearance jobs. **Any** run whose design develops fine features can enter it,
which is consistent with 128's borderline band and with production runs that stagnate
partway through rather than at iteration 0.

AMG on that same clean-box-with-contrast system:

```
AMG: 5 levels | stationary sustained 0.981 | AMG-PCG cycles=88 converged=yes
     setup 49.30s, solve 26.84s, 0.305s/cycle | memory 1464.7 MB | DETERMINISM: IDENTICAL
per-level: 0.978 -> 0.968 -> 0.940 -> 0.891   (every level degraded, as above)
level n:   345744 -> 30450 -> 5622 -> 2256 -> 1746   (ratio collapse 11.4x -> 1.3x)
nnz/row:      77.7 -> 353.0 -> 1496 -> 2256 -> 1746  (levels 3 and 4 fully dense)
```

**AMG carries it — 88 cycles against 3565 Jacobi iterations, a 40× iteration win — and is
4.1× SLOWER in wall-clock** (76.1 s vs 18.70 s). Same signature as the big lattice
fixture: the solve is fine, the *setup* is the problem, and the setup is expensive
precisely because the coarsening ratio collapses and the coarse operators densify.

### 2e. R1b summary

| fixture (developed-design field) | red. DOF | geometric | AMG-PCG | iteration win | wall |
|---|---:|---|---:|---:|---|
| `192×112×128` occ0.40+bore0.40 | 804 864 | 300 cycles → 13 741 Jacobi | 133 | **103×** | 191.9 → 213.8 s (**1.11× slower**) |
| `48³` solid *(clean geometry!)* | 345 744 | 300 cycles → 3 565 Jacobi | 88 | **40×** | 18.7 → 76.1 s (**4.1× slower**) |

Both carry. Neither is faster. **Fix the coarsening (§5e lever b) before believing any
end-to-end projection.**

---

## 3. R2 — THE BUILD-REJECTION REGIME

**Bar: GO iff AMG BUILDS and contracts on extents the geometric builder refuses.**

The refusal is real and rule-checked first (`mg_grid_coarsenable`, `coarsen.hpp` — the
solver's own predicate):

```
    64x  64x  64  coarsenable=yes      184x 104x 128  coarsenable=NO
    96x  96x  96  coarsenable=yes      100x  96x  96  coarsenable=NO
   192x 112x 128  coarsenable=yes      104x  96x  96  coarsenable=NO
```

Note the "96³ box class" the task names is *itself* coarsenable (96 = 2⁵·3 halves four
times); what the rule refuses is the neighbouring, equally ordinary extents —
`100×96×96`, `104×96×96` — and `184×104×128`, the real bracket grid 125 §1c identified
as the original build-rejection.

### 3a. A measured surprise that REFINES the 122/125/127 record

**The predicate's `false` is not a build-rejection prediction on a sparse active set.**
`mg_grid_coarsenable` bounds the coarse DOF count by `3 × (coarse NODE count)`. The real
builder (`build_mf_hierarchy` → `build_hierarchy`) instead counts the **ACTIVE** coarse
DOFs, and on a thin part in a large empty box that is far below the bound. Measured
directly:

```
== reject100x96x96   box 100x96x96 occ 0.40 bore 0.40 | geometric coarsenable(rule)=NO
   GEOMETRIC: hier_built=1 used_mg=0 mg_cycles=300 cg_iters=1607   <-- BUILT, then STAGNATED
```

`coarsenable(rule)=NO` and `hier_built=1` in the same row. `coarsen.hpp` documents the
`true` direction as conservative; the `false` direction is only a refusal prediction when
the active set is **dense**. This matters beyond this handoff: any future diagnosis that
reads the predicate as "the solver will refuse here" can be wrong in exactly the
low-occupancy regime that is this project's pathology — the same conflation family
125 §0 was written to break.

So the R2 fixtures were corrected to DENSE parts on shallow-2-adic extents, where the
refusal is real: `52³` (52→26→13 odd; coarsest usable level has 14³ nodes = 8232 DOF >
the 6000 cap) and `60³` (60→30→15 odd; 16³ nodes = 12288 DOF).

### 3b. Measurements — **R2 PASSES, and on the bar's own number**

`52³` solid, ρ=0.5, **438 204 reduced DOF**. The refusal is real:

```
GEOMETRIC: hier_built=0 used_mg=0 levels=0 mg_cycles=0 cg_iters=438  3.31s
   -> geometric FELL BACK (BUILD-REJECTION)
```

`hier_built=0` — the hierarchy is never built, the solve goes straight to Jacobi. AMG on
the identical system:

```
    level      n        nnz    nnz/row   aggregates
        0   438204   34163514     78.0         5832
        1    34992   11164155    319.0          782
        2     4692    4408703    939.6          227
        3     1362    1854900   1361.9          142
        4      852     725904    852.0            0
AMG stationary: sustained 0.812 | AMG-PCG: cycles=19 converged=yes
per-level sub-hierarchy contraction:
   level 0 (n=438204): sustained 0.808
   level 1 (n= 34992): sustained 0.605  (converged in 27 cycles)
   level 2 (n=  4692): sustained 0.398  (converged in 15)
   level 3 (n=  1362): sustained 0.223  (converged in  9)
DETERMINISM: IDENTICAL
```

That per-level ladder — 0.808 → 0.605 → 0.398 → 0.223 — is the sharpest evidence in the
study that **the coarsening is not the limiter**. Contraction improves monotonically and
steeply with depth; the aggregation sees the geometry perfectly well at every level. The
whole loss sits at the fine level, i.e. in the smoother and the aggregate size. Compare
§2c, where the same ladder on the *pathological* fixture is flatter (0.893 → 0.887 →
0.793) but still monotone in the same direction.

| | geometric | AMG |
|---|---|---|
| hierarchy built? | **NO** — refused | **YES**, 5 levels |
| outer iterations to 1e-6 | 438 (Jacobi) | **19** (**23×** fewer) |
| ρ_eff | 0.969 (Jacobi) | **0.483** — **meets the ≤0.5 bar** |

**This is the cleanest result in the study.** `52³` is a *healthy geometry*; only the
extents (52→26→13, odd, leaving 8232 coarse DOF against a 6000 cap) defeat the geometric
builder. AMG, having no coarsenability arithmetic at all, simply builds — and contracts at
the same rate as on the healthy control (stationary 0.812 vs 0.778–0.827 in §4), which is
exactly what "the geometry was never the problem, the extent arithmetic was" predicts.

Honest cost note: in **wall-clock** AMG loses here (21.4 s vs 3.31 s). On a
build-rejected but otherwise healthy grid the Jacobi fallback is already cheap and
threaded, so AMG's 23× iteration win does not convert to a time win at this size. The
iteration win is what scales; the seconds at 438 k DOF are not the argument.

**Second fixture, same verdict.** `60³` solid + `bore 0.30` (630 000 DOF, also
`coarsenable(rule)=NO`):

```
GEOMETRIC: hier_built=0 used_mg=0 mg_cycles=0 cg_iters=518  5.49s   -> BUILD-REJECTION
AMG: 4 levels | stationary sustained 0.814 | AMG-PCG cycles=19 converged=yes
     setup 16.73s, solve 7.84s, 0.413s/cycle, 1901.4 MB | DETERMINISM: IDENTICAL
```

**R2 summary — 2 of 2 pass, both on the bar's own number:**

| fixture | red. DOF | geometric | AMG-PCG | AMG ρ_eff | iteration win |
|---|---:|---|---:|---:|---:|
| `52³` solid | 438 204 | **refuses to build**, 438 Jacobi iters | **19** | **0.483** ✅ | 23× |
| `60³`+bore0.30 | 630 000 | **refuses to build**, 518 Jacobi iters | **19** | **0.483** ✅ | 27× |

AMG has no coarsenability arithmetic to fail, so it builds; and because these geometries
are healthy, it contracts at healthy rates. **R2 is the one regime where the stated ≤0.5
bar is met outright.**

### 3c. The over-sparse fixtures were not wasted — they are two more R1 points

Both originally-chosen R2 fixtures turned out to be **stagnation** cases, so they
strengthen §2 instead:

| fixture | red. DOF | geometric | AMG-PCG | AMG ρ_eff | outer-iteration win | wall |
|---|---:|---|---:|---:|---:|---|
| `100×96×96` occ0.40+bore0.40 | 142 848 | `hier=1 used_mg=0`, 300 cycles → **1607** Jacobi iters | **63** | 0.803 | **25×** | 29.5 s → 7.8 s (**3.8×**) |
| `184×104×128` occ0.40+bore0.40 | 738 048 | `hier=1 used_mg=0`, 300 cycles → **1357** Jacobi iters | **32** | 0.649 | **42×** | 59.1 s → 32.6 s (**1.8×**) |

The `100×96×96` case is also notable as `184×104×128` is **125 §1c's own bracket grid** —
the one 122 blamed on coarsenability. At occ 0.40 it does not reject; it **stagnates**,
which is precisely 127's walk-back conclusion, now confirmed on a third independent
fixture and read straight off `hier_built`.

The `100×96×96` case is the thinnest fixture in the study (34 560 solid elements in a
921 600-element box — ligaments a few voxels across) and AMG still carries it.

---

## 4. R3 — THE HEALTHY CONTROL

**Bar: AMG within ~2× of geometric's cycle count, else record a REGIME SPLIT.**

| case | red. DOF | geo cycles | geo ρ_eff | AMG-PCG cycles | AMG ρ_eff | ratio | AMG stationary | determ. |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| `solid_box_48` | 345 744 | 15 | 0.398 | **16** | 0.421 | **1.07×** | 0.778 | identical |
| `solid_box_64` | 811 200 | 14 | 0.373 | **18** | 0.464 | **1.29×** | 0.811 | identical |
| `solid_box_64+bore0.40` | 720 384 | 33 | 0.658 | **19** | 0.481 | **0.58×** | 0.827 | identical |

**R3 PASSES with room.** AMG is within 1.3× of geometric on the clean boxes and is
already **1.7× better** on the box-with-a-bore — the first point on the curve toward the
pathology. **No regime split is needed:** AMG is competitive where geometric is healthy,
so it is not a "only when the other one fails" tool.

This table is also what calibrates §1c's metric warning: on a *perfectly healthy solid
box*, this standard SA measures a **stationary** contraction of 0.778–0.827. That is
textbook for aggressive aggregation (aggregates of the full 27-point neighbourhood,
6 candidates, one symmetric Gauss-Seidel sweep) — SA is designed to be run under CG, and
under CG it lands at ρ_eff 0.42–0.48, right beside geometric's 0.37–0.66. **A stationary
≤0.5 bar is met by neither method on any fixture in this study, healthy or not.**

### 4b. Knob sensitivity — what was swept, and what was NOT

The verdict must not rest on one arbitrary default, so the smoother strength was swept on
the **stagnation** fixture (804 864 DOF):

| configuration | levels | stationary sustained | AMG-PCG cycles | setup |
|---|---:|---:|---:|---:|
| θ 0.08, **1** symmetric GS sweep, smoothed P *(the default used everywhere above)* | 4 | **0.902** | 37 | 20.2 s |
| θ 0.08, **2** symmetric GS sweeps, smoothed P | 4 | **0.896** | 32 | 18.8 s |

Doubling the smoother moves the sustained rate by **0.6 %** (0.902 → 0.896) and buys 13 %
fewer PCG cycles while making each cycle ≈1.6× dearer — **a net loss of work**, and
nowhere near 0.5.

**Not swept, and deliberately declared rather than quietly omitted:** the 3-sweep row, the
two θ = 0.25 rows (smaller aggregates — the classic lever for poor contraction) and the
unsmoothed-P row were **cut mid-run**. The box was swap-bound (§6a) and the two required
deliverables (R2, R4) were queued behind them. So the claim this study supports is *"the
smoother knob does not rescue the rate"*, **not** *"no knob does"*. A Phase-1 prototype
should sweep aggregate size before concluding the rate is intrinsic.

---

## 5. THE VERDICT

### 5a. The one-sentence answer

**On every fixture where geometric multigrid cannot converge — 7 of 7 — AMG builds a
hierarchy and carries the solve**, with 23–103× fewer outer iterations. On the healthy
control it stays within 1.3× of geometric and is 1.7× *better* on the box-with-a-bore.
**The pathology 125 diagnosed is not a wall for an operator-following coarsening.**

**But the cost story splits by where you are in the solve sequence, and that split is the
single most decision-relevant number in this handoff:**

| | iteration-0 field | developed-design field (§2d) |
|---|---|---|
| does AMG carry it? | yes, 37 cycles | yes, 133 cycles (and 88 on the clean box) |
| iteration win over the Jacobi fallback | 97× | 103× / 40× |
| AMG total vs the failing geometric path | **2.1× faster** | **1.11× and 4.1× SLOWER** |

A real run spends almost all of its iterations at the second column, not the first. **The
iteration win is robust; the wall-clock win measured at iteration 0 is not, and must not
be extrapolated to an end-to-end run.**

| fixture (all `hier_built=1, used_mg=0` — 125's stagnation) | red. DOF | geometric | AMG-PCG | outer-iteration win | wall |
|---|---:|---|---:|---:|---|
| `192×112×128` occ0.40+bore0.40 | 804 864 | 300 cycles → **3602** Jacobi | **37** | **97×** | 71.3 → 34.8 s (2.1×) |
| `184×104×128` occ0.40+bore0.40 | 738 048 | 300 cycles → **1357** Jacobi | **32** | **42×** | 59.1 → 32.6 s (1.8×) |
| `100×96×96` occ0.40+bore0.40 | 142 848 | 300 cycles → **1607** Jacobi | **63** | **25×** | 29.5 → 7.8 s (3.8×) |

### 5b. Against the bar as literally written: **NO in R1, YES in R2**

The bar was "sustained overall contraction ≤ ~0.5". **R2 meets it outright** on 125's own
metric — ρ_eff **0.483** on both build-rejected fixtures (§3b). **R1 does not.** On the
pathology AMG measures
**stationary 0.89–0.93** and **CG-accelerated ρ_eff 0.65–0.80**. It misses on *both*
metrics. That is stated first and without softening.

### 5c. Why that NO does not mean what it looks like — and this is a defect in the bar

Three measured facts, none of which was known when the bar was written:

1. **The bar is unreachable by ANY method here, on ANY fixture, healthy or not.** §4
   measures a *stationary* contraction of **0.778–0.827** on a perfectly healthy solid
   box — where geometric MG converges in 14 cycles and everyone agrees it is working. A
   bar that a known-good configuration fails cannot discriminate a good result from a bad
   one.
2. **125's own numbers are the CG-accelerated ρ_eff, not the stationary rate** (125 §1b:
   `rho_eff = 10^(-6/iters)`). Read on 125's own metric, AMG **does** meet ≤0.5 on the
   healthy control (0.42–0.48) and misses it on the pathology (0.65–0.80).
3. **The one knob that was swept (§4b) does not move it:** doubling the smoother changes
   the sustained rate 0.902 → 0.896 while making each cycle ~1.6× dearer — a net loss.
   That is one knob, not proof that no knob works (§4b says what was *not* swept), but it
   is the knob most likely to help and it did not. The honest reading is therefore not
   "we tuned it badly", it is **"AMG degrades gracefully on this pathology (ρ_eff
   0.65–0.80) where geometric degrades catastrophically (no convergence at all)"**.

### 5d. Against the bar's stated INTENT — "AMG carries where geometric stagnates": **GO, decisively**

**7 fixtures out of 7** where geometric cannot converge — 3 stagnation on the iteration-0
field (§2, §3c), 2 build-rejection (§3b) and 2 stagnation on the developed-design field
(§2e) — plus the healthy control (§4), which AMG also handles. **No fixture in this study
defeated AMG.**

The qualification that belongs beside that sentence, not after it: on the two
developed-design fixtures AMG *carries but does not pay for itself* (§2e). "Carries where
geometric stagnates" is satisfied; "is worth switching to" is not yet, and §5e says what
would have to change.

### 5e. Recommendation

**GO to a Phase 1 that is a SECOND MEASUREMENT, not a production wiring exercise.**

The Phase-0 question — *does AMG contract on our pathology?* — is answered **yes**: it
carries 7 of 7 fixtures that defeat geometric MG, deterministically, on the production
systems. But two measured facts say Phase 1 must not start by wiring a flag:

1. **Memory (§6c).** This prototype's hierarchy is **23.3×** the geometric matrix-free
   footprint (2 072 MB vs 88.9 MB at 804 864 DOF) because it re-assembles the fine matrix
   078 deliberately removed. At the same padded extents with `occ 1.00` (8 374 656 DOF)
   it would need ≈20 GB — not slow, **impossible**, and the iPad is far smaller again.
2. **The developed-design economics (§2d).** Where a real run actually lives, the
   prototype is 1.11× *slower* than the failing geometric path, its setup blows up 6.7×,
   and its coarse operators go 100 % dense.

Both point at the same two unswept levers, so **Phase 1 = prototype these two things and
re-measure §2d, before any production code**:

* **(a) fine-matrix-free construction** (§7a option A) — element-local strength and
  aggregation, element-local Galerkin, exactly the trick 078/090 already pull. §6d shows
  the way in: the **unsmoothed** variant still carries the stagnating solve, needs `A`
  only for the Galerkin product, and costs 12× less setup and 2.2× less memory.
* **(b) coarsening control** — a hard level cap and an aggregate-size / strength-threshold
  sweep, the levers §4b records as not swept and §2d shows collapsing (ratio 10.6× → 1.35×
  down the hierarchy).

If (a) proves infeasible the answer is **NO-GO on memory grounds** and the contraction
result is moot. If (b) does not repair the developed-design economics, AMG is still worth
having as **the latch's replacement target** (§7b item 5) — converting a doomed Jacobi
grind of 13 741 iterations into 133 V-cycles is valuable even at parity wall-clock,
because it is the case that currently costs hours.

The maintainer decides. Every ceiling above traces to a measured number in §2–§6; where
this handoff had to choose between two readings of a bar (§5b vs §5d) it gives both; and
the one result that undercuts its own headline (§2d) is stated in the summary, not buried.

---

## 6. R4 — THE COSTS, HONESTLY

### 6a. Thermal / measurement disclosure (113, and one addition)

Cycle counts, contraction factors, aggregate counts, nnz and residual histories are
**deterministic** — captured once, exact, thermally immune. Wall-clock is not, and here it
is worse than usual for two reasons that must be stated rather than smoothed over:

1. The AMG prototype is **single-threaded and untuned**; the geometric/Jacobi baselines
   are the real library path, which is **multi-threaded and NEON-tuned** (078/085). Every
   wall comparison below is therefore biased *against* AMG, and its real ceiling is higher
   than the seconds suggest.
2. **Another lane's harness was running on this box** during part of the measurement
   (a parallel worktree's probe, ~230 MB resident), and swap was heavily loaded (12–13 GB
   of a 14 GB swap file). Wall-clock is contaminated beyond the usual ±30 % thermal band.

**Read the cycle counts and the setup/solve RATIO. Do not quote the seconds as a
production estimate.** The costs table interleaves and takes medians anyway, but no
amount of interleaving repairs a contended box.

### 6b. Per-case cost breakdown (single capture; all from the runs above)

| case | red. DOF | fine CSR assembly | AMG setup | AMG solve | setup share | AMG hierarchy | fine CSR | geometric wall |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| stagnation `192×112×128` | 804 864 | 1.13 s | 17.0 s | 17.7 s | **49 %** | 2 072 MB | 701 MB | 71.3 s (fails) |
| stagnation `184×104×128` | 738 048 | 1.31 s | 16.5 s | 16.1 s | **51 %** | 1 973 MB | 642 MB | 59.1 s (fails) |
| stagnation `100×96×96` | 142 848 | 0.61 s | 2.5 s | 5.4 s | **32 %** | 280 MB | 108 MB | 29.5 s (fails) |
| healthy `48³` | 345 744 | — | 8.3 s | 3.4 s | **71 %** | 1 010 MB | 310 MB | 1.2 s |
| healthy `64³` | 811 200 | — | 48.2 s | 9.6 s | **83 %** | 2 527 MB | 735 MB | 3.4 s |
| healthy `64³+bore` | 720 384 | — | 18.2 s | 8.5 s | **68 %** | 2 006 MB | 645 MB | 3.3 s |

Three things fall out:

* **Fine-matrix assembly is NOT the tax.** 1.1–1.3 s at 55–61 M nonzeros — about 7 % of
  the AMG setup. The expensive part is the aggregation + smoothed prolongator + Galerkin
  triple product, as expected.
* **AMG's setup share (32–83 %) is the same order as the tax this project already pays.**
  The geometric Galerkin hierarchy is *also* rebuilt every MMA iteration (the SIMP modulus
  field moves), and 090 measured that build at ~48 % of a solve, 112 at ~66 %. So "AMG has
  a setup tax" is true but is **not a new category of cost** — it is the same category,
  and the honest question is only whether the constant is bigger. On the pathological
  cases it is not: AMG's *total* (setup + solve) beats the geometric path's total outright.
* **The `64³` outlier (48.2 s setup, 83 %) is a prototype artifact, not a property of
  AMG.** Its hierarchy went five levels deep with coarse operators filling in to
  2 363 nnz/row — essentially dense (§6d). A production build would cap that; this one
  does not, and no Phase-1 estimate may lean on fixing it until it is measured.

### 6c. Memory — the finding that decides Phase 1

On the stagnation fixture (804 864 DOF), measured side by side:

```
MEMORY: geometric matrix-free hierarchy stores 88.9 MB of COARSE operators and NO fine
        matrix (078); this AMG needs the fine matrix assembled: 701.3 MB for A0 alone.
```

| | geometric matrix-free (production) | this AMG prototype |
|---|---:|---:|
| fine operator | **none** (element-local, 576 doubles) | 701.3 MB assembled |
| coarse operators | 88.9 MB | ~1 370 MB |
| **total hierarchy** | **88.9 MB** | **2 071.6 MB** |
| ratio | 1× | **23.3×** |

**This, not contraction, is the Phase-1 gate.** 078 removed the assembled fine `K`
*because it OOMs on design-box grids*; this prototype puts it straight back. Extrapolated
to the same padded extents at `occ 1.00` — **8 374 656 reduced DOF**, measured by
`./amg_probe hunt` — the fine CSR alone would be ≈7.8 GB and the hierarchy ≈20 GB. That
is not "slow on a 16 GB Mac", it is impossible, and the iPad is far smaller again.

### 6d. Grid/operator complexity, and the unsmoothed variant — the Phase-1 lever

Grid-operator complexity (Σ nnz over levels / fine nnz) is **1.45** on the stagnation
fixture — healthy for SA. The deeper prototype levels do fill in badly on some fixtures
(the `64³` healthy case reached 2 363 nnz/row at level 3, essentially dense, and paid
48.2 s of setup for it); that is a level-capping tuning fault, not a property of the
method, and it is **not fixed here**.

The measurement that matters most for Phase 1 is the **unsmoothed-aggregation variant**
(`P = T`, i.e. the prolongator is never multiplied by `A`):

| | smoothed P (default) | unsmoothed P |
|---|---:|---:|
| setup | 26.9 s | **2.25 s** (**12×** cheaper) |
| stationary sustained | 0.902 | 0.969 |
| AMG-PCG cycles | 37 | **65** (1.76×) |
| hierarchy memory | 2 072 MB | **943 MB** (2.2× less) |
| still carries the stagnating solve? | yes | **yes** |

Read the totals: unsmoothed costs ~1.76× the cycles but ~12× less setup, so its
*end-to-end* time is about the same — and it **still carries the case geometric cannot**.
Its structural significance is larger than its arithmetic: forming `P = T` needs only the
aggregation, **never `A`'s rows**, which is exactly the property an element-local,
fine-matrix-free AMG needs (§7a option A). Phase 1 should start here, not with the
smoothed variant.

### 6e. Interleaved wall-clock (median of 3, min..max band)

```
stagnation(192x112x128), 804864 DOF:
  GEOMETRIC: hier=1 used_mg=0 mg_cycles=300 cg_iters=3602 | wall 98.30s [81.97..141.04]
  AMG:       pcg_cycles=37 | setup 26.94s [18.71..29.15]  solve 32.67s [19.16..33.98]
             setup/(setup+solve) = 45%
```

Median totals: geometric **98.3 s** (and it *fails*, falling back to Jacobi) vs AMG
**59.6 s** — **1.65×**, single-threaded against threaded. Note the geometric band
(82–141 s) is ±30 % wide: that is the contended box of §6a, and it is why the cycle
counts, not these seconds, are the claim.

Healthy `48³` (345 744 DOF), same protocol: AMG setup **8.66 s** [8.48..8.93], solve
**3.59 s** [3.55..3.77], setup share **71 %**; unsmoothed variant setup **0.68 s**,
34 PCG cycles, 421.5 MB. Geometric there is 1.23 s with MG carrying in 15 cycles (from
the `healthy` capture — see the note immediately below).

### 6f. A harness bug found by the measurement, and what it confirms

The first `costs` capture reported `hier=0 used_mg=0` for the **healthy** `48³` fixture —
a grid that unambiguously coarsens, and that the `healthy` mode had just measured
building a 4-level hierarchy and converging in 15 cycles.

Cause: **127's per-run stagnation latch, working exactly as specified.** It is
thread-local and sticky — after `kMgLatchThreshold = 3` consecutive stagnated solves it
stops *building* the hierarchy for the rest of the process — and production resets it once
per run (`minimize_plastic.cpp`). The `costs` mode runs **three interleaved repeats** of
the stagnating fixture, which is exactly the threshold, and the harness never reset the
latch, so it leaked into the next fixture.

Fixed: `geometric_baseline()` now calls `fea_matfree_reset_mg_stagnation_latch()` before
every baseline solve. Two consequences worth recording:

* **It is an independent live confirmation that the 127 latch fires and does what 127
  says it does** — three stagnations in, the doomed build stops happening.
* **It is a trap for any future harness** that solves many fixtures in one process. The
  other captures in this handoff are unaffected: `healthy` never stagnates at all, and
  `stagnation`/`reject` never reach three *consecutive* stagnations (a carrying solve in
  between clears the counter). Only the repeat-heavy `costs` mode could hit it, and only
  its healthy geometric row was wrong; that row is quoted above from the clean `healthy`
  capture.

---

## 7. PHASE 1 SKETCH (conditional on the §5 verdict)

### 7a. The blocker that decides Phase 1's SHAPE — read this first

This prototype **assembles the fine matrix**. The production matrix-free geometric path
(078) deliberately does not: the assembled fine `K` is the thing that OOMs on design-box
grids, and removing it was the whole point of `fea_solve_mgcg_matfree`. The measured
consequence (§6) is not marginal:

* At **804 864 DOF** (the stagnation fixture) the fine CSR alone is **701 MB** and the
  hierarchy **2.07 GB**.
* At the *same padded extents with `occ 1.00`* the reduced system is **8 374 656 DOF** —
  the fine CSR would be **≈7.8 GB** and the hierarchy **≈20 GB+**. On a 16 GB machine
  that is not slow, it is **impossible**, and the iPad is far smaller again.

So **a naively-assembled AMG is not shippable**, whatever its contraction. Phase 1 must
therefore be scoped as one of:

| option | what it is | verdict |
|---|---|---|
| **(A) element-local AMG** | Build the strength graph and the aggregation from the **element table** (node-pair blocks accumulated element-by-element, exactly as `mf_build_reduced` already accumulates the Jacobi diagonal), and form the Galerkin coarse operators with the **element-local triple product 078/090 already implement** for the geometric hierarchy. No assembled fine `A` ever exists; only the (≥8× smaller) coarse operators are stored — the same memory shape the production MG already has. | **the only shippable shape.** The one genuinely new piece is smoothing the prolongator, which needs `A`'s rows; §6's **unsmoothed-aggregation variant** measures exactly what that costs if it is dropped. |
| (B) assembled AMG, gated to small active sets | Ship it only when the reduced DOF count is under a cap. | Fragile: the cap would exclude the `occ 1.0` end, and the pathology is *low*-occupancy, so it might mostly work — but a silent capability cliff is exactly the class of trap 122/127 already paid for. Not recommended without (A) measured first. |
| (C) third-party AMG (hypre / AMGX / ML) | — | Rejected on the task's own terms (no new dependencies) and on determinism: those libraries' default aggregation is not reproducible across thread counts, and reproducibility is a hard constraint here (110/125 lineage). |

### 7b. The wiring, if Phase 1 proceeds

1. **Opt-in, default OFF, byte-identical when off.** A new `SolverKind::AlgebraicMG`
   beside `MultigridCG_Matfree` (the 073 precedent: nothing calls it unless the caller
   chooses it, the library default stays `JacobiCG`, and `configure_production_options`
   is untouched in the same commit). Byte-identity is then trivially provable: no
   existing call site changes.
2. **`mg_mode` gains `"amg-carried"`** (and `"amg-fallback"`), alongside 128's existing
   `"carried"` / `"stagnated-latched"` / `"build-rejected"`. `iterations.csv`'s
   `hier_built` and `mg_cycles_attempted` columns carry over **unchanged** — an AMG setup
   *is* a hierarchy build and an AMG V-cycle *is* a cycle, so the existing observability
   already describes it. No new columns.
3. **Reuse the latch/budget machinery UNCHANGED.** `kMgIterBudget` (300),
   `kMgAttemptWallGuardSec` (90), `kMgLatchThreshold` (3) and
   `fea_matfree_reset_mg_stagnation_latch()` all key on *"attempted cycles vs
   converged"*, which is preconditioner-agnostic. AMG plugs in behind the identical
   policy: same budget, same wall guard, same per-run latch, same exact Jacobi fallback,
   and 127's finding that **no within-solve early-bail is safe** still applies verbatim.
   Phase 1 adds no new policy surface — that is a feature, and it is what keeps the
   honesty story (127 Amendment 1, 128 §3) intact.
4. **The 110-template design-difference table, at TIGHT tolerance — the 130 lesson.**
   130 (`cg_tolerance_loose`) is the cautionary precedent: theory said a trajectory-only
   change would barely move the design, and measurement said mean|Δρ| ≈ 0.055 with a
   basin flip at every loose endpoint, and the flip was **BLOCKED**. A preconditioner
   swap at the *same* tight tolerance is a strictly weaker perturbation than that — but
   "strictly weaker than a thing that failed" is not a bar. So Phase 1 must run the
   `cg_tol_probe` two-fixture ladder (L-bracket loadcase + design-box) with geometric vs
   AMG at identical tight `cg_tolerance`, reporting per rung: outer MMA iterations,
   summed CG/V-cycles, wall, achieved fraction, worst-case margin, gate verdict; then the
   terminal-design **mean AND max |Δρ|**. Bars, stated now: mean|Δρ| must sit at
   round-off (≪ 130's 0.055), and **any** rung-acceptance or basin flip is a blocker
   regardless of the speed win.
5. **Where AMG should be ALLOWED to run.** §4 shows AMG is competitive on healthy grids,
   so the honest default for a Phase-1 experiment is *either* everywhere-when-selected
   *or* — the cheaper, lower-risk option — **as the latch's replacement target**: when
   128's stagnation latch would otherwise give up on geometric MG and fall to Jacobi,
   try AMG instead of Jacobi. That confines the change to the exact path that is already
   known-broken, keeps every healthy run bit-identical without relying on a flag, and
   converts 3602 Jacobi iterations into 37 V-cycles precisely where it matters.

### 7c. What Phase 1 must NOT assume from this handoff

* These are **single-threaded, untuned** prototype timings against a threaded, SIMD-tuned
  library path. The cycle counts and the setup/solve *ratio* transfer; the seconds do not.
* The prototype's deeper coarse levels fill in badly (§6) — a production build would cap
  levels differently. That is a tuning fix, but it is **not yet measured**, so no Phase-1
  cost estimate may lean on it.
* No end-to-end optimizer run was performed. Everything here is per-solve.

---

## 8. REPRODUCE — every number above

The harness is **committed**, so this is a two-command reproduction, not a
scratchpad recipe (the 113/125 probes could not be re-run; these can).

```bash
cmake -S core -B core/build -DCMAKE_BUILD_TYPE=Release
cmake --build core/build --target topopt -j8
c++ -std=c++17 -O2 -I core/include -I core/src/fea \
    core/tests/harness/amg_probe.cpp core/build/libtopopt.a -o amg_probe
```

| command | what it prints | cost |
|---|---|---|
| `./amg_probe extents` | the `mg_grid_coarsenable` table of §3 | instant |
| `./amg_probe correctness` | the §0b correctness gate | ~10 s |
| `./amg_probe hunt` | the geometric occ×bore factorial of §2a (baseline only) | ~15 min |
| `./amg_probe stagnation` | §2 — **the headline** | ~10 min for the first fixture |
| `./amg_probe reject` | §3 | ~10 min |
| `./amg_probe healthy` | §4 | ~5 min |
| `./amg_probe developed` | §2d — the second point on the solve sequence | ~15 min |
| `./amg_probe sweep` | §4b knob sensitivity | ~20 min |
| `./amg_probe costs` | §6 economics + memory | ~10 min |

**Memory warning, and it is a finding not a footnote (§6):** the AMG path assembles the
fine matrix, so peak RSS is several GB at ~1M DOF. On a 16 GB machine the `occ 1.00`
rows at the real padded extents (**8 374 656 reduced DOF**) cannot be measured at all by
the assembled path — `./amg_probe stagnation`'s third fixture and the `occ 0.40 nobore`
AMG measurement (1 377 792 DOF) were **deliberately not run to completion** for this
reason, and their geometric baselines are reported without an AMG counterpart. Run the
regimes **sequentially**, never concurrently (thermal protocol, 113).

**Raw captures are committed** under `docs/handoffs/evidence/131/` (the 129 convention),
so every table above can be checked against the exact stdout it came from:
`healthy_out.txt`, `stagnation_out.txt`, `hunt_out.txt`, `reject_out.txt` (the
over-sparse fixtures, §3c), `reject2_out.txt` (the corrected build-rejection fixtures,
§3b), `sweep_out.txt`, `costs_out.txt`, `developed_out.txt`.

One provenance note on those captures: they were produced by the same source at
successive edit points, and the two earliest (`healthy`, `stagnation`, `hunt`, `reject`)
predate the latch-reset fix of §6f. That fix affects **only** the repeat-heavy `costs`
mode — the other modes never reach three *consecutive* stagnations — and §6f says exactly
which row it touched and where the clean replacement number came from. The committed
source reproduces all of it.
