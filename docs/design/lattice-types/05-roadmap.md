# 05 — Build order and branches

**Plain language:** the core agent measures and builds one type at a time and pushes as each is ready. The app agent pulls core in and lights each type up as it arrives. You print a sample block of each new type and tick it off. Nothing waits for a merge to main.

## Who does what

| Step | Who | What | Needs |
|---|---|---|---|
| 0 | Maintainer | Commit this pack, `core/src/materials/lattice_print_tests.json` and the DECISIONS entry to main (one PR). | — |
| K0 | Core agent (PR 358) | Merge main. Write the octet-only inventory (02 §1) before any code. | Step 0 |
| A0 | App agent (PR 354) | Merge main and PR 358 one-way. Rebuild the linked core. Run the suite. Report the probes that flipped. | Step 0 |
| A1 | App agent | Picker driven by core's names; "Not print-tested" tag; greyed-with-reason for everything not live; the octet-only inventory for the app (03 §3). | A0 |
| K1 | Core agent | Strut types, **one at a time** in the R2 order (FCC → Kelvin → Rhombic → Diamond → BCC → SC). Each goes live only when the 02 §4 checklist passes. Push after each. Sample-block CLI. The octet legs-only report (02 §7). | K0 |
| A2 | App agent | For each type core has put live: per-type preview from core's cell, parity tests, per-type modes and reasons. Sync core whenever it pushes. | K1 (per type) |
| K2 | Core agent | `tpms.hpp`; Gyroid, then Schwarz-D: re-measured rows, wall law, generator, floors, checklist. | K1 done or parked |
| A3 | App agent | Sheet preview (raymarch core's field) and parity; one cell per region; Doubled/Stepped greyed with the reason. | K2 (per type) |
| P | Maintainer | For each live type: run `lattice-sample`, print it, and mark it tested in `lattice_print_tests.json` (commit on main). Answer Q1–Q5. | Each type live |

## Branch flow

```
PR 358 (core agent)     ◄── merges main
PR 354 (app agent)      ◄── merges main + PR 358
Flexible (C1 agent)     ◄── merges main + PR 358 + PR 354   (unchanged)
```
- **Merge only**; never rebase or force-push. Updates flow **one way** along the arrows.
- The app agent never edits core. The core agent never edits app. A merge conflict in the other side's files means stop.
- The Flexible agent keeps syncing #354, #358 and main as before. It receives all of this through #354. Its later C2 step reuses `tpms.hpp`.
- **The app agent pushes to PR 354's branch** (`git push origin HEAD:claude/topopt-holes-quilting-298212`).

## Tests (both agents)

- The app's full test suite takes 2–3 hours, so tests are tiered. For each change, build core and the app, run the core suite, and run the app tests covering what changed. Run the full suite once before each handoff.
- Pre-existing failures are listed in the latest handoff on each branch. Anything new must be explained.
