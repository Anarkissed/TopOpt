# evidence — 2026-08-19-peak-stress-convergence

Handoff: `docs/handoffs/2026-08-19-peak-stress-convergence.md`

**The question.** PR 320 measured that the certificate's peak von Mises does not
converge under mesh refinement — `sigma_peak ~ h^-q` with q = 0.4945 then 0.4391,
against 0.4555 for a 2-D re-entrant 90-degree corner — and diagnosed the voxel
staircase. That measurement refined a stored **density field** by replication, so
the staircase survived every rung by construction. The parametric level set now
ships an **analytic phi** beside every variant and the production ersatz is the
**exact volume fraction** of each cell inside `{phi < 0}`. Does the peak converge
on that boundary?

Everything here is on ONE analytic design: worker job `4f8a5fc335a44253`, the
maintainer's own `M2_verticalStand.step` PLSM run at resolution 128, rung 0.68 —
`out/variant_068_alpha.f64` (85,680 float64) plus the `.meta` beside it. Nothing
is re-optimised and no density field is resampled: **phi is re-evaluated on each
grid**, which is what makes every rung the same analytic surface.

## The instruments

| file | what |
|---|---|
| `../../core/tests/harness/smooth_convergence_probe.cpp` | the probe. `EXCLUDE_FROM_ALL`, not a ctest. Rebuilds the knot lattice from the `.meta`, re-evaluates phi on the solve grid, builds the density by `plsm.cpp`'s own `build_fields` + `frac_at` recipe, and certifies through `production_loadcase_from_job` → `build_production_loadcase` → `analyze_fixed_design`. Two modes (`replicate` / `retag`) and three arms (`frac` / `stair_base` / `stair_fine`); the header says why each exists. |
| `../../core/tests/harness/cavity_convergence_probe.cpp` | ★ the POSITIVE CONTROL. A spherical cavity in a bar under uniform uniaxial tension — a KNOWN finite concentration, `K = (27-15nu)/(2(7-5nu))` — through the same ersatz and the same `analyze_fixed_design`. |
| `s1_replicate.sh` | ★ S1, THE CONVERGENCE MEASUREMENT. Load case built once at resolution 96, grid subdivided 1x/2x/3x/4x, three arms. |
| `s2_retag.sh` | S2, the shipped builder run outright at 64…192. Not a convergence measurement — see below. |
| `s3_cavity.sh` | S3, the positive control's ladder. |
| `tables.py`, `s3_table.py` | the fits: pairwise q (PR 320's form) and a global log-log least squares with its R^2 beside it. |

## The measurements

| file | what |
|---|---|
| `s1_replicate.csv` | one row per solve, replicate mode — the raw table S1 is derived from. |
| `s2_retag.csv` | one row per solve, retag mode. |
| `s3_cavity.csv` | one row per solve, positive control. |
| `raw/*.txt` | each solve's full console output plus `/usr/bin/time -l`. |
| `raw/pre_split/` | the first pass, before the peak was split by who owns the cell. Kept because it is what forced the split; see its `NOTE.md`. |
| `raw/pre_stable_gate/` | the second pass, before the distance gate was anchored to the base grid. Kept for the same reason; see its `NOTE.md`. |
| `S1_tables.txt`, `S3_tables.txt` | `tables.py` / `s3_table.py` output. |

## The bars

| file | bar |
|---|---|
| `R6_byte_identity.txt`, `r6_byte_identity.sh`, `r6_build_*.log` | R6 — `topopt-cli` byte-identical to the merge base, with a NEGATIVE CONTROL arm proving the comparison can see a change, and a from-scratch-build guard so it cannot pass vacuously. ★ Its restore trap snapshots `core/CMakeLists.txt` rather than `git checkout HEAD --`-ing it; the version this was adapted from did the latter and silently discarded this task's own uncommitted CMake change on its first run. |
| `R7_assertion_census.txt`, `r7_assertion_census.sh` | R7 — assertion-message census plus the deleted-test sweep over this branch's own diff, against `origin/main` and not a moving head. |
