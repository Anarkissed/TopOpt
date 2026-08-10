# 2026-08-10-parametric-level-set

Handoff: `docs/handoffs/2026-08-10-parametric-level-set.md`.
`./reproduce.sh` regenerates everything here. Nothing is cloned or downloaded.

★ **EVERY COMPARISON IS AGAINST SIMP, THE SHIPPED LADDER, AND NOTHING ELSE.**

★ **The question.** Our parts are stored as 468,224 on/off numbers on a grid.
This tests storing the shape as an analytic function instead —
φ(x) = Σ αᵢψᵢ(x), whose design variables are ~10⁴ RBF coefficients — first by
FITTING it to a design SIMP already made (the gate), then by OPTIMISING in it.

## the four rows that decide it

| | overall | carved | CAD **error** | margin | mass |
|---|---|---|---|---|---|
| **SIMP rung 0.68** | 8.4075 | 7.5521 | 0.4293 mm | 3254 | 543.7 g |
| its design, re-described smoothly | **7.2541** | **5.7098** | **0.4099 mm** | ★ 1667 | 546.7 g |
| **from scratch, no SIMP anywhere** | 11.5068 | 14.1076 | 0.4826 mm | ★ **3392** | **463.0 g** |
| from scratch, smooth-boolean frozen set | 10.2647 | 12.5127 | 0.4637 mm | — | — |

★ Re-describing is **13.7% smoother and 4.5% MORE accurate against the real CAD
faces** — but **halves the certified margin on this part** (and raised it 60% on
another). **A re-described part must be re-certified.**
★ From scratch it is **stronger and lighter than SIMP** and needs no SIMP at all —
but rougher, because it converges on a finer topology with **3× the internal
surface**.

## the controls, which are the point

| file | why it exists |
|---|---|
| `s2_emission_control.txt` | ★ **read this first.** SIMP put through this task's emission path must reproduce the probe's own SIMP row. 19 columns, 0 mismatches. Nothing else means anything without it. |
| `s9_curves.csv` | the **BAND** control — a narrow ersatz band manufactures a staircase by itself; without this the whole result could have been band width |
| `s19_curves.csv` vs `s22_curves.csv` | the **FROZEN** control — hard voxel stamp vs smooth boolean. The first pass measured roughness on fields that do not certify. |
| `s0_shipped_arms/verdict.txt` | the shipped voxel path is byte-identical on the FINAL binary, with every new flag present and defaulted off |
| `s13_binarize/` | the band confound on PEAK STRESS, removed by thresholding both sides |

## the rest

| path | what |
|---|---|
| `sources/` | the subjects — SIMP's rung 0.68, its design mask, and two designs from the discarded method (subjects only, never a bar) |
| `fields/`, `simpfit/`, `boolean/`, `simpbool/` | the fits: sweep, SIMP-as-subject, and both frozen treatments |
| `s1_fit_*.txt`, `fields/fits.csv` | knot spacing PER AXIS (R4), both bases, the support sweep, and the slab trap reproduced on purpose |
| `arm2/` | the parametric optimiser, 8 arms + ablations |
| `arm3/` | ★ from scratch — B1 at 85,680 coefficients, B2 at 24,480 |
| `speed/` | ★ the three speed probes. **loose tolerance + warm start = 76% fewer solver steps, 59% less wall, same design** |
| `s3_margin/`, `s7_margin_frozen/`, `s12_margin/`, `s27_simpbool_margin/` | every certification, with mass |
| `r7_assertion_census.txt`, `ctest.txt` | the bars. 119/119 pass. |

## what is NOT committed, and why

★ **The large fields are regenerated, not stored.** An F=3 analytic field is
384 × 93 × 354 float64 = 101 MB and this task writes about forty of them; the
`_shipped` directories are byte-identical copies of `fields/*_vm_f1` with a
rewritten meta. What is kept is every **measurement** (`*.csv`, `*.txt`, `*.log`,
`summary.txt`), the voxel-lattice fields the certifications read, and each arm's
**`alpha.f64.gz` — the design itself, 685 KB against `rho.f64`'s 3.75 MB, and
re-evaluable at any resolution.**

The BEFORE halves of the two header-move verdicts are artefacts: reproducing them
needs the parent commit checked out. `reproduce.sh` reproduces the AFTER halves,
which is what the current tree must still produce.
