# evidence — strut-clip-matches-shell (2026-08-08)

Task `2026-08-08-strut-clip-matches-shell`. Handoff:
`docs/handoffs/2026-08-08-strut-clip-matches-shell.md`.

Branch `claude/strut-clip-shell-mismatch-9a4ee3`, branched from `966ffa6`
(`main`, PR 312).

## The run everything on the maintainer's part is measured on

His captured job document + `M2_verticalStand.step` at resolution 128, four rungs
`[0.68, 0.52, 0.38, 0.26]` — reused VERBATIM from
`evidence/2026-08-07-lattice-recipe-not-triangles/job_his_2mm_skinnone.json`,
including that task's two forced deviations (`skin: "none"` instead of `"rim"`,
and `grading.cell_min_mm: 2.0` instead of his `4.6026…`). Both are stated and
justified there; neither is a choice made by this task, and neither touches the
surfaces this task is about.

**The comparison is BEFORE vs AFTER on identical inputs**, from two binaries
built out of one folder that are asserted to differ by sha256 before anything is
compared (`r3_his_run.txt` header). "BEFORE" is this branch with exactly two
lines disarmed — the `set_shell_base` call and the protrusion refusal — so the
MEASUREMENT is present on both sides and the only thing that moves is the
surface the struts are clipped against. That is the only way to get a "before"
protrusion number at all: the measurement is part of this change.

## Files

| file | what |
|---|---|
| `s1_probe.txt` | **S1/S2, the whole table** — output of `core/tests/harness/strut_clip_shell_probe.cpp` on a convex-edge fixture at his 1.705 mm voxel |
| `s1b_surface_gap.csv` | **the mechanism, as a number** — the isosurface's inset below the voxel-cube boundary as a function of distance to the nearest convex edge. Zero beyond half a voxel. |
| `s1_protrusion.csv` | the protrusion under each clip and against each shell, with what each candidate fix costs in lattice volume, mass, latticed voxels and generator time |
| `r2_red.txt` / `r2_green.txt` | **R2** — the fixture failing first (4 failures, 2880 protruding vertices at 0.178444 mm), then passing |
| `r1_byte_identity.sh` / `r1_byte_identity.txt` | **R1** — byte-identity with no lattice present, both binaries rebuilt from one folder, with a latticed positive control that must DIFFER |
| `r3_his_run.py` / `r3_his_run.txt` | **R3 + R4** — the no-protrusion invariant per variant on his own run, the full gate table, and the voxel-classification flips against a same-file negative control |
| `r5_mesh_integrity.py` / `r5_mesh_integrity.txt` | **R5** — connected components and isolated fragments at the job's own 0.45 mm line width, before vs after |
| `assertion_census.sh` / `r6_assertion_census.txt` | **R6** — message census over test assertions, registered ctests and production refusals |
| `ctest_full.txt` | both CI jobs run locally — the full core suite (115/115; CI's denominator is 114 plus this task's `lattice_clip_shell`, and the lib3mf-gated tests DID register) and the app package (1367 tests, 0 failures) |
| `receipts_before/`, `receipts_after/` | the four lattice receipts + `run_info.json` from each side of his run — the raw source of the R3/R4 tables, so every number above can be re-derived without re-running anything |
| `job_his_2mm_skinnone.json` | the job actually run |

## The one thing to read first

`s1b_surface_gap.csv`. The maintainer said the lattice creeps out **on edges and
never on flat surfaces**. That column is his sentence:

```
distance to the nearest convex edge     max isosurface inset below the cube union
  < 0.25 voxels                           0.984382 mm
  < 0.50 voxels                           0.393753 mm
  < 1.00 voxels                           0.000000 mm
 >= 2.00 voxels                           0.000000 mm
```
