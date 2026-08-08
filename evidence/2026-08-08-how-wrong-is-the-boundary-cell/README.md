# evidence — 2026-08-08-how-wrong-is-the-boundary-cell

Handoff: `docs/handoffs/2026-08-08-how-wrong-is-the-boundary-cell.md`

The question: the certificate reads ONE number, the peak per-voxel von Mises, and
`margin.in_plane = yield / peak`. A boundary voxel holds its material smeared
uniformly across the cell. Is the coarse cell's peak the peak of the object the
certificate describes?

Everything here is on worker job `ca62f91cba4b422d` — the maintainer's own
`M2_verticalStand.step` run, `run_info` fingerprint `d9fe8f768331`, resolution
128, four rungs (vf 0.68 / 0.52 / 0.38 / 0.26). It is the only job carrying that
fingerprint with a complete four-rung `design.bin`; the other five are partial.

## The instrument

| file | what |
|---|---|
| `../../core/tests/harness/boundary_cell_probe.cpp` | the probe. `EXCLUDE_FROM_ALL`, not a ctest. Re-solves one stored variant at N× the run's resolution through `production_loadcase_from_job` → `build_production_loadcase` → `analyze_fixed_design` and reports everything the gate reads, split boundary/interior. Two modes — `replicate` (only the element size changes; **the reference**) and `retag` (the whole job re-discretized, load case included). |
| `s1_run.sh` | the sequential batch: both modes, four rungs, 1× and 2×, plus the R2 repeats. One process per solve, so no solve inherits a Krylov recycle space from the one before it. |
| `s1_table.py` | turns `s1_refine.csv` into the tables the handoff quotes, with the reference's own noise printed beside every difference (R2). |
| `field_census.py` | the design-field census: how much of the boundary is actually *smeared*, per rung, on the design's own lattice. |

## The measurements

| file | what |
|---|---|
| `s1_refine.csv` | one row per solve — the raw table everything else is derived from. |
| `raw_<mode>_rung<N>_r<R>[_repeat].txt` | each solve's full console output plus `/usr/bin/time -l` (peak RSS). |
| `S1_field_census.txt` | the grey-versus-binary census of `design.bin`, per rung, boundary / interior / interface band. |
| `S1_tables.txt` | `s1_table.py`'s output: the gate table, the surface/interior split, R2's noise, R4's cost. |
| `S2_cut_population.txt` | what a cut-cell scheme would actually have to integrate on this design, measured rather than assumed. |

## The bars

| file | bar |
|---|---|
| `R1_byte_identity.txt`, `r1_byte_identity.sh` | R1 — `topopt-cli` byte-identical to the merge base, with a **negative control** arm proving the comparison can see a change. |
| `R6_assertion_census.txt`, `assertion_census.sh` | R6 — assertion-message census plus the deleted-test sweep over this branch's own diff. |
