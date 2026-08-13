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

## ★ THE MONITORING DEFECTS, RECORDED

Six flaws in this run's own safety net, every one found by a layer firing (or
conspicuously not firing) rather than by inspection:

| # | flaw | consequence |
|---|---|---|
| 1 | `pgrep -c` does not exist on macOS | heartbeat reported blanks |
| 2 | stall measured the STATUS FILE, static for hours during a long step | false alarms, and learned indifference to them |
| 3 | Monitors given 1-hour timeouts on multi-hour runs | coverage expiring before the thing it watched |
| 4 | watchdog stood down on the FIRST completion marker | the critical re-run left unguarded |
| 5 | heartbeat v1 did the same | same |
| 6 | heartbeat v2 did the same again, one marker later | same |

★ 4, 5 and 6 are ONE defect implemented three times. The rule was stated after
the fourth and still implemented per-marker twice more. The structural fix is to
key on PROCESS LIVENESS — "any driver alive" — which survives adding another
driver without remembering to re-arm anything.

THE RULE, in the form that would have prevented all six:
  a monitoring layer must key on the WORK STILL RUNNING, OUTLIVE it, and measure
  the WORK rather than the PAPERWORK.
