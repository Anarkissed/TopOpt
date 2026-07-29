# Deflated CG with solid-component rigid-body modes — Phase 0 (measurement, read-only)

**The idea (Jönsthövel, van Gijzen, MacLachlan & Vuik 2011).** Deflation projects the
small eigenvalues that stall CG out of the operator by handing CG an a-priori subspace
`U`. Their result: deflated PCG using the **rigid-body modes of homogeneous-material
regions** matches AMG on extreme-contrast composites. For a near-void/solid SIMP field
the natural `U` is the 6 rigid-body modes (3 translations + 3 rotations) of each
connected **solid** component. This Phase 0 measures — on REAL per-rung design fields —
the numbers that decide whether the method is worth building.

**Scope / B2.** Measurement only. NO production source changed, NO production default
touched. Everything is a standalone probe (`core/tests/harness/deflation_probe.cpp`, NOT
wired into CTest — the sanctioned pattern, à la `recycle_probe` / `beta_schedule_probe`).
The probe reaches into the library's own matrix-free operator (`fea_matfree.hpp`:
`mf_build_reduced`, `MatfreeReduced::apply_kgg_raw`, `mf_cg_solve`) so the baseline it
measures **is** the production Jacobi-CG bit-for-bit.

**We do better than the task's D2 "Lanczos estimate."** We rebuild the EXACT operator
`A = K(ρ)` at each real rung's converged density, then run the SAME Jacobi-PCG once plain
and once with the additive rigid-body-mode coarse correction
`M_rec⁻¹ = M⁻¹ + U E⁻¹ Uᵀ, E = UᵀAU`, counting iterations to the same 1e-8 relative
residual. That IS the deflated-CG iteration count on the real field. The effective
condition number comes from the exact CG→Lanczos tridiagonal reconstruction (the PCG
α/β coefficients), so it uses the identical preconditioner including the coarse
correction.

**Reconstruction self-check (every row).** The probe's own un-deflated PCG reproduces the
library `mf_cg_solve` iteration count to **|Δ| = 1** on all 11 rungs of all 3 fixtures
(the standard initial-residual-test off-by-one). The rebuilt operator, RHS, Jacobi
diagonal and stopping test are therefore faithful, so the deflated delta is trustworthy.
Gravity is set to 0 in the field-generating runs so the reconstructed RHS is exact; the
fields are otherwise real production-ladder optimizer output (B1).

---

## D1 ★ HOW MANY MODES? — the number that decides the method

Connected **printed** (ρ > 0.5) solid components on each real per-rung field, both
face-connectivity (6-conn, the mechanically-correct notion for a rigid body) and
corner-connectivity (26-conn). Deflation dimension `k = 6 × n_components`.

| fixture | solved grid | ng | rung vf | status | printed vox | **comps 6c** | comps 26c | **k** |
|---|---|---|---|---|---|---|---|---|
| load16 | 16×5×16 | 2430 | 0.68 | accept | 394 | **1** | 1 | 6 |
| load16 | | | 0.52 | accept | 311 | **1** | 1 | 6 |
| load16 | | | 0.38 | accept | 238 | **2** | 1 | 12 |
| load16 | | | 0.26 | reject | 177 | **2** | 1 | 12 |
| load24 | 24×8×24 | 7749 | 0.68→0.26 | accept×4 | 1402→596 | **1** (all) | 1 | 6 |
| box | 32×16×24 | 27045 | 0.68 | accept | 318 | **1** | 1 | 6 |
| box | | | 0.52 | accept | 237 | **1** | 1 | 6 |
| box | | | 0.38 | reject | 157 | **1** | 1 | 6 |

**The design does not fragment — `n_components ≈ 1`, so the deflation space is 6 modes.**
This holds at real scale (ng = 27045) and in the **dilute design-box regime deflation was
invented for** (the box fixture: a small bracket adding material into a mostly-empty
1.5–2× domain — the 125/131 stand-class shape). The one exception is the tiny 16³ loadcase
at the two lightest rungs, where 6-conn sees **2** components across a single corner-only
contact (a near-hinge) that 26-conn bridges back to 1 — i.e. the count is ambiguous
exactly at the near-hinges that matter, and even there it is 2, not many.

**Why, structurally.** Two forces keep an accepted design a single welded blob: (1) the
connectivity belt (`load_path_connected`, handoff 2026-07-23) REJECTS any design whose
load path is severed, so a fragmented field is never an accepted product; (2) a
load-carrying optimum is connected by construction. A truss-like optimum has many
*members* but they are welded at joints → **one** topological component → **6** modes.
The `k × k` coarse solve is therefore trivially cheap (6×6) — but only because there is
essentially nothing for component-rigid-body deflation to deflate.

**This inverts the Jönsthövel premise.** Their method works because their domain
(aggregate in asphalt) has MANY genuinely disconnected stiff inclusions → a large
rigid-body deflation space that captures the near-null-space. Our SIMP field is ONE
connected structure with graded-soft regions, not separated inclusions. The dominant slow
modes are the members flexing/hinging relative to one another WITHIN the single component
— which are **not** rigid-body modes of that component and **not** separate components, so
the natural `U` both is tiny (6) and misses the modes that actually slow CG.

---

## D2. ITERATION REDUCTION — measured, not estimated

Baseline vs rigid-body-mode-deflated Jacobi-PCG on the exact rebuilt operator; cut =
`1 − iters_defl/iters_base`. `κ` is the effective condition number from the CG→Lanczos
tridiagonal; `κ-fac` = `κ_base/κ_defl`.

| fixture | rung | base | defl | **cut %** | κ_base | κ_defl | κ-fac |
|---|---|---|---|---|---|---|---|
| load16 | 0.68 | 445 | 316 | **29.0** | 89 k | 6.8 k | 13.2 |
| load16 | 0.52 | 598 | 451 | **24.6** | 185 k | 17 k | 11.0 |
| load16 | 0.38 | 980 | 742 | **24.3** | 430 k | 14 k | 30.7 |
| load16 | 0.26 | 1061 | 910 | **14.2** | 1.1 M | 32 k | 34.5 |
| load24 | 0.68 | 470 | 414 | **11.9** | 354 k | 30 k | 12.0 |
| load24 | 0.52 | 989 | 740 | **25.2** | 374 k | 32 k | 11.7 |
| load24 | 0.38 | 1325 | 1097 | **17.2** | 596 k | 50 k | 12.0 |
| load24 | 0.26 | 1715 | 1402 | **18.2** | 1.5 M | 85 k | 18.1 |
| box | 0.68 | 721 | 626 | **13.2** | 158 k | 21 k | 7.4 |
| box | 0.52 | 789 | 670 | **15.1** | 261 k | 24 k | 10.8 |
| box | 0.38 | 986 | 872 | **11.6** | 823 k | 50 k | 16.6 |

**Mean cut ≈ 18% (per-fixture 23% / 18% / 13%); range 12–29%.** Two things to read:

- **The cut is below the shipped recycler's 45%**, and does not improve with scale — it is
  *smaller* at real scale (box, ng=27k: 12–15%) than on the tiny loadcase.
- **κ improves 7–35× while iterations improve only ~15–18%.** That gap is the whole story:
  the 6 rigid-body modes lift a *handful* of global near-rigid modes (so the single
  smallest eigenvalue, hence κ, moves a lot), but a **dense cluster of small eigenvalues
  remains** — the internal soft-hinge/member-flexing modes — and CG's rate is governed by
  the density of small eigenvalues, not by κ alone. Removing 6 modes from a continuum
  barely moves the iteration count. This is the D2 answer: the rigid-body modes span only a
  thin slice of the low spectrum on a connected field.

---

## D3. INTERACTION WITH RECYCLING (armed ~45%, Jacobi-only, handoff 133)

**Same machinery — verbatim.** The production recycler and this deflation use the
IDENTICAL additive coarse correction `M⁻¹ + U E⁻¹ Uᵀ` (`recycle.hpp:41`). The only
difference is how `U` is obtained: recycling **harvests** it from CG's Lanczos process
across the solve sequence; deflation **constructs** it from component rigid-body modes.
`RecycleSession` already accepts any `U`, so the two **compose mechanically** for free —
concatenate columns `U = [U_rbm | U_harvested]`, form one `E`. No new solver code.

**But they duplicate.** The recycler's own header states the slow modes it targets ARE
"the near-rigid-body motions of weakly-connected solid regions" (`recycle.hpp:16`). So by
construction both aim at the same part of the spectrum. Measured: RBM deflation removes
12–29% of iterations; the harvester removes 45% — because the harvester ALSO captures the
internal soft-hinge modes that strict component RBMs cannot represent (the κ-vs-iteration
gap above proves those residual modes exist). After the first solve the harvested basis
already spans (approximately) the rigid-body directions, so bolting constructed RBMs on
top adds little. The recycler is the strictly stronger instantiation of the same idea for
exactly our sequence-of-systems setting.

**And they conflict on subspace stability — the task's specific question.** Recycling's
value comes from SLOW change: `K_{i+1} ≈ K_i`, the carried basis is sticky and reused
across near-identical systems, and it is only dropped when the free-DOF count `n` changes.
A component-defined deflation space does the opposite: it **changes dimension and content
discontinuously whenever components merge or split** (a thin neck forming or breaking).
Every such event forces `E` to be re-formed (`k` matvecs, the "free" reuse lost that
iteration) and partially invalidates any harvested Ritz vectors that pointed at a
now-merged pair of bodies. In our data the component count already changes across rungs
(load16: 1→1→2→2), and each change is a rebuild event. Injecting a discontinuously
changing subspace pulls against the one property that makes recycling cheap.

**Net.** Compose mechanically, **duplicate** spectrally (recycler already gets the rigid
modes AND the internal ones, at higher effectiveness), **conflict** dynamically on
merge/split. The only non-redundant niche for constructed RBMs is the **cold first solve**
of a run (or after a reset), where no harvest exists yet — a warm-start seed worth at most
one solve's fraction of the run.

---

## D4. Memory

`k = 6·n_components` vectors of length `ng`, plus a `k × k` dense coarse solve
(`E = UᵀAU`, one Cholesky, `k` setup matvecs per solve). Measured, because `n_components ≈ 1`:

| fixture | ng | k | basis (dbl) | coarse solve | setup matvecs/solve |
|---|---|---|---|---|---|
| load16 | 2430 | 6–12 | 0.1–0.2 MB | 6×6 … 12×12 | 6–12 |
| load24 | 7749 | 6 | 0.4 MB | 6×6 | 6 |
| box | 27045 | 6 | 1.2 MB | 6×6 | 6 |

Trivial — but trivial *because* the design does not fragment. The D1 warning ("if the
design fragments into many members it grows and the `k × k` solve becomes a cost") is real
but does not fire on real load-carrying fields; it would only bite on a severed corpse,
which the rung-infeasibility fast-fail (handoff 131) already ends at iteration 6 and never
solves. For reference the shipped recycler carries a fixed `k = 16` float basis
(`4·16·n` bytes) with a 16×16 solve — comparable, and it is not idle.

---

## B3. Can the flood-fill belt supply the components?

**No — not as-is; a separate (small, mechanical) pass is needed.** The belt is
`load_path_connected` (`core/src/voxel/voxelize.cpp:609`): a 26-connectivity flood-fill
over printed voxels (`grid.solid && density > iso`) that seeds from Fixture voxels and
returns a single **boolean** — did the flood reach every Load voxel. It is single-source
reachability, not a labeler: it never assigns per-voxel component ids and never enumerates
multiple regions. A repo search finds **no** voxel-grid component-labeling pass anywhere
(the only true labeler, `triangle_components` in `mesh.cpp:595`, is union-find over the
marching-cubes *triangle* mesh, post-solve, not over the density grid). Deflation needs the
per-component voxel membership to build 6 modes each, so it needs its own labeling pass.
That pass is a ~40-line adaptation of the belt's own `seen`/`stack` loop (multi-seed,
emit a label instead of a bool) — the probe implements exactly that
(`label_components`) — but it is a new pass, not a reuse of the belt's boolean.

---

## Verdict — Phase 0 says NO-GO for a production deflation solver

Measured on real fields, the deflation-with-component-rigid-body-modes idea does not clear
the bar, for a structural reason that will not change with more engineering:

1. **The deflation space is tiny and largely empty of value.** Real load-carrying SIMP
   optima stay a **single** connected component (`k = 6`) at every rung, at real scale,
   even in the dilute box regime deflation was designed for. The design does not fragment
   into the disconnected rigid inclusions the method needs.
2. **The measured iteration cut is 12–29% (mean ~18%), below the already-shipped recycler's
   45%**, and it targets the *same* near-rigid modes the recycler already removes — while
   missing the internal soft-hinge modes the recycler gets by harvesting. κ improves 7–35×
   but a dense small-mode cluster remains, so CG barely speeds up.
3. **It composes with recycling but duplicates it and conflicts with its slow-change
   assumption on component merge/split.** The recycler is the better instantiation of the
   identical additive machinery.

So the honest answer to the task's own framing: the "lowest-risk candidate" is low-risk
because it reuses the recycling plumbing — but the *idea* is redundant with what the
recycler already does, at lower effectiveness, precisely because our fields do not have the
fragmented near-null-space the 2011 result exploits.

**The one Phase-1 item worth keeping, if any:** the cold-start niche — seed the recycler's
initially-empty `U` with the 6 constructed rigid-body modes so the *first* solve of a run
(before any harvest exists) gets the ~15% cut instead of nothing. It reuses the identical
`RecycleSession` correction, needs only the small labeling pass (B3), and cannot conflict
(one solve, no merge/split within it). Whether one solve's ~15% is worth a new pass and the
merge/split guard is a business call; the sequence win it would add to is small.

---

## Reproduce

```bash
cd core
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build --target topopt -j8
c++ -std=c++17 -O2 -I include -I src -I /opt/homebrew/include/eigen3 \
  -DSETTINGS_RULES_PATH="\"$PWD/src/settings/rules.json\"" \
  tests/harness/deflation_probe.cpp build/libtopopt.a -o /tmp/deflation_probe
DF_ARM=16 DF_CSV_DIR=<dir> /tmp/deflation_probe load   # tiny loadcase
DF_ARM=24 DF_CSV_DIR=<dir> /tmp/deflation_probe load   # medium loadcase
           DF_CSV_DIR=<dir> /tmp/deflation_probe box   # dilute design box (ng≈27k)
python3 evidence/2026-07-28-deflation-phase0/analyze.py <dir> ...   # D1/D2 tables + self-check
```

Env knobs: `DF_ARM/DF_NY/DF_T/DF_SPAN` size the fixture; `DF_CONN=6|26` the component
connectivity (default 6). Deterministic: arm=16 reproduces bit-identically.

Files under `evidence/2026-07-28-deflation-phase0/`: `deflation_probe.cpp` (probe),
`analyze.py` (reducer), `README.md`, and `{load16,load24,box}/` each with
`deflation_*.csv` + `run.log`.
