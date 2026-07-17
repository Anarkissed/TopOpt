# 090 — Design-box void: profile, and the Galerkin block cache

**Track:** core. **Territory:** `/core/` only (no app, no fixtures, no benchmarks,
no materials.json, no ARCHITECTURE.md, no ROADMAP box).
**Builds on:** 077 (matrix-free operator), 078 (matrix-free multigrid), 079
(design-box padding + memory), 085 (SIMD/threaded apply, two-pass CSR).

## Summary

The profile says the task's premise is **half right, and the wrong half is the
expensive one.** The design box really is ~94% soft void, and that void really is
~91% of the cost — but the cost is **not the matvec** (085 already made it cheap: 40
of every 91 ms), it is the **coarse-operator build, rebuilt on every one of the
~120 solves in a ladder** (7.81 s of every 16.40 s solve). And the void's build cost
is **not near-zero arithmetic that can be skipped** — the per-element Galerkin block
is purely geometric, so a void element costs exactly what a solid one does. The
waste is *the same 8 blocks recomputed 638,820 times*.

So the lever is **repetition, not approximation**: the block is keyed by the element's
parity, which is exactly the 8-colour key the element table is already sorted by.
Computing it once per colour is **bit-identical** — measured **0 differing DOFs out of
2,286,387**, same 94 iterations — which means it needs no adaptivity, no
re-activation, and **cannot** break growth (nothing is ever deactivated).

**Result: solve 16.40 s → 12.21 s (1.34×), build 7.81 s → 3.73 s (2.09×), peak memory
unchanged, answer bit-identical, 43/43 green, opt-in and default OFF.** It does
**not** bring 128³ or Fine+box into range — it is a time win, not a memory win. The
two biggest remaining levers are named and measured at the end.

---

**Environment (read this).** Unlike 085 — which had no Apple hardware and measured
an x86/SSE2 proxy — this worktree ran on an **Apple M2 Pro (6 performance cores,
16 GB), clang -O3, arm64**, so every number below is the **real NEON path**. The
target is an **M1 iPad, 4 performance cores**, so all timings are taken with
`fea_set_matfree_threads(4)`. The absolute wall differs from the device; the
RATIOS transfer. No on-device run was performed.

---

## STEP 1 — PROFILE FIRST (the headline, and it CORRECTS the task's premise)

Real case reconstructed through the **actual `expand_design_domain` path**: an
L-bracket part inside a design box, `freeze_imported_part=false`, `coarsen_align=8`
→ **96×80×96 = 737,280 voxels, 638,820 elements, 2.29 M DOFs**. This is the
maintainer's padded grid exactly (96×80×96 = 737,280); the element count is within
2.5% of their 623,700 (my synthetic part is smaller, so slightly more of the box is
grow-region). Cross-checks against 079's measurements of the real case: 4 multigrid
levels, `used_multigrid=TRUE`, and 94 iterations against their 87.

### 1a. Cost by region

| region | voxels | elements | share of elements |
|--------|-------:|---------:|------------------:|
| align-8 Empty padding | 98,460 | **0** | **0.0%** |
| frozen part | 26,400 | 26,400 | 4.1% |
| Active grow region (near-void) | 612,420 | 612,420 | **95.9%** |

### 1b. The near-void share of each cost — measured, not estimated

| cost | total | near-void share | how measured |
|------|------:|----------------:|--------------|
| elements | 638,820 | **94%** | census |
| **matvec (apply) wall** | 10.0 ms | **83%** | full apply vs non-void-only apply |
| **hierarchy build wall** | 8.07 s | **91.4%** | full grid vs near-void-absent grid |
| coarse-operator nnz (memory) | 22.2 M (267 MB) | **84.4%** | same probe |
| element table (memory) | 66.4 MB | 94% | 104 B/elem × count |

### 1c. Where the solve time actually goes — the Amdahl check the task demanded

Full `fea_solve_mgcg_matfree`, 96×80×96, 4 threads, on the **iteration-0 field the
design-box optimize actually solves first** (frozen part at rho=1, Active envelope
at the volume fraction). This converges in **94 iterations, `used_multigrid=TRUE`,
`mg_levels=4`** — matching 079's measured 87, so it is the representative regime.

| phase | time | share of solve |
|-------|-----:|---------------:|
| **hierarchy build** | **7.81 s** | **48%** |
| CG / V-cycle iterate (94 iters, 91 ms/iter) | 8.59 s | 52% |
| full solve | **16.40 s** | 100% |

Build interior (instrumented, pre-090 code):

| build stage | time | share of build |
|-------------|-----:|---------------:|
| **pass2 NUMERIC (element blocks + scatter)** | **6.32 s** | **80%** |
| coarser levels + LDLT | 0.52 s | 7% |
| pass1b symbolic | 0.43 s | 5% |
| P0 + prolong | 0.21 s | 3% |
| pass0 ecds | 0.19 s | 2% |
| structure insert | 0.13 s | 2% |
| pass1a inverse map | 0.04 s | 1% |

This **reproduces 085's finding on real Apple hardware** (085 measured the numeric
pass at 73% of the build on x86; here 80%).

### 1d. THE ACHIEVABLE CEILING, named before designing — and two premise corrections

**Ceiling probe** (build the hierarchy on the same grid with the near-void voxels
ABSENT — not a valid solve, a pure cost probe):

> build **8.07 s → 0.69 s = 11.6×**; coarse nnz **22.2 M → 3.5 M (−84%)**.

(Run-to-run the pre-090 build measures **7.8–8.3 s**; both figures in this probe come
from the same process, and the A/B in MEASURED RESULTS uses the 7.810 s run taken in
the same session as the cache-ON number. The ~5% spread does not move any conclusion.)

So the near-void region really is ~91% of the dominant cost, and the ceiling is
large. But the profile corrects the task's premise in **two** ways:

**Correction 1 — the matvec is not the dominant cost; the BUILD is.** The task
targets "every matvec computes near-zero contributions". After 085's SIMD+threading
the apply is **10 ms** (4/iteration = 40 ms of a 91 ms iteration), so the entire
apply is ~3.8 s of a 16.4 s solve. Even making the apply **free** buys ~1.30×. The
hierarchy build — rebuilt on **every** solve, i.e. every MMA iteration — is **7.81 s
of every 16.40 s solve (48%)**, and **91% of it is near-void work**.

**Correction 2 — the near-void cost is NOT near-zero arithmetic, so it cannot be
skipped for being small.** In the build's numeric pass each element forms
`S = Wᵀ Ke W`, and **S is purely GEOMETRIC**: `W` comes from the trilinear
prolongation stencil and `Ke` is the single reference element stiffness. The
element's modulus enters **only afterwards**, as the scalar `v = el.factor * S`. A
near-void element therefore costs the build **exactly as much as a solid one**. The
waste is not near-zero values that could be dropped — it is **the same handful of
blocks recomputed 638,820 times**.

That reframes the lever: the way to collect the near-void 91% is **repetition, not
approximation**.

---

## STEP 2 — DESIGN AND JUSTIFY (all four options, against the STEP-1 profile)

**(d) Drop the align-8 Empty padding from the element set — ALREADY FREE, confirmed.**
`mf_build_elems` starts `if (!grid.solid(i,j,k)) continue;`, so the 98,460 padding
voxels produce **0 elements and 0 DOFs** (measured). 079 proved them inert on
compliance (0.00e+00); they are also inert on cost. **Nothing to do — verified, not
assumed.**

**(a) Skip/coarsen elements below a density threshold, with periodic re-activation —
REJECTED on physics, at the fine level.** This cannot work where the cost is, and it
is the scheme guard (b) exists to kill. Two independent reasons:
1. The soft void is what keeps the void DOFs constrained. Drop those elements and
   their DOFs have **zero stiffness** — K is singular there and CG cannot solve it.
2. **It would break growth, which is the feature.** The optimizer decides where to
   grow from the sensitivity `dc/drho_e = -p·rho^(p-1)·E0·u_eᵀ Ke u_e`, which needs
   the **displacement u_e inside the near-void region**. A skipped element supplies
   no u_e, so the optimizer is blind exactly where it is supposed to grow. No
   re-activation schedule repairs this: the signal that would trigger re-activation
   is the very thing that was skipped.
   Separately, per Correction 2, skipping would not even pay in the build, because
   the build's per-element cost is geometric and value-independent.

**(b) A coarser multigrid level for void regions — VIABLE but not chosen (see
"What remains").** The coarse operators are only a **preconditioner**: CG converges
to the same field regardless, so this is answer-preserving in principle and it is
the one lever that reaches the 84% of coarse nnz (267 MB) and the ~51 ms/iter of
V-cycle. But it changes the iteration count (so 078's parity is no longer exact),
risks a **singular A1** (coarse DOFs supported only by dropped void elements get
zero rows), and degrades the preconditioner precisely in the ill-conditioned region.
It is the biggest remaining lever and is left, measured, for a follow-up.

**(c) Sparsity in the element table — real but small.** `MfElem` is 104 B (8 B
factor + 24 int edof); the 24 edof are **derivable** from the voxel index on a
regular grid, so the table could be 12 B/elem: **66.4 MB → 7.7 MB**. Exact, but
~3% of the 1.97 GB end-to-end peak. Not chosen; noted.

**CHOSEN — the Galerkin block cache: collect the near-void 91% of the build
EXACTLY, via repetition.** `axis_weights` is **parity-based and translation-
invariant** (an even fine index maps to 1 coarse node at weight 1, an odd one to 2
at weight 0.5 — no boundary special-casing). Therefore every element whose 24 fine
DOFs are all free and whose 8 coarse nodes are all active ("generic" — the interior
majority, void and solid alike) has the same `W`, and hence the same `S`, as any
other element **of the same (i,j,k) parity**. That parity is **exactly the existing
8-colour key `m.elems` is already sorted by** (085's threading colour). So `S` is
computed **once per colour** and reused; non-generic elements (BC-fixed / void-gated
at the boundary) take the unchanged full path.

Why this is the right pick against the profile:
- It targets the **measured** dominant cost (the build's numeric pass, 80% of the
  build, which is 48% of the solve), of which **91% is near-void**.
- It is **bit-identical**, not an approximation — so it needs no adaptivity, no
  re-activation schedule, and **cannot** break growth.
- **Genericity test = `mloc == 24`.** An element's 8 nodes span 2 coarse indices per
  axis whatever its parity (the union over {i, i+1} is 2 either way), so its coarse
  support is always 2×2×2 nodes × 3 components = 24 coarse DOFs. `mloc` counts the
  DISTINCT coarse DOFs actually discovered, so `mloc < 24` **iff** some coarse DOF
  was inactive and its stencil entry dropped. `mloc == 24` therefore certifies that
  nothing was dropped; combined with every `kg[r] >= 0`, `W` is fully determined by
  the colour.

### How growth is preserved, and how global coupling is preserved

**Growth: nothing is deactivated, so there is nothing to re-activate.** Every
element — including every near-void one — remains fully represented in *both* the
exact matrix-free fine operator *and* in A1, at its own `el.factor`. The fine
operator alone determines the field and therefore the sensitivities that drive
growth, and it is **not touched at all**. The cache changes only *how* a geometric
block is obtained (compute-once vs recompute), never *whether* an element
participates.

**Global coupling: untouched.** The domain is not fragmented, nothing is solved
independently, and nothing is frozen. It remains one global matrix-free fine solve
preconditioned by one global Galerkin hierarchy — bit-for-bit the same hierarchy as
before.

---

## STEP 3 — IMPLEMENTATION (opt-in, DEFAULT OFF)

`fea_set_matfree_galerkin_block_cache(bool)` — additive public API, **default OFF**,
returns the previous setting. Enabled, `build_mf_hierarchy`'s pass 2 walks the
colour ranges alongside the element loop, seeds `S` from the first generic element
of each colour, and reuses it for the rest.

**Bit-identity by construction:** the cached `S` is the same arithmetic on the same
inputs; each element still scales by its **own** `el.factor`; the element loop order
and the per-(i,j) add order are unchanged. So A1, the V-cycle, the iteration count
and the field are unchanged.

---

## MEASURED RESULTS (96×80×96, 638,820 elements, 4 threads)

**Before/after against the ACTUAL status quo** — three separate processes, quiet
machine, `ru_maxrss` high-water. The baseline is the **pre-090 `multigrid.cpp`**
(same library, original translation unit swapped back in), NOT the cache-OFF path —
see the note below, which matters:

| | build | **full solve** | peak RSS | iters | coarse nnz |
|--|------:|---------------:|---------:|------:|-----------:|
| **pre-090 (079/085 status quo)** | 7.810 s | **16.398 s** | **1.511 GB** | 94 | 22,231,386 |
| 090, cache OFF (the shipped default) | 6.063 s | 14.605 s | 1.511 GB | 94 | 22,231,386 |
| **090, cache ON** | **3.729 s** | **12.211 s** | **1.511 GB** | 94 | 22,231,386 |
| **ON vs status quo** | **2.09×** | **1.34×** | **unchanged** | **same** | **identical** |

The numeric pass — the whole target — goes **6.32 s → 2.25 s (2.8×)**.

**The cache-OFF row is not a null result, and it is why the baseline had to be
measured separately.** Restructuring pass 2 to materialise `S` *before* the scatter
loop (rather than computing each entry inline inside it) separates the FP block
arithmetic from the unpredictable binary-search memory traffic, and that alone is
worth **7.810 → 6.063 s (1.29×)** on the DEFAULT path — bit-identically, with the
cache off. Had I reported "cache OFF vs cache ON" I would have silently credited the
cache with 1.21× while hiding a 1.29× refactor win in the baseline. Against the real
status quo the change is worth **1.34×**.

**Honest reading of the 1.34×.** The block cache removes the *block arithmetic* half
of the numeric pass. What remains (2.25 s) is the **scatter** — 576 binary searches
into A1's value array per element — now pass 2's dominant term. Against the STEP-1
ceiling: the build went 7.81 → 3.73 s where "near-void free" would be 0.69 s, so
this captures **57% of the available build headroom** ((7.81−3.73)/(7.81−0.69)). And
since the build is only 48% of the solve, even a **free** build would cap the solve
at 16.40 → 8.59 s = **1.91×**. 1.34× of an available 1.91× is what this buys. That
Amdahl ceiling was named in STEP 1 *before* designing, not discovered afterwards.

**4-rung ladder — MODEL, not a measurement.** ~30 MMA iterations × 4 rungs ≈ **120
solves**, each rebuilding the hierarchy:

| | per solve | ladder (120 solves) |
|--|----------:|--------------------:|
| pre-090 status quo | 16.40 s | **32.8 min** |
| 090, cache ON | 12.21 s | **24.4 min** |

I could not run the real iPad ladder (no Apple device here). The M2 Pro model
(32.8 min) against the maintainer's observed ~80 min on the M1 iPad implies the
device is ~2.4× slower, which is plausible for 4 M1 cores vs 4 M2 Pro cores; on that
scale the ladder would go **~80 → ~60 min**. The RATIO transfers, not the wall.

### Does this bring 128³ or Fine+box into range? **No — and it cannot.**

State it plainly: **this change is TIME-only. Peak memory is unchanged — 1.511 GB
in all three configurations, identical to the digit (the cache is 8 colours × 24 ×
24 doubles = 36 KB).** It therefore moves nothing across the
~3 GB per-app ceiling. Scaling the measured per-element costs:

| case | elements | coarse nnz | coarse-op memory | solve (cache ON) |
|------|---------:|-----------:|-----------------:|-----------------:|
| 96×80×96 design box (measured) | 0.64 M | 22.2 M | 0.27 GB | 12.2 s |
| 128³, no box | 2.10 M | ~73 M | **~0.88 GB** | ~40 s |
| Fine + box (~5.4 M voxels) | ~4.7 M | ~163 M | **~1.95 GB** | ~89 s |

At 0.64 M elements the end-to-end peak is already ~1.97 GB (079). 128³ is 3.3× the
elements with ~0.88 GB of coarse operators alone, and Fine+box is 7.3× with ~1.95 GB
of coarse operators alone — both blow the budget. Bringing either into range needs a
**memory** lever, and per STEP 1 the only one large enough is the 84.4% of coarse
nnz held by the near-void region — i.e. option (b), which is exactly what remains.

---

## What remains (honest, with the numbers to act on)

1. **Option (b) — shrink the coarse operator over the void. The biggest remaining
   lever, and the only one that is BOTH memory and time.** Measured: 84.4% of A1's
   22.2 M nnz (267 MB) is near-void, and the V-cycle + CG vectors are ~51 ms of
   every 91 ms iteration (the apply is only 40 ms of it). Because the coarse operators are only a *preconditioner*, CG still
   converges to the same field, so this is answer-preserving in principle — but it
   changes the iteration count (078's parity stops being exact), and the design must
   handle the **singular-A1 risk** (coarse DOFs supported only by dropped void
   elements get zero rows) and the fact that the void is where conditioning is
   worst. Growth would still be safe *provided the fine operator stays exact*, which
   is the invariant this handoff establishes.
2. **Cache the hierarchy ACROSS solves — the largest pure-time win, now unlocked.**
   The key finding of STEP 1 generalises: P0, `prolong`, `ecds`, the symbolic
   structure, A1's sparsity pattern **and** the geometric blocks S are *all* pure
   geometry, so they are **identical across every solve of a run** — only
   `el.factor` changes. The hierarchy is nonetheless rebuilt from scratch on all
   ~120 solves. A persistent hierarchy (the `PenalizedSolver` pattern the assembled
   JacobiCG path already uses) would cut the build to just the value re-scatter:
   **7.81 s → ~2.3 s per solve** (a further ~1.35× end-to-end on top of this change). It needs
   a solver object threaded through `simp.cpp`'s optimize loop, so it is a larger,
   separate change.
3. **Thread the numeric pass.** 085 noted it needs a coarser colour than the apply's
   2×2×2; a 4×4×4 (64-colour) partition makes the coarse scatter race-free
   (same-colour elements are ≥4 fine cells apart, so their 2×2×2 coarse supports are
   disjoint). Worth up to ~3.5× on 4 cores by 085's measured apply scaling. **Cost: it forfeits
   bit-identity** — reordering elements reorders the cross-element summation into
   each A1 entry — so it trades guard (c)'s exactness for speed. Not done for that
   reason.
4. **Option (c) — element-table sparsity.** `MfElem`'s 24 `edof` are derivable from
   the voxel index: **66.4 MB → 7.7 MB**, exact. ~3% of peak; not done.
5. **No on-device run** (no iPad here). This worktree is real arm64/NEON, but the
   M1's 4 cores and memory behaviour still need confirming on the device.
6. **A caveat on my synthetic fields.** Two "converged-design" fields I first tried
   — random 6% material, and a period-8 strut lattice — both drove MG-CG past
   `kMgIterBudget` into the Jacobi-CG fallback (5338 iterations, `used_multigrid
   =FALSE`). Real SIMP fields are density-**filtered** and smooth; these were not.
   All numbers above therefore use the **iteration-0 field the optimize actually
   solves**, which converges in 94 iterations with `used_multigrid=TRUE` — matching
   079's 87. Worth knowing that a sharp high-contrast field defeats the multigrid.

---

## CORRECTNESS GUARDS — all green (`test_galerkin_cache`, 16 checks, 0 failures)

**a. SAME ANSWER — stronger than asked: BIT-IDENTICAL, not within 1e-6.**
- On the real 96×80×96 design box: **0 differing DOFs out of 2,286,387**,
  `max|du| = 0.000e+00`, iterations **94 == 94**, coarse nnz **22,231,386 ==
  22,231,386**.
- On the M7.dom design-box optimize: final design **max|drho| = 0.00e+00**, the
  **same rung count**, and the **same accept/reject decision** on every rung.
- Solid 32³ and soft-void graded 32³ (rho_min^p = 1e-9): bit-identical, same iters.

**b. GROWTH PRESERVED — the decisive guard.** On the M7.dom L-bracket gusset case
(the fixture the growth gate itself uses), where the optimizer is KNOWN to grow into
initially-near-void space: the uncached run grows **140** Active voxels to rho >= 0.5
and the cached run grows **exactly the same 140**, with `max|drho| = 0.00e+00`. The
test asserts `grown_off > 0` first, so it cannot pass vacuously on a case that never
grew.

> **This guard was vacuous when first written, and the fix is worth recording.**
> `SimpOptions::solver` defaults to `JacobiCG`, which never calls
> `build_mf_hierarchy` — so the first version of this test compared two runs that
> both bypassed the cache entirely and passed while proving nothing. It now sets
> `o.simp.solver = SolverKind::MultigridCG_Matfree` (what 079 flipped the production
> bridge to) and additionally asserts `used_multigrid == TRUE` on that expanded grid,
> so the cached coarse-operator build demonstrably runs. Anyone extending these
> guards should check the same trap.

*Would it fail against a broken scheme?* A scheme that permanently skipped the
void would produce no `u_e` inside it, so the sensitivity
`-p·rho^(p-1)·E0·u_eᵀ Ke u_e` that selects growth would be absent — `grown_on` would
diverge from `grown_off` and the check fails. (This particular change passes it
trivially *because it deactivates nothing* — which is the point, not a loophole: the
guard is what proves the fine operator was left exact.)

**c. 078 PARITY — holds EXACTLY.** With the cache ON, the matrix-free MG-CG still
converges in the same iteration count as the assembled MG-CG on the soft-void graded
grid (20 == 20 in the new test's setup); `fea_mgcg_matfree`'s own **18 == 18** is
untouched and passes. Since A1 is bit-identical, parity holds by construction.

**d. Gate-V2 green and unchanged; assembled + no-box paths byte-identical.**
Full suite **43/43 passed, 0 failed** (42 pre-existing + the new guard), including `gate_v2`, `design_domain`,
`designbox_reduction`, `designbox_padding`, `designbox_anchor_pad`,
`fea_mgcg_matfree`, `fea_matfree_threads`.

## Files

- `core/src/fea/multigrid.cpp` — the Galerkin block cache in `build_mf_hierarchy`'s
  numeric pass (matrix-free path only).
- `core/src/fea/matfree.cpp` / `fea_matfree.hpp` — the `mf_set/get` toggle state.
- `core/include/topopt/fea.hpp` — `fea_set_matfree_galerkin_block_cache` (additive).
- `core/CMakeLists.txt`, `core/tests/unit/test_galerkin_cache.cpp` — **new** guards.

## THE ONE RULE — honoured

- The **assembled path is byte-identical**: the diff touches only the matrix-free
  `build_mf_hierarchy` numeric pass plus an additive, default-OFF public setter.
  `fea_solve_mgcg`, `fea_solve_cg`, `build_hierarchy`, `galerkin_pt_a_p_frugal` and
  `PenalizedSolver` are untouched. Gate-V2 stays pinned to the assembled JacobiCG.
- **Opt-in and DEFAULT OFF** — `test_galerkin_cache` asserts the default is OFF, and
  the full suite is green with it off (nothing is enabled by this diff; no caller in
  `/core/` or the bridge turns it on).
- **No ROADMAP box checked.** `/core/` changed → run `app/scripts/build_core.sh`
  before the app sees it.
