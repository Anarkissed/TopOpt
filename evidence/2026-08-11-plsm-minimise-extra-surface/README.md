# 2026-08-11-plsm-minimise-extra-surface

Handoff: `docs/handoffs/2026-08-11-plsm-minimise-extra-surface.md`.
`./reproduce.sh` regenerates everything here. Nothing is cloned or downloaded.

★ **THE QUESTION.** PR 324's ARM 2 replaced SIMP outright — stronger, lighter,
certified, no SIMP anywhere in the pipeline — and came out **three times rougher
in internal surface**: 79,679 carved triangles against SIMP's 26,191. This task
goes after that surface.

★ **EVERY COMPARISON IS AGAINST SIMP, THE SHIPPED LADDER.** PR 324's ARM 2
appears only as the thing being re-baselined, never as a bar.

## read these first, in this order

| file | why it exists |
|---|---|
| `c0_control.txt` | ★ **the control that licenses everything.** PR 324's ARM 2, five iterations, on THIS task's binary with every new flag off. 20 computed columns, 0 mismatches. Without it, PR 324's committed trajectory could not stand in as the "without S1" half of S1(b). |
| `s2_*_cad.txt` (the AGREEMENT block) | ★ **S2's control.** The frozen region derived from the CAD faces must reproduce the voxel mask core actually built. It does, on **468,224 of 468,224 voxels**. Getting there needed one fix — core tests `<=`, a continuous field tested `< 0`, and on a flush face that equality case is a whole voxel layer. |
| `m1_surface.csv` | every roughness number, all arms **and SIMP** produced by one `external_field_surface_probe` invocation at one extraction convention (R2). `n_cut` is R3's internal-surface triangle count. |
| `m2/margin_curve.csv` | every margin, mass, achieved vf and load-path answer, from `analyze_fixed_design` via `levelset_probe --certify-field`. ★ **Read the curve, not the endpoint** — see the handoff §T2. |
| `m3_matched.csv` | ★ **THE TABLE THE HANDOFF USES.** Every arm at MATCHED iteration 60. `measure.sh`'s `m1_surface.csv` reads each arm's `rho`, which is its BEST-COMPLIANCE iterate — iteration 9 for one arm and 60 for another. Comparing those is the error P11 records. |
| `m4/margin_curve.csv` | ★ every iterate of one converged tail, certified. **The margin's spread over 43..60 is 0.15%** — it is not noise; it is SLOW, settling long after compliance does. |
| `eta_probe.csv` | ★ one fixed design at four band widths. η cannot change the extracted mesh's topology or classification AT ALL, and there is a proof: the crossing set is the sign set of φ_eff, which does not contain η. |
| `tables.txt` | the handoff's tables, joined from the three files above by `tables.py`, which computes no geometry and no mechanics of its own. |

## the arms

| directory | what it is |
|---|---|
| `arms/C0_control_5it` | the inertness control |
| `arms/RB1_volcount` | ★ **the re-baseline.** PR 324's ARM 2 with S1's constraint and nothing else. Every number is measured against this. |
| `arms/S0_seed16` | the SEED's topology scale, alone. Not the basis — PR 324 §6(ii) refuted that and it is not retested. |
| `arms/P1_c1`, `P2_c2`, `P3_c4`, `P4_c8` | **S3's frontier.** The perimeter penalty at four weights. |
| `arms/PR_c4_ramp` | S3(b)'s continuation, paired with `P3_c4` — same weight, ramped on instead of applied from iteration 1. |
| `arms/N1_c4_norefit` | ★ **S3(d)'s pair.** The same weight with the approximate reinitialisation OFF. The sweep's arms all run `--plsm-refit-every 5`, so on their own they cannot test the "no reinitialisation to fight it" prediction. |
| `arms/A2_all` | **ARM 2** — every mechanism at once (3 state solves/iteration). |
| `arms/A3_seed16_perim` | ARM 2's CHEAP pair — coarse seed + fixed C=1, one solve. |
| `arms/E1_c1_eta1` | ★ **THE BEST POINT.** C=1 with η halved to 1 voxel. |
| `arms/A4_mask` | the nucleation band, and (via `--snapshot-every 1`) the margin-variance measurement. |

## the bars

| file | bar |
|---|---|
| `r6_shipped_path.txt` | R6 — `git diff main -- core/src core/include app/` is **0 lines**, and `materials.json` is untouched |
| `r7_assertion_census.txt` | R7 — no assertion message, ctest, production refusal or harness refusal disappeared |
| `ctest.txt` | R1 — the suite passes |

## what is NOT committed, and why

★ **The large fields are regenerated, not stored.** The same discipline PR 324
used: an F=2 analytic field is 256 × 62 × 236 float64 = 30 MB and this task
writes dozens. What is kept is every **measurement** (`*.csv`, `*.txt`, `*.log`,
`summary.txt`), each arm's `iterations.csv`, and each arm's **`alpha.f64.gz` —
the design itself, and re-evaluable at any resolution**, which is what
`plsm_probe --alpha` reads to produce S2's rows without re-running an optimiser.

★ **The wall clocks in these CSVs are not comparable to PR 324's.** Measurement
work ran alongside the optimiser queue on the same machine. Speed is out of
scope for this task, the designs are deterministic, and no conclusion here rests
on a wall clock — but `iteration_wall_s` should not be read across tasks.
