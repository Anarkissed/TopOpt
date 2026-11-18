# Octet strut law re-measured on the full octet (2026-11-17)

`kOctetStrutLaw` in `core/src/fea/strut_strength.cpp` is the `*_cert` columns of `octet/kfit.csv`, verbatim. The table it replaces (PR 259, July: `evidence/2026-07-31-lattice-dehomogenization-probe`) was measured on the legs-only octet (the FCC cell); the engine lays the full octet (legs and braces), whose stiffness and density laws were re-measured on 2026-11-02. `reproduce.sh` runs it again with the committed probe (`core/tests/harness/lattice_dehomog_probe.cpp`, whose octet now goes through its production strut cell; `TOPOPT_DEHOMOG_OCTET_LEGACY=1` brings back PR 259's cell).

Folders: `octet/` (every phase's csv and log, `*.time` the `/usr/bin/time -l` output), `fcc_control/` (the control: byte-identical to `evidence/2026-11-09-lattice-type-strut-laws/fcc/`), `old_against_new.md`.

The notes below are the builder's, as written; the scratch file names they cite are `probe_octet_full.cpp` = the committed probe, `octet_full/` = `octet/` here.


## What was run
- Source: `git archive` of `claude/install3-engine` at afe68f23 (core/include, core/src, the probe) into `src/`. No worktree was written.
- Probe: `probe_octet_full.cpp` is `core/tests/harness/lattice_dehomog_probe.cpp` with one flag, `kLegacyOctetCell = false`. It turns off the probe's 7 octet special cases (`probe_octet_full.diff`):
  - geometry (lines 159, 191): octet uses `lattice_strut_cell(Octet)`, the full octet the generator lays, not PR 259's legs-only cell;
  - density (179): octet uses `lattice_density_from_strut(Octet)`, the full-cell law;
  - rho sweep (883), bulk vpc choice (1162), boundary case list (1258), aliasing escalation (1292): octet takes the 11-09 path exactly as every other type.
  - j6 (PR 255's designs) was not run. It is not part of the law.
- Library: `fea/*.cpp` and `voxel/*.cpp` compiled with the core Release flags (`-O3 -UNDEBUG -DTOPOPT_HAVE_ACCELERATE`; `build_lib.sh`) into `libtopopt_sub.a`.
  - The probe is built `-O3 -DNDEBUG -framework Accelerate` (11-09 recipe), linked with `-undefined dynamic_lookup`.
  - The only unresolved symbols are mesh helpers and `analyze_fixed_design`, which only j6 reaches.
- Commands: `run_octet.sh` runs `TOPOPT_DEHOMOG_TYPE=octet ./lattice_dehomog_probe_octet_full <phase> octet_full` for selfcheck, bulk, blocks, boundary and fit. It is single-threaded (`fea_set_matfree_threads(1)`).

## Time and memory (`/usr/bin/time -l`, `octet_full/*.time`)
| phase | wall | peak footprint |
|---|---|---|
| selfcheck | 0.5 s | 0.14 GB |
| bulk | 46 s | 3.8 GB |
| blocks | 122 s | 5.6 GB |
| boundary | 2142 s (35.7 min) | **10.4 GB** (the N3 vpc40 floor-row re-measure, the last cases) |
| fit | 0.02 s | - |

Total: about 38 min. The library build took 14 s. Peak memory was well over the 2-3 GB budget. System free memory stayed at 59-69 % and swap did not grow during the checks. Swap is not logged for the last vpc40 cases.

## Control (the recipe reproduces 11-09)
- `TOPOPT_DEHOMOG_TYPE=fcc` was run with the same binary for selfcheck and bulk (46 s, 2.2 GB).
- `selfcheck.csv`, `k_exact_bulk.csv`, `k_states_bulk.csv` and `bulk_tensor.csv` are byte-identical to `evidence/2026-11-09-lattice-type-strut-laws/fcc/`. That includes FCC's 0.20 bulk row: 32.6214 / 18.6888 / 34.0848 / 21.9361.
- FCC's boundary phase was not re-run (about 30 min). The code path is unchanged for every type but octet (see the diff).
- Octet selfcheck S1-S6: ALL PASS (`octet_full/selfcheck.csv`).
- Every CG solve converged: residual ≤ 1.0e-7, and no "NOT CONVERGED" lines.

## The new rows
`kOctetStrutLaw_new.txt` holds the `*_cert` columns of `octet_full/kfit.csv` verbatim. It is the envelope of bulk (periodic, vpc 48), free-surface and cut-cell populations, on the 11-09 grid.

The span is 0.04959 .. 0.90027, the octet band exactly. The old table spanned 0.04762 .. 0.89598, so no density in the band clamps any more.

Rows that needed attention:
- **0.04959 is bulk only.** The aliasing guard dropped every boundary fixture there:
  - N3 vpc24 fell apart (all floaters);
  - vpc32 read rho +26 %;
  - vpc40 read rho -16 %.
  - At those pitches the cut layer read Kd ≈ 172. The true envelope there is probably about 1.6x the row's 108.4, so this row is a lower bound. PR 259's floor row was bulk only as well.
- **0.157** at N3 vpc24 aliased onto 0.10 (rho_meas 0.106). It was re-measured at N3 vpc32 (kept, -1 %).
- **0.313** at N4 vpc16 aliased onto 0.20 (0.219). It was re-measured at N3 vpc24 (kept, -3 %).

## Old against new
Each cell is the old table (`law_at` at the new row's rho) -> the new row, with the % change.

| rho | Kd | Kv | Kild | Kilv | note |
|---|---|---|---|---|---|
| 0.04959 |  121.65 -> 108.37 (-11%) |  59.66 -> 57.06 (-4%) |  90.00 -> 68.76 (-24%) |  65.12 -> 46.03 (-29%) | bulk only, lower bound |
| 0.10000 |  63.18 -> 78.75 (+25%) |  36.46 -> 42.79 (+17%) |  64.12 -> 59.61 (-7%) |  41.64 -> 35.07 (-16%) |  |
| 0.15700 |  38.61 -> 55.90 (+45%) |  20.54 -> 27.67 (+35%) |  30.74 -> 35.18 (+14%) |  20.85 -> 24.17 (+16%) |  |
| 0.20000 |  35.10 -> 38.77 (+10%) |  21.38 -> 22.86 (+7%) |  33.71 -> 24.42 (-28%) |  21.55 -> 15.96 (-26%) |  |
| 0.31300 |  21.09 -> 23.54 (+12%) |  13.55 -> 15.43 (+14%) |  18.02 -> 13.65 (-24%) |  12.13 -> 10.27 (-15%) |  |
| 0.45000 |  11.52 -> 14.77 (+28%) |  8.02 -> 10.62 (+32%) |  12.61 -> 9.97 (-21%) |  9.44 -> 6.82 (-28%) |  |
| 0.60000 |  9.39 -> 9.95 (+6%) |  6.46 -> 8.14 (+26%) |  6.97 -> 7.03 (+1%) |  6.33 -> 5.15 (-19%) |  |
| 0.75000 |  4.75 -> 8.42 (+77%) |  3.61 -> 5.89 (+63%) |  4.32 -> 4.19 (-3%) |  4.37 -> 3.43 (-21%) |  |
| 0.90027 |  3.69 -> 6.39 (+73%) |  2.86 -> 3.74 (+31%) |  3.22 -> 2.37 (-26%) |  2.88 -> 2.11 (-27%) | old clamps here |

- **Largest change:** Kd +77 % at 0.75. The cut layer governs there: cut 8.42 against bulk 4.62.
  - PR 259 measured cut cells only at 0.20, 0.313 and 0.60, so its 0.75 and 0.896 rows were bulk or free-surface only.
  - Part of the high-rho rise is therefore the 11-09 recipe (cut cells at every rho), not the geometry.
- **By column:** Kd and Kv rise at every row but the floor (Kd +6 to +77 %, Kv +7 to +63 %). The interlayer pair falls at most rows (Kild -28 to +14 %, Kilv -29 to +16 %).
- **Effect on the margin:** the strut margin goes as 1/(Kd·vm + Kv·|p|). With the new rows a deviatoric strut margin falls by up to 44 % (at 0.75), typically 10-30 %. Interlayer margins mostly rise.

## Files
- Outputs: `octet_full/` (all CSVs and logs), `fcc_control/`, `kOctetStrutLaw_new.txt`, `cmp_rows.md`.
- Inputs: `probe_octet_full.cpp`, `probe_octet_full.diff`, `run_octet.sh`, `build_lib.sh`.
- The bulk-only spot measurement from earlier is in `full_octet_bulk_vpc48.csv` and `full_octet_bulk_vpc64.csv`.
