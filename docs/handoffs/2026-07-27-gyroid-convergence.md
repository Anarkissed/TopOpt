# 2026-07-27 — Gyroid convergence: the 5-cell direct comparison returned zero

**Track:** measurement / harness only. **NO production code, NO `/app/`, NO gate
change, NO knockdown-law change, NO solver wiring.** Additive changes to the existing
offline harness (`core/tests/harness/lattice_homog_probe.cpp`: one new gated section
`H3B` and two env knobs) plus this report and its evidence directory. Nothing under
`core/src`, `core/include`, `docs/ARCHITECTURE.md`, `docs/DECISIONS.md`,
`docs/ROADMAP.md` or `materials.json` was touched. Follows and corrects one row of
[2026-07-26-lattice-homog-phase0](2026-07-26-lattice-homog-phase0.md).

## The question

PR 198's `h3_convergence.csv` reported `direct_freeface_E = 0.0000` in the **5-cell
row for all three lattices**. Gyroid's free-surface value was still climbing across
1/2/3 cells (0.0833 → 0.1011 → 0.1072 vs periodic 0.1200), so its 11.95% H4 NO-GO
looked like an un-converged comparison rather than a homogenization failure. The
Phase-0 handoff never explained the zeros. This report names them and fills them.

---

## a. WHY THE 5-CELL RUN PRODUCED NO NUMBER — named

**It is a hardcoded skip, not a crash, a solver failure, or a plumbing gap.**
`core/tests/harness/lattice_homog_probe.cpp`, in `H3_convergence`, line 668:

```cpp
double dirE = (K <= 3) ? direct_apparent_E(grid, 2) : 0.0;
```

For `K = 5` the ternary short-circuits to the **literal `0.0`**; that constant is then
written straight into the CSV's `direct_freeface_E_MPa` / `direct_over_Es` columns. The
direct solver was never invoked at 5 cells. Corroborating detail that explains why the
row *looks* populated: the `cg_iters = 66` and `solve_ms = 56503` in that same row are
the **periodic homogenization** solve's statistics (`R.cg_iters_max`, `R.solve_ms` from
the `homogenize()` call a few lines up) — the periodic solve *did* run at K = 5 (512 k
voxels, ~57 s); only the *direct* comparison was skipped. A genuine direct solve can
never return exactly `0.0`: `direct_apparent_E` returns `Fsum / (A·strain)` on success
and `-1.0` (with a stderr warning) on non-convergence. Exact `0.0000` is the skip
sentinel and nothing else.

The intent was defensible (the comment: the direct solve is expensive at 5 cells and
the periodic bulk it is compared against is K-independent, so K = 5 "keeps periodic
only"). The defect is that the skip wrote a sentinel `0.0` into a measurement column
instead of leaving it blank / `(skipped)` — so a reader sees a failed or zero
measurement where none was attempted.

---

## G1. H1 SELF-CHECK — re-run first, still machine precision

Re-ran before touching anything (`evidence/.../h1_self_check.txt`):

| quantity | analytic | measured | rel. err |
|---|---|---|---|
| C11 = λ+2μ | 5185.7585 | 5185.7585 | **8.07e-15** |
| C12 = λ | 2554.1796 | 2554.1796 | 4.99e-15 |
| C44 = μ | 1315.7895 | 1315.7895 | 7.26e-15 |

Off-cubic residual 3.88e-13. **PASS — the instrument is unchanged and sound.**

---

## b. THE 5-CELL (AND 7-CELL) GYROID FREE-SURFACE VALUE

New harness section `H3B` computes the exact periodic bulk **once** from a single cell
(K-independent, so no need to re-solve the expensive large periodic systems) and runs
the **direct** free-surface uniaxial solve (production `fea_solve_cg`, free lateral
faces, 1e-5 relative residual) at K = 1, 2, 3, 5, 7. Every direct solve **converged**
(no cap-truncation: the 30000-iter cap throws `SolverNonConvergence`, which would have
surfaced as `-1`). K = 1/2/3 reproduce PR 198's committed numbers **bit-for-bit**, so
K = 5 and K = 7 are exactly what that run would have produced had the solve not been
skipped. `evidence/.../h3b_direct_convergence.csv`:

| K (cells) | voxels | DOF (~) | direct free-face E (MPa) | E/Es | gap vs periodic bulk 419.85 | solve |
|---|---|---|---|---|---|---|
| 1 | 4,096 | 14 k | 291.55 | 0.0833 | -30.56% | 3 s |
| 2 | 32,768 | 106 k | 353.99 | 0.1011 | -15.69% | 36 s |
| 3 | 110,592 | 346 k | 375.04 | 0.1072 | -10.67% | 103 s |
| **5** | **512,000** | **1.5 M** | **392.48** | **0.1121** | **-6.52%** | 12 min |
| **7** | **1,404,928** | **4.3 M** | **400.36** | **0.1144** | **-4.64%** | 23 min |

(6-P-core Mac, matrix-free Jacobi-CG; multigrid stagnates on thin-wall lattices and is
deliberately not used here.) Both K = 5 and K = 7 are runnable in memory and time — no
G3 escalation was needed.

### Re-scored H4 (bar: homogenized within 10% of a direct resolved block)

| comparison | direct E | homogenized (periodic) | gap | verdict |
|---|---|---|---|---|
| PR 198 — gyroid vs **3-cell** block | 375.04 | 419.85 | **11.9%** | NO-GO (marginal) |
| **this — gyroid vs 5-cell block** | 392.48 | 419.85 | **6.52%** | **GO** |
| this — gyroid vs 7-cell block | 400.36 | 419.85 | **4.64%** | **GO** |

The H4 bar is met at 5 cells and comfortably at 7. Schwarz-D and octet already passed
at 1–3 cells (0.04%, 0.81%) and are unaffected.

---

## G2. GAP VS CELL COUNT — the trend

| K | gyroid gap | gyroid gap · K | Schwarz-D gap | octet gap |
|---|---|---|---|---|
| 1 | -30.56% | -30.56 | -0.30% | -2.34% |
| 2 | -15.69% | -31.37 | -0.00% | -1.10% |
| 3 | -10.67% | -32.02 | +0.04% | -0.82% |
| 5 | **-6.52%** | -32.60 | +0.06% | -0.47% |
| 7 | **-4.64%** | -32.50 | (not needed) | (not needed) |

Gyroid's `gap · K` is near-constant (≈ -31 to -32.6), i.e. the deviation decays as a
clean **1/K free-surface / windowing law**. Richardson extrapolation on K = 3, 5 gives
the K → ∞ gap ≈ **-0.3%**: the direct free-surface modulus converges *onto* the exact
periodic bulk, exactly as the physics requires (a periodic single cell IS the effective
property; the free-surface deviation is a finite-window artifact, not homogenization
error). Schwarz-D and octet are already flat at 1 cell — bicontinuous / well-connected
topologies carry bulk behaviour in a single cell — so K = 5 is confirmatory only and
K = 7 was not run for them.

---

## c. DOES GYROID CONVERGE BELOW 10%? — plainly

**Yes.** The gap crosses below 10% between 3 and 5 cells (-10.67% → -6.52%), reaches
-4.64% at 7 cells, and extrapolates to ≈ 0% as cells → ∞. **Gyroid's 11.9% NO-GO was a
measurement artifact** — the direct comparison was stopped at a 3-cell window that had
not yet converged, and PR 198 could not see past it because the 5-cell row it would
have needed was the hardcoded `0.0`. **On the H4 homogenization-vs-direct bar, gyroid
is a GO.**

One caveat carried forward unchanged from Phase 0 (it is a *different* question, not
re-opened here): gyroid's cubic anisotropy is Zener ≈ 1.05–1.16, E₁₁₁/E₁₀₀ up to +13%.
That argues for carrying a **stiffness tensor** rather than a scalar knockdown for
gyroid, same as for octet and Schwarz-D — but it does not bear on the isotropic-E₁₀₀
GO/NO-GO settled above, which now passes.

---

## G4. IS THIS A GENERAL FAILURE MODE? — YES, and it matters for the strut family

**The zero is not gyroid-specific.** Line 668 is lattice-agnostic; the same `(K <= 3)
? … : 0.0` fires for every lattice, which is why PR 198's committed CSV shows `0.0000`
at K = 5 for gyroid **and** Schwarz-D **and** octet. It was harmless for Schwarz-D and
octet only because they converge at 1 cell, so nobody needed the 5-cell number — but
the harness itself will silently write a sentinel `0.0` into the direct column for
**any** lattice above 3 cells.

**The strut family is about to run through this same harness.** Strut lattices are the
class most likely to need large windows to converge (slender members, low connectivity
at low ρ — like octet's low-ρ rows the HR study already flags as ill-conditioned
near-mechanisms). If a strut variant needs 5–7 cells to separate — exactly gyroid's
situation — this harness will hand back `0.0` and the reader will misread it as a dead
or zero-stiffness result, repeating the false NO-GO. **Fix the harness before the strut
work uses it:** a skipped measurement must be blank or an explicit `(skipped)` marker,
never `0.0`. (`H3B` added here already does this — it runs the solve, or on a genuine
non-convergence records the `-1` sentinel and prints `NONCONV`, never a bare `0.0`.)

---

## Harness changes (additive)

- `H3B_direct_convergence()` — new gated section (`TOPOPT_HOMOG_ONLY=h3b`): exact
  periodic bulk once + direct solves at K = 1,2,3,5,7, per-row CSV flush so a slow
  K = 7 cannot lose K = 5.
- Env knobs: `TOPOPT_H3B_LATTICE=<gyroid|schwarzD|octet>` (restrict to one),
  `TOPOPT_H3B_KMAX=<n>` (cap cell count).
- The original `H3_convergence` line 668 skip is **left as-is** (this report does not
  rewrite PR 198's method); the general-failure-mode recommendation above is the
  follow-up for whoever owns the strut-family pass.

## VERIFICATION / REPRODUCE

See `evidence/2026-07-27-gyroid-convergence/README.md`. In brief, from `core/`:

```bash
cmake -S . -B build -DTOPOPT_USE_OCCT=OFF -DTOPOPT_BUILD_TESTS=OFF && cmake --build build --target topopt -j
c++ -std=c++17 -O2 -I include -I /opt/homebrew/include/eigen3 \
    tests/harness/lattice_homog_probe.cpp build/libtopopt.a -o build/lattice_homog_probe
TOPOPT_HOMOG_ONLY=h1 ./build/lattice_homog_probe                                  # G1 self-check
TOPOPT_HOMOG_ONLY=h3b TOPOPT_H3B_LATTICE=gyroid TOPOPT_LATTICE_CSV_DIR=<dir> ./build/lattice_homog_probe
TOPOPT_HOMOG_ONLY=h3b TOPOPT_H3B_KMAX=5 TOPOPT_LATTICE_CSV_DIR=<dir> ./build/lattice_homog_probe
```

Every number here is first-hand in `evidence/2026-07-27-gyroid-convergence/`
(`h3b_direct_convergence.csv`, `h1_self_check.txt`, `probe_stdout_gyroid.txt`,
`probe_stdout_others.txt`). Largest single solve: gyroid K = 7 direct (4.3 M DOF,
23 min).
