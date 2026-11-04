# Lattice stage, round 6 (2026-10-10): #354's handoff

These are the reviewer's rulings of 2026-10-09 and 2026-10-10, all approved by the maintainer. The
core reference is #358 at 3952c411 (D5, K2, K6 part 1, K1). Evidence:
`docs/handoffs/evidence/2026-10-08-plan-proofs/` (round 6 rows added there).

## Logged for later (no change now)

### Auto's ladder anchor reads the histogram bucket's MIDPOINT (reviewer, 2026-10-10 item 4)

`LatticeMeasuredRegionWidth.ladderBaseCellMM` anchors Auto's dyadic ladder on the part's dominant
member. It takes that member's width as the histogram bucket's midpoint, `(mode + 0.5) × 2 mm`.

**The effect at the job's cap:** the printable floor is 2.25 mm at a 0.45 mm bead, so halving
stops sooner.
- A uniform 20 mm wall reads as 21 mm.
- It anchors at 4.20 mm, over the 4.0 mm that the wall holds five of. Core's planner then plans
  nothing for it.
- Production does not show this. `latticePreviewCellSweep` only takes the per-local-member sweep
  when `ceiling >= base`. Otherwise it falls back to the posture's window (4–4 mm), which is the
  job's own.
- The planner test `LatticePerLocalMemberCellTests.planned` pins the uncapped floor and says why.

**Candidate fix:** anchor on the bucket's LOW edge, or on the measured mode itself.

**Why it is not done:** it would move his ladder (his part's 2.30 / 4.60 / 9.20 mm rungs) without
him seeing it.

### The strip at the back of a partial-depth prism prints EMPTY (core ask, gone to #358 as K3)

This is a plan run on a 14 mm prism whose whole cells stop at 12 mm. The 12–14 mm strip is in
the law's mask, so the companion removes it (run_job.cpp:1968, 6245-6247). No plan cell covers
it, so no struts are laid there. Nothing fills it either: the validator only bounds depth from
above (stepped_plan.cpp:408-409).

The consequences:
- The strip ships as void inside the shell.
- The back node layer stands about 2 mm clear of the solid.
- The certificate credits lattice there (run_job.cpp:7575-7579).

The preview draws air there, which matches today's print. Under K3 the companion becomes
printed-minus-plan-cells. The strip is then solid, and the preview draws it solid behind a probe.

### K6 part 1 numbers only REGION-backed includes

The run sets `declared_region_id` only on the `kind == "region"` branch (run_job.cpp:984). The
face/bolt path pushes its geometry with id 0 (:1009-1026), so faces stay positional.

The app's owner bridge mirrors the run exactly. It keeps the include-count guard until #358 adds
the run-level discriminating test (K7). Ruling 3, 2026-10-10.

### Frozen CLI banner

`topopt-cli` at sync-3952c411 prints `core 30982e5284b2`, which is a stale version string. The
binary is proven by `provenance.txt`, its sha `1538ab06`, and 4 occurrences of `plan_base_cell_mm`
(the 36f5fdde CLI has 0).
