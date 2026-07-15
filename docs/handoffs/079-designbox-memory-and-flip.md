# 079 — Design-box on-device: memory measurement, coarsening padding, matrix-free flip

**Track:** core. **Territory:** `/core/` only + the sanctioned bridge flip
(`app/TopOptKit/Sources/TopOptBridge/bridge.cpp`). No app view code, fixtures,
benchmarks, materials.json, ARCHITECTURE.md, or ROADMAP box.
**Builds on:** 078 (matrix-free geometric multigrid `fea_solve_mgcg_matfree`).
This branch MERGED 078 first (`claude/intelligent-archimedes-a6b1a7`) — it was not
on `main`; the merge is /core/-only and additive (see "What was done").

## THE ONE RULE — honoured

The assembled default path (JacobiCG / `fea_solve_cg` / `PenalizedSolver`) is
byte-for-byte unchanged and Gate-V2 stays pinned to JacobiCG. Every existing test
passes; the two design-box tests updated their EXPECTED grid dims (the intended
behaviour change), not the physics they assert. Full suite: **36/36 green**.

- `expand_design_domain` gained a `coarsen_align` parameter **defaulting to 1**
  (no rounding = byte-identical); only the driver passes 8.
- `multigrid.cpp` matrix-free changes are matrix-free-path only. `fea_solve_mgcg`
  (assembled) and `build_hierarchy(frugal=false)` are byte-identical.
- `simp.cpp` gates the `PenalizedSolver` to the JacobiCG path; for JacobiCG the
  construction/use is identical to before.

---

## STEP 1 — MEASUREMENT FIRST (the table, before any change)

Real failing case reconstructed: **623,700 solid voxels**, frozen part @ E0=2000,
grown region @ E0·1e-9 (SIMP rho_min^p soft void, p=3, rho_min=1e-3), BC/load on
the frozen part (mirrors the part-indexed remap). Peak = `getrusage` `ru_maxrss`
(macOS = bytes), isolated per process. Budget target ~1.5 GB.

| Grid                | Path      | used_mg | lvls | iters | conv | **PEAK** | steady | verdict |
|---------------------|-----------|---------|------|-------|------|----------|--------|---------|
| 90×78×91 raw (odd z)| assembled `fea_solve_mgcg` | FALSE | 0 | hang | no | **7.14 GB** | 7.1 GB | OOM — the device `std::bad_alloc` |
| 90×78×91 raw (odd z)| matfree `fea_solve_mgcg_matfree` | **FALSE** | 0 | hang | no | 0.25 GB | 0.25 GB | fits mem but HANGS (Jacobi-CG on 1e-9) |
| 96×80×96 padded     | assembled `fea_solve_mgcg` | TRUE | 4 | 87 | yes | **7.52 GB** | 2.31 GB | over (peak AND steady) |
| 96×80×96 padded     | matfree `fea_solve_mgcg_matfree` | TRUE | 4 | 87 | yes | **7.53 GB** | 0.86 GB | peak over (A1 transient); steady FITS |

Per-component (padded matfree, the fix target), BEFORE the STEP-3 fix:
- element table: 62 MB · **A1 element-local Galerkin triplet transient: 5.48 GB
  (359,251,200 triplets × 16 B) ← THE BLOCKER** · assembled coarse ops: 248 MB ·
  CG vectors: 192 MB · fine K: **0** (never assembled; the assembled path holds
  2.0 GB there).

Confirmations (all as the task predicted):
1. **matfree on 90×78×91 reports `used_multigrid=FALSE`** — the odd z=91 makes
   `build_mf_hierarchy` bail (every fine element dim must be even). CONFIRMED.
2. Assembled path peaks **7.14 GB** — matches the device `std::bad_alloc`. Its
   fine-K assembly streams the SAME ~359M-triplet transient (~5.5 GB) plus the
   ~1.7 GB compressed matrix. CONFIRMED.
3. The A1 element-local Galerkin transient is **5.48 GB** (my ~5.7 GB arithmetic
   check confirmed) — the matrix-free blocker, present only AFTER padding (on the
   raw odd grid the matrix-free path bails before A1). CONFIRMED.
4. Matrix-free steady-state (0.86 GB) is under budget → batching A1 lands it under.

Both problems stacked exactly as described: (1) OOM from the assembled fine K —
matrix-free removes it; (2) NO coarsening on the odd 91 axis — matrix-free does
NOT fix it, padding does.

---

## STEP 2 — PAD THE EXPANDED GRID (fixes problem 2: no coarsening)

`expand_design_domain(part, box, keep_out, coarsen_align=1)`: rounds each expanded
element dim UP to a multiple of `coarsen_align` by **appending EMPTY voxels on the
HIGH side only**. The driver (`minimize_plastic`) passes **8** (`>= 3` multigrid
levels).

- **Padding choice: align to 8.** 90×78×91 → **96×80×96**. Voxel cost:
  638,820 → 737,280 = **+15.4%** grid voxels (the padding is Empty — no elements,
  no DOFs after the void gate — so no *physics* cost). Buys mg_levels=4.
- **No physics added:** appended voxels sit beyond `design_box.max`, so they are
  classified Empty exactly like any existing out-of-box voxel; the void-DOF gate
  removes their DOFs. Proven: unpadded vs padded design-box compliance matches
  **exactly** (rel.diff 0.00e+00), and the design-box optimize's grown-material /
  keep-out-void / frozen-retained assertions are unchanged.
- **Remap stays correct:** only the high side grows, so `offset_i/j/k` and origin
  are untouched and `remap_node_to_domain` needs no change. Verified at a NONZERO
  offset (test grid 17×10×10 → 24×16×16, offset (4,1,1); corner node remap holds).
- **Multigrid now engages:** a padded grid reports `used_multigrid=TRUE`,
  `mg_levels >= 3` (test: 3 levels on 24×16×16; 4 on the real 96×80×96).

New test `tests/validation/test_designbox_padding.cpp` proves all three (12
checks). `test_design_domain.cpp` updated: its directly-built domain now passes
align=8 to match the driver, and its dim assertion is 16×8×16 (was 11×3×11) — the
intended behaviour change; all physical assertions unchanged.

---

## STEP 3 — BATCH/BOUND THE A1 TRANSIENT (needed: STEP 1 showed 5.48 GB)

Batching WAS needed. Two changes to the matrix-free A1 build in
`build_mf_hierarchy` + the coarse products:

1. **A1 accumulated in place** (no triplet array): A1 is pre-reserved with the
   coarse Galerkin stencil width (81 = 3×3×3 coarse nodes × 3 comps) and each
   element block is added via `coeffRef`. The 359M-triplet / 5.48 GB array is
   never materialised. (An intermediate `A1 += block` batching attempt still hit
   ~3.5 GB from sparse-add churn + malloc fragmentation — the in-place path is the
   one that works.)
2. **Frugal (column-blocked) coarse Galerkin** for the matrix-free path: `A_c =
   P^T A P` computed 4096 coarse columns at a time so the `A·P` intermediate is a
   block, not the full peak-doubling product. Opt-in (`build_hierarchy(...,
   frugal=true)`); the assembled path keeps the plain product byte-for-byte.

**Bit-comparability held:** the 078 assert `matfree iters == assembled iters`
(18 == 18 on the soft-void 32³) is unchanged — the regrouped summations differ
only at the ULP level. End-to-end, the matrix-free design matches the assembled
multigrid design: `max|rho_mf − rho_asm| = 4.26e-7`, compliance rel.diff 3.3e-11.

**Solver peak after STEP 3:** 7.53 GB → **1.34 GB** on the real 96×80×96
(used_multigrid=TRUE, mg_levels=4, 87 iters). Under the 1.5 GB budget.

---

## STEP 4 — FLIP PRODUCTION (done; see the honest end-to-end number)

- `SolverKind` extended with `MultigridCG_Matfree` (default OFF at the library
  level; JacobiCG stays the default, Gate-V2 untouched). `simp_compliance` routes
  it to `fea_solve_mgcg_matfree`.
- **Critical gate:** `simp_optimize` constructed a `PenalizedSolver`
  UNCONDITIONALLY, and its constructor assembles the BC-reduced fine K — the very
  ~2 GB / ~7 GB-transient matrix. It is now built ONLY for JacobiCG; both
  multigrid kinds (which bypass it) skip it. Without this gate the flip would have
  re-introduced the OOM. This applies to BOTH `simp_optimize` variants, incl. the
  mask-aware MMA one the design-box run uses.
- Bridge: both production entry points (`run_minimize_plastic`,
  `run_minimize_plastic_loadcase`) flipped `MultigridCG → MultigridCG_Matfree`.

**End-to-end re-measurement (the honest numbers):** the real 96×80×96 design-box
case run through `minimize_plastic` with the flip **completes**, uses multigrid,
and peaks at:

| scale | ndof | end-to-end peak (ru_maxrss) |
|-------|------|-----------------------------|
| 96×72×88 | 1.89M | 1.58 GB |
| **96×80×96 (real)** | **2.29M** | **1.97 GB** |

Decomposition (real scale): solver working set 0.90 GB steady / 1.34 GB peak +
density filter 0.21 GB + MMA/keyframes/fragmentation ~0.4 GB.

**This is OVER the 1.5 GB target but a 3.6× improvement that no longer
crashes/hangs** (the status quo — assembled `MultigridCG` — OOMs at 7.1 GB on this
case). `ru_maxrss` is malloc high-water and OVERestimates the iOS `phys_footprint`
(macOS does not return freed pages), and the harness part is fuller than the real
85%-solid case, so the on-device footprint is likely lower. It is under the ~2 GB
device kill line.

**Decision (user-confirmed): KEEP THE FLIP.** It is strictly better than the
crashing status quo — matrix-free is neither known-OOM (completes at ~1.97 GB) nor
known-hang (converges in 87 iters). The ~1.97 GB peak is documented as a known
limitation with a follow-up lever below.

---

## What was NOT done / follow-ups

- **End-to-end peak is ~1.97 GB, not comfortably under 1.5 GB.** The working sets
  (solver ~0.9 GB + filter ~0.2 GB + MMA/driver ~0.2 GB) floor at ~1.3 GB, so no
  cheap change gets it well under target.
- **Biggest remaining lever: matrix-free CG-solve allocation churn.** The
  V-cycle/matvec (`mf_fine_matvec`, `mf_v_cycle`) allocate several ng-sized Vec
  temporaries PER iteration (~87 iters), inflating the high-water by ~0.45 GB
  (solver peak 1.34 GB vs 0.90 GB steady). Reusing preallocated scratch would push
  the solver peak toward ~1.0 GB and end-to-end toward ~1.5-1.6 GB. Not done: it
  touches the numerically-sensitive hot path (078 iteration-count parity must
  hold) and has diminishing returns against the ~1.3 GB working-set floor.
- The density filter (~0.2 GB) and MMA state are inherent to the optimize.
- No on-device run performed (no hardware in this environment); the device
  footprint is inferred from macOS `ru_maxrss` (a conservative overestimate).

## Evidence

- Full suite: **36/36 passed** (`ctest`), Gate-V2 green and unchanged.
- STEP-1 table above (per-component, per-path, peak). used_multigrid/mg_levels:
  FALSE/0 on raw 90×78×91 (odd), TRUE/4 on padded 96×80×96 — before and after
  padding.
- New/changed tests: `test_designbox_padding` (padding inert + multigrid engages +
  remap at nonzero offset), `test_design_domain` (+4 checks: matrix-free flip ==
  assembled design end-to-end; updated expected dims).
- `/core/` changed → run `app/scripts/build_core.sh` before the app sees it.
