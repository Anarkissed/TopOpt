# Lattice types round 3: the maintainer's rulings and their status

Kept in the repo so a session restart cannot lose it. Round 2 (efa8f81b) was accepted on
2026-10-03: rulings (a)–(5), both crash fixes, CoreBuildIdentity, core's readiness words.

Every item lands as its own commit, with RED controls and stage hashes after it (round 2's tools:
`../2026-10-02-lattice-types-round2/tools/`). The full suite runs before the handoff; then push to
PR #354's branch.

## Core

#358 is still at 23e6154e (includes 4764ca7e); main f932266f is already in. Nothing new to merge.

## Rulings and status

| # | Ruling (2026-10-03) | Status |
|---|---|---|
| G | **No core exception ever crosses the bridge.** Every bridge.cpp function that calls core wraps its body through ONE helper: `std::exception` → the function's invalid/error result carrying `e.what()`; `...` → the same with a generic reason. `lattice_cell_bounds` returns `valid = false` with core's reason. Sweep every bridge function. Gate the stale type before `LatticeBounds.compute`. Red-first: `LatticeStaleTypeTests` passes on core ≥ 4764ca7e; a new bridge test calls each per-type bridge function with sc, bcc, fcc, diamond, kelvin, rhombic, bccz, fccz, reentrant and an unknown id: invalid with core's reason, no crash. | done (see the guard commit): 66/66 declared functions guarded; per-type functions answer only for a live type; G1 + G2; BridgeGuardTests; RED ×3; hashes g = fo |
| 1 | **R1 → (b): core takes the anchor.** #358 is asked for an optional per-region `slot_origin_mm` (absent = today's derived origin). Send it once the key lands. | waiting on #358 |
| 7 | **R7: one owner per cell, by its CENTRE**, never by declaration order: the region whose prism contains the centre owns it; a centre in two prisms goes to the region whose face plane is nearer (the emission's seam mitre); an exact tie goes to the lower region id; cells stay whole. Prove on 68BF7B74: overlaps 1,367 → 0, and the preview changes only in those cells. | open |
| 3 | **Gyroid/Schwarz-D:** keep "Not buildable or strength-checked yet". #358 is asked to treat the round's planned ids as known-not-ready; at that sync read core's words and drop the override. | kept; drop at that sync |
| 4 | **Regions popover: keep it.** Queue a separate task after this round, with its own handoff: move each popover-only ability into the Surface stage (filter-backed union + drift; Small-faces filter with sliders; Dissolve, Undo split, add/drop one face; whole-region grid split, cylindrical, up to 64), screenshot-and-match the Surface stage first, then remove the popover everywhere. | queued: `../../2026-10-03-task-regions-popover-into-surface.md` |
| 5 | **Organic single-size Fit:** send a one-size window (`cell_min_mm = cell_max_mm` = the size), no schema change. The app must never write a job core refuses: a test that core's parser accepts what the app writes; re-pin OrganicMainWiringTests to the accepted form. Report whether preview and run then match. | done: one mapping (`organicCellWindowMM`) for job and preview; OrganicJobsCoreAcceptsTests (core's parser on stage/run/forecast/probe × single/grade/auto/fit); RED on pre-ruling code = core refuses all four single-size documents; hashes o5 = g. Preview-vs-run report: open |
| 6 | **Default Grade switch stays OFF** until #358 lands R2/R3/R5/R6 and the slot origin, and R7 is in. Meanwhile Default Grade and Stepped previews carry one plain line: the run currently builds core's own (coarser) layout. Shown only while the plan isn't sent. | line done: caption "Run builds core's own layout" (sentence behind the (i)), keyed on `LatticeSteppedCellWire.runBuildsCoresOwnLayout` = the job's own `sendsPlan`; RED ×2; hashes l6 = o5. "coarser" left out: 3418E167's planless run laid 2.40 mm cells, finer than the preview's 3.00 |
| N | **One number, one source:** the drawer's "Cell 2.40 mm" and the bake use the same (measured) member width; the preview's printability floor is core's (1.8 vs 4.93 mm on 102117B9) — check a real Structural octet project, report the gap before and after. | open |
| A | **Octree bake:** limit each region's anchor search to its footprint; prove with identical bakes on two projects; before Default Grade is ever switched on. | open |
| B | **Core brief R2/R3/R5/R6 now**, a minimal failing job and a passing control for each, for #358's Stepped work. | open (R6 job to add) |
