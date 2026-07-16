# 085 — Matrix-free solver SPEED (SIMD + threading + scratch reuse)

**Track:** core. **Territory:** `/core/` only (no app, no fixtures, no benchmarks,
no materials.json, no ARCHITECTURE.md, no ROADMAP box).
**Builds on:** 077 (matrix-free operator), 078 (matrix-free multigrid), 079
(design-box flip + the named scratch-reuse lever).

## Goal

Make the matrix-free solver FAST. 077/078 built it correct-but-scalar
("straightforward per-element loop, no SIMD/threading — raw speed later"); 079
flagged the per-iteration V-cycle allocation. This is a **pure-performance,
same-answer** task on the matrix-free path only.

## THE ONE RULE — honoured

- **Assembled path byte-identical.** `multigrid.cpp`'s assembled functions
  (`v_cycle`, `jacobi_sweep`, `build_hierarchy`, `mgpcg`, `solve_reduced_mgcg`,
  `fea_solve_mgcg`, `galerkin_pt_a_p_frugal`, `inverse_diagonal`) are untouched;
  the diff only edits the `mf_*` matrix-free functions. Gate-V2 (pinned to the
  assembled JacobiCG) green and unchanged.
- **078 parity holds EXACTLY:** matrix-free MG-CG converges in the SAME iteration
  count as assembled MG-CG — **18 == 18** on the soft-void 32³ — after every step.
  All iteration counts (34/216/15/18/843) are unchanged from the 077/078 baseline.
- **DETERMINISM proven** as a test: bit-identical output across thread counts
  (1/2/4/8) and run-to-run (see STEP 4 + `test_matfree_threads`).

> **Environment caveat (read this).** The task targets Apple Silicon / NEON on an
> iPad. This worktree ran on **x86-64, 4 cores, GCC 13 -O3**. I therefore measured
> the SIMD kernel at **2-wide SSE2 — the SAME vector width as NEON** — so the local
> numbers are a faithful proxy for the 2-wide NEON apply, and I wrote the NEON
> intrinsic path (compiled on `__ARM_NEON`) alongside it. Thread scaling is real
> but capped at **4 physical cores**; 6/8-thread and the true on-device wall time
> need the 8-performance-core device. Every number below says which it is. No Apple
> hardware was available here; on-device re-measurement is the honest next step.

---

## STEP 1 — PROFILE FIRST (96×80×96 = 737,280 elements, graded soft-void, MG-CG)

Baseline (077/078 code, Release), full `fea_solve_mgcg_matfree`, per component:

| component                              |     time | share | note |
|----------------------------------------|---------:|------:|------|
| **build_mf_hierarchy (A1 element Galerkin)** | **26.4 s** | **63 %** | one-time/solve, `coeffRef`-bound |
| **fine element apply (matvec)**        | **12.5 s** | **30 %** | 40 calls, ~312 ms each, scalar 1-thread |
| coarse v_cycle                         |  1.39 s | 3.3 % | |
| prolong / restrict / CG-vec / jacobi-axpy | ~0.7 s | ~1.7 % | combined |

Full solve **38.7 s**, peak RSS **1.64 GB**. Kernel micro-bench: `mf_apply_full`
**271 ms/apply → 3.1 GFLOP/s, scalar single-threaded**.

**Top two costs, with numbers:**
1. **fine element apply** — 312 ms/call, 4 calls/CG-iter (2 smooth + residual +
   CG matvec) = 1.25 s/iter. At the real design-box iteration count (~87, per 079)
   this is ~108 s/solve and DOMINATES. This is the scalar/SIMD/threading target
   (STEP 3/4). Its scalar 3.1 GFLOP/s is the "10-30× too slow" the task names.
2. **build_mf_hierarchy** — 26 s/solve, one-time, `A1.coeffRef` sparse
   accumulation (079 chose `coeffRef` to avoid a 5.48 GB triplet transient). Fixed
   per solve; co-dominant at low iteration counts. **NOT touched here** (see
   "Not done") — it is out of the task's named apply scope and directly memory-
   sensitive, but it is now the #1 remaining lever and is flagged below.

Allocation: `mf_fine_matvec` allocated 3 vectors/call; the V-cycle/CG allocated
~6-8 ng-sized `Vec` temporaries/iter (ng=2.26M → 18 MB each). STEP 2 target.

---

## STEP 2 — SCRATCH REUSE (079's named lever)

- Added `MatfreeReduced::apply_kgg_raw(const double*, double*)`: Eigen vectors are
  contiguous, so the fine matvec now drives the element apply straight off
  `x.data()/y.data()` — **no `Vec`↔`std::vector` marshalling** (baseline allocated
  two `std::vector`s + an output `Vec` every call).
- Added `MfScratch` (Ax, vr, prol, Ap, zc, bc, ec), sized ONCE per solve and reused
  by `mf_jacobi_sweep`/`mf_v_cycle`/`mf_mgpcg`. The per-iteration `Vec` temporaries
  are gone. Every buffer is fully written before read ⇒ **bit-for-bit identical**
  arithmetic; iteration counts and residuals unchanged.

Measured:
- Wall: fine matvec **312 → 285 ms/call** (−9 %, marshalling removed; per-call, so
  it scales with iteration count).
- Malloc traffic (64×48×64, counted via `operator new`): **1656.6 → 1283.4 MB
  per 10-iter solve (−373 MB, −22 %)**, ~37 MB/iter removed; scales to ~12 GB of
  churn removed over an 87-iter design-box solve. (Alloc *count* barely moves —
  1.5 M tiny allocs live in `build_mf_hierarchy`'s `coeffRef`, untouched.)
- Peak RSS on 96×80×96: 1.64 → 1.64 GB **unchanged on this proxy** — at these
  iteration counts the high-water is set by `build_mf_hierarchy`'s transient, which
  the iteration temporaries never exceed. 079 measured ~0.45 GB peak reduction
  on-device (macOS, 87 iters) from exactly this change, where per-iteration churn
  inflated the high-water. Honest: on this allocator/scale STEP 2 is a
  malloc-traffic + small-wall win; the peak win lands on the many-iteration device.

---

## STEP 3 — SIMD THE ELEMENT APPLY (2.48× measured)

The 24×24 reference-block matvec `y_r = Σ_c Ke[r][c]·ul[c]` is restructured from
row-dot (fixed r, horizontal reduction) to **column-major AXPY** (fixed c, all r):
`Ke` is pre-transposed once into `KeCM[c*24+r]` and `res[]` is accumulated one
contiguous column at a time. Because each output r still sums its terms in
ascending-c order, the result is **BIT-FOR-BIT identical** to the row-dot loop
(same terms, same order) — proven: residuals 8.160e-9 / 8.239e-9 / 4.544e-9 /
5.340e-10 and iters 34/216/15/18/843 all EXACTLY match baseline; 18==18 holds.

- `axpy24()`: 2-wide SIMD — **NEON** (`vmulq_f64`+`vaddq_f64`) on Apple Silicon,
  **SSE2** on x86, scalar fallback. **Plain multiply+add, never FMA**, so the
  vector and scalar paths agree to the last bit and the parity does not depend on
  the compiler's fp-contraction setting.

Measured (96×80×96, single thread, 2-wide = NEON width):
| kernel | before | after | speedup |
|--------|-------:|------:|--------:|
| `mf_apply_full` | 271 ms | **109 ms** | **2.48×** (3.1→7.8 GFLOP/s) |
| `apply_kgg`     | 292 ms | 123 ms | |
| fine matvec (in-solve) | 312 ms | 128 ms | |

The 2.48× from a 2-wide unit comes from killing the row-dot's horizontal reduction.
**Single precision was NOT adopted** — it changes the numerics (078 parity risk)
for a kernel that is not bandwidth-bound enough to need the extra width; doubles
kept. Cache blocking is unnecessary: `KeCM` (4.6 KB) is reused across all elements
and stays in L1.

---

## STEP 4 — THREAD THE ELEMENT LOOP (deterministic 8-colour, proven bit-identical)

**Scheme.** `colour(i,j,k) = (i&1) | (j&1)<<1 | (k&1)<<2` — the 2×2×2 parity
partition. Two same-colour elements differ by an even offset on ≥1 axis, so they
are ≥2 cells apart there and their node spans are DISJOINT ⇒ **no two same-colour
elements share a node**. The apply runs colour 0..7 in FIXED order; within a colour
the elements run in parallel with **no races**, and because each node is written by
exactly ONE element per colour, its (≤8) contributions accumulate strictly in
**colour order regardless of thread count or scheduling**. ⇒ **Deterministic:
bit-identical for 1 vs N threads and run-to-run.** (A naive atomic scatter would
vary run-to-run and break parity — this is why colouring, not atomics.)

**Implementation.** Elements are stored colour-sorted (`mf_build_elems` +
`color_offsets`); a **persistent fork-join thread pool** (spawned once, reused
across the thousands of applies in a solve) dispatches each colour's chunks. A
first cut that spawned `std::thread`s per apply made 4 threads **2× SLOWER**
in-solve (repeated pthread stack mmap/join); the pool fixed it. Public knob:
`fea_set_matfree_threads(n)` (0 = auto = hardware concurrency). The coarse direct
solve is NOT threaded.

Scaling — kernel apply, 96×80×96, x86 4-core:
| threads | 1 | 2 | 4 | 6 | 8 |
|---------|---:|---:|---:|---:|---:|
| ms/apply | 121.7 | 61.9 | 34.6 | 42.9 | 37.4 |
| speedup  | 1.00× | 1.97× | **3.51×** | 2.84× | 3.25× |

6/8 threads oversubscribe a 4-core box (need the 8-perf-core device). In-solve fine
matvec (real V-cycle interspersing): 133 → 85.8 → 57.9 ms at 1/2/4 threads (2.30×
at 4; the gap to the kernel is cold cache between sparse V-cycle ops, which the
device's higher memory bandwidth narrows).

**DETERMINISM (the required guard, `test_matfree_threads`, 20 checks):**
`fea_solve_mgcg_matfree`, `fea_solve_cg_matfree` and `fea_matfree_apply` all
produce **bit-identical (0 differing DOFs, maxdiff 0.0e+00)** output across thread
counts 1/2/4/8 and across repeated runs; the threaded MG-CG still matches the
assembled `fea_solve_mgcg` DOF-for-DOF ≤1e-6 and at the SAME iteration count.

Colour-sorting shifts the scatter order vs the old grid-scan order, moving
residuals at the ULP level (8.239e-9 → 8.238e-9), within tolerance and without
changing any iteration count.

**Combined SIMD+4-thread apply kernel: 271 ms → 34.6 ms = 7.8× on 4 cores.** On the
8-perf-core device, SIMD(2.5×) × threading targets the task's 10-30× band;
on-device measurement required.

---

## END-TO-END (the number that matters, honest)

**Measured full solve, 96×80×96, baseline vs final (default/auto threads):**

| | solve | apply portion | peak RSS | iters |
|--|------:|--------------:|---------:|------:|
| baseline (077/078, scalar 1-thread) | **38.4 s** | ~12.5 s | 1.64 GB | 10 |
| final (SIMD + 4-thread + scratch)   | **29.0 s** | ~2.5 s | 1.64 GB | 10 |

**1.33× here** — and that is the *honest, unflattering* number: this geometry
converges in **10 iterations**, so the solve is dominated by the one-time
`build_mf_hierarchy` (~26 s, deliberately NOT optimized), and the apply — which I
sped up ~5× — is only ~⅓ of the work. The apply speedup shows fully only when the
iteration count is high, which is exactly the design-box regime.

**4-rung design-box ladder — MODEL (measured per-call costs × 079's design-box
parameters).** I could not run the real 2.5 h iPad ladder (no Apple hardware) and
my harness geometry converges in 10 iters, not the design box's ~87. So this is a
model, not a measurement: it multiplies the **measured** in-solve costs (fine
matvec baseline 0.312 s vs final 0.058 s/call; 4 applies/CG-iter; ~0.20 s/iter
coarse+vector; 26 s build) by 079's ~87 iters × ~30 MMA × 4 rungs ≈ 120 solves.

| | per solve (87 iters) | ladder (120 solves) |
|--|---------------------:|--------------------:|
| baseline | 26 + 87·1.45 ≈ **152 s** | ≈ **5.1 h** |
| final    | 26 + 87·0.43 ≈ **64 s**  | ≈ **2.1 h** |

**≈ 2.4× per solve / ladder** from the apply work alone, on this 4-core x86 proxy.
On the device: (a) 8 performance cores scale the apply further than my 4, pushing
the ratio up; (b) the absolute wall differs from both my model and the observed
2.5 h (different ISA, core count, and the real 85 %-solid geometry) — the RATIO is
what transfers. After this change the build is ~40 % of each solve, so the
`build_mf_hierarchy` follow-up (below) is the next ~2× and the clear path to well
under the device time.

## Correctness guards — all green

- `fea_matfree` (78 checks), `fea_mgcg_matfree` (44 checks incl. **18==18**),
  **`fea_matfree_threads` (20 checks, NEW — determinism)** all pass.
- Full core suite green; **Gate-V2 green and unchanged** (pinned to assembled
  JacobiCG, byte-identical).
- 078 same-answer suite unchanged: matrix-free MG-CG == assembled MG-CG ==
  Jacobi-CG DOF-for-DOF ≤1e-6 on solid AND soft-void graded grids.

## Files

- `core/src/fea/matfree.cpp` — column-major AXPY SIMD kernel (NEON/SSE2/scalar),
  colour-sorted element table, persistent thread pool, `apply_kgg_raw`,
  `fea_set_matfree_threads`.
- `core/src/fea/fea_matfree.hpp` — `apply_kgg_raw`, `color_offsets`, colour/thread
  declarations (internal).
- `core/src/fea/multigrid.cpp` — `MfScratch` + scratch-reuse in the matrix-free
  V-cycle/CG (matrix-free functions only; assembled path byte-identical).
- `core/include/topopt/fea.hpp` — `fea_set_matfree_threads` (additive public API).
- `core/CMakeLists.txt` — link `Threads::Threads`; build/register
  `test_matfree_threads`.
- `core/tests/unit/test_matfree_threads.cpp` — **new**, determinism guard.

## Not done / follow-ups (honest)

- **`build_mf_hierarchy` (~26 s/solve) is now the co-dominant / dominant cost and
  is NOT optimized here.** It is out of the task's named apply scope and is the
  memory-sensitive `coeffRef` path 079 engineered to avoid a 5.48 GB triplet
  transient. The clean speedup is a two-pass CSR assembly (count per-column nnz,
  then scatter values into the fixed 81-wide coarse stencil) — memory-bounded and
  ~5-10× faster than `coeffRef` — but it is a substantial change to numerically-
  sensitive code and warrants its own task with the 18==18 + memory guards.
  **This is the biggest remaining end-to-end lever.**
- **On-device measurement not performed** (no Apple hardware). NEON path is
  correct-by-construction (bit-identical arithmetic to the verified SSE2/scalar
  path); wall time and 6/8-thread scaling need the iPad / an arm64 host.
- Thread-count is a process-global knob; the pool assumes applies are not issued
  concurrently from multiple threads (true for the single optimise loop).

## Build

`/core/` change → run `app/scripts/build_core.sh` before the app sees it (rebuilds
the xcframework; the iOS/macOS arm64 slices compile the NEON `axpy24`).
