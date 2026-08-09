# evidence — 2026-08-10-levelset-alpha-and-stopping-rule

The corrected alpha and the stopping rule, both arms certified per iterate, plus
a like-for-like surface measurement that reverses the earlier headline. Handoff:
`docs/handoffs/2026-08-10-levelset-alpha-and-stopping-rule.md`.

`./reproduce.sh` regenerates everything here. Nothing is cloned.
**3 threads throughout**, and the SIMP baseline is re-measured at that count in
the same session rather than quoted.

## the three answers

1. **At alpha 9.6, does the cut share stop climbing? NO** — +2.86 points against
   alpha 2.4's +5.41. Alpha halves the rate; it is a mitigation, not the
   mechanism.
2. **Best whole-mesh roughness at margin >= SIMP: 8.6136 deg** (SIMP 8.4075,
   +2.5%) at iteration 35 of the **alpha-2.4** arm, margin 3404.33, 3.55x SIMP's
   total wall. Cheapest frontier point: alpha 9.6 at iteration 5 — 8.6776,
   margin 3414.18, **1.39x**.
3. **How much of the iteration-1 "+2.2 deg" survives like-for-like? NONE — it
   reverses.** 9.7267 against SIMP's 10.1891 over the same region of space: 4.5%
   SMOOTHER, where the own-population comparison said 28.8% rougher.

## the frontier

Pareto-optimal over (margin high, whole-mesh roughness low), margin >= SIMP's
3254.36. **Total = SIMP's 311.2 s + the level set's**, because every arm is
SEEDED from SIMP's converged rung — the cost is additive, and PR 323's "1.58x"
omitted that.

| arm | it | margin | whole (deg) | like-for-like | mid% | TOTAL | xSIMP |
|---|---|---|---|---|---|---|---|
| SIMP | 27 | 3254.36 | 8.4075 | 10.1891 | 85.28 | 311.2 s | 1.00x |
| alpha 2.4 | 35 | 3404.33 | **8.6136** | 9.9364 | 66.93 | 1106.1 s | 3.55x |
| alpha 2.4 | 30 | 3406.35 | 8.6195 | 9.9374 | 67.06 | 992.5 s | 3.19x |
| alpha 2.4 | 25 | 3414.14 | 8.6435 | 9.8978 | 67.12 | 879.0 s | 2.82x |
| **alpha 9.6** | **5** | **3414.18** | 8.6776 | **9.7993** | 67.56 | **431.9 s** | **1.39x** |

★ **The stopping rule subsumes the alpha fix**: the best surface at margin >=
SIMP comes from the UNCORRECTED alpha. Alpha mattered for the CONVERGED design
(13.02 against 9.66) and the converged design is dominated by every row above.

★ **A safety finding.** The alpha-9.6 arm passes through **4.1x peak stress** at
iteration 15 (max vM 0.0669 MPa against ~0.0162; margin 821.89, still ACCEPTED).
It recovers by iteration 20. Margin may NOT be interpolated between
certifications, and any stopping rule must certify the iterate it selects.

## the arms

| dir | rule | alpha | HJ steps | damper | iters | s/iter | margin | verdict |
|---|---|---|---|---|---|---|---|---|
| `s1_simp_3thread` | shipped `minimize_plastic` | — | — | — | 27 | 11.525 | 3254.36 | ACCEPTED |
| `s2_alpha_min` | `--gridap-auto min` | 2.4 | 6 | off | 76 | 22.711 | 3405.33 | ACCEPTED |
| `s3_alpha_max` | `--gridap-auto max --damp` | 9.6 | 24 | 3 | 43 | 24.145 | 3401.08 | ACCEPTED |

**The positive control passes on the derivation and the trajectory.**
`--gridap-auto min` returns max_steps 6 / alpha 2.4 (`s0_gridap_auto_control.txt`)
and reproduces PR 323's run of record — the SIMP baseline **bit-identically**
(27/27 compliances, 0 CG mismatches), the level-set arm to **1.07e-8**, the CG
tolerance. The two level-set runs differ only in `--snapshot-every`, which
touches no computation; Krylov recycling amplifies a last-bit difference into
different CG counts, because each solve's recycled subspace depends on the
previous solve's floating-point detail. **Level-set compliance differences below
~1e-8 are noise.**

## the like-for-like column, and why it exists

`dihedral_cut_deg` restricts each arm to the triangles THAT ARM's classifier
called CUT — and the arms do not share a cut population (SIMP 18.40%, the level
set 36.23% on its FIRST iteration). `ref_region_mask` in
`external_field_surface_probe` fixes this by measuring every arm over the SAME
REGION OF SPACE: the voxels the reference's cut surface passes through, dilated
one voxel (24366 voxels, 5.2% of the grid, 22-29% of each mesh's vertices).
`dihedral_refcut_deg` / `dihedral_refcad_deg` are that column.

| framing | verdict |
|---|---|
| each arm's own cut population | +27.9% WORSE |
| whole mesh (no selection) | +9.0% worse |
| **same region of space** | **2.5% BETTER** |

Not in conflict: **the level set does not roughen the surface SIMP already has —
it ADDS internal cut surface (18.4% -> 36.8%), and the added surface is the rough
part.** The region is defined by SIMP's cut surface, so the column answers "over
the region SIMP cuts"; `dihedral_all_deg` is reported throughout and needs no
such caveat.

**R4 — the CAD population never moves**: 7.4934 to 7.7007 across every snapshot
of both arms, against SIMP's 7.5842.

## files

| file | what it is |
|---|---|
| `reproduce.sh` | regenerates everything below |
| `s0_gridap_auto_control.txt` | the positive control: their rule evaluated on both axes |
| `s1_simp_3thread.log`, `s1_simp_3thread/` | the 3-thread SIMP baseline — the shipped ladder, invoked |
| `s2_alpha_min.log`, `s2_alpha_min/` | their rule AS WRITTEN (alpha 2.4, 6 steps) |
| `s3_alpha_max.log`, `s3_alpha_max/` | keyed to the resolution axis (alpha 9.6, 24 steps) + damper |
| `s4_surface_probe.txt` | the roughness measurement, both curves, own SIMP rows, like-for-like column |
| `s4_curves.csv` | every row, every snapshot |
| `s5_margin_curve/{MIN,MAX}/margin_curve.csv` | **every snapshot certified** at the production penalty |
| `s5_margin_curve.log` | the certification transcript |
| `ctest.txt` | the suite |

Each arm carries `summary.txt`, `iterations.csv`, `design.bin`, `rho.f64.gz` +
`rho.meta`, and `snap/` (the every-5-iterations occupancy the curves are measured
from). `levelset.stl` is not committed — 17 MB of what `design.bin` already
holds:

    cmake --build build --target design_rung_dump
    ./build/design_rung_dump evidence/2026-08-10-levelset-alpha-and-stopping-rule/s3_alpha_max/design.bin <out> --stl

## the bars

**R1 — it runs and it finishes.** Three runs, both level-set arms converged on
the shipped MMA plateau rule, 25 per-iterate certifications, curves on disk.

**R2 — our instruments, invoked not retyped.** `external_field_surface_probe`
produces every roughness row in ONE invocation carrying its own four SIMP
baseline rows; `minimize_plastic` produces the SIMP baseline;
`analyze_fixed_design` every margin. The like-for-like column is a new SELECTION
handed to the existing `dihedral_rms_deg`, not a second metric.

**R3 — margin and verdict for every arm.** 3401-3405 ACCEPTED against SIMP's
3254 on less material, peak von Mises below SIMP's. Every one of the 25
per-iterate certifications is ACCEPTED, including the 4.1x stress excursion.

**R4 — CAD-population roughness reported for every arm and every snapshot**, and
it does not move (above).

**R5 — the shipped SIMP path is untouched.** `git diff main -- core/src
core/include app/` is EMPTY; the change is two files under `core/tests/harness/`
and no CMake line.

**R6 — no assertion weakened or deleted, no scratch at the repository root.** No
test file touched, no `add_test` added or removed, so the denominator is `main`'s
by construction.

---

## ADDENDUM — S6, the max-effort arm

Five components built from the literature, each independently switchable. Four
were worth ~nothing; one works and costs margin. **The arm reached no Pareto
frontier point.**

| flag | verdict |
|---|---|
| `--russo-smereka` | **HARMFUL — dropped.** Two real bugs found and fixed; still lost |
| `--weno --rk3` | neutral |
| `--reinit-substeps` | ~2% on interface area |
| `--perimeter C` | **works on roughness, costs margin** |
| `--no-surface-delta` | restores PR 322's volume velocity (added for the unfinished s9) |

**Perimeter sweep** (25 iterations, sub-step + WENO + RK3, no RS):

| C | interface area | cut (deg) | whole (deg) | margin (final) |
|---|---|---|---|---|
| 0 | 24787 | 8.9886 | 8.9458 | 3400.41 |
| **2** | 19250 (−22%) | **7.2908** | **8.2986** | 3046.62 (−6.4% vs SIMP) |
| 8 | 17336 (−30%) | 7.6981 | 8.4162 | 1105.63 (−66%) |
| SIMP | — | 7.5521 | 8.4075 | 3254.36 |

★ **Certifying every snapshot refuted the prediction I was about to make.** The
added structure is LOAD-BEARING: margin at C=2 falls to 3046.62 and swings
(2015 -> 3172 -> 2015); C=8 collapses. "Margin saturates early so the structure is
nearly free to give up" is wrong.

★ **THE FRONTIER — PR 322 dominates SIMP and everything from three sessions.**

| arm | margin | vs SIMP | whole (deg) | vs SIMP |
|---|---|---|---|---|
| **PR 322** (eta=1, penalty 3) | 3378.49 | +3.8% | **8.1797** | **−2.7%** |
| PR 324 alpha 2.4 @ it 35 | 3404.33 | +4.6% | 8.6136 | +2.5% |
| PR 324 alpha 9.6 @ it 5 | 3414.18 | +4.9% | 8.6776 | +3.2% |
| ~~SIMP~~, ~~MAX C=2~~, ~~MAX C=8~~ | dominated | | | |

The three sessions spent matching GridapTopOpt are a **net regression** on the
metric they existed to improve: cut roughness 6.7080 -> 13.0156, clawed back to
7.2908.

**`s9_pr322_stopped` was started and STOPPED AT 15/60, UNFINISHED** — the
direction changed to a parametric level set. No partial numbers from it are used.
The handoff §5 carries the exact command; it is the correct baseline to beat.

### files added by S6

| file | what it is |
|---|---|
| `s6_max_C{0,2,8}.log`, `s6_max_C{0,2,8}/` | the perimeter sweep, 25 iterations each |
| `s7_max_surface.txt`, `s7_max_curves.csv` | roughness for all three, own SIMP rows, like-for-like column |
| `s8_max_margin/C{0,2,8}/margin_curve.csv` | every snapshot certified at the production penalty |
| `s8_max_margin.log` | the certification transcript |

### a note on the ctest denominator

`ctest.txt` (117/117) was recorded before the S6 harness edits. Those edits touch
only `levelset_probe` and `external_field_surface_probe`, both `EXCLUDE_FROM_ALL`
targets that the default build does not build and that no `add_test` registers —
verified with `grep add_test core/CMakeLists.txt`. They therefore cannot change
the suite or its denominator, and the recorded result stands for the tree as
shipped. Any subsequent change to `core/src` or `core/include` would need a fresh
run; there is none (`r5_no_production_change.txt` is empty).
