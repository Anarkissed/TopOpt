# 092 — Mixed-precision matrix-free multigrid V-cycle (FP32 preconditioner, FP64 CG)

**Track:** core. **Territory:** `/core/` only — `matfree.cpp`, `fea_matfree.hpp`,
`multigrid.cpp`, `fea.hpp` (+ the new test and its CMake registration). No app, no
fixtures, no benchmarks, no materials.json, no ARCHITECTURE.md, no ROADMAP box.
**Builds on:** 077 (matrix-free operator), 078 (matrix-free multigrid + the
`18 == 18` parity tripwire), 085 (SIMD + 8-colour deterministic threading), 090
(Galerkin block cache).

## What shipped

An **opt-in, default-OFF** mixed-precision path in the matrix-free MG-CG: the
multigrid **V-cycle preconditioner runs in FP32** (fine apply, Jacobi smoother,
restriction, prolongation) while the **outer CG stays FP64** (residual, dot
products, α/β, x/r/p, and the convergence test) and the **coarse direct solve
stays FP64**. Public knob: `fea_set_matfree_mixed_precision(bool)` (returns the
previous value; thread-global; default OFF).

The mechanism is the published one — **Kronbichler, Ljungkvist et al. 2019, "Fast
matrix-free evaluation…/multigrid"**: a single-precision geometric-multigrid
V-cycle preconditioning a double-precision Krylov solver, reported *47%–83%*
faster with *comparable discretization error*. The safety argument is theirs
verbatim: *"single precision is only used in the multigrid V-cycle. The outer
Krylov solver operates in double precision. Larger round-off errors in the
multigrid cycle can be tolerated since these high-frequency errors introduced by
single-precision round-off are tackled by the multigrid smoothers, and since
multigrid is only a preconditioner applied to the residual of the outer Krylov
solver."* The V-cycle format is **converted on entry and exit** (double residual →
float in, float correction → double out).

---

## STEP 1 — PROFILE AND CEILING, named before believing the headline

**Environment caveat (same as 085/090).** Target is Apple Silicon / NEON on an
iPad Pro M1 (4P+4E). This worktree ran on **x86-64, 4 cores, GCC 13 -O3**. The
FP64 kernel is 2-wide SSE2 (== NEON double width); the FP32 kernel is **4-wide
SSE (== NEON `float32x4` width)**, so the local ratios faithfully proxy the
on-device 4-wide NEON float apply, and the NEON intrinsic path is written
alongside (compiled under `__ARM_NEON`). On-device wall time and true 8-core
scaling need the device; **the RATIO is what transfers**, the correctness and
iteration-count story is machine-independent.

### 1a. Which parts are bandwidth-bound and actually gain from FP32?

The V-cycle's cost, per the code and 085/090:

| V-cycle component | nature | FP32-eligible? |
|---|---|---|
| **fine element apply** (`mf_apply_full`) | bandwidth-bound on the 2.29M-DOF x/y vectors; Ke (576 doubles) stays in L1 | **yes — the lever** |
| Jacobi smoother axpy | bandwidth-bound (fine vectors) | yes |
| restriction `P0ᵀ r`, prolongation `P0 e` | sparse matvec, bandwidth-bound | yes |
| coarse solve (SimplicialLDLT, ≤ ~6000 DOF) | compute/latency, tiny | kept **FP64** |
| outer CG vector ops, dot products | FP64 by requirement | no |

**The literature's "halve the bytes → halve the time" is only PARTLY true for
THIS kernel — verified, not assumed.** Measured `mf_apply_full`, 96³ solid:

| threads | FP64 | FP32 | kernel speedup |
|--------:|-----:|-----:|---------------:|
| 1 | 92.31 ms | 62.94 ms | **1.47×** |
| 4 | 27.36 ms | 19.66 ms | **1.39×** |
| 8 (oversub. 4-core) | 31.64 ms | 19.86 ms | **1.59×** |

The apply is bandwidth-ish but the **24-DOF gather/scatter indirection** (integer
`edof` reads, unchanged in FP32) and the in-L1 Ke cap the win at **~1.4×, not 2×**.
This is the single most important number the task asked me to check rather than
assume: **FP32 does not double the apply.**

### 1b. The CEILING, up front (this project has been burned twice)

Of the **four fine applies per CG iteration** — 2 Jacobi smooths + 1 residual (all
inside the V-cycle) + 1 CG operator `A·p` — **only three are FP32-eligible**; the
CG operator stays FP64 (it defines the residual). So the CG-phase ceiling is:
`1 / (1 − 0.75·f_apply·(1 − 1/1.4))` where `f_apply` ≈ 0.84 of CG time is apply
work → **~1.25×**. Measured CG-phase (below) is **1.22×**.

End-to-end is then bounded by the **build share**. On the post-090 design-box
baseline (build 3.73 s / solve 12.21 s = 30 % build, 94 iters), applying the
measured 1.22× CG-phase gives `3.73 + 8.48/1.22 = 10.68 s → ~1.14×`. **Named
ceiling: ~1.4× kernel, ~1.22× CG-phase, ~1.15× end-to-end on the design box — NOT
2×, and it does NOT bring 128³ or Fine+box into range.** Same class as 090's 1.34×.
Stated before the measurements so the modest result is not a surprise.

### 1c. MEMORY — FP32 is NOT a memory lever here. Measured, plainly.

Peak RSS, real 96×80×96 solid, threads 4, cache ON, measured via `getrusage`:

| | peak RSS |
|--|---:|
| FP64 | **1.53 GB** |
| FP32 (mixed) | **1.53 GB** |

**Unchanged.** 091 proved the high-water is set by the **iteration-0 FP64 build
transient** (the symbolic CSC + A1 construction), which mixed precision leaves
entirely FP64. The FP32 V-cycle's float working set is *smaller* (helps cache —
part of the 1.22×), but it never approaches the build peak, and mixed mode in fact
*adds* ~150 MB of float copies (P0f, dinv_f, float scratch) alongside the FP64
originals kept for the fallback. So: **FP32 does not move the peak that 091
identified. It is a compute/bandwidth lever only, not the memory lever nothing
else has managed.** Said plainly, as instructed.

---

## STEP 2 — Design decisions, with justification

**Coarse solve: kept FP64.** The task biased toward this and it is right. The
coarse level is ≤ a few thousand DOFs, so the FP32 time/memory saving is
negligible, while an FP32 `SimplicialLDLT` factorization would risk robustness on
the graded operator. The literature note is the precedent: one implementation left
its AMG coarse solver in double *"since the Trilinos ML solver used here only
supports double precision."* The restricted residual is cast float→double on the
way into `v_cycle(H.coarse, …)` and the correction double→float on the way out.

**Galerkin block cache (090) composes cleanly — it does NOT conflict.** The cache
lives **entirely in the FP64 coarse-operator build** (`build_mf_hierarchy`'s A1
numeric pass): the blocks `S = WᵀKe W` are FP64 geometric constants, and A1..LDLT
are built identically whether or not FP32 is on. The mixed path only **rounds the
already-built fine `P0` and fine Jacobi diagonal to float** at the end of the
build — it never rebuilds A1 and never touches the cache. **No FP32 copy of the 8
blocks is needed** (they feed A1, which stays FP64), so there is no per-inner-loop
conversion cost. Cache and FP32 are orthogonal; both may be on, and the probe ran
with both on (reldiff 2.6e-14, converged). `test_galerkin_cache` stays green
(16/0), confirming the cache is bit-identical and unaffected.

**Determinism (STEP 3c) preserved without atomics.** The FP32 apply
(`mf_apply_full_f32` / `axpy24_f32`) keeps 085's exact structure: 8-colour
(2×2×2 parity) partition, colours applied in fixed order 0..7, each node written by
exactly one element per colour. FP32 addition is non-associative, but the
**summation ORDER is fixed** regardless of thread count, so the result is
bit-identical for 1/2/4/8 threads and run-to-run. Plain mul+add, **never FMA**
(085's reasoning — void inside the FP32 cycle since there is no double path to
match, but honoured anyway so no lane depends on fp-contraction). No atomic scatter.

**Underflow / overflow (the soft-void 1e-9-contrast check) — a POSITIVE finding.**
SIMP's soft void is `rho_min^p = 1e-9`, so graded factors span `1e-9·E0 … E0`
(≈ 2e-6 … 2100), comfortably inside FP32's normal range (min normal ≈ 1.2e-38) —
**no factor underflows.** The real risk is *catastrophic cancellation*: at a node
shared by a solid element (factor 1) and void elements (factor 1e-9), the void
contribution is ~1e-9 relative, **below FP32 eps (~1.2e-7)**, so it is rounded away
**in the preconditioner apply**. That makes the FP32 V-cycle a slightly different
(still SPD) operator — it can cost iterations, not accuracy, because the outer FP64
residual test still sees the full-precision operator. **Measured: it costs ZERO
extra iterations here.** On the graded soft-void 32³ (`rho_min^p = 1e-9`), FP32
converged in **18 iters == FP64 18**, field reldiff **5.84e-13**; at 64³, **17 ==
17**, reldiff 1.4e-11. The dynamically-scaled-residual mitigation one *half*-
precision paper needed is **not** required at single precision with this 1e-9
contrast. (If a future higher-contrast case ever degrades, that is a finding, not a
failure — and the fallback below already catches non-convergence.)

---

## STEP 3 — The new correctness story (retiring `18 == 18` on THIS path)

This path **deliberately breaks bit-identity**: FP32 is genuinely different
arithmetic, so the preconditioner differs and the iteration count *may* move. That
**retires 078's `18 == 18` bit-parity tripwire on the FP32 path** — iteration count
is a fingerprint of the preconditioner, and the preconditioner really is different.
It is replaced by a weaker-but-honest guard set (`test_mixed_precision`, 18 checks):

1. **SAME ANSWER (primary).** FP32 converges to the same field as FP64
   **DOF-for-DOF within `max|du|/max|u| ≤ 1e-6`**, on solid AND the `rho_min^p =
   1e-9` soft-void graded grid, at ≥ 3 levels. Airtight because the outer CG is
   FP64: its residual test is the guarantee. **Measured reldiff: solid 1.05e-14,
   graded 5.84e-13** — orders of magnitude under 1e-6.
2. **ITERATION-COUNT BOUND.** Asserted `FP32 iters ≤ FP64 iters + 8`; **observed
   FP32 == FP64 exactly** (solid 15==15, graded 18==18). If FP32 ever needed many
   more iterations the bandwidth win would be eaten — the bound catches that.
3. **DETERMINISM.** Bit-identical (0 differing DOFs, same iters) across thread
   counts 1/2/4/8 and run-to-run.
4. **STILL SPD.** CG *converges* (≤ 45 iters on 16³, ~ order of magnitude below the
   DOF count) rather than stalling — a ruined/non-SPD M would stall.
5. **DEFAULT OFF + FP64 PARITY UNTOUCHED.** Default is OFF; with it OFF the
   matrix-free MG-CG still matches the assembled MG-CG at the same iteration count.
6. **FALLBACK.** With mixed ON, a non-coarsenable grid still falls back to the
   exact matrix-free Jacobi-CG (`used_multigrid==false`) and matches the direct
   solve.

**Why replacing `18 == 18` with `≤ 1e-6` is honest, not a loophole.** The
`18 == 18` was a bit-fingerprint appropriate when the matrix-free path claimed to
*reproduce* the assembled preconditioner exactly. FP32 makes a *deliberately
different* preconditioner, so a bit-fingerprint is the wrong instrument — it would
fail by design and tell us nothing. The right instrument is the property the task
actually needs: **same converged field, bounded iteration cost, deterministic,
fallback-guarded.** The FP64 path keeps `18 == 18` **exactly** (guard 5 here, plus
`test_mgcg_matfree` and `test_galerkin_cache` unchanged and green), so nothing was
weakened on the path that still promises exactness — only the FP32 path, which
promises something different, is measured against a different-but-honest bar.

**FALLBACK discipline (STEP 3e).** In `solve_mgcg_matfree`, mixed mode tries the
FP32-V-cycle MG-CG first; if it fails to reach `tol` within the budget it
**retries the exact FP64 MG-CG on the same hierarchy** before the existing
Jacobi-CG fallback. Never ships an unconverged result; `used_multigrid` reports
truthfully.

---

## STEP 4 — Measured deltas (x86 4-core proxy; ratios transfer)

Cache ON in both arms (the true post-090 baseline).

**Kernel apply** (96³ solid): **1.39× @ 4 threads, 1.59× @ 8, 1.47× @ 1.**

**End-to-end, real 96×80×96 = 2.74M-DOF solid, cache ON** (this geometry converges
in 15 iters — solid & well-conditioned — so the solve is **build-dominated**, and
the apply win is diluted, exactly 085/090's honest caveat):

| threads | FP64 | FP32 | end-to-end | reldiff | peak RSS |
|--------:|-----:|-----:|-----------:|--------:|---------:|
| 4 | 15 it, 14.97 s | 15 it, 13.90 s | **1.08×** | 2.5e-14 | 1.53 GB (both) |
| 8 | 15 it, 14.23 s | 15 it, 13.28 s | **1.07×** | 2.5e-14 | — |

**Isolated build** (96×80×96 solid, cache ON, threads 4): **9.06 s** → CG-phase =
`(14.97−9.06)/15 = 0.394 s/iter` FP64 vs `(13.90−9.06)/15 = 0.323` FP32 →
**CG-phase per-iteration speedup 1.22×**. (Note: this x86 build is 9 s on an
884,736-element *solid* cube; the task's 3.73 s is the *design box*, 638,820 elems,
where the cache's ~94 % identical void blocks pay off more — different geometry and
ISA, so absolute build differs; the CG-phase RATIO is what transfers.)

**Iteration counts, correctness cases:** solid 15==15; graded soft-void
(`rho_min^p=1e-9`) 18==18 (32³) / 17==17 (64³). **Zero extra iterations** on every
case measured — the underflow concern did not materialize.

**The honest end-to-end number.** On this build-dominated proxy geometry, **1.08×**.
Projecting the measured 1.22× CG-phase onto the design box's 94-iter / 30 %-build
split gives **~1.14–1.15× per solve** — a real but modest win, **the same class as
090's 1.34×, and like 090 it does NOT bring 128³ or Fine+box into range.** The full
apply-dominated win shows only at high iteration counts (the real design-box
regime, ~94 iters), which this synthetic solid (15 iters) understates; on the
device's higher memory bandwidth the kernel ratio may rise toward the 8-thread
1.59× seen here under memory pressure, but that is a device measurement, not a
claim.

---

## Files

- `core/src/fea/matfree.cpp` — `axpy24_f32` (4-wide NEON/SSE/scalar, mul+add no
  FMA), `apply_one_element_f32`, `mf_apply_full_f32`,
  `MatfreeReduced::apply_kgg_raw_f32` (lazy float scratch), the
  `mf_set/get_mixed_precision` toggle, and the `fea_set_matfree_mixed_precision`
  public wrapper. FP64 kernels untouched.
- `core/src/fea/fea_matfree.hpp` — float scratch on `MatfreeReduced`,
  `apply_kgg_raw_f32`, `mf_apply_full_f32`, mixed-precision toggle decls.
- `core/src/fea/multigrid.cpp` — `SpMatF`/`VecF` aliases; `MfHierarchy::{P0f,
  fine_dinv_f}` (built only when enabled); `MfScratch` float buffers + `resize_f`;
  `mf_v_cycle_mixed`; `mf_mgpcg` gains a `mixed` flag dispatching the preconditioner
  (everything else FP64); the FP32-then-FP64-then-Jacobi fallback in
  `solve_mgcg_matfree`. Assembled path and FP64 matrix-free path byte-unchanged.
- `core/include/topopt/fea.hpp` — `fea_set_matfree_mixed_precision` (additive
  public API, documented mechanism + safety + the deliberate non-bit-identity).
- `core/tests/unit/test_mixed_precision.cpp` — **new**, the 18-check replacement
  guard described in STEP 3.
- `core/CMakeLists.txt` — build/register `test_mixed_precision`.

## THE ONE RULE — honoured

- **Assembled + FP64 matrix-free paths byte-identical.** Only new `*_f32` /
  `*_mixed` code and a default-OFF branch were added; the FP64 functions are
  untouched. `test_mgcg_matfree` (44, incl. **18==18**), residuals
  4.544e-9 / 5.340e-10 unchanged.
- **Gate-V2 green and unchanged** (72 checks; OC + projection path, never touches
  the matrix-free solver).
- Green: `fea_cg` (26), `fea_mgcg` (35), `fea_matfree` (78), `fea_mgcg_matfree`
  (44), `fea_matfree_threads` (20), `galerkin_cache` (16), **`fea_mixed_precision`
  (18, new)**, `gate_v2` (72).

## Not done / follow-ups (honest)

- **On-device (iPad M1) measurement not performed** (no Apple hardware). NEON FP32
  path is correct-by-construction (same colour-ordered arithmetic as the verified
  SSE/scalar path); wall time and true 8-perf-core scaling need the device. The
  M1's high unified-memory bandwidth may push the kernel ratio above the proxy's
  1.4×, but that is unmeasured.
- **The apply-dominated (high-iteration) end-to-end win is projected, not measured**
  — my harness geometry converges in 15 iters, not the design box's ~94. The 1.22×
  CG-phase is measured; the ~1.15× design-box end-to-end is a model, clearly labeled.
- Mixed mode keeps both `P0` (double, for the FP64 fallback) and `P0f` (float),
  costing ~150 MB — below the build peak, so it does not raise the reported RSS, but
  it is not a memory saving either.

## Build

`/core/` change → run `app/scripts/build_core.sh` before the app sees it (rebuilds
the xcframework; the iOS/macOS arm64 slices compile the NEON `axpy24_f32`). No
ROADMAP box checked.
