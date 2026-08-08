# evidence — reference-implementation-bakeoff (2026-08-09)

Task: **run HIS part through somebody else's maintained topology-optimisation and
implicit-lattice software, and measure the output with OUR instruments.** Five
methods have been refused (PR 299 Taubin, 303 SDF/RBF, 314 mean-curvature flow,
315 morphological closing, 319 SEMDOT) and every one of them was our own
implementation of someone else's idea. Nothing is built here; nothing in
`core/src`, `core/include` or `app/TopOptKit/Sources` changes.

Handoff: `docs/handoffs/2026-08-09-reference-implementation-bakeoff.md`.

Machine of record: Apple M2 Pro (10 cores), 16 GB, macOS 26.5.1 (Darwin 25.5.0),
Apple clang, core library Release. Julia 1.12.6 (arm64). Contention during each
timed run is recorded in `host_contention.txt`.

**Neither third-party library is vendored into this repo** (bar R6). Both were
cloned into the session scratch directory
`/private/tmp/claude-501/.../scratchpad/refimpl/`, and the exact commits are
recorded in `third_party_commits.txt`. `reproduce.sh` re-clones them.

## the problem, and the run it is compared against

| file | what |
|---|---|
| `job_simp.json` | PR 319's SIMP arm of record — his own captured job document with the `lattice`/`grading` blocks removed. THE SAME DOCUMENT, so the comparison is against a measured row and not a remembered one. |
| `M2_verticalStand.step` | his part (sha256 identical to PR 303/307's copy) |
| `s2_simp_baseline/` | PR 319's SIMP run: `design.bin` (14 MB), `loadcase.json`, `run_info.json`, `iterations.csv`, carried from the **unmerged** branch `claude/semdot-optimizer-smoothness-9b8184`. ★ **This is a DUPLICATE and it is deliberate**: every measurement here reads that `design.bin`, and copying it keeps this task reproducible without checking out somebody else's unmerged branch. When PR 319 merges, this directory can be deleted and the paths in `reproduce.sh` pointed at `evidence/2026-08-08-semdot-does-it-come-out-smoother/s2_simp/` instead. |
| `baseline_pr319_*.csv` | PR 319's committed geometry and cost tables, carried unchanged |

★ **The brief's fingerprint is not this run's.** The brief names `d9fe8f768331`
and 33.36 N; the four rungs every measured row in PR 299/303/306/314/315/319
stands on come from the 22.24 N capture. `s1_premise_corrections.txt` sets out
what matches (face 18, the 22 load faces, 5,165 tagged voxels, face 16 with
10,554 frozen) and what does not, and why the 22.24 N run is the only one that
can be compared.

## S1 — his problem, in a portable form

| file | what |
|---|---|
| `s1_portable_problem_export.txt` | the exporter's full output, including the counts that are its positive control |
| `s1_problem.json` | the scalars a consumer needs: grid, spacing, origin, node ordering, material, ladder, counts |
| `s1_positive_control.txt` | those four counts against the run of record's own `loadcase.json`, field by field |
| `s1_fidelity_losses.txt` | ★ every constraint that does NOT survive the crossing, with the reason |
| `s1_premise_corrections.txt` | three places the brief's numbers do not match the record |

Probe: `core/tests/harness/portable_problem_export.cpp`. It calls
`build_production_loadcase` — the production builder both front-ends call — so
the voxel tags, the clamped DOFs and the nodal loads are core's own rather than
a re-derivation in Julia.

## S2 — GridapTopOpt.jl

| file | what |
|---|---|
| `s2_build_and_install.txt` | ★ the Apple-Silicon question, answered: what was installed, what it cost, what broke |
| `his_part_ALM.jl` | the driver — their `3d_elastic_compliance_ALM.jl` with the domain, the boundary conditions and two mask factors changed, and **no analytic shape derivative** |
| `s2_reference_impl_vs_simp.csv` | the geometry table, every arm, every rung |
| `s2_surface_probe.txt` | the probe's full output, every arm and every control |
| `s2_surface_probe_simp_only.txt` | the same probe on the SIMP baseline alone — the R2 control's input |
| `s2_cost.csv` | compliance, achieved vf, and **iterations and wall SEPARATELY** (R4), plus the two constraint controls (solid outside the part; pad interior held) |
| `s2_from_scratch_timing.log` | the 277.7 s/iteration measurement §S2.4 rests on |
| `s2_sdf_arm.log`, `s2_controls.log` | the four-rung SDF arm and the η sweep / no-reinit controls |
| `edt.jl` | the exact Euclidean distance transform. ★ This is §S4c's "smallest useful step" in ~40 lines |
| `verify_labelling.jl`, `s2_labelling_control.txt` | ★ the control for the one library function that had to be replaced — same dofs, same free-dof-to-node maps |
| `diag_reinit_full.jl`, `diag_scale.jl`, `diag_edt.jl`, `diag_init.jl`, `s2_initial_field_diagnosis.txt` | ★ why the initial level set is what it is — the configurations that make their reinitialiser return NaN, measured rather than guessed |
| `r2_reproduces_pr319.py`, `r2_reproduces_pr319.txt` | R2 — this task's SIMP rows against PR 319's committed CSV |

Probe: `core/tests/harness/external_field_surface_probe.cpp`. It **includes** PR
299's `stairstep_metric.hpp` and PR 306's `surface_instruments.hpp` and uses PR
307's `attribute_to_cad_faces` — it retypes none of them (bar R2).

## S3 — PicoGK

| file | what |
|---|---|
| `s3_graded_lattice.txt` | ★ ALL of S3 in one file: §a what it took to install and build, §b does the thickness vary continuously and what happens at the transitions, §c what PicoGK holds in memory / writes / exports against his 102,972,348 triangles, §d where the certificate would have to sit |
| `s3_lattice_Program.cs` | the program. The whole of the new code is `FieldBeamThickness`, twenty lines |
| `s3_dump_von_mises.py` | his von Mises field out of a `fields.bin`, so the grading has something that actually varies to grade on |
| `s3/*.log` | the seven runs: two drivers, three cell sizes, three voxel pitches |
| `s3/*_grading_profile.csv.gz` | 2000 thickness samples along each of two axes per run — the continuity reading |

## the bars

| file | bar |
|---|---|
| `r1_no_production_change.txt` | R1 — `git diff main -- core/src core/include app/TopOptKit/Sources` is empty, with the command |
| `r2_reproduces_pr319.txt` | R2 — our instruments, included not retyped, 96 fields compared |
| `r5_what_could_not_be_done.txt` | R5 — every failure, at full size |
| `third_party_commits.txt` | R6 — what was cloned, where, and at which commit |
| `ctest.txt` | the core suite. **Local denominator note**: this worktree's CMake cache has `lib3mf_DIR-NOTFOUND`, so the lib3mf-gated tests do not register and the local total is BELOW CI's. The file records both numbers. |
| `host_contention.txt` | the host, and what else was on it during each timed run |
| `reproduce.sh` | regenerates all of it. Clones both libraries into `$SCRATCH` (default: outside the repo) and does NOT vendor them. The ~100-minute sequential arm is not run by default. |
