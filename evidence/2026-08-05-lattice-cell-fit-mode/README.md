# evidence — lattice-cell-fit-mode (2026-08-05)

Handoff: `docs/handoffs/2026-08-05-lattice-cell-fit-mode.md`.

★ **This branch is stacked on PR #298** (`claude/lattice-cell-size-adaptation-7ec715`).
`lattice_derive_cell_for_member`, `lattice_percolation_cells_per_member_min` and the
three-case pre-flight are on that branch, not on `main`. Every `BASE_REF` below is
PR #298's tip, **935a77f479c29fa5cbab92fc41d6c03090000d77** — the only control that
isolates this task's own movement. See handoff §1.

| file | bar | what it is |
|---|---|---|
| `r1_byte_identity.sh` / `.txt` | R1 | four cases: no lattice, graded swept, graded fixed above the rho_min floor (all must be byte-identical), graded fixed below it (deliberately different — the S2 fix) |
| `r2_flip_probe.txt` | R2 | the cell law's own before/after on the same inputs, produced by `core/tests/tools/probe_fit_flips.cpp`; includes the three shipped fixtures this task PINNED, run at their unpinned values |
| `r3_before_after.sh` / `.txt` | R3 | seven 4 mm include regions, graded, at a 0.42 mm bead: base binary under `auto`, branch binary under `auto` (must match), branch binary under `fit` |
| `r4_his_part.sh` / `.txt` | R4 | WallMount_ShelfBracket.stl with seven 4 mm include regions, his loads verbatim. **PARTIAL** — the derivation and the analyze path are measured; the three-rung optimize did not finish on this machine, and the file says so |
| `r5_percolation.py` | R5 | connected components and isolated-component count on an emitted STL, at the RUN's own `wall_line_width_mm` read from `run_info.json` (never a literal, never a strut radius) |
| `r6_cost.sh` / `.txt` | R6 | iterations and wall, separately: one 12 mm region so BOTH modes run, asserting the solver iterations are identical and only generation moves |
| `r7_test_suite.txt` | R7 | the full core suite, before and after the one fixture pin, plus the re-run after the final code change |
| `analyze_path_fit.txt` | — | `fit` through the ANALYZE call site on his part (a unit test on `grade_lattice` exercises none of the three call sites) |
| `s3_seam.sh` / `.txt` | S3 | two abutting regions with different derived cells: what the emitter produces at the seam, measured. Also carries the **R5 result: 1 isolated component, not 0**, located and attributed |

Reproduce (from the repo root, with a Release build in `core/build`):

```
export BASE_REF=935a77f479c29fa5cbab92fc41d6c03090000d77
cmake --build core/build --target topopt_cli probe_fit_flips test_grading
evidence/2026-08-05-lattice-cell-fit-mode/r1_byte_identity.sh core/build /tmp/r1
evidence/2026-08-05-lattice-cell-fit-mode/r3_before_after.sh  core/build /tmp/r3
evidence/2026-08-05-lattice-cell-fit-mode/r4_his_part.sh      core/build /tmp/r4 64
evidence/2026-08-05-lattice-cell-fit-mode/r6_cost.sh          core/build /tmp/r6
evidence/2026-08-05-lattice-cell-fit-mode/s3_seam.sh          core/build /tmp/s3
./core/build/probe_fit_flips
```

★ **The CMake target is `topopt_cli` (underscore); the binary is `topopt-cli`
(hyphen).** `--target topopt-cli` finds an existing file, declares it up to date and
builds nothing. Every script here asserts the base and branch binaries **differ**
before comparing a single artifact.
