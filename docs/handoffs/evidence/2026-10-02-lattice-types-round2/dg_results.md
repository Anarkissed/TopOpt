# Default Grade plan proof: results (ruling 4)

Recorded 2026-10-02 with:
- snapshot S1-2026-10-02;
- the app at 5bf34e18 (R4 fixed; plans OFF in production, forced on through the proof's seam);
- the frozen CLI `linked-19a1443b` (core equal to 19a1443b; it prints fingerprint 1d1bde5e2714).

The procedure is in `README.md` §6–8. The raw outputs are local, in `scratch/evidence/dg/<id>/`.

**Verdict: core refuses the plan on every project. The enable switch stays OFF.**

## Per project

| Project | Kind | Preview plan (core's format) | CLI, plan | CLI, no plan | Run histogram, no plan |
|---|---|---|---|---|---|
| 570B38E2 "DOUBLED test" | **native** Default Grade, aesthetic | 4198 cells / 2 regions: 6.02=125 5.16=543 3.01=2479 2.58=1051 | REFUSED: cell 0 (r1, 2.578 mm) not on its family's tile on x z | ACCEPTED | 12.00=7 |
| 68BF7B74 "M2 verticalStand" | **converted** (stepped → doubled), aesthetic | 10664 / 5: 12.07=11 6.04=108 5.16=852 4.01=2637 3.02=916 2.58=6140 | REFUSED: cell 2637 (r2) not on its tile | ACCEPTED | 6.00=683 |
| 3418E167 "M2 verticalStand THICK" | **converted** (stepped → doubled), structural | 2636 / 2: 12.00=5 6.00=179 4.67=914 3.00=1538 | REFUSED: cell 914 (r2, 3 mm) not on its tile | ACCEPTED | 2.40=3 |
| 92A8016E "l bracket 3" | **converted** ('' → doubled) | 2657 / 1: 1.51=2657 | REFUSED before any work: a grading block is not supported with a design box | REFUSED, the same | — |
| 102117B9 | **converted** (organic → doubled) | PENDING | | | |

- "Run histogram, no plan" is `run_info.json` `grading.cell_levels`: what core lays when it packs for itself. It is nowhere near the preview's on any project. That gap is what the plan exists to close.
- 92A8016E: his ORIGINAL stage job (no conversion; dump f5) is refused by the CLI with the same sentence. The app already refuses that setup before sending it: `LatticeCoreCapability.liveConflict`, used by `WorkspacePlaceholder.latticeDesignBoxConflict`, fires on densityMode sim + an active design box. The refusal is core's and is known; no new defect.

## Every cell, by cause (`tools/classify_plan.py`)

| Project | R1 alignment | R2 depth | R3 cross-region hash | R5 same-region hash | Exact overlaps (same / cross) |
|---|---|---|---|---|---|
| 570B38E2 | 3530 | 0 | 0 | 1458 | 0 / 0 |
| 68BF7B74 | 7164 | 1557 | 1312 | 0 | 0 / **1367** |
| 3418E167 | 1717 | 0 | 0 | 31 | 0 / 0 |
| 92A8016E | 0 | 230 | 0 | 0 | 0 / 0 |

- **R1 (the app's):** one constant in-plane residue per region. Examples:
  - 570B38E2 r1: (1.6647, 0.5443) mod 2.578, for both cell sizes;
  - 3418E167: (2.1035, 4.5);
  - 68BF7B74 r2: (1.5986, 0.5443).

  It is the app's in-plane anchor shift, which the wire does not carry. It needs a ruling: (a) the app drops its anchor search, or (b) core takes a per-region slot origin.
- **R2, R3, R5 (core's):** see `../../2026-10-02-core-brief-default-grade-plan.md`. Each has a minimal failing job and a control in `core-brief-jobs/`.
- **R5 are all false.** The exact check finds 0 positive-volume overlaps on 570B38E2 and 3418E167.
- **R7 (the app's):** 68BF7B74's 1367 cross-region overlaps are REAL. The face-23 facets' 24.15 mm prisms run into both walls, and the plan lists both regions' cells over the same space.
- **The exact check's control:** two cubes that overlap by 1 mm give (0, 1); two that only touch give (0, 0).
