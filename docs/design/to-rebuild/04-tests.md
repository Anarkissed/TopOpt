# TO rebuild: the tests

Two kinds. **Repo tests** use made-up shapes with known answers and run anywhere. **The reference table** runs his real parts from his own job files, read in place on his Mac, never copied into the repo; it is the gate for every stage. Tests never dirty tracked files.

## Repo tests (new unless marked)

| id | checks | passes when | rule | stage |
|---|---|---|---|---|
| A | exported surface of known shapes: walls tilted 11, 18, 27, 45 degrees and on (1,2,3); round holes of 5 and 10 mm radius; a sphere | worst distance to the true shape at most 0.05 mm at a 1.7 mm voxel | 9 | 0 (written, failing today by design: ledger C-1 measures 0.2 mm), 3 (passes) |
| B | drawn faces after export, with `measure_flats` / `measure_bores` (exists) | flats within 0.02 mm; bores round within 0.02 mm and true to diameter | 9 | 3 |
| C | loaded and anchored area | within 2 % of the drawn face's area at 6 resolutions and 3 grid offsets; total force unchanged | 6 | 1 |
| D | protection and pad depth | equals the typed mm within a tenth of a voxel at 3 resolutions | 3 | 1 |
| E | the strength number against known stress: a plate with a hole pulled along an axis tilted to the grid (peak is 3x the far stress), a thick ring under pressure | within 5 % of the textbook value; and the same part at 4 resolutions agrees within 10 % | 5 | 0 (written), 2 (passes) |
| F | ripple: a known smooth design exported and band-filtered at 1 to 10 mm | at most 0.05 mm | 9 | 3 |
| G | thinnest wall of the exported mesh | at least 0.9 mm everywhere outside drawn features | 10 | 4 |
| H | the five print checks on made-up parts built to fail each one | each bad part is refused with its own plain reason | 11 | 4 |
| I | sealed pockets and drain | a design with a sealed pocket is caught; a lattice void with no way out is refused | 20 | 4 |
| J | the file is one clean solid (case (k) exists from the X-05 fix) | no edge shared by more than two triangles, no point contacts | 18 | 3 |
| K | same job twice, and after any unrelated solve | identical bytes | 21 | 0 |
| L | order of events sent to the app | no version event before its file check; one accept verdict per version | 13 | 1 |
| M | pure moves (stage 0 split, later deletions) | outputs byte-identical before and after on two jobs | 21 | 0, 10 |
| N | generative on a made-up bracket with a known lightest answer | every scenario at or above the target; printed grams no more than the bracket search's | 1, 2 | 6 |
| O | lattice modes on a made-up block | the lattice engine's own strength check passes; one solid; every difference from the placement is listed | 17 to 20 | 7, 8 |
| P | Release run time of two fixed jobs | no stage slows them by more than 10 % unless its report says so | 23 | every |

## The reference table (every stage, before and after)

Parts: 2040 Extrusion Stand (original, v2, v3, v4), Base, Pressing Plate Mount, Top Motor Mount, PillowBlock stands, WallMount (growth). One row per part and setting:

- stair-step: worst and RMS distance from a fitted smooth patch (3 mm), on sloped and curved walls;
- ripple at 1 to 10 mm; curvature bumps per 100 cm2; internal surface area; hole sizes;
- drawn faces: flatness, bore roundness and size;
- thinnest wall;
- margin under every scenario, at two resolutions; printed grams; sealed pockets;
- Release run time, split into solve and the rest;
- one slicer picture, same view every time, beside the previous stage's.

"Today" column: CAD-referenced numbers and the strengthen route are in ledger section L. Stand v2, Stand v3 and WallMount have no "today" row (maintainer, 2026-11-23: "Skip those parts"); they get rows from the first stage that runs them. Slicer pictures of today's parts are skipped (maintainer, 2026-11-25).

## What a stage report contains

The table before and after; which repo tests moved from failing to passing; the open choice it settled, with its three or more settings; anything refused, by rule 24.
