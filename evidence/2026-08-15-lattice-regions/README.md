# evidence — 2026-08-15 lattice regions

★ **THIS DIRECTORY IS THIN, AND THAT IS THE REPORT.** The mechanism is built and
unit-tested; the bars that need production runs were not reached. See §0 of the
handoff, which marks every answer MEASURED or NOT.

| file | what it is |
|---|---|
| `subset_ctest.txt` | The lattice/job/clearance `ctest` subset after the R3 fix: **8/8 passed** (1571 s), including `cli_demo`, `lattice_variant` and `lattice_hookup` — the paths the resolver's new `(model, grid)` parameters and the mask branch run through. The FULL suite has not been re-run. |
| `r7_assertion_census.txt` | **R7** — assertion census against `726160c` (PR 331's head, this task's baseline). No category fell. |

## What is asserted, and where

* `core/tests/unit/test_lattice_region_mask.cpp` — 34 checks. The mask branch of
  the one membership predicate; the mask answering in its OWN grid; the exact
  cell-box tests that replace the Lipschitz bound; **bar R5**, protection and
  lattice selecting the same voxels at four declared depths; and two sectors of
  one face at different depths selecting different, disjoint sets.
* `core/tests/unit/test_face_region.cpp` — 68 checks, unchanged from PR 331.

## What is NOT here

* **R1** byte-identity on a job with no region-backed lattice region.
  Reuse `evidence/2026-08-14-face-regions/r1_r2_byte_identity.sh` with
  `726160c` as the base — it already separates the design set from the receipts.
* **R2** CAD error / attributed share re-proven on this branch.
* **R4** the demonstration on `M2_verticalStand.step`: grid-split a curved
  feature, different depths per sector, per-sector latticed voxels and derived
  cell/density/strut against the last real run's 13,034 / 12% / 507 g.
* **R6** the cost of the mask-backed predicate against the geometric one.
