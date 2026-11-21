# 2026-08-25, second overnight round — his rulings wired, the mush explained, the sample rebuilt

Every claim below was verified ON THE SIMULATOR per his standing rule, on the
stepped test copy ("M2 verticalStand", the card with the Optimized badge),
with the installed binary hash-checked after every build. App log DIAG lines
are quoted where they are the receipt.

## Shipped and sim-verified

### 1. Ruling A — per-spot cell = min(prism depth, local wall), both directions
`steppedCellField` re-fits every painted cell to ITS OWN material: thinner
wall → its own smaller cell; wall at/past the declaration → the cell GROWS to
span it (his corner rule), `/ the per-voxel floor` in structural. Far cut
flush by construction. Stepped only. In-sim receipt (single-cell, Auto):
`sizes=[10.31=217 12.00=114 12.03=83 13.00=114]` — 114 cells grew to the
declared 12.00 on face 15, 114 to 13.00 on face 2, zero sliced back band.
The tiling phase is ONE implementation (`LatticePreviewOccupancy.tilingPhase`)
used by the per-region encoder and the per-cell bake — exact at any ratio.

### 2. The dyadic flash — root cause found, closed
Every lattice wrapper wrote `latticeLayer?.x = v`; on the frame where the
layer didn't exist yet the write silently dropped, so a FRESH layer's first
bake ran with empty stepped cells and baked the DYADIC LADDER as current.
That was the wrong-algorithm flash on every layer rebuild. The host now
stores desired state and REPLAYS it before the first bake; belt-and-braces,
a stepped scene with missing cells now bakes NOTHING (stays hidden) rather
than the wrong algorithm. In-sim: zero `stepped NOT RUN` lines across the
whole night's arming/edits (was 2 per change), bakes per change 4 → 2.

### 3. The load time
The bake built its candidate array three times and ran the in-plane BFS
twice more than needed (the DIAG block re-ran the whole sweep to print two
numbers). Fixed. Remaining known waste: TWO full bakes per change (two
update passes ~9 s apart on arming) — one more session should coalesce them.

### 4. The 5%→43% "density does nothing" — diagnosed, three parts
* The dial WORKS end-to-end (proved offline by `LatticeStatedDensityDeliveryProbe`
  and in-sim: 43→90 % moved mass 115→240 g and strut 1.86→2.30 mm).
* What made it LOOK dead: (a) 63 % of all cells sat in the 10 mm shape-fit
  band at 1.7–3 mm sizes with printability-LIFTED density the dial cannot
  move — the picture was mostly band; (b) the visible radius change on the
  remaining cells is ~2 px at his zoom.
* The cure is his own new options (below) — under No grade the dial owns the
  whole wall, visibly.
* NOTE: his stored 43 % on face 15 was found CLEARED to Auto at 05:28 (cause
  not yet pinned — watch for recurrence). The "massive holes at 5 %" picture
  is the same band story: interior struts at ~0.7 mm at Fast·64³ wash out
  while the lifted band stays — with No grade at 5 % the wall now draws
  uniform thin struts instead of holes.

### 5. The grading options (his request), shipped and sim-verified
* `LatticeGradingMode` full / fitShape / none + `LatticeGradeStepStyle`
  stepped / dyadic, wire-hygienic (absent unless moved). Settings-page
  "Grading" row under the Stepped transition (stepped algorithm only, per
  his scoping).
* The per-face CELL dial: "Cell · Auto · N mm" directly above Density in the
  face drawer, visible ONLY under the two new modes (his follow-up), typed in
  mm, 0 clears to Auto, stored per selectable. A stated cell is honoured as
  stated — capped per voxel at min(declared, local wall), never divided by
  the floor, write-clamped at the declared depth.
* In-sim receipts: No grade → `n=[n1=528]`, sizes only the four full-depth
  values, rim still baked (`solidRim=24`); typing 6 → `stated=[6.0, …]`,
  964 cells at 6.00; 0 → back to Auto. The wall reads as a clean open truss.
* Left ON the test copy: gradingMode = No grade (deliberate — it is the look
  he was chasing; two taps back to Full).

### 6. The stepped sample, rebuilt and iterated ON SCREEN (three rounds)
Cell-granular centre-and-shell (nothing clipped, every interface node
shared, per-grade strut radii), a cutaway quarter so the coarse centre is
actually VISIBLE (a full shell hid the one thing the sample shows), block
struts drawn at ≤ 0.35 density display-only (his stored max = 1.0 drew the
sample as a fused quilt), and the tris label now counts the mesh on screen
(it was a uniform-block prediction that read 118,920 whatever was drawn —
that lie cost an hour). Verified k=1 and k=2 on the settings page.

## Open for his desk

* **Preview ↔ run parity (his GO)** — scoped, not shipped: core's run derives
  its own per-region stepped cells in `run_stepped_step`
  (core/src/cli/run_job.cpp ~3511) and the region schema accepts no cell key
  (job.cpp:1262). Parity = teaching that function the preview's law
  (median-wall never-overshoot fit; per-spot min(depth, local wall) both
  ways; user-stated cells; grading modes) or emitting per-region cells into
  the job (schema + generator). Hours of core work + xcframework rebuild +
  print-worthy verification — wrong thing to rush at dawn after this much
  change; it deserves the next session's full attention.
* The "Auto · N mm" display reads the card's derivation (12.00) while the
  bake states the never-overshoot walk's 10.31 — unify the display on the
  bake's number.
* Two bakes per change remain (see 3).
* Rim: seeded and drawn (24 cells) but ~1.7 mm — his width call stands.
* The wizard "In the part" entry rebuilds the sample twice.
* `steppedFinestPrintableCellMM` cannot terminate if a band ceiling of 1.0
  ever reaches it (rhoStar is capped at 1) — unreachable for certifiable
  topologies, live for preview-only ones. Defensive break worth adding.
